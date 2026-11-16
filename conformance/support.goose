// goose-io conformance suite: what every check shares.
//
// A check is a function `c_name<Io>(k: Case&, io: Io&, ev: goose_io::Event)` and a Case it advances. The
// driver calls it once with a synthetic Tick (step 0: start) and then once per event, after `track` has
// recorded the event. A check fails by calling `expect` or `fail`, finishes with `finish`, and the driver
// moves on when the check has finished and every link it made has had its Closed. Every check works with
// at most two pairs of links:
//
//     role 0: a dialled link (pair 0)    role 1: the link a listener accepted for it
//     role 2: a dialled link (pair 1)    role 3: the link a listener accepted for it
//
// Tags are `base + 2p` for the accepted end of pair p and `base + 2p + 1` for the dialled end, so a
// check's events are told from those of an earlier check whose links are still closing.
namespace goose_io_conformance;
import std;
import goose_io;

let RUNNING = 0;
let PASSED = 1;
let FAILED = 2;

let TAGS_PER_CHECK = 4;

// What contract calls cannot produce: an address that never answers a connect, and one that is held.
struct Fixture {
    silent:  const u8[:] = "",   // a dial to it never gets an answer
    held:    const u8[:] = "",   // a listen on it fails with AddressInUse
    refused: const u8[:] = "",   // an address that nothing listens on: a dial to it is refused
    // Optional: an address that still answers while the loop is draining (every listener of the loop has
    // stopped by then, so calls cannot make one). Without it the dial-while-draining part proves only that
    // the dial still ends in exactly one event.
    answers: const u8[:] = "",
}

// One recorded link event.
// Name, requirement and part of one check.
struct Info { name: const u8[:] = "", req: const u8[:] = "", part: i64 = 0, group: i64 = 0 }

// The groups of the contract (design D2) and the marker type of each. The driver is generic over a marker, and the
// functions `step` and `takes` of the suite are overloaded on it, so that a suite for one group compiles only the
// checks of that group (design D5). PENDING and AllGroups are transitional, for the checks not yet assigned to a group
// (tasks 4.2 to 4.4 of the change simplify-contract), and go when every check has its group.
let GROUP_CORE = 0;
let GROUP_HALF_CLOSE = 1;
let GROUP_SIZING = 2;
let GROUP_ABORT = 3;
let GROUP_INSPECTION = 4;
let GROUP_BATCHING = 5;
let GROUP_PENDING = 9;

struct CoreGroup { n: i64 = 0 }
struct BatchingGroup { n: i64 = 0 }
struct SizingGroup { n: i64 = 0 }
struct HalfCloseGroup { n: i64 = 0 }
struct InspectionGroup { n: i64 = 0 }
struct AllGroups { n: i64 = 0 }

struct Rec {
    role:     i64                   = 0,
    kind:     u8                    = 0,    // 'O' 'D' 'W' 'E' 'C'
    at:       i64                   = 0,
    off:      i64                   = 0,    // Data: its bytes in Case.bytes
    len:      i64                   = 0,
    why:      goose_io::CloseReason = goose_io::CloseReason.Error,
    user:     u32                   = 0,
    tag:      u16                   = 0,
    listener: goose_io::Listener    = goose_io::Listener { .. }, // Opened: the listener that accepted it
}

root struct Case {
    id:       i64                = 0,
    base:     i64                = 0,
    step:     i64                = 0,
    verdict:  i64                = 0,
    why:      u8[>..]            = [],       // an owned copy: a slice could not outlive serve
    done:     bool               = false,
    started:  i64                = 0,
    deadline: i64                = 0,
    live:     i64                = 0,        // links of this check that have not had their Closed
    link:     goose_io::Link[4]  = [goose_io::Link { .. }; 4],
    l:        goose_io::Listener = goose_io::Listener { .. },
    l2:       goose_io::Listener = goose_io::Listener { .. },
    old:      goose_io::Link     = goose_io::Link { .. },    // a handle kept to see that it goes stale
    port:     i64                = 0,
    n:        i64                = 0,
    m:        i64                = 0,
    t:        i64                = 0,
    p:        i64                = 0,
    q:        i64                = 0,
    flag:     bool               = false,
    recs:     Rec[>..]           = [],
    bytes:    u8[>..]            = [],
    after:    bool               = false,    // serve has returned: a check that waited for stop gives its verdict
}

// Makes the case ready for check `id` (a Case cannot be copied, so the driver reuses one).
fn reset(k: Case&, id: i64, base: i64) {
    k.id = id;
    k.base = base;
    k.step = 0;
    k.verdict = RUNNING;
    k.why.clear();
    k.done = false;
    k.after = false;
    k.started = 0;
    k.deadline = 0;
    k.live = 0;
    for r in 4 { k.link[r] = goose_io::Link { .. }; }
    k.l = goose_io::Listener { .. };
    k.l2 = goose_io::Listener { .. };
    k.old = goose_io::Link { .. };
    k.port = 0;
    k.n = 0;
    k.m = 0;
    k.t = 0;
    k.p = 0;
    k.q = 0;
    k.flag = false;
    k.recs.clear();
    k.bytes.clear();
}

// --- failing and finishing -----------------------------------------------------------------------

// Records the first failure of a check: later ones add nothing, so the report names the cause.
fn fail(k: Case&, why: const u8[:]) {
    if k.verdict == RUNNING { k.verdict = FAILED; k.why.clear(); k.why.append(why); }
}

fn expect(k: Case&, ok: bool, why: const u8[:]) {
    if !ok { k.fail(why); }
}

// The check has seen what it needs. It passes once its links have closed, unless it has failed.
fn finish(k: Case&) { k.done = true; }

// Allows `ms` more of the loop's clock from now.
fn within<Io>(k: Case&, io: Io&, ms: i64) {
    k.started = io.now_ms();
    k.deadline = k.started + ms;
    io.tick_by(k.deadline);
}

// --- tags and roles ------------------------------------------------------------------------------

fn tag(k: Case&, i: i64) -> u16 { (k.base + i) as u16 }

// The role of the link whose tag index is i: an even index is an accepted end, an odd one a dialled end.
fn role_of_tag(i: i64) -> i64 { if i % 2 == 0 { i + 1 } else { i - 1 } }

fn owns(k: Case&, t: u16) -> bool { t >= k.base && t < k.base + TAGS_PER_CHECK }

fn role(k: Case&, link: goose_io::Link) -> i64 {
    for r in 4 { if goose_io::same(k.link[r], link) { return r; } }
    return -1;
}

fn is_mine(k: Case&, ev: goose_io::Event) -> bool {
    if !goose_io::is_link_event(ev) { return false; }
    return k.owns(goose_io::tag_of(ev));
}

// Listens on the loopback address with a system-chosen port and remembers the port.
fn listen_local<Io>(k: Case&, io: Io&, pair: i64) -> bool {
    let l, err = io.listen("127.0.0.1:0", k.tag(pair * 2));
    k.expect(goose_io::is_listener(l) && !goose_io::failed(err), "listen on a free port failed");
    if pair == 0 { k.l = l; } else { k.l2 = l; }
    k.port = io.listener_port(l) as i64;
    k.expect(k.port != 0, "listener_port is 0 after listening on port 0");
    return goose_io::is_listener(l) && k.port != 0;
}

fn local_text(port: i64) -> u8[>..] {
    var out: u8[>..] = [];
    format(out, "127.0.0.1:", port);
    return out;
}

// Dials the port of the last listen_local; the dialled end is role 2 * pair.
fn dial_local<Io>(k: Case&, io: Io&, pair: i64, connect_ms: i64) -> goose_io::Link {
    return k.dial_to(io, local_text(k.port), pair, connect_ms);
}

fn dial_to<Io>(k: Case&, io: Io&, address: const u8[:], pair: i64, connect_ms: i64) -> goose_io::Link {
    let link = io.dial(address, k.tag(pair * 2 + 1), connect_ms);
    k.link[pair * 2] = link;
    k.live++;
    return link;
}

// A pair on the loopback: listen, dial. Returns whether both calls were made.
fn connect_local<Io>(k: Case&, io: Io&, pair: i64) -> bool {
    if !k.listen_local(io, pair) { return false; }
    k.dial_local(io, pair, 0);
    return true;
}

// --- recording -----------------------------------------------------------------------------------

// Appends a record and checks the tag the event carried against the role of the link: every check gets
// the rule that an event names its owner (*Every link event names its owner*) for nothing.
fn _record(k: Case&, link: goose_io::Link, tag: u16, rec: Rec) {
    var r = rec;
    r.role = k.role(link);
    r.tag = tag;
    if r.role >= 0 && tag - k.base != (if r.role % 2 == 1 { r.role - 1 } else { r.role + 1 }) {
        k.fail("a link event carried the wrong tag");
    }
    k.recs.push(r);
}

// Records a link event of this check and keeps the counts of its links; every check calls it first.
fn track<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    let now = io.now_ms();
    match ev {
        Opened e => {
            if k.owns(e.tag) {
                let r = role_of_tag(e.tag - k.base);
                if goose_io::is_listener(e.listener) { k.link[r] = e.link; k.live++; }
                k._record(e.link, e.tag, Rec { kind: 'O', at: now, user: e.user, listener: e.listener, .. });
            }
        },
        Data e => {
            if k.owns(e.tag) {
                let off = k.bytes.len;
                k.bytes.append(e.bytes);
                k._record(e.link, e.tag, Rec { kind: 'D', at: now, off: off, len: e.bytes.len, user: e.user, .. });
            }
        },
        Writable e => { if k.owns(e.tag) { k._record(e.link, e.tag, Rec { kind: 'W', at: now, user: e.user, .. }); } },
        PeerEof e => { if k.owns(e.tag) { k._record(e.link, e.tag, Rec { kind: 'E', at: now, user: e.user, .. }); } },
        Closed e => {
            if k.owns(e.tag) {
                k._record(e.link, e.tag, Rec { kind: 'C', at: now, why: e.why, user: e.user, .. });
                k.live--;
            }
        },
        _ => {},
    }
}

// The link events of a role as letters, in order.
fn kinds(k: Case&, r: i64) -> u8[>..] {
    var out: u8[>..] = [];
    for e in k.recs { if e.role == r { out.push(e.kind); } }
    return out;
}

// Every byte delivered to a role, in order.
fn received(k: Case&, r: i64) -> u8[>..] {
    var out: u8[>..] = [];
    for e in k.recs { if e.kind == 'D' && e.role == r { out.append(k.bytes[e.off..e.off + e.len]); } }
    return out;
}

fn count(k: Case&, r: i64, kind: u8) -> i64 {
    var n = 0;
    for e in k.recs { if e.role == r && e.kind == kind { n++; } }
    return n;
}

// Index of the first record of that kind for the role, or -1.
fn first(k: Case&, r: i64, kind: u8) -> i64 {
    for e, i in k.recs { if e.role == r && e.kind == kind { return i; } }
    return -1;
}

fn closed_with(k: Case&, r: i64, why: goose_io::CloseReason) -> bool {
    let i = k.first(r, 'C');
    return i >= 0 && k.recs[i].why == why;
}

fn failed_with(k: Case&, r: i64, kind: goose_io::ConnectFailure) -> bool {
    let i = k.first(r, 'C');
    let want: goose_io::CloseReason = goose_io::CloseReason.ConnectFailed { kind: kind };
    return i >= 0 && k.recs[i].why == want;
}

// True when the role's link has opened and has not closed.
fn is_open(k: Case&, r: i64) -> bool { k.first(r, 'O') >= 0 && k.first(r, 'C') < 0 }

// Both ends of a pair have had their Opened.
fn pair_open(k: Case&, pair: i64) -> bool { k.first(pair * 2, 'O') >= 0 && k.first(pair * 2 + 1, 'O') >= 0 }

// A byte pattern of n bytes, the same on every run.
fn pattern(n: i64) -> u8[>..] {
    var out: u8[>..] = [];
    for i in n { out.push(('a' + i % 26) as u8); }
    return out;
}

// The text of an address, as an owned array.
fn addr_text(a: goose_io::Address) -> u8[>..] {
    var out: u8[>..] = [];
    out.append(a.text[..]);
    return out;
}

fn starts_with(text: const u8[:], prefix: const u8[:]) -> bool {
    guard text.len >= prefix.len else { return false; }
    for i in prefix.len { if text[i] != prefix[i] { return false; } }
    return true;
}
