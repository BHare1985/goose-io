// goose-io: Deadlines, a bounded min-heap of (time, id) so that a library with many deadlines does not write
// one. The contract keeps no timer table: a library asks for a wake with `tick_by(next_at())` and, on every
// Tick, takes what is due with `pop_due(now_ms)` (docs/contract.md, "Time").
//
//     var d = goose_io::Deadlines { .. };
//     d.add(io.now_ms() + 2000, request_id);
//     io.tick_by(d.next_at());
//     // in the handler of a Tick:
//     loop { let x = d.pop_due(t.now_ms); if !x.found { break; } expire(x.id); }
//     if !d.is_empty() { io.tick_by(d.next_at()); }
//
// Pure Goose, no allocation: the set holds at most DEADLINES_MAX entries, and `add` says when it is full.
// Ties in time are broken by the lower id, so the order is the same on every run.
namespace goose_io;
import std;

let DEADLINES_MAX = 1024;

struct Deadline { at_ms: i64 = 0, id: u32 = 0, found: bool = false }

struct Deadlines {
    len:   i64              = 0,
    items: Deadline[..1024] = [],
}

fn _before(a: Deadline, b: Deadline) -> bool {
    a.at_ms < b.at_ms || (a.at_ms == b.at_ms && a.id < b.id)
}

fn _swap(d: Deadlines&, i: i64, j: i64) {
    let t = d.items[i];
    d.items[i] = d.items[j];
    d.items[j] = t;
}

fn _up(d: Deadlines&, from: i64) {
    var i = from;
    while i > 0 {
        let parent = (i - 1) / 2;
        if !_before(d.items[i], d.items[parent]) { break; }
        _swap(d, i, parent);
        i = parent;
    }
}

fn _down(d: Deadlines&, from: i64) {
    var i = from;
    loop {
        let l = i * 2 + 1;
        let r = l + 1;
        var least = i;
        if l < d.len && _before(d.items[l], d.items[least]) { least = l; }
        if r < d.len && _before(d.items[r], d.items[least]) { least = r; }
        if least == i { break; }
        _swap(d, i, least);
        i = least;
    }
}

fn count(d: Deadlines&) -> i64 { d.len }

fn is_empty(d: Deadlines&) -> bool { d.len == 0 }

// Removes the deadline of `id`. False if there is none.
fn cancel(d: Deadlines&, id: u32) -> bool {
    for i in d.len {
        if d.items[i].id == id {
            d.len--;
            if i != d.len {
                d.items[i] = d.items[d.len];
                _down(d, i);
                _up(d, i);
            }
            d.items.pop();
            return true;
        }
    }
    return false;
}

// Sets the deadline of `id` to `at_ms`; an id that is there already is moved. False, and nothing changed,
// when the set is full.
fn add(d: Deadlines&, at_ms: i64, id: u32) -> bool {
    if d.len >= DEADLINES_MAX {
        // a full set can still move an id it has
        var present = false;
        for i in d.len { if d.items[i].id == id { present = true; } }
        if !present { return false; }
    }
    d.cancel(id);
    d.items.push(Deadline { at_ms: at_ms, id: id, found: true });
    d.len++;
    _up(d, d.len - 1);
    return true;
}

// The earliest deadline, or one with found false when there is none. Does not remove it.
fn earliest(d: Deadlines&) -> Deadline {
    if d.len == 0 { return Deadline { .. }; }
    return d.items[0];
}

// The time of the earliest deadline, or -1: what to pass to tick_by.
fn next_at(d: Deadlines&) -> i64 {
    if d.len == 0 { return -1; }
    return d.items[0].at_ms;
}

// Removes and returns the earliest deadline if it is due at `now_ms`, else one with found false.
fn pop_due(d: Deadlines&, now_ms: i64) -> Deadline {
    if d.len == 0 || d.items[0].at_ms > now_ms { return Deadline { .. }; }
    let out = d.items[0];
    d.cancel(out.id);
    return out;
}
