// The test kit: what the unit and example tests share, so each test file is only its scenarios.
// ("kit" is short for "test kit"; it is not an acronym.) It has
//   check / finish    a failure counter: `kit::check(ok, "what must hold")` prints a failure, `kit::finish()` sets the
//                     exit status;
//   Log / note        an event recorder that works on any provider, with queries over it (kinds_of, data_of, ...);
//   Pair / connect    a listener and a dialled link on one loop, and `track`, which keeps the pair up to date;
//   scenario          which scenario of a test to run (`-- 3`), so a provider that holds one loop per process can.
// The conformance suite has its own, in conformance/support.goose, because it must not import test code.
// Imported from a test as `import goose_io.tests.support.kit;`.
namespace kit;
import std;
import goose_io;
import os;

var failures: i64 = 0;

fn check(ok: bool, what: const u8[:]) {
    if !ok { print("FAIL: ", what); failures++; }
}

// Ends the test program: exit status 1 if any check failed.
fn finish() {
    if failures > 0 { print(failures, " failed"); exit(1); }
}

let OPENED = 1;
let DATA = 2;
let WRITABLE = 3;
let PEER_EOF = 4;
let CLOSED = 5;
let TICK = 6;
let PASS_END = 7;

struct Entry {
    kind:     u8                    = 0,
    link:     goose_io::Link        = goose_io::Link { .. },
    tag:      u16                   = 0,
    user:     u32                   = 0,
    listener: goose_io::Listener    = goose_io::Listener { .. },
    why:      goose_io::CloseReason = goose_io::CloseReason.Error,
    at_ms:    i64                   = 0,
    off:      i64                   = 0, // Data: where its bytes start in Log.bytes
    len:      i64                   = 0,
}

// Everything a handler saw, in order. Ticks are recorded only when `ticks` is set.
root struct Log {
    entries: Entry[>..] = [],
    bytes:   u8[>..]    = [],
    ticks:   bool       = false,
}

fn note<Io>(log: Log&, io: Io&, ev: goose_io::Event) {
    let now = io.now_ms();
    match ev {
        Opened e => { log.entries.push(Entry { kind: OPENED, link: e.link, tag: e.tag, user: e.user, listener: e.listener, at_ms: now, .. }); },
        Data e => {
            let off = log.bytes.len;
            log.bytes.append(e.bytes);
            log.entries.push(Entry { kind: DATA, link: e.link, tag: e.tag, user: e.user, at_ms: now, off: off, len: e.bytes.len, .. });
        },
        Writable e => { log.entries.push(Entry { kind: WRITABLE, link: e.link, tag: e.tag, user: e.user, at_ms: now, .. }); },
        PeerEof e => { log.entries.push(Entry { kind: PEER_EOF, link: e.link, tag: e.tag, user: e.user, at_ms: now, .. }); },
        Closed e => { log.entries.push(Entry { kind: CLOSED, link: e.link, tag: e.tag, user: e.user, why: e.why, at_ms: now, .. }); },
        Tick t => { if log.ticks { log.entries.push(Entry { kind: TICK, at_ms: t.now_ms, .. }); } },
        PassEnd => { log.entries.push(Entry { kind: PASS_END, at_ms: now, .. }); },
    }
}

fn count(log: Log&, kind: u8) -> i64 {
    var n = 0;
    for e in log.entries { if e.kind == kind { n++; } }
    return n;
}

fn count_for(log: Log&, kind: u8, link: goose_io::Link) -> i64 {
    var n = 0;
    for e in log.entries { if e.kind == kind && goose_io::same(e.link, link) { n++; } }
    return n;
}

// Index of the n-th entry (from 0) of a kind, or -1.
fn nth(log: Log&, kind: u8, n: i64) -> i64 {
    var seen = 0;
    for e, i in log.entries {
        if e.kind == kind {
            if seen == n { return i; }
            seen++;
        }
    }
    return -1;
}

// Index of the first entry of a kind for a link, or -1.
fn first_for(log: Log&, kind: u8, link: goose_io::Link) -> i64 {
    for e, i in log.entries { if e.kind == kind && goose_io::same(e.link, link) { return i; } }
    return -1;
}

// The link events of one link as letters, in order: O D W E C.
fn kinds_of(log: Log&, link: goose_io::Link) -> u8[>..] {
    var out: u8[>..] = [];
    for e in log.entries {
        if goose_io::same(e.link, link) && e.kind >= OPENED && e.kind <= CLOSED { out.push(_letter(e.kind)); }
    }
    return out;
}

// Every byte delivered to one link, in order.
fn data_of(log: Log&, link: goose_io::Link) -> u8[>..] {
    var out: u8[>..] = [];
    for e in log.entries {
        if e.kind == DATA && goose_io::same(e.link, link) { out.append(log.bytes[e.off..e.off + e.len]); }
    }
    return out;
}

// The whole log as text, one entry per line: for comparing two runs.
fn text(log: Log&) -> u8[>..] {
    var out: u8[>..] = [];
    for e in log.entries {
        format(out, "t=", e.at_ms, " ");
        out.push(_letter(e.kind));
        format(out, " link=", e.link.slot, ".", e.link.gen, " tag=", e.tag, " user=", e.user, " n=", e.len);
        if e.kind == CLOSED { format(out, " why=", reason_name(e.why)); }
        out.push('\n');
    }
    return out;
}

fn _letter(kind: u8) -> u8 {
    match kind {
        1 => 'O',
        2 => 'D',
        3 => 'W',
        4 => 'E',
        5 => 'C',
        6 => 'T',
        7 => 'P',
        _ => '?',
    }
}

fn is_reason(e: Entry, why: goose_io::CloseReason) -> bool { e.why == why }

// The link has exactly one Closed and it is ConnectFailed of this kind.
fn failed_with(log: Log&, link: goose_io::Link, kind: goose_io::ConnectFailure) -> bool {
    return closed_once(log, link, goose_io::CloseReason.ConnectFailed { kind: kind });
}

fn reason_name(why: goose_io::CloseReason) -> const u8[:] {
    match why {
        PeerClosed => "PeerClosed",
        PeerReset => "PeerReset",
        ConnectFailed f => match f.kind {
            Refused => "ConnectFailed.Refused",
            TimedOut => "ConnectFailed.TimedOut",
            Unreachable => "ConnectFailed.Unreachable",
            Denied => "ConnectFailed.Denied",
            NoResources => "ConnectFailed.NoResources",
            BadAddress => "ConnectFailed.BadAddress",
            Other => "ConnectFailed.Other",
        },
        IdleTimeout => "IdleTimeout",
        HalfCloseTimeout => "HalfCloseTimeout",
        Local => "Local",
        Shutdown => "Shutdown",
        Error => "Error",
        LoopSpecific p => "LoopSpecific",
    }
}

// --- one link with both ends on the same loop ----------------------------------------------------

// Tag 1 is the accepted end ("server"), tag 2 the dialled end ("client").
struct Pair {
    client:    goose_io::Link = goose_io::Link { .. },
    server:    goose_io::Link = goose_io::Link { .. },
    open:      i64            = 0,
    writables: i64            = 0,
    depth:     i64            = 0, // handler nesting, for tests that check it never exceeds 1
}

fn connect<Io>(io: Io&, p: Pair&, address: const u8[:]) {
    let l, err = io.listen(address, 1);
    check(goose_io::is_listener(l), "fixture: listen");
    p.client = io.dial(address, 2, 0);
}

// Records the event and keeps the pair up to date; true when both ends have just become open.
fn track<Io>(p: Pair&, log: Log&, io: Io&, ev: goose_io::Event) -> bool {
    note(log, io, ev);
    match ev {
        Opened e => {
            if e.tag == 1 { p.server = e.link; }
            p.open++;
            return p.open == 2;
        },
        Writable e => { p.writables++; return false; },
        _ => { return false; },
    }
}

// Stops the loop at the first Tick at or after at_ms.
fn stop_after<Io>(io: Io&, ev: goose_io::Event, at_ms: i64) {
    match ev {
        Tick t => { if t.now_ms >= at_ms { io.stop(0); } },
        _ => {},
    }
}

// The reason in the Closed entry of a link, and whether there is exactly one.
fn closed_once(log: Log&, link: goose_io::Link, why: goose_io::CloseReason) -> bool {
    let i = first_for(log, CLOSED, link);
    return i >= 0 && count_for(log, CLOSED, link) == 1 && log.entries[i].why == why;
}

// The scenario a test program was asked to run (`goose run test.goose -- 3`), or -1 for all of them. A
// provider that holds one loop per process (the wrapper) runs one scenario per process.
fn scenario() -> i64 {
    if arg_count() < 2 { return -1; }
    var text: u8[>..] = [];
    arg(1, text);
    var n = 0;
    for c in text { if c >= '0' && c <= '9' { n = n * 10 + (c - '0'); } }
    return n;
}
