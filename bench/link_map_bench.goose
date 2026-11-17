// LinkMap layout benchmark: what finding a library's state by link costs, and how much memory the table reserves.
//
// A library keeps its own state in a table keyed by `Link` (change `link-keyed-state`). The event loop hands out slots
// for every library at once, so a library with few links can still hold links with high slots. This measures two
// layouts of that table with the same interface, `put`, `find`, `drop`:
//
//   flat     one `T` per slot (up to the highest slot used) and a generation per slot: one load to find a value
//   compact  8 bytes of metadata per slot (generation and cell index packed in a u64) and one `T` cell per live
//            link of the library: two dependent loads to find a value, memory that follows the library's own links
//
// A scenario is (peak, own, placement): `peak` is the number of slots the loop has issued, `own` how many of them are
// this library's, `spread` puts the library's links evenly across the slots (another library holds the rest), `packed`
// puts them at slots 0..own. Three sizes of state: 32, 128 and 512 bytes.
//
// Reported: ns per `find` that touches the value (random order over the library's links, a hit every time), ns per
// `drop` + `put` of a new generation (a connection that closes and one that opens), and the memory the table holds
// (`reserved`: metadata and cells it has allocated).
//
// To measure the real `LinkMap` of the contract package, add a third arm: any type whose `put`, `find` and `drop`
// match (`m.put(link, v)`, `m.find(link) -> T&?`, `m.drop(link)`) can be passed to `run`, with `reserved` filled in.
//
// Run:  goose build bench/link_map_bench.goose -o /tmp/link_map_bench && /tmp/link_map_bench
// (`goose run` compiles at -O1; build uses -O2, which is the figure that matters.)
import std;
import os;

struct Link { slot: u32 = 0, gen: u32 = 0 }

struct S32 { hits: i64 = 0, key: i64 = 0, fill: u8[16] = [0; 16] }
struct S128 { hits: i64 = 0, key: i64 = 0, fill: u8[112] = [0; 112] }
struct S512 { hits: i64 = 0, key: i64 = 0, fill: u8[496] = [0; 496] }

// --- the flat layout ------------------------------------------------------------------------------------------

root struct Flat<T> {
    gens: u32[>..] = [],        // gens[slot] is the generation of the link the value belongs to; 0 means empty
    vals: T[>..]   = [],
}

fn put<T>(m: Flat<T>&, link: Link, v: T) {
    while m.gens.len <= link.slot as i64 { m.gens.push(0); m.vals.push(T { .. }); }
    m.gens[link.slot] = link.gen;
    m.vals[link.slot] = v;
}

fn find<T>(m: Flat<T>&, link: Link) -> T&? {
    guard link.slot as i64 < m.gens.len && m.gens[link.slot] == link.gen && link.gen != 0 else { return null; }
    return m.vals[link.slot];
}

fn drop<T>(m: Flat<T>&, link: Link) {
    guard link.slot as i64 < m.gens.len && m.gens[link.slot] == link.gen else { return; }
    m.gens[link.slot] = 0;
    m.vals[link.slot] = T { .. };
}

fn reserved<T>(m: Flat<T>&, size: i64) -> i64 { m.gens.len * 4 + m.vals.len * size }

// --- the compact layout ---------------------------------------------------------------------------------------

root struct Compact<T> {
    meta: u64[>..]  = [],       // meta[slot]: generation in the high 32 bits, index of the cell in the low 32; 0 is empty
    vals: T[>..]    = [],       // vals[0] is never used, so that index 0 can mean empty
    free: u32[>..<] = [],       // cells that were dropped, to be reused
}

fn put<T>(m: Compact<T>&, link: Link, v: T) {
    while m.meta.len <= link.slot as i64 { m.meta.push(0); }
    if m.vals.len == 0 { m.vals.push(T { .. }); }
    var idx = 0 as u32;
    if m.free.len > 0 { idx = m.free.pop(); m.vals[idx] = v; }
    else { m.vals.push(v); idx = (m.vals.len - 1) as u32; }
    m.meta[link.slot] = ((link.gen as u64) << 32) | idx as u64;
}

fn find<T>(m: Compact<T>&, link: Link) -> T&? {
    guard link.slot as i64 < m.meta.len else { return null; }
    let e = m.meta[link.slot];
    guard (e >> 32) as u32 == link.gen && (e & 0xFFFFFFFF) != 0 else { return null; }
    return m.vals[(e & 0xFFFFFFFF) as i64];
}

fn drop<T>(m: Compact<T>&, link: Link) {
    guard link.slot as i64 < m.meta.len else { return; }
    let e = m.meta[link.slot];
    guard (e >> 32) as u32 == link.gen && (e & 0xFFFFFFFF) != 0 else { return; }
    m.meta[link.slot] = 0;
    m.vals[(e & 0xFFFFFFFF) as i64] = T { .. };
    m.free.push((e & 0xFFFFFFFF) as u32);
}

fn reserved<T>(m: Compact<T>&, size: i64) -> i64 { m.meta.len * 8 + m.vals.len * size + m.free.len * 4 }

// --- the measurement ------------------------------------------------------------------------------------------

let TARGET_OPS = 8000000;       // finds per repetition, about
let REPEATS = 15;               // each figure is the best of this many repetitions (the least disturbed one)

// The slot of the library's i-th link: the first `own` slots, or spread evenly over `peak`.
fn slot_of(i: i64, peak: i64, own: i64, spread: bool) -> u32 {
    if spread { return (i * (peak / own)) as u32; }
    return i as u32;
}

// A fixed pseudo-random order over 0..own, the same for every layout.
fn make_order(order: u32[>..]&, own: i64, n: i64) {
    var x = 12345;
    for k in n {
        x = (x * 1103515245 + 12345) % 2147483648;
        order.push((x / 16 % own) as u32);
    }
}

fn round1(x: f64) -> f64 { (x * 10.0) as i64 / 10.0 }

fn run<M, T>(m: M&, name: const u8[:], size: i64, scenario: const u8[:], peak: i64, own: i64, spread: bool) {
    var links: Link[>..] = [];
    for i in own {
        let l = Link { slot: slot_of(i, peak, own, spread), gen: 1 };
        links.push(l);
        m.put(l, T { key: i, .. });
    }
    // the loop has issued `peak` slots: the highest one is used so the table has the length a real loop would force
    if spread { m.put(Link { slot: (peak - 1) as u32, gen: 1 }, T { .. }); m.drop(Link { slot: (peak - 1) as u32, gen: 1 }); }
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
    let churn = 500000;
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

    print(name, "  ", scenario, "  size=", size, "  find ", round1(find_ns), " ns   drop+put ", round1(churn_ns), " ns   reserved ", reserved(m, size) / 1024, " KiB");
    if sum == 0 { print("(no hit)"); }
}

// Both layouts, each on a table of its own, for one scenario.
fn both<T>(size: i64, label: const u8[:], peak: i64, own: i64, spread: bool) {
    var flat = Flat<T> {};
    run<Flat<T>, T>(flat, "flat   ", size, label, peak, own, spread);
    var compact = Compact<T> {};
    run<Compact<T>, T>(compact, "compact", size, label, peak, own, spread);
}

fn scenarios<T>(size: i64) {
    both<T>(size, "alone   peak=1024    own=16     ", 1024, 16, false);
    both<T>(size, "alone   peak=1024    own=1024   ", 1024, 1024, false);
    both<T>(size, "shared  peak=100000  own=16     ", 100000, 16, true);
    both<T>(size, "shared  peak=100000  own=1024   ", 100000, 1024, true);
    both<T>(size, "all     peak=100000  own=100000 ", 100000, 100000, false);
    print("");
}

fn main() {
    scenarios<S32>(32);
    scenarios<S128>(128);
    scenarios<S512>(512);
}
