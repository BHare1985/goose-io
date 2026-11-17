// An event loop that wraps another event loop: the layering that *Event loops can be layered* allows.
//
// It sits over the in-memory event loop and presents the same contract to the libraries above it, while it
//   - changes every byte on the way out (XOR with a key) and restores it on the way in, so two links of the
//     wrapper see their own bytes while the inner event loop carries something else;
//   - delays each link's Opened by one pass (and holds back, in order, whatever the link gets meanwhile);
//   - gives every other event, and every operation, to the inner event loop unchanged.
// A scripted peer is on the inner event loop and sees the changed bytes: the `peer_` functions here change them
// for the test, so a test written for any event loop runs on this one (`peer_send` takes the plain bytes, and
// `peer_received` returns them as the library sent them).
//
// The inner event loop is a global of this module, so one process holds one wrapper: run a wrapper test in its own
// process, as tests/examples/over_wrapper.sh does. Setting `cfg` on the wrapper sets it on the inner event loop.
namespace wrapper;
import std;
import goose_io;
import memory;

let KEY = 0x5a;

var inner: goose_io_memory::Loop = goose_io_memory::Loop { .. };

// One event the wrapper holds back.
struct Held {
    kind:     u8                    = 0,        // 'O' 'D' 'W' 'E' 'C'
    link:     goose_io::Link        = goose_io::Link { .. },
    tag:      u16                   = 0,
    user:     u32                   = 0,
    listener: goose_io::Listener    = goose_io::Listener { .. },
    why:      goose_io::CloseReason = goose_io::CloseReason.Error,
    pass:     i64                   = 0,
    off:      i64                   = 0,
    len:      i64                   = 0,
}

// What a library chose for a link. The wrapper delays Opened, so the library chooses what the peer's end of
// stream does after the inner event loop would have acted on its default: the wrapper keeps every inner link
// open on end of stream and does what the library chose.
struct Mode {
    link:       goose_io::Link = goose_io::Link { .. },
    live:       bool           = false,
    keep:       bool           = false,     // set_keep_open_on_eof(link, true)
    eof_close:  bool           = false,     // the wrapper closed the inner link because the peer finished and keep is off
    lib_closed: bool           = false,     // the library called close or reset
}

root struct Layer {
    cfg:       goose_io_memory::Config = goose_io_memory::Config { .. },
    ready:     bool                    = false,
    pass:      i64                     = 0,        // the wrapper's pass: raised when the inner event loop ends one
    delivered: bool                    = false,    // a link event was given to the application since the last PassEnd
    held:      Held[>..]               = [],
    held_off:  i64                     = 0,        // items before this have been released
    bytes:     u8[>..]                 = [],       // the bytes of held Data events
    scratch:   u8[>..]                 = [],       // what the application is lent, or what goes to the inner event loop
    out:       Out[>..]                = [],       // events to give the application
    modes:     Mode[>..]               = [],
}

fn _prepare(w: Layer&) {
    if !w.ready {
        w.ready = true;
        inner.cfg = w.cfg;
        w.scratch.resize(70000, 0);
    }
}

fn _changed(w: Layer&, first: const u8[:], second: const u8[:]) -> i64 {
    var n = 0;
    for b in first { w.scratch[n] = b ^ KEY; n++; }
    for b in second { w.scratch[n] = b ^ KEY; n++; }
    return n;
}

fn _plain(bytes: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    for b in bytes { out.push(b ^ KEY); }
    return out;
}

// --- the contract: operations, given to the inner event loop ----------------------------------------------

fn listen(w: Layer&, address: const u8[:], tag: u16) -> goose_io::Listener, goose_io::ListenError { w._prepare(); return inner.listen(address, tag); }
fn listener_port(w: Layer&, l: goose_io::Listener) -> u16 { w._prepare(); return inner.listener_port(l); }
fn stop_listening(w: Layer&, l: goose_io::Listener) { w._prepare(); inner.stop_listening(l); }
fn dial(w: Layer&, address: const u8[:], tag: u16, connect_ms: i64) -> goose_io::Link { w._prepare(); return inner.dial(address, tag, connect_ms); }
fn peer_address(w: Layer&, link: goose_io::Link) -> goose_io::Address { w._prepare(); return inner.peer_address(link); }
fn send_room(w: Layer&, link: goose_io::Link) -> i64 { w._prepare(); return inner.send_room(link); }
fn max_send(w: Layer&) -> i64 { w._prepare(); return inner.max_send(); }
fn pause_reading(w: Layer&, link: goose_io::Link, paused: bool) { w._prepare(); inner.pause_reading(link, paused); }
fn _mode(w: Layer&, link: goose_io::Link) -> i64 {
    for i in w.modes.len { if w.modes[i].live && goose_io::same(w.modes[i].link, link) { return i; } }
    return -1;
}

fn set_keep_open_on_eof(w: Layer&, link: goose_io::Link, keep: bool) {
    w._prepare();
    let m = w._mode(link);
    if m >= 0 { w.modes[m].keep = keep; }
}
fn shutdown_write(w: Layer&, link: goose_io::Link) { w._prepare(); inner.shutdown_write(link); }
// The user value is read when an event is given, so an event the wrapper holds (or has queued) for the link takes the
// new value too: every event given after `set_user` carries it.
fn set_user(w: Layer&, link: goose_io::Link, user: u32) {
    w._prepare();
    inner.set_user(link, user);
    for i in w.held.len {
        if i >= w.held_off && goose_io::same(w.held[i].link, link) { w.held[i].user = user; }
    }
    for i in w.out.len {
        if w.out[i].kind == 'L' && goose_io::same(w.out[i].h.link, link) { w.out[i].h.user = user; }
    }
}
fn user(w: Layer&, link: goose_io::Link) -> u32 { w._prepare(); return inner.user(link); }
fn now_ms(w: Layer&) -> i64 { w._prepare(); return inner.now_ms(); }
fn tick_by(w: Layer&, at_ms: i64) { w._prepare(); inner.tick_by(at_ms); }
fn stop(w: Layer&, grace_ms: i64) { w._prepare(); inner.stop(grace_ms); }
fn draining(w: Layer&) -> bool { w._prepare(); return inner.draining(); }

// The bytes go out changed; what the application sent is not touched.
fn send(w: Layer&, link: goose_io::Link, bytes: const u8[:]) -> goose_io::SendStatus {
    w._prepare();
    if bytes.len > 70000 { return goose_io::SendStatus.TooLarge; }
    let n = w._changed(bytes, "");
    return inner.send(link, w.scratch[..n]);
}

fn send2(w: Layer&, link: goose_io::Link, first: const u8[:], second: const u8[:]) -> goose_io::SendStatus {
    w._prepare();
    if first.len + second.len > 70000 { return goose_io::SendStatus.TooLarge; }
    let n = w._changed(first, second);
    return inner.send(link, w.scratch[..n]);
}

// Nothing is delivered for a link after close or reset, so what the wrapper holds for it is dropped.
fn _drop_held(w: Layer&, link: goose_io::Link) {
    for i in w.held.len {
        if i >= w.held_off && w.held[i].kind != 'C' && goose_io::same(w.held[i].link, link) { w.held[i].kind = 0; }
    }
}

fn close(w: Layer&, link: goose_io::Link) {
    w._prepare();
    w._drop_held(link);
    let m = w._mode(link);
    if m >= 0 { w.modes[m].lib_closed = true; }
    inner.close(link);
}

fn reset(w: Layer&, link: goose_io::Link) {
    w._prepare();
    w._drop_held(link);
    let m = w._mode(link);
    if m >= 0 { w.modes[m].lib_closed = true; }
    inner.reset(link);
}

// --- the application side: events pass through, with Opened delayed -----------------------------------------------------

fn _holds(w: Layer&, link: goose_io::Link) -> bool {
    for i in w.held.len {
        if i >= w.held_off && w.held[i].kind != 0 && goose_io::same(w.held[i].link, link) { return true; }
    }
    return false;
}

fn _hold(w: Layer&, h: Held) { w.held.push(h); }

// The events the application is to be given, in order: the wrapper decides what they are while handling an inner event,
// and the serve block gives them to the application, which is the only code that can call it.
struct Out { kind: u8 = 0, h: Held = Held { .. } }

fn _out(w: Layer&, kind: u8, h: Held) { w.out.push(Out { kind: kind, h: h }); }

// Queues one held event for the application.
fn _give(w: Layer&, h: Held) {
    if h.kind == 0 { return; }
    w.delivered = true;
    w._out('L', h);
}

// Queues what was held in an earlier pass, in order.
fn _release(w: Layer&) {
    while w.held_off < w.held.len && w.held[w.held_off].pass < w.pass {
        let h = w.held[w.held_off];
        w.held_off++;
        w._give(h);
    }
    if w.held_off == w.held.len { w.held.clear(); w.held_off = 0; }
}

fn _end_pass(w: Layer&) {
    if w.delivered {
        w.delivered = false;
        w._out('P', Held { .. });
    }
}

fn _on_event(w: Layer&, ev: goose_io::Event) {
    match ev {
        Tick t => {
            w._end_pass();
            w._out('T', Held { pass: t.now_ms, .. });
            w._release();
        },
        PassEnd => {
            w.pass++;
            w._end_pass();
        },
        Opened e => {
            inner.set_keep_open_on_eof(e.link, true);
            w.modes.push(Mode { link: e.link, live: true, .. });
            w._hold(Held { kind: 'O', link: e.link, tag: e.tag, user: e.user, listener: e.listener, pass: w.pass, .. });
        },
        Data e => {
            let off = w.bytes.len;
            for b in e.bytes { w.bytes.push(b ^ KEY); }
            let h = Held { kind: 'D', link: e.link, tag: e.tag, user: e.user, pass: w.pass, off: off, len: e.bytes.len, .. };
            if w._holds(e.link) { w._hold(h); } else { w._give(h); }
        },
        Writable e => {
            let h = Held { kind: 'W', link: e.link, tag: e.tag, user: e.user, pass: w.pass, .. };
            if w._holds(e.link) { w._hold(h); } else { w._give(h); }
        },
        PeerEof e => {
            let h = Held { kind: 'E', link: e.link, tag: e.tag, user: e.user, pass: w.pass, .. };
            if w._holds(e.link) { w._hold(h); } else { w._give(h); }
        },
        Closed e => {
            var why = e.why;
            let m = w._mode(e.link);
            if m >= 0 {
                if w.modes[m].eof_close && !w.modes[m].lib_closed && why == goose_io::CloseReason.Local { why = goose_io::CloseReason.PeerClosed; }
                w.modes[m].live = false;
            }
            let h = Held { kind: 'C', link: e.link, tag: e.tag, user: e.user, why: why, pass: w.pass, .. };
            if w._holds(e.link) { w._hold(h); } else { w._give(h); }
        },
    }
}

// Called just before the application is given an event, once the events before it have been handled. An end of stream
// for a link whose library has not chosen to keep it open is not given: the default is to close the link, with
// PeerClosed. The choice is read now and not earlier, because the library makes it while handling Opened, which
// may be one of the events given just before.
fn _wanted(w: Layer&, o: Out) -> bool {
    if o.kind == 'L' && o.h.kind == 'E' {
        let m = w._mode(o.h.link);
        if m >= 0 && !w.modes[m].keep {
            w.modes[m].eof_close = true;
            inner.close(o.h.link);
            return false;
        }
    }
    return true;
}

// What the application is to be given now, one event at a time (kind 0 when there is none).
fn _event_of(w: Layer&, o: Out) -> goose_io::Event {
    let h = o.h;
    if o.kind == 'T' { return goose_io::Event.Tick { now_ms: h.pass }; }
    if o.kind == 'P' { return goose_io::Event.PassEnd {}; }
    if h.kind == 'O' { return goose_io::Event.Opened { link: h.link, tag: h.tag, user: h.user, listener: h.listener }; }
    if h.kind == 'D' { return goose_io::Event.Data { link: h.link, tag: h.tag, user: h.user, bytes: w.bytes[h.off..h.off + h.len] }; }
    if h.kind == 'W' { return goose_io::Event.Writable { link: h.link, tag: h.tag, user: h.user }; }
    if h.kind == 'E' { return goose_io::Event.PeerEof { link: h.link, tag: h.tag, user: h.user }; }
    return goose_io::Event.Closed { link: h.link, tag: h.tag, user: h.user, why: h.why };
}

// Runs the inner event loop's loop and gives the application its events. A held event is given the pass after the one
// that had it; whatever is still held when the inner loop has finished is given before serve returns.
fn serve<F>(w: Layer&) {
    w._prepare();
    inner.serve() { io, ev =>
        w._on_event(ev);
        var i = 0;
        while i < w.out.len {
            if w._wanted(w.out[i]) {
                let e = w._event_of(w.out[i]);
                F(w, e);
            }
            i++;
        }
        w.out.clear();
        if w.held.len == 0 { w.bytes.clear(); }
    };
    while w.held_off < w.held.len {
        w.pass++;
        w._release();
        w._end_pass();
        var i = 0;
        while i < w.out.len {
            if w._wanted(w.out[i]) {
                let e = w._event_of(w.out[i]);
                F(w, e);
            }
            i++;
        }
        w.out.clear();
    }
}

// The wrapper passes through the core and every group but batching, so it supplies each of them. This function
// is never called: it makes the compiler check the wrapper against the contract's own checks whenever it is built.
fn _supplied(w: Layer&) {
    goose_io::require_core(w);
    goose_io::require_half_close(w);
    goose_io::require_sizing(w);
    goose_io::require_abort(w);
    goose_io::require_inspection(w);
}

// --- for tests: the inner event loop's extras, with the bytes changed for the scripted peer ------------------------

fn add_peer(w: Layer&) -> goose_io_memory::Peer { w._prepare(); return inner.add_peer(); }
fn peer_accept(w: Layer&, p: goose_io_memory::Peer, address: const u8[:]) { inner.peer_accept(p, address); }
fn peer_refuse(w: Layer&, p: goose_io_memory::Peer, address: const u8[:]) { inner.peer_refuse(p, address); }
fn peer_connect(w: Layer&, p: goose_io_memory::Peer, address: const u8[:], after_ms: i64) { inner.peer_connect(p, address, after_ms); }
fn peer_send(w: Layer&, p: goose_io_memory::Peer, after_ms: i64, bytes: const u8[:]) { inner.peer_send(p, after_ms, _plain(bytes)[..]); }
fn peer_stop_reading(w: Layer&, p: goose_io_memory::Peer, after_ms: i64) { inner.peer_stop_reading(p, after_ms); }
fn peer_resume_reading(w: Layer&, p: goose_io_memory::Peer, after_ms: i64) { inner.peer_resume_reading(p, after_ms); }
fn peer_shutdown(w: Layer&, p: goose_io_memory::Peer, after_ms: i64) { inner.peer_shutdown(p, after_ms); }
fn peer_close(w: Layer&, p: goose_io_memory::Peer, after_ms: i64) { inner.peer_close(p, after_ms); }
fn peer_abort(w: Layer&, p: goose_io_memory::Peer, after_ms: i64) { inner.peer_abort(p, after_ms); }
fn peer_received(w: Layer&, p: goose_io_memory::Peer) -> u8[>..] { return _plain(inner.peer_received(p)[..]); }
fn peer_connected(w: Layer&, p: goose_io_memory::Peer) -> bool { return inner.peer_connected(p); }
fn peer_saw_eof(w: Layer&, p: goose_io_memory::Peer) -> bool { return inner.peer_saw_eof(p); }
fn peer_saw_reset(w: Layer&, p: goose_io_memory::Peer) -> bool { return inner.peer_saw_reset(p); }
fn peer_closed(w: Layer&, p: goose_io_memory::Peer) -> bool { return inner.peer_closed(p); }
fn hold(w: Layer&, address: const u8[:]) { w._prepare(); inner.hold(address); }
fn silent(w: Layer&, address: const u8[:]) { w._prepare(); inner.silent(address); }
fn fail_dials(w: Layer&, address: const u8[:], kind: goose_io::ConnectFailure) { w._prepare(); inner.fail_dials(address, kind); }
fn close_with_reason(w: Layer&, link: goose_io::Link, why: goose_io::CloseReason) { w._prepare(); inner.close_with_reason(link, why); }
