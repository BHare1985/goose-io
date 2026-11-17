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
// A check's events are told from those of an earlier check whose links are still closing by their links: a dialled
// end is the link `dial` returned to the check, an accepted end is one whose `Opened` names a listener the check started
// (`k.l` for pair 0, `k.l2` for pair 1), and every later event is one whose link the check holds.
namespace goose_io_conformance;
import std;
import goose_io;

let RUNNING = 0;
let PASSED = 1;
let FAILED = 2;

// What contract calls cannot produce: an address that never answers a connect, and one that is held.
struct Fixture {
    silent:  const u8[:] = "",   // a dial to it never gets an answer
    held:    const u8[:] = "",   // a listen on it fails with AddressInUse
    refused: const u8[:] = "",   // an address that nothing listens on: a dial to it is refused
    // Optional: an address that still answers while the loop is draining (every listener of the loop has
    // stopped by then, so calls cannot make one). Without it the dial-while-draining part proves only that
    // the dial still ends in exactly one event.
    answers: const u8[:] = "",
    // The unix group only: an absolute path at which the loop may create a socket (without `unix:`); the checks derive
    // every other path from it. The loop creates and removes the file; the suite stops its listeners before it ends.
    unix: const u8[:] = "",
}

// One recorded link event.
// Name, requirement and part of one check.
struct Info { name: const u8[:] = "", req: const u8[:] = "", part: i64 = 0, group: i64 = 0 }

// The groups of the contract (design D2) and the marker type of each. The driver is generic over a marker, and the
// functions `step` and `takes` of the suite are overloaded on it, so that a suite for one group compiles only the
// checks of that group (design D5). Every check belongs to exactly one group; GROUP_NONE is the answer for a name that
// is not a check.
let GROUP_CORE = 0;
let GROUP_HALF_CLOSE = 1;
let GROUP_SIZING = 2;
let GROUP_ABORT = 3;
let GROUP_INSPECTION = 4;
let GROUP_BATCHING = 5;
let GROUP_UNIX = 6;
let GROUP_NONE = 9;

struct CoreGroup { n: i64 = 0 }
struct BatchingGroup { n: i64 = 0 }
struct SizingGroup { n: i64 = 0 }
struct HalfCloseGroup { n: i64 = 0 }
struct InspectionGroup { n: i64 = 0 }
struct AbortGroup { n: i64 = 0 }
struct UnixGroup { n: i64 = 0 }

struct Rec {
    role:     i64                   = 0,
    kind:     u8                    = 0,    // 'O' 'D' 'W' 'E' 'C'
    at:       i64                   = 0,
    off:      i64                   = 0,    // Data: its bytes in Case.bytes
    len:      i64                   = 0,
    why:      goose_io::CloseReason = goose_io::CloseReason.Error,
    listener: goose_io::Listener    = goose_io::Listener { .. }, // Opened: the listener that accepted it
}

// The two checks that carry the handle rules (conformance/handles.goose). The driver fails whichever check is running
// when a rule is broken, except that each of these two ignores a break of the other's rule, so that each fails for its own.
// A check whose id is at least this runs after `serve` has returned, on the finished loop, and not inside serve: the driver
// gives it one step with `k.after` set (*A finished loop does nothing*).
let AFTER_ID = 900;

let CHECK_PAIR_UNIQUE = 119;
let CHECK_SLOT_HELD = 120;

// One issuance of a link handle, as the driver saw it: the handle `dial` returned and the same handle in that link's
// `Opened` are one issuance, an accepted link's `Opened` is another. `closed` is set when its `Closed` is delivered.
struct Issue { slot: u32 = 0, gen: u32 = 0, closed: bool = false }

root struct Case {
    id:       i64                = 0,
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
    prev:     goose_io::Link[4]  = [goose_io::Link { .. }; 4],   // the links of an earlier round of the check
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
    // What the driver knows of every handle the loop has issued in this part. It is not cleared between the checks of
    // a part, because the rules are about the loop and the loop is shared.
    issues: Issue[>..] = [],
    // What the entry point set up before serve (see `setup_before_serve` in conformance/handles.goose); not cleared between checks.
    pre_l:    goose_io::Listener = goose_io::Listener { .. },
    pre_link: goose_io::Link     = goose_io::Link { .. },
    pre_done: bool               = false,
    pair_bad: bool               = false,    // a pair was issued twice, or a link had generation 0
    slot_bad: bool               = false,    // a slot was issued while the link before it had not had its Closed
    pair_why: u8[>..]            = [],
    slot_why: u8[>..]            = [],
}

// Makes the case ready for check `id` (a Case cannot be copied, so the driver reuses one).
fn reset(k: Case&, id: i64) {
    k.id = id;
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
    for r in 4 { k.prev[r] = goose_io::Link { .. }; }
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

// --- the handles the loop issues ---------------------------------------------------------------------

fn _issue_at(k: Case&, slot: u32, gen: u32) -> i64 {
    for e, i in k.issues { if e.slot == slot && e.gen == gen { return i; } }
    return -1;
}

// Fails the check that is running, and every check that asks `pair_bad` later, with the first violation of the pair rule.
fn _pair_violation(k: Case&, link: goose_io::Link, what: const u8[:]) {
    var text: u8[>..] = [];
    format(text, "[A slot and generation pair is never issued twice] slot ", link.slot, " generation ", link.gen, " ", what);
    if !k.pair_bad { k.pair_bad = true; k.pair_why.append(text[..]); }
    if k.id != CHECK_SLOT_HELD { k.fail(text[..]); }
}

fn _slot_violation(k: Case&, link: goose_io::Link) {
    var text: u8[>..] = [];
    format(text, "[A slot is held until its Closed is delivered] slot ", link.slot, " was issued while the link in it had not had its Closed delivered");
    if !k.slot_bad { k.slot_bad = true; k.slot_why.append(text[..]); }
    if k.id != CHECK_PAIR_UNIQUE { k.fail(text[..]); }
}

// A handle the loop has just issued: the link `dial` returned, or an accepted link. Called by the driver for an
// accepted link's `Opened` and by `dial_to` (and by a check that dials itself) for a dialled one.
fn issued(k: Case&, link: goose_io::Link) {
    if link.gen == 0 { k._pair_violation(link, "has generation 0, which is reserved for the invalid link"); return; }
    if k._issue_at(link.slot, link.gen) >= 0 { k._pair_violation(link, "was issued again"); return; }
    for e in k.issues { if e.slot == link.slot && !e.closed { k._slot_violation(link); break; } }
    k.issues.push(Issue { slot: link.slot, gen: link.gen, closed: false });
}

// Every link event the driver is given, whichever check's link it is.
fn sight(k: Case&, ev: goose_io::Event) {
    match ev {
        Opened e => {
            if goose_io::is_listener(e.listener) { k.issued(e.link); }
            else if k._issue_at(e.link.slot, e.link.gen) < 0 { k.issues.push(Issue { slot: e.link.slot, gen: e.link.gen, closed: false }); }
        },
        Data e => { if k._issue_at(e.link.slot, e.link.gen) < 0 { k.issues.push(Issue { slot: e.link.slot, gen: e.link.gen, closed: false }); } },
        Writable e => { if k._issue_at(e.link.slot, e.link.gen) < 0 { k.issues.push(Issue { slot: e.link.slot, gen: e.link.gen, closed: false }); } },
        PeerEof e => { if k._issue_at(e.link.slot, e.link.gen) < 0 { k.issues.push(Issue { slot: e.link.slot, gen: e.link.gen, closed: false }); } },
        Closed e => {
            let i = k._issue_at(e.link.slot, e.link.gen);
            if i < 0 { k.issues.push(Issue { slot: e.link.slot, gen: e.link.gen, closed: true }); }
            else { k.issues[i].closed = true; }
        },
        _ => {},
    }
}

// --- roles ---------------------------------------------------------------------------------------

fn role(k: Case&, link: goose_io::Link) -> i64 {
    for r in 4 { if goose_io::same(k.link[r], link) { return r; } }
    return -1;
}

// The role an `Opened` that names a listener belongs to: 1 for the listener of pair 0, 3 for pair 1, -1 when the
// listener is not one this check started (another check's, still open).
fn accepted_role(k: Case&, listener: goose_io::Listener) -> i64 {
    if goose_io::is_listener(k.l) && goose_io::same(listener, k.l) { return 1; }
    if goose_io::is_listener(k.l2) && goose_io::same(listener, k.l2) { return 3; }
    return -1;
}

// True for a link event of this check: its link is one the check holds, or it is the `Opened` of a link that one of
// the check's listeners accepted.
fn is_mine(k: Case&, ev: goose_io::Event) -> bool {
    if !goose_io::is_link_event(ev) { return false; }
    match ev {
        Opened e => {
            if goose_io::is_listener(e.listener) { return k.accepted_role(e.listener) >= 0; }
            return k.role(e.link) >= 0;
        },
        _ => { return k.role(goose_io::link_of(ev)) >= 0; },
    }
}

// Listens on the loopback address with a system-chosen port and remembers the port.
fn listen_local<Io>(k: Case&, io: Io&, pair: i64) -> bool {
    let l, err = io.listen("127.0.0.1:0");
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
    let link = io.dial(address, connect_ms);
    k.issued(link);
    k.link[pair * 2] = link;
    k.live++;
    return link;
}

// Asks for the end of stream to be kept open on the accepted end of `pair`, in the handler of its `Opened` (a call made
// later has no effect). Call it with every event from the check's step; it needs the half-close group. The dialled end is
// configured with `io.set_keep_open_on_eof` right after `dial_to`, while it is dialling.
fn keep_open_on_accept<Io>(k: Case&, io: Io&, ev: goose_io::Event, pair: i64) {
    match ev {
        Opened e => {
            if goose_io::is_listener(e.listener) && k.accepted_role(e.listener) == pair * 2 + 1 { io.set_keep_open_on_eof(e.link, true); }
        },
        _ => {},
    }
}

// A pair on the loopback: listen, dial. Returns whether both calls were made.
fn connect_local<Io>(k: Case&, io: Io&, pair: i64) -> bool {
    if !k.listen_local(io, pair) { return false; }
    k.dial_local(io, pair, 0);
    return true;
}

// --- recording -----------------------------------------------------------------------------------

// Appends a record of an event of this check, for the role of its link.
fn _record(k: Case&, link: goose_io::Link, rec: Rec) {
    var r = rec;
    r.role = k.role(link);
    k.recs.push(r);
}

// Records a link event of this check and keeps the counts of its links; every check calls it first.
fn track<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    let now = io.now_ms();
    match ev {
        Opened e => {
            if goose_io::is_listener(e.listener) {
                let r = k.accepted_role(e.listener);
                if r >= 0 {
                    k.link[r] = e.link;
                    k.live++;
                    k._record(e.link, Rec { kind: 'O', at: now, listener: e.listener, .. });
                }
            } else if k.role(e.link) >= 0 {
                k._record(e.link, Rec { kind: 'O', at: now, listener: e.listener, .. });
            }
        },
        Data e => {
            if k.role(e.link) >= 0 {
                let off = k.bytes.len;
                k.bytes.append(e.bytes);
                k._record(e.link, Rec { kind: 'D', at: now, off: off, len: e.bytes.len, .. });
            }
        },
        Writable e => { if k.role(e.link) >= 0 { k._record(e.link, Rec { kind: 'W', at: now, .. }); } },
        PeerEof e => { if k.role(e.link) >= 0 { k._record(e.link, Rec { kind: 'E', at: now, .. }); } },
        Closed e => {
            if k.role(e.link) >= 0 {
                k._record(e.link, Rec { kind: 'C', at: now, why: e.why, .. });
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
