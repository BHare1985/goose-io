// goose-io: the in-memory event loop.
//
// The whole contract with no sockets and no real clock. A dial to an address that something on
// the same loop listens on joins two links: bytes one side sends arrive as Data on the other,
// under the same backpressure rules as any link. Time is a number that moves only when the loop
// has nothing left to do, straight to the next moment something is due, so nothing ever sleeps
// and the same test gives the same events at the same times on every run.
//
// It exists for two things: testing a library without a network, and giving the contract one
// working implementation that the conformance suite can run against. It supplies the core of the
// contract and every group of extras.
//
//     var io = goose_io_memory::Loop { .. };
//     let l, err = io.listen("127.0.0.1:8080", 1);
//     let link = io.dial("127.0.0.1:8080", 2, 0);
//     io.serve() { io, ev => handle(io, ev); };
namespace goose_io_memory;
import std;
import goose_io;

// --- configuration -------------------------------------------------------------------------------

// Change these on `io.cfg` before the first listen, dial or serve. A value that would stop the loop
// making progress is raised: tick_ms and passes_per_ms to at least 1, max_send to 4096.
struct Config {
    link_buffer:        i64  = 65536,   // most bytes held unsent for one link
    max_send:           i64  = 65536,   // largest single send; at least 4096, at most link_buffer
    read_chunk:         i64  = 16384,   // most bytes in one Data event
    max_links:          i64  = 256,     // link ends of libraries at once, not connections: a joined pair is two; a dial beyond it fails with ConnectFailed, NoResources
    max_listeners:      i64  = 4096,    // listeners ever created: a handle is never used again, so they can run out
    connect_timeout_ms: i64  = 5000,    // what connect_ms 0 means
    tick_ms:            i64  = 100,     // the regular Tick period
    time_limit_ms:      i64  = 600000,  // a serve that runs this long in loop time has hung: fail
    exit_on_time_limit: bool = true,    // false: serve returns instead and hit_time_limit() is true
    passes_per_ms:      i64  = 64,      // busy passes at one instant before the clock moves 1 ms
    unix_paths:         bool = true,    // supply the unix group; false: unix:/path is refused with BadAddress, as by a loop without it
}

// --- internals: addresses ------------------------------------------------------------------------

// A numeric endpoint, or, with `unix` set, the path of a Unix socket (the unix group): then ip, port and v6 are unused.
struct _Addr { ok: bool = false, v6: bool = false, ip: u8[16] = [0; 16], port: u16 = 0, unix: bool = false, path: u8[..103] = [] }

fn _same_endpoint(a: _Addr, b: _Addr) -> bool {
    if a.unix || b.unix { return a.unix && b.unix && a.path[..] == b.path[..]; }
    return a.v6 == b.v6 && a.port == b.port && a.ip == b.ip;
}

fn _is_any(a: _Addr) -> bool {
    if a.unix { return false; }
    for b in a.ip { if b != 0 { return false; } }
    return true;
}

// Two bindings overlap when one connection could be meant for both: the same family and port, and
// either address is the wildcard or they are equal. Overlapping listeners cannot coexist.
fn _overlaps(a: _Addr, b: _Addr) -> bool {
    if a.unix || b.unix { return _same_endpoint(a, b); }
    return a.v6 == b.v6 && a.port == b.port && (_is_any(a) || _is_any(b) || a.ip == b.ip);
}

// A listener on the wildcard address takes a dial to any address of its family.
fn _listener_takes(l: _Addr, target: _Addr) -> bool {
    if l.unix || target.unix { return _same_endpoint(l, target); }
    return l.v6 == target.v6 && l.port == target.port && (l.ip == target.ip || _is_any(l));
}

fn _parse_number(s: const u8[:], limit: i64) -> i64, bool {
    guard s.len > 0 && s.len <= 5 else { return 0, false; }
    var v = 0;
    for c in s {
        guard c >= '0' && c <= '9' else { return 0, false; }
        v = v * 10 + (c - '0');
    }
    return v, v <= limit;
}

fn _parse_v4(s: const u8[:], a: _Addr&) -> bool {
    var part = 0;
    var start = 0;
    for i in s.len + 1 {
        if i == s.len || s[i] == '.' {
            guard part < 4 else { return false; }
            let v, ok = _parse_number(s[start..i], 255);
            guard ok && i - start <= 3 else { return false; }
            a.ip[part] = v as u8;
            part++;
            start = i + 1;
        }
    }
    return part == 4;
}

fn _hex_value(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

fn _parse_v6(s: const u8[:], a: _Addr&) -> bool {
    var groups: i64[8] = [0; 8];
    var n = 0;
    var gap = -1;           // the group index where "::" stands, or -1
    var i = 0;
    guard s.len >= 2 else { return false; }
    if s[0] == ':' {
        guard s[1] == ':' else { return false; }
        gap = 0;
        i = 2;
    }
    while i < s.len {
        guard n < 8 else { return false; }
        var v = 0;
        var digits = 0;
        while i < s.len && _hex_value(s[i]) >= 0 {
            v = v * 16 + _hex_value(s[i]);
            digits++;
            i++;
        }
        guard digits > 0 && digits <= 4 else { return false; }
        groups[n] = v;
        n++;
        if i == s.len { break; }
        guard s[i] == ':' else { return false; }
        i++;
        guard i < s.len else { return false; }          // a single trailing colon
        if s[i] == ':' {
            guard gap < 0 else { return false; }        // only one "::"
            gap = n;
            i++;
        }
    }
    if gap < 0 { guard n == 8 else { return false; } } else { guard n < 8 else { return false; } }
    var full: i64[8] = [0; 8];
    if gap < 0 {
        full = groups;
    } else {
        for k in gap { full[k] = groups[k]; }
        let tail = n - gap;
        for k in tail { full[8 - tail + k] = groups[gap + k]; }
    }
    for k in 8 {
        a.ip[k * 2] = (full[k] >> 8) as u8;
        a.ip[k * 2 + 1] = (full[k] & 0xff) as u8;
    }
    return true;
}

// "ip:port" or "[ip]:port", numeric only, or "unix:/path" or "unix:///path" (the same path): an absolute path of at
// most 103 bytes with no NUL byte (and so no leading "@"). After "unix://" the path must begin with a single "/", so an
// authority and "unix:////x" do not parse; nothing is decoded or split. A host name does not parse.
fn _parse_address(text: const u8[:]) -> _Addr {
    var a = _Addr { .. };
    guard text.len > 0 else { return a; }
    if starts_with(text, "unix:") {
        var path = text[5..];
        if starts_with(path, "//") {
            path = path[2..];
            guard path.len > 0 && path[0] == '/' && !starts_with(path, "//") else { return a; }
        }
        guard path.len > 0 && path.len <= 103 && path[0] == '/' else { return a; }
        for c in path { if c == 0 { return a; } }
        a.unix = true;
        a.path.append(path);
        a.ok = true;
        return a;
    }
    var port_at = 0;
    if text[0] == '[' {
        var close = -1;
        for c, i in text { if c == ']' { close = i; break; } }
        guard close > 1 && close + 1 < text.len && text[close + 1] == ':' else { return a; }
        guard _parse_v6(text[1..close], a) else { return a; }
        a.v6 = true;
        port_at = close + 2;
    } else {
        var colon = -1;
        for c, i in text { if c == ':' { colon = i; break; } }
        guard colon > 0 else { return a; }
        guard _parse_v4(text[..colon], a) else { return a; }
        port_at = colon + 1;
    }
    let port, ok = _parse_number(text[port_at..], 65535);
    guard ok else { return a; }
    a.port = port as u16;
    a.ok = true;
    return a;
}

fn _push_decimal(out: u8[..56]&, v: i64) {
    if v >= 10 { _push_decimal_digits(out, v / 10); }
    out.push(('0' + v % 10) as u8);
}

// Up to four more leading digits: enough for a port (five digits in all).
fn _push_decimal_digits(out: u8[..56]&, v: i64) {
    var digits: u8[5] = [0; 5];
    var n = 0;
    var rest = v;
    while rest > 0 && n < 5 { digits[n] = ('0' + rest % 10) as u8; n++; rest = rest / 10; }
    for k in n { out.push(digits[n - 1 - k]); }
}

fn _push_hex(out: u8[..56]&, v: i64) {
    var started = false;
    for k in 4 {
        let nibble = (v >> ((3 - k) * 4)) & 0xf;
        if nibble != 0 || started || k == 3 {
            started = true;
            out.push((if nibble < 10 { '0' + nibble } else { 'a' + nibble - 10 }) as u8);
        }
    }
}

fn _format_address(a: _Addr) -> goose_io::Address {
    var out = goose_io::Address { .. };
    guard a.ok && !a.unix else { return out; }
    if a.v6 {
        var groups: i64[8] = [0; 8];
        for k in 8 { groups[k] = ((a.ip[k * 2] as i64) << 8) | a.ip[k * 2 + 1]; }
        // the longest run of two or more zero groups becomes "::"
        var best = -1;
        var best_len = 1;
        var k = 0;
        while k < 8 {
            if groups[k] == 0 {
                var run = 0;
                while k + run < 8 && groups[k + run] == 0 { run++; }
                if run > best_len { best = k; best_len = run; }
                k += run;
            } else {
                k++;
            }
        }
        out.text.push('[');
        k = 0;
        while k < 8 {
            if k == best {
                out.text.push(':');
                out.text.push(':');
                k += best_len;
            } else {
                if k > 0 && k != best + best_len { out.text.push(':'); }
                _push_hex(out.text, groups[k]);
                k++;
            }
        }
        out.text.push(']');
    } else {
        for k in 4 {
            if k > 0 { out.text.push('.'); }
            _push_decimal(out.text, a.ip[k]);
        }
    }
    out.text.push(':');
    _push_decimal(out.text, a.port);
    return out;
}

// --- internals: tables ---------------------------------------------------------------------------

let _FREE = 0;          // the slot is unused
let _DIALING = 1;       // dial returned; the connect has not finished
let _OPENING = 2;       // connected; its Opened is queued and not yet delivered
let _OPEN = 3;          // Opened was delivered
let _CLOSED = 4;        // its Closed is queued; nothing else will be delivered

let _EV_OPENED = 1;
let _EV_DATA = 2;
let _EV_WRITABLE = 3;
let _EV_PEER_EOF = 4;
let _EV_CLOSED = 5;

let _FOREVER = 0x7fffffffffffffff;
let _EPHEMERAL_PORTS = 16384;     // 49152 to 65535

// One end of a connection. Bytes sent to this end wait in its region of Loop.inbuf until its
// handler has been given them, so what a sender may still send is bounded by the receiver's
// unread bytes: that is the backpressure.
struct _Slot {
    gen:              u32                   = 1,
    state:            u8                    = 0,
    listener:         u32                   = 0,     // the listener that accepted it, 0 for a dialled link
    peer:             i64                   = -1,    // the slot of the other end, -1 when there is none (any more)
    script:           i64                   = -1,    // the scripted peer that plays this end, -1 for a library's link
    in_len:           i64                   = 0,     // unread bytes waiting for this end
    opened:           bool                  = false, // its Opened was delivered
    paused:           bool                  = false,
    keep_open:        bool                  = false,
    wr_shut:          bool                  = false, // this end finished sending
    peer_fin:         bool                  = false, // the other end finished sending (seen once in_len reaches 0)
    eof_seen:         bool                  = false,
    want_writable:    bool                  = false, // a send was refused with Full
    want_room:        i64                   = 0,     // the largest send refused since the last Writable
    refusals:         i64                   = 0,     // fault WritablePerRefusal
    writable_given:   bool                  = false, // fault OneWritableOnly
    data_queued:      bool                  = false, // a Data record for it is in the queue
    local_closed:     bool                  = false, // its owner called close or reset
    silent:           bool                  = false, // a dial to an address that never answers
    why:              goose_io::CloseReason = goose_io::CloseReason.Error,
    target:           _Addr                 = _Addr { .. }, // where a dial goes
    remote:           _Addr                 = _Addr { .. }, // the other end's address
    connect_at:       i64                   = 0,
    connect_deadline: i64                   = 0,
}

struct _Listener { addr: _Addr = _Addr { .. }, active: bool = false }

// A dial to addr fails with this kind (fail_dials).
struct _Failing { addr: _Addr = _Addr { .. }, kind: goose_io::ConnectFailure = goose_io::ConnectFailure.Other }

fn _failed(kind: goose_io::ConnectFailure) -> goose_io::CloseReason { goose_io::CloseReason.ConnectFailed { kind: kind } }

struct _Pending { kind: u8 = 0, slot: i64 = 0, gen: u32 = 0 }

// A scripted peer: the other end of one link, played by the test.
struct Peer { id: u32 = 0 }

let _ST_CONNECT = 1;
let _ST_SEND = 2;
let _ST_STOP_READING = 3;
let _ST_RESUME_READING = 4;
let _ST_SHUTDOWN = 5;
let _ST_CLOSE = 6;
let _ST_ABORT = 7;

struct _Script {
    addr:      _Addr = _Addr { .. },    // where it waits for a dial
    accepting: bool  = false,
    refuse:    bool  = false,
    taken:     bool  = false,           // it has had its one connection, or refused its one dial
    slot:      i64   = -1,              // its end of the link, -1 when it has none
    connected: bool  = false,
    saw_eof:   bool  = false,
    saw_reset: bool  = false,
    closed:    bool  = false,
    blocked:   bool  = false,           // its send was refused with Full and waits for Writable
    ready_at:  i64   = 0,               // when its previous step finished, or its link opened
    cursor:    i64   = 0,               // none of its unfinished steps is before this index
}

struct _Step {
    peer:     i64   = 0,
    kind:     u8    = 0,
    after_ms: i64   = 0,
    off:      i64   = 0,                // send: its bytes in Loop._step_bytes
    len:      i64   = 0,
    sent:     i64   = 0,
    done:     bool  = false,
    addr:     _Addr = _Addr { .. },     // connect: where to
}

struct _Chunk { peer: i64 = 0, off: i64 = 0, len: i64 = 0 }

// --- the event loop --------------------------------------------------------------------------------

// One loop. Declare it as a local or global (`var io = goose_io_memory::Loop { .. };`) and pass it
// by reference; it cannot be copied or returned.
root struct Loop {
    cfg:            Config         = Config { .. },
    _slots:         _Slot[>..]     = [],
    _free:          i64[>..<]      = [],
    _inbuf:         u8[>..]        = [], // slot i owns [i * link_buffer, (i + 1) * link_buffer)
    _scratch:       u8[>..]        = [], // the bytes lent by the Data event being delivered
    _listeners:     _Listener[>..] = [],
    _held:          _Addr[>..]     = [],
    _silent:        _Addr[>..]     = [],
    _failing:       _Failing[>..]  = [],
    _pending:       _Pending[>..<] = [],
    _pending_head:  i64            = 0,
    _clock:         i64            = 0,
    _next_tick:     i64            = 0,
    _wake_at:       i64            = 0x7fffffffffffffff,
    _busy_passes:   i64            = 0,
    _passes:        i64            = 0,
    _started:       bool           = false,
    _started_at:    i64            = 0,
    _draining:      bool           = false,
    _stop_deadline: i64            = 0x7fffffffffffffff,
    _library_links: i64            = 0, // links that are not scripted peers' ends and not free
    _live_slots:    i64            = 0, // of those, the ones not closed either: what max_links limits
    _next_port:     i64            = 49152,
    _hit_limit:     bool           = false,
    _scripts:       _Script[>..]   = [],
    _steps:         _Step[>..]     = [],
    _step_bytes:    u8[>..]        = [],
    _captured:      u8[>..]        = [], // what scripted peers received, in the pieces of _chunks
    _chunks:        _Chunk[>..]    = [],
    _last_remote:   _Addr          = _Addr { .. },   // fault StalePeerAddress
    _fault:         i64            = 0,  // a deliberately broken behaviour, for showing that a check fails (set_fault)
}

// The period of the regular Tick. Fault TickEvery250.
fn _tick_period(io: Loop&) -> i64 { if io._fault == 44 { 250 } else { io.cfg.tick_ms } }

fn _start(io: Loop&) {
    guard !io._started else { return; }
    io._started = true;
    io._started_at = io._clock;
    if io.cfg.max_send < 4096 { io.cfg.max_send = 4096; }
    if io.cfg.link_buffer < io.cfg.max_send { io.cfg.link_buffer = io.cfg.max_send; }
    if io.cfg.read_chunk < 1 { io.cfg.read_chunk = 1; }
    if io.cfg.read_chunk > io.cfg.link_buffer { io.cfg.read_chunk = io.cfg.link_buffer; }
    // A period that does not move the clock would make every pass deliver a Tick and never end.
    if io.cfg.tick_ms < 1 { io.cfg.tick_ms = 1; }
    if io.cfg.passes_per_ms < 1 { io.cfg.passes_per_ms = 1; }
    io._next_tick = io._clock + io._tick_period();
}

// The slot of a link whose handle is current (any state but free), or -1.
fn _slot_of(io: Loop&, link: goose_io::Link) -> i64 {
    if io._fault == 54 && link.gen == 0 {          // fault UnsetHandleAccepted: an unset handle names the first live link
        for i in io._slots.len { if io._slots[i].state != _FREE { return i; } }
        return -1;
    }
    guard link.gen != 0 && link.slot < io._slots.len else { return -1; }
    let s .= io._slots[link.slot];
    guard s.state != _FREE && (s.gen == link.gen || io._fault == 1) else { return -1; }
    return link.slot;
}

fn _link_of(io: Loop&, i: i64) -> goose_io::Link {
    goose_io::Link { slot: i as u32, gen: io._slots[i].gen }
}

fn _new_slot(io: Loop&, script: i64) -> i64 {
    var i = 0;
    if io._free.len > 0 && io._fault != 64 {       // fault SlotsNeverReused: a new slot for every link
        i = io._free[io._free.len - 1];
        io._free.pop();
        let gen = io._slots[i].gen;
        io._slots[i] = _Slot { gen: gen, .. };
    } else {
        i = io._slots.len;
        io._slots.push(_Slot { .. });
        io._inbuf.resize((i + 1) * io.cfg.link_buffer, 0);
    }
    io._slots[i].script = script;
    if script < 0 { io._library_links++; io._live_slots++; }
    return i;
}

fn _queue(io: Loop&, kind: u8, i: i64) {
    io._pending.push(_Pending { kind: kind, slot: i, gen: io._slots[i].gen });
}

// Ends slot i only: its Closed is queued and nothing else will be delivered for it.
fn _mark_closed(io: Loop&, i: i64, why: goose_io::CloseReason) {
    let s .= io._slots[i];
    guard s.state != _FREE && s.state != _CLOSED else { return; }
    // faults OpenedBeforeFailure and CancelledDialOpens: an Opened that must not be delivered
    if io._fault == 5 && goose_io::is_connect_failed(why) { io._queue(_EV_OPENED, i); }
    if io._fault == 38 && s.state == _DIALING && why == goose_io::CloseReason.Local { io._queue(_EV_OPENED, i); }
    s.state = _CLOSED;
    s.why = why;
    s.in_len = 0;
    s.want_writable = false;
    if s.script < 0 { io._live_slots--; }
    io._queue(_EV_CLOSED, i);
}

// Ends slot i and tells the other end. `abort` discards what the other end has not read and ends
// it with PeerReset; otherwise the other end reads what is left and then sees end of stream.
fn _close(io: Loop&, i: i64, why: goose_io::CloseReason, abort: bool) {
    let s .= io._slots[i];
    guard s.state != _FREE && s.state != _CLOSED else { return; }
    let p = s.peer;
    // fault ClosedNeverDelivered: a close with bytes the peer has not read never completes
    if io._fault == 41 && !abort && why == goose_io::CloseReason.Local && p >= 0 && io._slots[p].in_len > 0 { return; }
    s.peer = -1;
    io._mark_closed(i, why);
    guard p >= 0 else { return; }
    let other .= io._slots[p];
    other.peer = -1;
    if abort {
        io._mark_closed(p, goose_io::CloseReason.PeerReset);
    } else {
        other.peer_fin = true;
        if io._fault == 4 { other.in_len = 0; }      // fault PeerCloseDropsData
    }
}

// --- the contract: listening ---------------------------------------------------------------------

fn listen(io: Loop&, address: const u8[:]) -> goose_io::Listener, goose_io::ListenError {
    io._start();
    var a = io._addr(address);
    guard a.ok else { return goose_io::Listener { .. }, goose_io::ListenError { kind: goose_io::ListenErrorKind.BadAddress, code: 22 }; }
    guard !io._draining || io._fault == 51 else { return goose_io::Listener { .. }, goose_io::ListenError { kind: goose_io::ListenErrorKind.Other, code: 108 }; }
    // A handle is never issued twice, so there are only so many: fail, never wrap.
    guard io._listeners.len < io.cfg.max_listeners && io._listeners.len < 0xfffffffe else { return goose_io::Listener { .. }, goose_io::ListenError { kind: goose_io::ListenErrorKind.NoResources, code: 24 }; }
    if a.port == 0 && !a.unix {
        // One lap of the ephemeral range at most, skipping ports that are in use.
        var found = false;
        for _ in _EPHEMERAL_PORTS {
            a.port = io._take_port() as u16;
            if io._binding_free(a) { found = true; break; }
        }
        guard found else { return goose_io::Listener { .. }, goose_io::ListenError { kind: goose_io::ListenErrorKind.NoResources, code: 99 }; }
    }
    guard io._binding_free(a) else { return goose_io::Listener { .. }, goose_io::ListenError { kind: goose_io::ListenErrorKind.AddressInUse, code: 98 }; }
    if io._fault == 13 {            // fault ListenerHandleReused: a stopped listener's handle comes back
        for l, k in io._listeners {
            if !l.active && _same_endpoint(l.addr, a) {
                io._listeners[k].active = true;
                return goose_io::Listener { id: (k + 1) as u32 }, goose_io::ListenError { .. };
            }
        }
    }
    io._listeners.push(_Listener { addr: a, active: true });
    return goose_io::Listener { id: io._listeners.len as u32 }, goose_io::ListenError { .. };
}

// No held address and no active listener overlaps a.
// The address a text names. Fault Ipv6Unsupported: IPv6 text is not understood.
fn _addr(io: Loop&, text: const u8[:]) -> _Addr {
    var a = _parse_address(text);
    if io._fault == 19 && a.v6 { a = _Addr { .. }; }
    if !io.cfg.unix_paths && a.unix { a = _Addr { .. }; }
    if io._fault == 60 && !a.ok && starts_with(text, "unix:") && text.len > 5 && text[5] != '/' && text[5] != '@' && text.len <= 108 {      // fault UnixRelativeAccepted
        a = _Addr { ok: true, unix: true, .. };
        a.path.append(text[5..]);
    }
    if io._fault == 62 && starts_with(text, "unix://") { a = _Addr { .. }; }      // fault UnixTripleSlashRefused: the URL spelling is refused
    if io._fault == 63 && a.unix && starts_with(text, "unix://") && a.path.len < 103 {      // fault UnixAliasNotHeld: the URL spelling is a different endpoint
        var other: u8[..103] = [];
        other.push('~');
        other.append(a.path[..]);
        a.path = other;
    }
    if io._fault == 61 && a.unix && a.path.len > 100 { a = _Addr { .. }; }      // fault UnixLongestRefused: a long path is refused
    return a;
}

fn _binding_free(io: Loop&, a: _Addr) -> bool {
    if io._fault != 10 { for h in io._held { if _overlaps(h, a) { return false; } } }     // fault HeldIgnored
    if io._fault == 57 && a.unix { return true; }      // fault UnixOverlapIgnored: a path can be listened on twice
    for l in io._listeners { if l.active && _overlaps(l.addr, a) { return false; } }
    return true;
}

// The next port of the range for a system-chosen listener port or the remote port of an accepted
// link. It wraps inside the range and never leaves it.
fn _take_port(io: Loop&) -> i64 {
    let p = io._next_port;
    io._next_port++;
    if io._next_port > 65535 { io._next_port = 49152; }
    return p;
}

fn _listener_index(io: Loop&, l: goose_io::Listener) -> i64 {
    guard l.id != 0 && l.id <= io._listeners.len else { return -1; }
    guard io._listeners[l.id - 1].active else { return -1; }
    return l.id - 1;
}

fn listener_port(io: Loop&, l: goose_io::Listener) -> u16 {
    let i = io._listener_index(l);
    if i < 0 || io._fault == 11 { 0 } else if io._fault == 59 && io._listeners[i].addr.unix { 4242 } else { io._listeners[i].addr.port }      // fault UnixPortInvented
}

fn stop_listening(io: Loop&, l: goose_io::Listener) {
    let i = io._listener_index(l);
    if i >= 0 { io._listeners[i].active = false; }
    if i >= 0 && io._fault == 12 {          // fault StopListeningClosesLinks
        for k in io._slots.len {
            if io._slots[k].listener == l.id && io._slots[k].script < 0 { io._close(k, goose_io::CloseReason.Local, false); }
        }
    }
}

// --- the contract: links -------------------------------------------------------------------------

fn dial(io: Loop&, address: const u8[:], connect_ms: i64) -> goose_io::Link {
    io._start();
    let link = io._dial(io._addr(address), connect_ms, -1);
    if io._fault == 15 { return goose_io::Link { .. }; }        // fault DialReturnsInvalid
    return link;
}

fn _dial(io: Loop&, target: _Addr, connect_ms: i64, script: i64) -> goose_io::Link {
    let i = io._new_slot(script);
    let s .= io._slots[i];
    s.state = _DIALING;
    let link = goose_io::Link { slot: i as u32, gen: s.gen };
    if script < 0 && io._live_slots > io.cfg.max_links { io._close(i, _failed(goose_io::ConnectFailure.NoResources), false); return link; }
    s.target = target;
    if !s.target.ok { io._close(i, _failed(if io._fault == 18 { goose_io::ConnectFailure.Refused } else { goose_io::ConnectFailure.BadAddress }), false); return link; }
    if io._fault == 52 && io._draining && script < 0 { io._close(i, _failed(goose_io::ConnectFailure.NoResources), false); return link; }
    s.connect_at = io._clock;
    s.connect_deadline = io._clock + (if connect_ms > 0 { connect_ms } else { io.cfg.connect_timeout_ms }) / (if io._fault == 17 { 2 } else { 1 });
    for a in io._silent { if _same_endpoint(a, s.target) { s.silent = true; } }
    return link;
}

fn peer_address(io: Loop&, link: goose_io::Link) -> goose_io::Address {
    let i = io._slot_of(link);
    if i < 0 && io._fault == 14 { return _format_address(io._last_remote); }       // fault StalePeerAddress
    guard i >= 0 && io._slots[i].opened else { return goose_io::Address { .. }; }
    return _format_address(io._slots[i].remote);
}

fn send(io: Loop&, link: goose_io::Link, bytes: const u8[:]) -> goose_io::SendStatus {
    return io._send(link, bytes, "");
}

// Both parts or neither: the two lengths added are what must fit.
fn send2(io: Loop&, link: goose_io::Link, first: const u8[:], second: const u8[:]) -> goose_io::SendStatus {
    return io._send(link, first, second);
}

// What one send would accept now.
fn send_room(io: Loop&, link: goose_io::Link) -> i64 {
    if io._fault == 2 && link.gen == 0 { return io.cfg.max_send; }      // fault UnsetLinkHasRoom
    let i = io._slot_of(link);
    guard i >= 0 else { return 0; }
    let s .= io._slots[i];
    guard (s.state == _OPEN || (io._fault == 29 && s.state == _CLOSED)) && !s.wr_shut else { return 0; }      // fault RoomWhenClosed
    guard s.peer >= 0 else { return io.cfg.max_send; }
    let room = io.cfg.link_buffer - io._slots[s.peer].in_len;
    return if room < io.cfg.max_send { room } else { io.cfg.max_send };
}

fn max_send(io: Loop&) -> i64 {
    io._start();
    return io.cfg.max_send;
}

// While paused the link's bytes stay where they are, so its peer's sends fill up and are refused.
fn pause_reading(io: Loop&, link: goose_io::Link, paused: bool) {
    let i = io._slot_of(link);
    if i >= 0 && io._fault != 34 { io._slots[i].paused = paused; }
}

fn _send(io: Loop&, link: goose_io::Link, first: const u8[:], second: const u8[:]) -> goose_io::SendStatus {
    let i = io._slot_of(link);
    guard i >= 0 else { return goose_io::SendStatus.Closed; }
    let s .= io._slots[i];
    if io._fault == 21 && io._scratch.len > 0 { io._scratch[0] = 'X'; }      // fault SendClobbersLentBytes
    if s.state == _CLOSED && io._fault == 24 { return goose_io::SendStatus.Sent; }      // fault SendAfterCloseAccepted
    if s.wr_shut && io._fault == 55 { return goose_io::SendStatus.Sent; }      // fault SendAfterShutdownAccepted
    if s.state == _CLOSED || s.wr_shut { return goose_io::SendStatus.Closed; }
    if s.state != _OPEN { return if io._fault == 23 { goose_io::SendStatus.Sent } else { goose_io::SendStatus.NotOpen }; }      // fault SendBeforeOpenSent
    let total = first.len + second.len;
    if total == 0 { return goose_io::SendStatus.Sent; }
    if total > io.cfg.max_send {
        if io._fault == 27 { s.want_writable = true; s.want_room = 1; }      // fault TooLargeGivesWritable
        return goose_io::SendStatus.TooLarge;
    }
    if s.peer < 0 {
        // The other end is gone: the bytes are accepted and lost, and the link is reset.
        io._close(i, goose_io::CloseReason.PeerReset, false);
        return goose_io::SendStatus.Sent;
    }
    let p .= io._slots[s.peer];
    if total > io.cfg.link_buffer - p.in_len {
        if io._fault == 28 { return goose_io::SendStatus.Sent; }        // fault NeverFull: accepted and lost
        // One Writable for however many refusals, once the largest of them would fit.
        if !s.want_writable || total > s.want_room { s.want_room = total; }
        s.want_writable = true;
        s.refusals++;
        if io._fault == 26 && first.len > 0 && second.len > 0 && first.len <= io.cfg.link_buffer - p.in_len {     // fault Send2TakesFirstPart
            let at = s.peer * io.cfg.link_buffer + p.in_len;
            io._inbuf[at..at + first.len].move_from(first);
            p.in_len += first.len;
        }
        return goose_io::SendStatus.Full;
    }
    let base = s.peer * io.cfg.link_buffer + p.in_len;
    if io._fault == 25 && first.len > 0 && second.len > 0 {                // fault Send2SwapsParts
        io._inbuf[base..base + second.len].move_from(second);
        io._inbuf[base + second.len..base + total].move_from(first);
    } else {
        if first.len > 0 { io._inbuf[base..base + first.len].move_from(first); }
        if second.len > 0 { io._inbuf[base + first.len..base + total].move_from(second); }
    }
    p.in_len += total;
    if io._fault == 22 { p.in_len--; }                                      // fault SendDropsLastByte
    return goose_io::SendStatus.Sent;
}

fn close(io: Loop&, link: goose_io::Link) {
    let i = io._slot_of(link);
    guard i >= 0 && io._slots[i].state != _CLOSED else { return; }
    io._slots[i].local_closed = true;
    let unread = io._slots[i].in_len > 0;
    io._close(i, goose_io::CloseReason.Local, unread && io._fault == 40);      // fault CloseWithUnreadResets
}

// Closes at once. What the other end has not read is discarded and it ends with PeerReset.
fn reset(io: Loop&, link: goose_io::Link) {
    let i = io._slot_of(link);
    guard i >= 0 && io._slots[i].state != _CLOSED else { return; }
    io._slots[i].local_closed = true;
    io._close(i, goose_io::CloseReason.Local, io._fault != 39);      // fault ResetIsGraceful
}

// keep: the peer's end of stream is delivered as PeerEof and the link stays open for sending.
fn set_keep_open_on_eof(io: Loop&, link: goose_io::Link, keep: bool) {
    let i = io._slot_of(link);
    if i >= 0 { io._slots[i].keep_open = keep; }
}

// Ends this side's sending. The other end reads what was sent and then sees the end of the stream.
fn shutdown_write(io: Loop&, link: goose_io::Link) {
    let i = io._slot_of(link);
    guard i >= 0 else { return; }
    let s .= io._slots[i];
    guard s.state == _OPEN && !s.wr_shut else { return; }
    s.wr_shut = true;
    if io._fault != 35 { s.want_writable = false; }      // fault WritableAfterShutdown
    if s.peer >= 0 { io._slots[s.peer].peer_fin = true; }
    // The peer had finished already: both directions are done.
    if s.eof_seen { io._close(i, goose_io::CloseReason.PeerClosed, false); }
}

// --- the contract: time and the application side --------------------------------------------------

fn now_ms(io: Loop&) -> i64 { io._clock }

// Asks for a Tick at or after at_ms. Only the earliest request is kept, and the next Tick clears it.
fn tick_by(io: Loop&, at_ms: i64) {
    if io._fault == 45 { return; }                                   // fault TickByIgnored
    if at_ms < io._wake_at || io._fault == 46 { io._wake_at = at_ms; }      // fault TickByKeepsLatest
}

// Every listener stops now. serve returns when the last link has closed, or grace_ms from now,
// after closing what is left with Shutdown. Of several calls the earliest end of grace stands.
fn stop(io: Loop&, grace_ms: i64) {
    io._start();
    io._draining = true;
    for &l in io._listeners { l.active = false; }
    var deadline = io._clock + (if grace_ms > 0 { grace_ms } else { 0 });
    if io._fault == 50 { deadline = io._clock; }                      // fault ShutdownEarly
    if deadline < io._stop_deadline || io._fault == 53 { io._stop_deadline = deadline; }      // fault StopLatestWins
}

fn draining(io: Loop&) -> bool { io._draining }

fn serve<F>(io: Loop&) {
    io._start();
    // Sized here and never from an operation: a handler holds a slice of it while it calls operations.
    if io._scratch.len != io.cfg.read_chunk { io._scratch.resize(io.cfg.read_chunk, 0); }
    loop {
        var ticked = false;
        io._passes++;
        io._run_due();
        io._queue_reads();
        // The order of one pass: a Tick if one is due, the link events, then PassEnd, always last.
        if io._clock >= io._next_tick || io._clock >= io._wake_at {
            io._next_tick = io._clock + io._tick_period();
            io._wake_at = _FOREVER;
            ticked = true;
            let e: goose_io::Event = goose_io::Event.Tick { now_ms: io._clock };
            F(io, e);
        }
        let link_events = io._deliver(F);
        if (link_events > 0 || (io._fault == 48 && ticked)) && io._fault != 47 {      // faults NoPassEnd and IdlePassEnd
            let e: goose_io::Event = goose_io::Event.PassEnd {};
            F(io, e);
        }
        if io._draining && io._library_links == 0 && io._pending_head >= io._pending.len && !io._peer_read_work() && (io._fault != 49 || io._clock >= io._stop_deadline) { break; }      // fault StopWaitsForGrace
        io._advance();
        if io._hit_limit { break; }
    }
}

// --- internals: one pass -------------------------------------------------------------------------

// What has come due at the current time: the end of a grace period, connects, connect timeouts.
fn _run_due(io: Loop&) {
    if io._draining && io._clock >= io._stop_deadline {
        for i in io._slots.len {
            if io._slots[i].script < 0 { io._close(i, goose_io::CloseReason.Shutdown, false); }
        }
    }
    for i in io._slots.len {
        if io._slots[i].state == _DIALING {
            if !io._slots[i].silent && io._clock >= io._slots[i].connect_at { io._connect(i); }
            else if io._clock >= io._slots[i].connect_deadline { io._close(i, _failed(goose_io::ConnectFailure.TimedOut), false); }
        }
    }
    for k in io._scripts.len { io._run_script(k); }
}

// Finishes the dial in slot i: joins it to a listener's new link, or fails it.
fn _connect(io: Loop&, i: i64) {
    let target = io._slots[i].target;
    var found = -1;
    for l, k in io._listeners {
        if l.active && _listener_takes(l.addr, target) && !(io._fault == 56 && l.addr.unix) { found = k; break; }      // fault UnixListenerIgnored: a dial to a path never reaches its listener
    }
    for f in io._failing {
        if _same_endpoint(f.addr, target) { io._close(i, _failed(f.kind), false); return; }
    }
    var j = -1;
    if found >= 0 {
        if io._live_slots >= io.cfg.max_links {
            io._close(i, _failed(goose_io::ConnectFailure.NoResources), false);
            return;
        }
        j = io._new_slot(-1);
        io._slots[j].listener = (found + 1) as u32;
    } else {
        // no listener: the first scripted peer still waiting at this address takes the dial
        var k = -1;
        for sc, n in io._scripts {
            if sc.accepting && !sc.taken && _listener_takes(sc.addr, target) { k = n; break; }
        }
        if k >= 0 { io._scripts[k].taken = true; }
        if k < 0 || io._scripts[k].refuse {
            if k >= 0 { io._scripts[k].closed = true; }
            io._close(i, _failed(if io._fault == 16 { goose_io::ConnectFailure.Unreachable } else if io._fault == 58 && target.unix { goose_io::ConnectFailure.BadAddress } else { goose_io::ConnectFailure.Refused }), false);      // fault UnixRefusedAsBadAddress
            return;
        }
        j = io._new_slot(k);
        io._scripts[k].slot = j;
    }
    let accepted .= io._slots[j];
    accepted.state = _OPENING;
    accepted.peer = i;
    // the accepted end of a Unix link has no name: its remote formats as the empty value
    accepted.remote = if target.unix { target } else { _Addr { ok: true, v6: target.v6, ip: target.ip, port: io._take_port() as u16 } };
    let dialled .= io._slots[i];
    dialled.state = _OPENING;
    dialled.peer = j;
    dialled.remote = target;
    io._queue(_EV_OPENED, j);
    io._queue(_EV_OPENED, i);
}

// Every open link that has unread bytes gets one Data record; one whose peer has finished and
// that has read everything sees the end of the stream.
fn _queue_reads(io: Loop&) {
    for i in io._slots.len {
        let s .= io._slots[i];
        if s.state == _OPEN && !s.data_queued {
            if io._fault == 43 && s.keep_open && s.peer_fin && !s.eof_seen && s.in_len > 0 {      // fault PeerEofBeforeData
                s.eof_seen = true;
                io._queue(_EV_PEER_EOF, i);
            }
            if s.in_len > 0 {
                if !s.paused { s.data_queued = true; io._queue(_EV_DATA, i); }
            } else if s.peer_fin && !s.eof_seen {
                s.eof_seen = true;
                if s.keep_open {
                    io._queue(_EV_PEER_EOF, i);
                    // A refused send must not wait for ever on a peer that is gone: the retry is
                    // accepted and lost, and resets the link, as a send to a gone peer does.
                    if s.want_writable && s.peer < 0 && io._fault != 36 {      // fault FullUnresolvedOnPeerClose
                        s.want_writable = false;
                        io._queue(_EV_WRITABLE, i);
                    }
                }
                // Closed by default, and always once this end has finished sending too.
                if (!s.keep_open && io._fault != 42) || s.wr_shut { io._close(i, goose_io::CloseReason.PeerClosed, false); }      // fault EofIgnoresDefault
            }
        }
    }
}

// Calls the handler for every queued event, in order, including those the handler itself causes.
// Returns how many it delivered.
fn _deliver<F>(io: Loop&) -> i64 {
    var delivered = 0;
    while io._pending_head < io._pending.len {
        let r = io._pending[io._pending_head];
        io._pending_head++;
        let s .= io._slots[r.slot];
        if s.state != _FREE && s.gen == r.gen {
            let link = goose_io::Link { slot: r.slot as u32, gen: r.gen };
            if s.script >= 0 {
                io._peer_deliver(r.kind, r.slot);
            } else if r.kind == _EV_OPENED {
                // Not delivered when the owner already closed the link (a cancelled dial).
                if !s.local_closed || io._fault == 38 {
                    if s.state == _OPENING { s.state = _OPEN; }
                    s.opened = true;
                    let e: goose_io::Event = goose_io::Event.Opened { link: link, listener: goose_io::Listener { id: if io._fault == 9 { 0 } else if io._fault == 6 && s.listener != 0 { 1 } else { s.listener } } };      // faults OpenedWithoutListener and WrongListenerNamed
                    delivered++;
                    F(io, e);
                }
            } else if r.kind == _EV_DATA {
                s.data_queued = false;
                if s.state == _OPEN && !s.paused && s.in_len > 0 {
                    let n = if s.in_len < io.cfg.read_chunk { s.in_len } else { io.cfg.read_chunk };
                    let base = r.slot * io.cfg.link_buffer;
                    io._scratch[..n].move_from(io._inbuf[base..base + n]);
                    let rest = s.in_len - n;
                    if rest > 0 { io._inbuf[base..base + rest].move_from(io._inbuf[base + n..base + n + rest]); }
                    s.in_len = rest;
                    io._room_opened(s.peer);
                    if io._fault == 20 { io._scratch[0] = io._scratch[0] ^ 1; }      // fault DataCorrupted
                    let e: goose_io::Event = goose_io::Event.Data { link: link, bytes: io._scratch[..n] };
                    delivered++;
                    F(io, e);
                }
            } else if r.kind == _EV_WRITABLE {
                // not after shutdown_write, even if it was queued before the call: nothing can fit now
                if (s.state == _OPEN || io._fault == 37) && (!s.wr_shut || io._fault == 35) {
                    let e: goose_io::Event = goose_io::Event.Writable { link: link };
                    delivered++;
                    F(io, e);
                }
            } else if r.kind == _EV_PEER_EOF {
                if !s.local_closed {
                    let e: goose_io::Event = goose_io::Event.PeerEof { link: link };
                    delivered++;
                    F(io, e);
                }
            } else if r.kind == _EV_CLOSED {
                let e: goose_io::Event = goose_io::Event.Closed { link: if io._fault == 7 && goose_io::is_connect_failed(s.why) { goose_io::Link { .. } } else { link }, why: s.why };      // fault DialClosedLost
                delivered++;
                if io._fault == 3 { io._release(r.slot); }      // fault ClosedHandleStaleEarly
                F(io, e);
                if io._fault != 3 { io._release(r.slot); }
            }
        }
    }
    io._pending.clear();
    io._pending_head = 0;
    return delivered;
}

// The reader of slot `sender`'s bytes took some: a sender that was refused may now fit.
fn _room_opened(io: Loop&, sender: i64) {
    guard sender >= 0 else { return; }
    let s .= io._slots[sender];
    guard s.state == _OPEN && s.want_writable && s.peer >= 0 else { return; }
    if io._fault == 30 || (io._fault == 33 && s.writable_given) { return; }      // faults NoWritable and OneWritableOnly
    let room = io.cfg.link_buffer - io._slots[s.peer].in_len;
    if room >= (if io._fault == 32 { 1 } else { s.want_room }) {        // fault WritableOnFirstByte
        s.want_writable = false;
        s.writable_given = true;
        io._queue(_EV_WRITABLE, sender);
        if io._fault == 31 { for _ in s.refusals - 1 { io._queue(_EV_WRITABLE, sender); } }      // fault WritablePerRefusal
        s.refusals = 0;
    }
}

// The Closed of slot i has been delivered: the handle is stale from here on.
fn _release(io: Loop&, i: i64) {
    let s .= io._slots[i];
    io._last_remote = s.remote;
    if s.script < 0 { io._library_links--; }
    s.state = _FREE;
    s.gen++;
    if s.gen == 0 { s.gen = 1; }
    io._free.push(i);
}

// An open end with bytes it will be given, or an end of stream it has not been told of.
fn _has_read_work(s: _Slot) -> bool {
    (s.in_len > 0 && !s.paused) || (s.in_len == 0 && s.peer_fin && !s.eof_seen)
}

// Scripted peer k has nothing left to do, the library has finished sending, and it is about to hang up
// (see _run_script).
fn _will_hang_up(io: Loop&, k: i64) -> bool {
    let sc .= io._scripts[k];
    return sc.saw_eof && sc.slot >= 0 && io._slots[sc.slot].state == _OPEN && io._next_step(k) < 0;
}

// True while a scripted peer has something to read or a hang-up to make. A peer that was told to stop
// reading, and one whose next step is not yet due, have no such work: stop does not wait for them.
fn _peer_read_work(io: Loop&) -> bool {
    for i in io._slots.len {
        let s .= io._slots[i];
        if s.script >= 0 && s.state == _OPEN && _has_read_work(s) { return true; }
    }
    for k in io._scripts.len {
        if io._will_hang_up(k) { return true; }
    }
    return false;
}

// Nothing more can happen at this instant: move the clock to the next moment something is due.
fn _advance(io: Loop&) {
    var busy = io._pending_head < io._pending.len || io._wake_at <= io._clock;
    var next = if io._next_tick < io._wake_at { io._next_tick } else { io._wake_at };
    if io._draining && io._library_links > 0 {
        if io._stop_deadline <= io._clock { busy = true; }
        else if io._stop_deadline < next { next = io._stop_deadline; }
    }
    for i in io._slots.len {
        let s .= io._slots[i];
        if s.state == _OPEN {
            if _has_read_work(s) { busy = true; }
        } else if s.state == _DIALING {
            let due = if s.silent { s.connect_deadline } else { s.connect_at };
            if due <= io._clock { busy = true; }
            else if due < next { next = due; }
        }
    }
    for k in io._scripts.len {
        let sc .= io._scripts[k];
        let n = io._next_step(k);
        if n < 0 {
            if io._will_hang_up(k) { busy = true; }
        } else if io._steps[n].kind == _ST_CONNECT || (sc.connected && !sc.blocked) {
            let due = sc.ready_at + io._steps[n].after_ms;
            if due <= io._clock { busy = true; }
            else if due < next { next = due; }
        }
    }
    if busy {
        io._busy_passes++;
        if io._busy_passes >= io.cfg.passes_per_ms { io._busy_passes = 0; io._clock++; }
    } else {
        io._busy_passes = 0;
        if next > io._clock { io._clock = next; }
    }
    if io._clock - io._started_at > io.cfg.time_limit_ms {
        io._hit_limit = true;
        print("goose_io_memory: the loop ran for more than ", io.cfg.time_limit_ms, " ms of its own clock without serve returning (cfg.time_limit_ms): nothing called stop, or a link never closed");
        if io.cfg.exit_on_time_limit { exit(1); }
    }
}

// --- inspection ----------------------------------------------------------------------------------

// How many passes serve has made. A loop with nothing to do makes one pass per Tick, so a test can
// check that waiting costs nothing.
fn passes(io: Loop&) -> i64 { io._passes }

// True once serve gave up because cfg.time_limit_ms of the loop's clock passed (only reachable
// with cfg.exit_on_time_limit off; otherwise the program has exited).
fn hit_time_limit(io: Loop&) -> bool { io._hit_limit }

// Bytes the event loop accepted from this link and still holds because the other end has not read
// them. Never more than cfg.link_buffer.
fn stored_bytes(io: Loop&, link: goose_io::Link) -> i64 {
    let i = io._slot_of(link);
    guard i >= 0 && io._slots[i].peer >= 0 else { return 0; }
    return io._slots[io._slots[i].peer].in_len;
}

// --- scripting: peers ----------------------------------------------------------------------------
//
// A peer is the other end of one link, played by the test instead of by a library. It gets its
// link either by waiting at an address for a dial (peer_accept, peer_refuse) or by connecting to
// a listener on this loop (peer_connect). Then it does its steps in the order they were added.
// Each step has a delay: it runs that long after the step before it finished, or after the
// peer's link opened, whichever is later. A peer plays one connection; for a second connection
// to the same address add a second peer, and dials meet the peers in the order they were added.
//
// A peer reads everything sent to it unless told to stop, and hangs up by itself once the library
// has finished sending and it has no steps left.

fn add_peer(io: Loop&) -> Peer {
    io._start();
    io._scripts.push(_Script { ready_at: io._clock, .. });
    return Peer { id: io._scripts.len as u32 };
}

// The peer waits at `address` and accepts one dial to it.
fn peer_accept(io: Loop&, p: Peer, address: const u8[:]) {
    guard io._is_peer(p) else { return; }
    let sc .= io._scripts[p.id - 1];
    sc.addr = _parse_address(address);
    sc.accepting = sc.addr.ok;
    sc.refuse = false;
}

// The peer waits at `address` and refuses one dial to it: the dial fails with ConnectFailed, Refused.
fn peer_refuse(io: Loop&, p: Peer, address: const u8[:]) {
    io.peer_accept(p, address);
    if io._is_peer(p) { io._scripts[p.id - 1].refuse = true; }
}

// Step: connect to a listener on this loop.
fn peer_connect(io: Loop&, p: Peer, address: const u8[:], after_ms: i64) {
    io._add_step(p, _Step { kind: _ST_CONNECT, after_ms: after_ms, addr: _parse_address(address), .. });
}

// Step: send these bytes. More than fits goes out as the library reads; later steps wait for it.
fn peer_send(io: Loop&, p: Peer, after_ms: i64, bytes: const u8[:]) {
    let off = io._step_bytes.len;
    io._step_bytes.append(bytes);
    io._add_step(p, _Step { kind: _ST_SEND, after_ms: after_ms, off: off, len: bytes.len, .. });
}

// Step: stop reading, so the library's sends fill the link's bound and are refused.
fn peer_stop_reading(io: Loop&, p: Peer, after_ms: i64) { io._add_step(p, _Step { kind: _ST_STOP_READING, after_ms: after_ms, .. }); }

// Step: read again.
fn peer_resume_reading(io: Loop&, p: Peer, after_ms: i64) { io._add_step(p, _Step { kind: _ST_RESUME_READING, after_ms: after_ms, .. }); }

// Step: finish sending and keep receiving (a half-close).
fn peer_shutdown(io: Loop&, p: Peer, after_ms: i64) { io._add_step(p, _Step { kind: _ST_SHUTDOWN, after_ms: after_ms, .. }); }

// Step: close. The library reads what the peer sent and then sees a clean end.
fn peer_close(io: Loop&, p: Peer, after_ms: i64) { io._add_step(p, _Step { kind: _ST_CLOSE, after_ms: after_ms, .. }); }

// Step: abort. The library's link ends with PeerReset and what it had not read is lost.
fn peer_abort(io: Loop&, p: Peer, after_ms: i64) { io._add_step(p, _Step { kind: _ST_ABORT, after_ms: after_ms, .. }); }

// Everything the library has sent to the peer and the peer has read, in order.
fn peer_received(io: Loop&, p: Peer) -> u8[>..] {
    var out: u8[>..] = [];
    guard io._is_peer(p) else { return out; }
    for c in io._chunks {
        if c.peer == p.id - 1 { out.append(io._captured[c.off..c.off + c.len]); }
    }
    return out;
}

// The peer's link is open now.
fn peer_connected(io: Loop&, p: Peer) -> bool { io._is_peer(p) && io._scripts[p.id - 1].connected }

// The library finished sending to the peer (closed its link or called shutdown_write).
fn peer_saw_eof(io: Loop&, p: Peer) -> bool { io._is_peer(p) && io._scripts[p.id - 1].saw_eof }

// The library reset the peer's link.
fn peer_saw_reset(io: Loop&, p: Peer) -> bool { io._is_peer(p) && io._scripts[p.id - 1].saw_reset }

// The peer's link has ended, or its connect failed, or it refused its dial.
fn peer_closed(io: Loop&, p: Peer) -> bool { io._is_peer(p) && io._scripts[p.id - 1].closed }

fn _is_peer(io: Loop&, p: Peer) -> bool { p.id != 0 && p.id <= io._scripts.len }

fn _add_step(io: Loop&, p: Peer, step: _Step) {
    guard io._is_peer(p) else { return; }
    var st = step;
    st.peer = p.id - 1;
    io._steps.push(st);
}

// The index of peer k's first unfinished step, or -1.
fn _next_step(io: Loop&, k: i64) -> i64 {
    let sc .= io._scripts[k];
    while sc.cursor < io._steps.len {
        let st .= io._steps[sc.cursor];
        if st.peer == k && !st.done { return sc.cursor; }
        sc.cursor++;
    }
    return -1;
}

// Runs every step of peer k that is due.
fn _run_script(io: Loop&, k: i64) {
    loop {
        let sc .= io._scripts[k];
        let n = io._next_step(k);
        if n < 0 {
            // Nothing left to do and the library has finished sending: hang up.
            if sc.saw_eof && sc.slot >= 0 && io._slots[sc.slot].state == _OPEN {
                io._close(sc.slot, goose_io::CloseReason.Local, false);
            }
            return;
        }
        let st .= io._steps[n];
        if st.kind == _ST_CONNECT {
            guard io._clock >= sc.ready_at + st.after_ms else { return; }
            st.done = true;
            sc.ready_at = io._clock;
            // a peer plays one connection: a second connect step does nothing
            if !sc.taken {
                sc.taken = true;
                let link = io._dial(st.addr, 0, k);
                sc.slot = link.slot;
            }
        } else if sc.closed || (sc.taken && sc.slot < 0) {
            st.done = true;                 // its link is gone: the step can never run
        } else {
            guard sc.connected && !sc.blocked && io._clock >= sc.ready_at + st.after_ms else { return; }
            let i = sc.slot;
            let link = io._link_of(i);
            if st.kind == _ST_SEND {
                if io._slots[i].wr_shut { st.sent = st.len; }
                while st.sent < st.len {
                    let room = io.send_room(link);
                    let left = st.len - st.sent;
                    if room == 0 {
                        // register the refusal so that a Writable comes, and wait for it
                        let ask = if left < io.cfg.max_send { left } else { io.cfg.max_send };
                        let status = io._send(link, io._step_bytes[st.off + st.sent..st.off + st.sent + ask], "");
                        if status == goose_io::SendStatus.Full { sc.blocked = true; return; }
                        st.sent = st.len;   // the link ended under it
                    } else {
                        let take = if left < room { left } else { room };
                        let status = io._send(link, io._step_bytes[st.off + st.sent..st.off + st.sent + take], "");
                        if status == goose_io::SendStatus.Sent { st.sent += take; } else { st.sent = st.len; }
                    }
                }
            } else if st.kind == _ST_STOP_READING {
                io._slots[i].paused = true;
            } else if st.kind == _ST_RESUME_READING {
                io._slots[i].paused = false;
            } else if st.kind == _ST_SHUTDOWN {
                io.shutdown_write(link);
            } else if st.kind == _ST_CLOSE {
                io._slots[i].local_closed = true;
                io._close(i, goose_io::CloseReason.Local, false);
            } else if st.kind == _ST_ABORT {
                io._slots[i].local_closed = true;
                io._close(i, goose_io::CloseReason.Local, true);
            }
            st.done = true;
            sc.ready_at = io._clock;
        }
    }
}

// An event for a peer's end of a link: the peer takes it, no handler sees it.
fn _peer_deliver(io: Loop&, kind: u8, i: i64) {
    let s .= io._slots[i];
    let sc .= io._scripts[s.script];
    if kind == _EV_OPENED {
        if !s.local_closed {
            if s.state == _OPENING { s.state = _OPEN; }
            s.opened = true;
            s.keep_open = true;             // the test decides when a peer closes
            sc.connected = true;
            sc.ready_at = io._clock;
        }
    } else if kind == _EV_DATA {
        s.data_queued = false;
        if s.state == _OPEN && !s.paused && s.in_len > 0 {
            let n = if s.in_len < io.cfg.read_chunk { s.in_len } else { io.cfg.read_chunk };
            let base = i * io.cfg.link_buffer;
            io._chunks.push(_Chunk { peer: s.script, off: io._captured.len, len: n });
            io._captured.append(io._inbuf[base..base + n]);
            let rest = s.in_len - n;
            if rest > 0 { io._inbuf[base..base + rest].move_from(io._inbuf[base + n..base + n + rest]); }
            s.in_len = rest;
            io._room_opened(s.peer);
        }
    } else if kind == _EV_WRITABLE {
        sc.blocked = false;
    } else if kind == _EV_PEER_EOF {
        sc.saw_eof = true;
    } else if kind == _EV_CLOSED {
        if s.why == goose_io::CloseReason.PeerReset { sc.saw_reset = true; }
        sc.closed = true;
        sc.connected = false;
        sc.blocked = false;
        sc.slot = -1;
        io._release(i);
    }
}

// --- scripting: the event loop's own decisions ----------------------------------------------------

// Closes a link as an event loop may on its own policy, with any reason (IdleTimeout, Error,
// LoopSpecific { code }, ...), so a library can be tested against each. The other end sees a clean end.
fn close_with_reason(io: Loop&, link: goose_io::Link, why: goose_io::CloseReason) {
    let i = io._slot_of(link);
    if i >= 0 { io._close(i, why, false); }
}

// --- scripting: addresses ------------------------------------------------------------------------

// Makes listen on this address fail with AddressInUse, as if another process held it.
fn hold(io: Loop&, address: const u8[:]) {
    let a = _parse_address(address);
    if a.ok { io._held.push(a); }
}

// Makes a dial to this address fail at once with ConnectFailed of this kind, whatever listens
// there: Unreachable, Denied, NoResources, Other.
fn fail_dials(io: Loop&, address: const u8[:], kind: goose_io::ConnectFailure) {
    let a = _parse_address(address);
    if a.ok { io._failing.push(_Failing { addr: a, kind: kind }); }
}

// Makes a dial to this address never answer: it ends only when its connect time passes.
fn silent(io: Loop&, address: const u8[:]) {
    let a = _parse_address(address);
    if a.ok { io._silent.push(a); }
}

// --- faults --------------------------------------------------------------------------------------

// Switches the loop to a named fault: a deliberate break of one behaviour of the contract, so that the
// conformance suite can be shown to fail on it (see tests/conformance/faults.sh). Does nothing for a name
// it does not know.
fn set_fault(io: Loop&, name: const u8[:]) {
    let fault = _fault_named(name);
    if fault != 0 { io._fault = fault; }
}

fn _fault_named(name: const u8[:]) -> i64 {
    guard name.len > 0 else { return 0; }       // position 8 of the list is retired (it was UserReadAtDial)
    let names = [
        "StaleHandleAccepted", "UnsetLinkHasRoom", "ClosedHandleStaleEarly", "PeerCloseDropsData", "OpenedBeforeFailure",
        "WrongListenerNamed", "DialClosedLost", "", "OpenedWithoutListener", "HeldIgnored",
        "PortZeroReportsZero", "StopListeningClosesLinks", "ListenerHandleReused", "StalePeerAddress", "DialReturnsInvalid",
        "RefusedAsUnreachable", "TimeoutEarly", "BadAddressAsRefused", "Ipv6Unsupported", "DataCorrupted",
        "SendClobbersLentBytes", "SendDropsLastByte", "SendBeforeOpenSent", "SendAfterCloseAccepted", "Send2SwapsParts",
        "Send2TakesFirstPart", "TooLargeGivesWritable", "NeverFull", "RoomWhenClosed", "NoWritable",
        "WritablePerRefusal", "WritableOnFirstByte", "OneWritableOnly", "PauseIgnored", "WritableAfterShutdown",
        "FullUnresolvedOnPeerClose", "WritableAfterClose", "CancelledDialOpens", "ResetIsGraceful", "CloseWithUnreadResets",
        "ClosedNeverDelivered", "EofIgnoresDefault", "PeerEofBeforeData", "TickEvery250", "TickByIgnored",
        "TickByKeepsLatest", "NoPassEnd", "IdlePassEnd", "StopWaitsForGrace", "ShutdownEarly",
        "ListenAfterStop", "DialFailsWhileDraining", "StopLatestWins", "UnsetHandleAccepted", "SendAfterShutdownAccepted",
        "UnixListenerIgnored", "UnixOverlapIgnored", "UnixRefusedAsBadAddress", "UnixPortInvented", "UnixRelativeAccepted",
        "UnixLongestRefused", "UnixTripleSlashRefused", "UnixAliasNotHeld", "SlotsNeverReused",
    ];
    for n, i in names { if n == name { return i + 1; } }
    return 0;
}
