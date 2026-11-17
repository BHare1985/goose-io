// What it costs to find a library's state by link: the contract package's `LinkMap` against the table a library wrote
// by hand before the tag and the user value went (change `link-keyed-state`), and against a compact layout.
//
//   by-index  the old way, written by hand: one array of {generation, value} indexed by slot, a bounds check and a
//             generation compare (what `_conn_of(user, link)` did, with the slot as the index)
//   linkmap   `goose_io::LinkMap<T>`, the implementation the contract package ships (the same layout, behind
//             `put`, `find`, `has` and `drop`, so the comparison shows what the shipped functions add)
//   compact   8 bytes of metadata for each slot and one value for each link the library owns (a layout a library
//             can write for itself when its state is large on a very busy loop; it is not in the contract package)
//
// A scenario is (peak, own, placement): `peak` is the number of slots the event loop has issued, `own` how many of
// them are this library's, `spread` puts the library's links evenly across the slots (other libraries hold the rest),
// `packed` puts them at slots 0..own. Three sizes of state: 32, 128 and 512 bytes. The last scenario, every one of
// 100,000 slots owned, is the largest the contract allows for one library; it is the worst case for every arm.
//
// Reported, for each arm: ns per `find` that touches the value (random order over the library's links, a hit every
// time), ns per `drop` + `put` of a new generation (a connection closing and another opening), and the memory the
// table has reserved. After each group of arms, `linkmap` minus `by-index`: the overhead of using `LinkMap`.
//
// Time per figure is the best of REPEATS repetitions (the least disturbed one). Small figures vary by a nanosecond or
// two between runs; read a gap of that size as a tie. Run it on the machine that matters, with nothing else busy.
//
// Run:  goose build bench/link_map_bench.goose -o /tmp/link_map_bench && taskset -c 2 /tmp/link_map_bench
// (`goose run` compiles at -O1; build uses -O2, which is the figure that matters. See bench/README.md.)
//
// To measure another table (a library's own), declare it with `put`, `find`, `drop` and `reserved` as below and add
// a `run<YourTable<T>, T>(...)` line to `arms`.
import std;
import os;
import goose_io from "..";

struct S32 { hits: i64 = 0, key: i64 = 0, fill: u8[16] = [0; 16] }
struct S128 { hits: i64 = 0, key: i64 = 0, fill: u8[112] = [0; 112] }
struct S512 { hits: i64 = 0, key: i64 = 0, fill: u8[496] = [0; 496] }

// --- by-index: the table a library wrote by hand ------------------------------------------------------------

struct Entry<T> { gen: u32 = 0, v: T = T { .. } }

root struct ByIndex<T> {
    entries: Entry<T>[>..] = [],
}

fn put<T>(m: ByIndex<T>&, link: goose_io::Link, v: T) {
    guard link.gen != 0 else { return; }
    while m.entries.len <= link.slot { m.entries.push(Entry<T> { .. }); }
    m.entries[link.slot] = Entry<T> { gen: link.gen, v: v };
}

fn find<T>(m: ByIndex<T>&, link: goose_io::Link) -> T&? {
    guard link.slot < m.entries.len else { return null; }
    let e .= m.entries[link.slot];
    guard e.gen == link.gen && link.gen != 0 else { return null; }
    return e.v;
}

fn drop<T>(m: ByIndex<T>&, link: goose_io::Link) {
    guard link.slot < m.entries.len && m.entries[link.slot].gen == link.gen else { return; }
    m.entries[link.slot] = Entry<T> { .. };
}

fn reserved<T>(m: ByIndex<T>&, size: i64) -> i64 { m.entries.len * (size + 8) }       // 8: the generation, padded to the value's alignment

// `goose_io::LinkMap<T>` is measured as it is.
fn reserved<T>(m: goose_io::LinkMap<T>&, size: i64) -> i64 { m.entries.len * (size + 8) }

// --- compact: a layout for a library with large state on a very busy loop --------------------------------------

root struct Compact<T> {
    meta: u64[>..]  = [],       // meta[slot]: generation in the high 32 bits, index of the cell in the low 32; 0 is empty
    vals: T[>..]    = [],       // vals[0] is never used, so that index 0 can mean empty
    free: u32[>..<] = [],       // cells that were dropped, to be reused
}

fn put<T>(m: Compact<T>&, link: goose_io::Link, v: T) {
    guard link.gen != 0 else { return; }
    while m.meta.len <= link.slot { m.meta.push(0); }
    if m.vals.len == 0 { m.vals.push(T { .. }); }
    var idx = 0 as u32;
    if m.free.len > 0 { idx = m.free.pop(); m.vals[idx] = v; }
    else { m.vals.push(v); idx = (m.vals.len - 1) as u32; }
    m.meta[link.slot] = ((link.gen as u64) << 32) | idx as u64;
}

fn find<T>(m: Compact<T>&, link: goose_io::Link) -> T&? {
    guard link.slot < m.meta.len else { return null; }
    let e = m.meta[link.slot];
    guard (e >> 32) as u32 == link.gen && (e & 0xFFFFFFFF) != 0 else { return null; }
    return m.vals[(e & 0xFFFFFFFF) as i64];
}

fn drop<T>(m: Compact<T>&, link: goose_io::Link) {
    guard link.slot < m.meta.len else { return; }
    let e = m.meta[link.slot];
    guard (e >> 32) as u32 == link.gen && (e & 0xFFFFFFFF) != 0 else { return; }
    m.meta[link.slot] = 0;
    m.vals[(e & 0xFFFFFFFF) as i64] = T { .. };
    m.free.push((e & 0xFFFFFFFF) as u32);
}

fn reserved<T>(m: Compact<T>&, size: i64) -> i64 { m.meta.len * 8 + m.vals.len * size + m.free.len * 4 }

// --- the measurement ------------------------------------------------------------------------------------------

let TARGET_OPS = 4000000;       // finds per repetition, about
let REPEATS = 9;                // each figure is the best of this many repetitions

struct Result { find_ns: f64 = 0.0, churn_ns: f64 = 0.0, reserved_kib: i64 = 0 }

fn round1(x: f64) -> f64 { (x * 10.0) as i64 / 10.0 }

// The slot of the library's i-th link: the first `own` slots, or spread evenly over `peak`.
fn slot_of(i: i64, peak: i64, own: i64, spread: bool) -> u32 {
    if spread { return (i * (peak / own)) as u32; }
    return i as u32;
}

// A fixed pseudo-random order over 0..own, the same for every arm.
fn make_order(order: u32[>..]&, own: i64, n: i64) {
    var x = 12345;
    for k in n {
        x = (x * 1103515245 + 12345) % 2147483648;
        order.push((x / 16 % own) as u32);
    }
}

fn run<M, T>(m: M&, size: i64, peak: i64, own: i64, spread: bool) -> Result {
    var links: goose_io::Link[>..] = [];
    for i in own {
        let l = goose_io::Link { slot: slot_of(i, peak, own, spread), gen: 1 };
        links.push(l);
        m.put(l, T { key: i, .. });
    }
    // the loop has issued `peak` slots: the highest one is used so the table has the length a real loop would force
    if spread { m.put(goose_io::Link { slot: (peak - 1) as u32, gen: 1 }, T { .. }); m.drop(goose_io::Link { slot: (peak - 1) as u32, gen: 1 }); }
    var order: u32[>..] = [];
    let n = 65536;
    make_order(order, own, n);

    let rounds = TARGET_OPS / n;
    var sum = 0;
    var find_ns = 1.0e18;
    for rep in REPEATS {
        let t0 = clock_ns();
        for r in rounds {
            for k in n {
                let c = m.find(links[order[k]]);
                if c != null { c.hits += 1; sum += c.key; }
            }
        }
        let ns = (clock_ns() - t0) / (rounds * n) as f64;
        if ns < find_ns { find_ns = ns; }
    }

    // a connection closing and another opening on the same slot, a new generation each time
    let churn = 250000;
    var gen = 2;
    var churn_ns = 1.0e18;
    for rep in REPEATS {
        let t2 = clock_ns();
        for k in churn {
            let i = order[k % n] as i64;
            m.drop(links[i]);
            links[i].gen = gen as u32;
            gen += 1;
            m.put(links[i], T { key: i, .. });
        }
        let ns = (clock_ns() - t2) / churn as f64;
        if ns < churn_ns { churn_ns = ns; }
    }
    if sum == 0 { print("(no hit)"); }
    return Result { find_ns: find_ns, churn_ns: churn_ns, reserved_kib: reserved(m, size) / 1024 };
}

fn show(arm: const u8[:], r: Result) {
    print("  ", arm, "  find ", round1(r.find_ns), " ns   drop+put ", round1(r.churn_ns), " ns   reserved ", r.reserved_kib, " KiB");
}

// Each arm on a table of its own, for one scenario.
fn arms<T>(size: i64, label: const u8[:], peak: i64, own: i64, spread: bool) {
    print(label, "  state ", size, " B");
    var by_index = ByIndex<T> {};
    let a = run<ByIndex<T>, T>(by_index, size, peak, own, spread);
    show("by-index ", a);
    var linkmap = goose_io::LinkMap<T> {};
    let b = run<goose_io::LinkMap<T>, T>(linkmap, size, peak, own, spread);
    show("linkmap  ", b);
    var compact = Compact<T> {};
    let c = run<Compact<T>, T>(compact, size, peak, own, spread);
    show("compact  ", c);
    print("  linkmap minus by-index:  find ", round1(b.find_ns - a.find_ns), " ns   drop+put ", round1(b.churn_ns - a.churn_ns), " ns   reserved ", b.reserved_kib - a.reserved_kib, " KiB");
}

fn scenarios<T>(size: i64) {
    arms<T>(size, "one library, 16 links on a loop of 1,024 slots", 1024, 16, false);
    arms<T>(size, "one library, 1,024 links on a loop of 1,024 slots", 1024, 1024, false);
    arms<T>(size, "shared loop, 100,000 slots, the library owns 16", 100000, 16, true);
    arms<T>(size, "shared loop, 100,000 slots, the library owns 1,024", 100000, 1024, true);
    arms<T>(size, "the largest case: the library owns all 100,000 slots", 100000, 100000, false);
    print("");
}

fn main() {
    scenarios<S32>(32);
    scenarios<S128>(128);
    scenarios<S512>(512);
}
