// A line client: a library on the goose-io contract that sends newline-delimited requests over a pool of links.
//
// Needs: core only. It runs on every loop that supplies the core.
//
// Like the line server it imports the contract and nothing else. It shows what a client needs on top of the
// contract (docs/libraries.md): a pool of links it dials itself, requests pipelined on a link and matched to
// replies in order, a deadline for each request kept with `Deadlines` and `tick_by`, a reconnect after a backoff
// that is counted on the loop's clock, and `Full` and `Writable` for sends that are refused.
//
//     var c = lineclient::LineClient { .. };
//     c.start(io, "10.0.0.2:6379", tag, 4, 200);          // a pool of four links, 200 ms backoff
//     let id = c.request(io, "GET key", 1000);            // answered, or timed out, within a second
//     io.serve() { io, ev =>
//         c.client_event(io, ev);
//         loop { var text: u8[>..] = []; let r = c.take_result(text); if !r.found { break; } use(r, text); }
//     };
//
// A request that is not answered by its deadline is reported once as timed out; its reply, if it comes, is read
// and thrown away in its place, so it can never be taken for the reply to a later request. A link that is lost
// fails each of its outstanding requests once and is dialled again after the backoff. Every buffer has a fixed
// size, so a peer that never reads or never answers cannot make the client grow: a request that does not fit
// waits for room, and ends at its own deadline.
namespace lineclient;
import std;
import goose_io;
import deadlines;

let POOL_MAX = 8;
let REQ_MAX = 256;             // requests in flight or waiting, at most
let PIPELINE_MAX = 32;         // requests outstanding on one link, at most
let TEXT_MAX = 4000;           // the longest request
let OUT_CAP = 16384;           // output held per link
let IN_CAP = 4096;             // input held per link

enum Outcome { Ok, TimedOut, LinkLost, Failed }

// The state of a pool position.
let EMPTY = 0;                 // nothing: not dialled
let DIALLING = 1;
let OPEN = 2;
let BACKOFF = 3;               // lost or failed: dialled again at retry_at
let GAVE_UP = 4;               // a failure that is permanent (a bad address)

// The state of a request.
let R_FREE = 0;
let R_WAITING = 1;             // no link could take it yet
let R_SENT = 2;               // in a link's queue, waiting for its reply
let R_ABANDONED = 3;           // timed out; its reply is still to come and is to be discarded

struct Slot {
    link:     goose_io::Link = goose_io::Link { .. },
    state:    u8             = 0,
    retry_at: i64            = 0,
    fails:    i64            = 0,                 // failures in a row, for the backoff
    sent:     i64            = 0,                 // bytes of `out` the event loop has taken
    queue:    u32[..32]      = [],                // ids of the requests waiting for a reply, in the order sent
    in_buf:   u8[..4096]     = [],
    out:      u8[..16384]    = [],
}

struct Req { id: u32 = 0, state: u8 = 0, off: i64 = 0, len: i64 = 0 }

struct Result { found: bool = false, id: u32 = 0, outcome: Outcome = Outcome.Ok }

struct Done { id: u32 = 0, outcome: Outcome = Outcome.Ok, off: i64 = 0, len: i64 = 0 }

root struct LineClient {
    tag:        u16                      = 0,
    address:    goose_io::Address        = goose_io::Address { .. },
    size:       i64                      = 0,
    backoff_ms: i64                      = 0,
    connect_ms: i64                      = 1000,
    next_id:    u32                      = 1,
    slots:      Slot[..8]                = [],
    reqs:       Req[..256]               = [],
    deadlines:  goose_io::Deadlines      = goose_io::Deadlines { .. },
    dials:      i64                      = 0,
    fulls:      i64                      = 0,
    last_dial:  i64                      = -1,
    last_kind:  goose_io::ConnectFailure = goose_io::ConnectFailure.Other,
    wait_ids:   u32[>..]                 = [],            // requests waiting for a link, in order
    wait_text:  u8[>..]                  = [],            // their texts
    done:       Done[>..]                = [],            // results not yet taken
    done_head:  i64                      = 0,
    done_text:  u8[>..]                  = [],
}

// Starts a pool of `pool` links (at most 8) to `address`, whose links carry `tag`. A failed dial or a lost link
// is dialled again after `backoff_ms`, doubling for each failure in a row. False if the address is too long or
// the pool size is out of range.
fn start<Io>(c: LineClient&, io: Io&, address: const u8[:], tag: u16, pool: i64, backoff_ms: i64) -> bool {
    guard pool >= 1 && pool <= POOL_MAX && address.len <= 56 else { return false; }
    c.tag = tag;
    c.size = pool;
    c.backoff_ms = backoff_ms;
    c.address.text.append(address);
    while c.slots.len < POOL_MAX { c.slots.push(Slot { .. }); }
    while c.reqs.len < REQ_MAX { c.reqs.push(Req { .. }); }
    for i in pool { c._open_slot(io, i); }
    return true;
}

fn open_links(c: LineClient&) -> i64 {
    var n = 0;
    for i in c.size { if c.slots[i].state == OPEN { n++; } }
    return n;
}

// How many dials the client has made.
fn dial_count(c: LineClient&) -> i64 { c.dials }

// The loop's clock when the last dial was made, or -1.
fn last_dial_at(c: LineClient&) -> i64 { c.last_dial }

// How many sends were refused with Full.
fn full_count(c: LineClient&) -> i64 { c.fulls }

// The kind of the last failed dial (Other if none has failed).
fn last_failure(c: LineClient&) -> goose_io::ConnectFailure { c.last_kind }

// The link at a pool position, invalid if there is none now.
fn link_of(c: LineClient&, i: i64) -> goose_io::Link {
    if i < 0 || i >= c.size || c.slots[i].state == EMPTY || c.slots[i].state == BACKOFF || c.slots[i].state == GAVE_UP { return goose_io::Link { .. }; }
    return c.slots[i].link;
}

// --- results ---------------------------------------------------------------------------------------------

fn _complete(c: LineClient&, id: u32, outcome: Outcome, text: const u8[:]) {
    let off = c.done_text.len;
    c.done_text.append(text);
    c.done.push(Done { id: id, outcome: outcome, off: off, len: text.len });
}

// The next result: the id of a request and how it ended. For Ok, the reply is appended to `text`. Each request
// is reported once.
fn take_result(c: LineClient&, text: u8[>..]&) -> Result {
    if c.done_head >= c.done.len {
        c.done.clear();
        c.done_text.clear();
        c.done_head = 0;
        return Result { .. };
    }
    let d = c.done[c.done_head];
    c.done_head++;
    text.append(c.done_text[d.off..d.off + d.len]);
    return Result { found: true, id: d.id, outcome: d.outcome };
}

fn _find(c: LineClient&, id: u32) -> i64 {
    for i in REQ_MAX { if c.reqs[i].state != R_FREE && c.reqs[i].id == id { return i; } }
    return -1;
}

// --- the pool --------------------------------------------------------------------------------------------

fn _open_slot<Io>(c: LineClient&, io: Io&, i: i64) {
    let s .= c.slots[i];
    s.link = io.dial(c.address.text[..], c.tag, c.connect_ms);
    io.set_user(s.link, i as u32);
    s.state = DIALLING;
    s.sent = 0;
    s.queue.clear();
    s.in_buf.clear();
    s.out.clear();
    c.dials++;
    c.last_dial = io.now_ms();
}

fn _slot_of(c: LineClient&, user: u32, link: goose_io::Link) -> i64 {
    guard user < c.size else { return -1; }
    guard c.slots[user].state != EMPTY && goose_io::same(c.slots[user].link, link) else { return -1; }
    return user;
}

fn _backoff(c: LineClient&, i: i64) -> i64 {
    var d = c.backoff_ms;
    var n = c.slots[i].fails - 1;
    while n > 0 && n < 6 { d = d * 2; n--; }
    return d;
}

// Sends what the event loop will take of a link's output. A refusal waits for Writable.
fn _flush<Io>(c: LineClient&, io: Io&, i: i64) {
    let s .= c.slots[i];
    while s.state == OPEN && s.out.len > s.sent {
        let left = s.out.len - s.sent;
        let n = if left < io.max_send() { left } else { io.max_send() };
        let status = io.send(s.link, s.out[s.sent..s.sent + n]);
        if status == goose_io::SendStatus.Sent {
            s.sent += n;
        } else if status == goose_io::SendStatus.Full {
            c.fulls++;
            return;
        } else {
            return;                              // the link is going: its Closed fails what is queued
        }
    }
    if s.out.len == s.sent { s.out.clear(); s.sent = 0; }
}

// Hands waiting requests to links that are open and have room, in the order they were made.
fn _dispatch<Io>(c: LineClient&, io: Io&) {
    var taken = 0;
    for w in c.wait_ids.len {
        let k = c._find(c.wait_ids[w]);
        if k < 0 || c.reqs[k].state != R_WAITING { taken++; continue; }          // it ended while it waited
        let r .= c.reqs[k];
        // the open link with the fewest outstanding requests that has room for this one
        var best = -1;
        for i in c.size {
            let s .= c.slots[i];
            if s.state == OPEN && s.queue.len < PIPELINE_MAX && s.out.len + r.len + 1 <= OUT_CAP {
                if best < 0 || s.queue.len < c.slots[best].queue.len { best = i; }
            }
        }
        if best < 0 { break; }
        let s .= c.slots[best];
        s.out.append(c.wait_text[r.off..r.off + r.len]);
        s.out.push('\n');
        s.queue.push(r.id);
        r.state = R_SENT;
        taken++;
        c._flush(io, best);
    }
    if taken > 0 {
        let rest = c.wait_ids.len - taken;
        for j in rest { c.wait_ids[j] = c.wait_ids[taken + j]; }
        c.wait_ids.resize(rest, 0);
    }
    if c.wait_ids.len == 0 { c.wait_text.clear(); }
}

// A request ends: the result is reported, its deadline dropped, its place freed.
fn _finish(c: LineClient&, k: i64, outcome: Outcome, text: const u8[:]) {
    let id = c.reqs[k].id;
    c.deadlines.cancel(id);
    c._complete(id, outcome, text);
    c.reqs[k].state = R_FREE;
}

// A link ended or never opened: every request waiting for it is failed once, and it is dialled again later.
fn _lost<Io>(c: LineClient&, io: Io&, i: i64, why: goose_io::CloseReason) {
    let s .= c.slots[i];
    for j in s.queue.len {
        let k = c._find(s.queue[j]);
        if k >= 0 {
            if c.reqs[k].state == R_SENT { c._finish(k, Outcome.LinkLost, ""); } else { c.reqs[k].state = R_FREE; }
        }
    }
    s.queue.clear();
    s.in_buf.clear();
    s.out.clear();
    s.sent = 0;
    s.fails++;
    var kind = goose_io::ConnectFailure.Other;
    var permanent = false;
    match why {
        ConnectFailed f => {
            kind = f.kind;
            c.last_kind = f.kind;
            permanent = f.kind == goose_io::ConnectFailure.BadAddress;      // retrying cannot help
        },
        _ => {},
    }
    if io.draining() {
        s.state = EMPTY;
    } else if permanent {
        s.state = GAVE_UP;
        c._fail_waiting();
    } else {
        s.state = BACKOFF;
        s.retry_at = io.now_ms() + c._backoff(i);
        io.tick_by(s.retry_at);
    }
}

// Every request that is waiting for a link is failed: there will be none.
fn _fail_waiting(c: LineClient&) {
    for k in REQ_MAX {
        if c.reqs[k].state == R_WAITING { c._finish(k, Outcome.Failed, ""); }
    }
    c.wait_ids.clear();
    c.wait_text.clear();
}

fn _all_gave_up(c: LineClient&) -> bool {
    for i in c.size { if c.slots[i].state != GAVE_UP { return false; } }
    return c.size > 0;
}

// Takes complete lines from a link's input and matches each to the request at the front of its queue.
fn _read_lines<Io>(c: LineClient&, io: Io&, i: i64) {
    let s .= c.slots[i];
    loop {
        var k = -1;
        for j in s.in_buf.len { if s.in_buf[j] == '\n' { k = j; break; } }
        if k < 0 { break; }
        let end = if k > 0 && s.in_buf[k - 1] == '\r' { k - 1 } else { k };
        if s.queue.len > 0 {
            let id = s.queue[0];
            for j in s.queue.len - 1 { s.queue[j] = s.queue[j + 1]; }
            s.queue.pop();
            let r = c._find(id);
            if r >= 0 {
                if c.reqs[r].state == R_SENT { c._finish(r, Outcome.Ok, s.in_buf[..end]); } else { c.reqs[r].state = R_FREE; }     // an abandoned request's reply is discarded
            }
        }
        // a line with nothing waiting for it is dropped
        let rest = s.in_buf.len - (k + 1);
        if rest > 0 { s.in_buf[..rest].move_from(s.in_buf[k + 1..k + 1 + rest]); }
        s.in_buf.resize(rest, 0);
    }
}

// doc:begin expire
// Requests whose deadline has come: reported once; a request already sent keeps its place in the link's queue
// so that its reply, when it comes, is read and discarded.
fn _expire<Io>(c: LineClient&, io: Io&) {
    loop {
        let d = c.deadlines.pop_due(io.now_ms());
        if !d.found { break; }
        let k = c._find(d.id);
        if k >= 0 {
            let was = c.reqs[k].state;
            c._complete(d.id, Outcome.TimedOut, "");
            c.reqs[k].state = if was == R_SENT { R_ABANDONED } else { R_FREE };
        }
    }
}
// doc:end expire
// doc:begin rearm
// Asks the event loop to wake the client for its next deadline or redial, whichever is first.
fn _rearm<Io>(c: LineClient&, io: Io&) {
    if !c.deadlines.is_empty() { io.tick_by(c.deadlines.next_at()); }
    for i in c.size { if c.slots[i].state == BACKOFF { io.tick_by(c.slots[i].retry_at); } }
}
// doc:end rearm
// Makes a request: `text` is one line (without its end of line). Returns its id, or 0 if the text is too long or
// too many requests are in flight. It is reported by take_result within `timeout_ms`, answered or not.
fn request<Io>(c: LineClient&, io: Io&, text: const u8[:], timeout_ms: i64) -> u32 {
    if text.len > TEXT_MAX { return 0; }
    var k = -1;
    for i in REQ_MAX { if c.reqs[i].state == R_FREE { k = i; break; } }
    if k < 0 { return 0; }
    let id = c.next_id;
    c.next_id++;
    if c.next_id == 0 { c.next_id = 1; }
    if c._all_gave_up() {
        c._complete(id, Outcome.Failed, "");
        return id;
    }
    let off = c.wait_text.len;
    c.wait_text.append(text);
    c.reqs[k] = Req { id: id, state: R_WAITING, off: off, len: text.len };
    c.wait_ids.push(id);
    c.deadlines.add(io.now_ms() + timeout_ms, id);
    c._dispatch(io);
    c._rearm(io);
    return id;
}

// The library's one entry point: true if the event was for this client, false if it is another library's (or a
// Tick or PassEnd, which every library is offered).
fn client_event<Io>(c: LineClient&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Tick t => {
            c._expire(io);
            if io.draining() {
                c._fail_waiting();
                for i in c.size {
                    let s .= c.slots[i];
                    if s.state == OPEN && s.queue.len == 0 && s.out.len == s.sent { io.close(s.link); s.state = EMPTY; }
                }
            } else {
                for i in c.size {
                    if c.slots[i].state == BACKOFF && t.now_ms >= c.slots[i].retry_at { c._open_slot(io, i); }
                }
            }
            c._rearm(io);
            return false;
        },
        PassEnd => { return false; },
        Opened e => {
            if e.tag != c.tag { return false; }
            let i = c._slot_of(e.user, e.link);
            if i >= 0 {
                c.slots[i].state = OPEN;
                c.slots[i].fails = 0;
                c._dispatch(io);
            }
            return true;
        },
        Data e => {
            if e.tag != c.tag { return false; }
            let i = c._slot_of(e.user, e.link);
            if i >= 0 {
                let s .= c.slots[i];
                if s.in_buf.len + e.bytes.len > IN_CAP { io.close(s.link); return true; }       // not this protocol
                s.in_buf.append(e.bytes);
                c._read_lines(io, i);
                c._dispatch(io);
            }
            return true;
        },
        Writable e => {
            if e.tag != c.tag { return false; }
            let i = c._slot_of(e.user, e.link);
            if i >= 0 {
                c._flush(io, i);
                c._dispatch(io);
            }
            return true;
        },
        PeerEof e => {
            if e.tag != c.tag { return false; }
            return true;                  // the link is not kept open: its Closed follows
        },
        Closed e => {
            if e.tag != c.tag { return false; }
            let i = c._slot_of(e.user, e.link);
            if i >= 0 {
                c._lost(io, i, e.why);
                c._rearm(io);
            }
            return true;
        },
    }
}
