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
//     let listener, err = io.listen("127.0.0.1:8080");
//     let link = io.dial("127.0.0.1:8080", 0);
//     io.serve() { io, ev => handle(io, ev); };
//
// Reading guide. Goose has no privacy, so a leading underscore marks everything that is not part
// of the contract. Deliberate faults (see the end of the file) are checked with `io._faulty(...)`;
// every such line is a detour from the correct behaviour, never part of it. Comments that start
// with "POSSIBLE BUG" mark behaviour that looks wrong and should be checked against the contract.
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
    // Link ends of libraries at once, not connections: a joined pair is two. A dial beyond it fails
    // with ConnectFailed, NoResources. A retired slot (see `age_slot`) does not lower it.
    max_links:          i64  = 256,
    max_listeners:      i64  = 4096,    // listeners ever created: a handle is never used again, so they can run out
    connect_timeout_ms: i64  = 5000,    // what connect_ms 0 means
    tick_ms:            i64  = 100,     // the regular Tick period
    time_limit_ms:      i64  = 600000,  // a serve that runs this long in loop time has hung: fail
    exit_on_time_limit: bool = true,    // false: serve returns instead and hit_time_limit() is true
    passes_per_ms:      i64  = 64,      // busy passes at one instant before the clock moves 1 ms
    // Supply the unix group. false: unix:/path is refused with BadAddress, as by a loop without it.
    unix_paths:         bool = true,
    // The peek group: most bytes held for a link that waits for input; Input is delivered at it.
    peek_bound:         i64  = 4096,
    // The relay group: a relayed pair whose bytes cannot move for this long ends with Local on both links (0: never).
    relay_stall_ms:     i64  = 0,
    // The relay group: a relayed link whose peer takes none of its bytes for this long ends with Error
    // (the transport's timeout; 0: never).
    kernel_timeout_ms:  i64  = 0,
}

// --- constants -----------------------------------------------------------------------------------

let _FOREVER = 0x7fffffffffffffff;
let _MIN_MAX_SEND = 4096;
let _FIRST_EPHEMERAL_PORT = 49152;
let _LAST_PORT = 65535;
let _EPHEMERAL_PORTS = 16384;           // _FIRST_EPHEMERAL_PORT to _LAST_PORT
let _MAX_UNIX_PATH = 103;
let _LAST_GENERATION = 0xffffffff;
let _MAX_LISTENER_HANDLES = 0xfffffffe;

// The errno-style codes a ListenError carries.
let _ERR_INVALID = 22;                  // EINVAL
let _ERR_TOO_MANY_FILES = 24;           // EMFILE
let _ERR_ADDRESS_IN_USE = 98;           // EADDRINUSE
let _ERR_ADDRESS_NOT_AVAILABLE = 99;    // EADDRNOTAVAIL
let _ERR_SHUT_DOWN = 108;               // ESHUTDOWN

// The limits group: an index for each goose_io::Limit, into the per-slot limit arrays.
let _LIMIT_IDLE = 0;
let _LIMIT_SILENT = 1;
let _LIMIT_STALLED = 2;
let _LIMIT_HALF_OPEN = 3;
let _LIMIT_AGE = 4;
let _LIMIT_KINDS = 5;

// --- internals: addresses ------------------------------------------------------------------------

// A numeric endpoint, or, with `unix` set, the path of a Unix socket (the unix group): then ip, port and v6 are unused.
struct _Addr {
    ok:   bool       = false,
    v6:   bool       = false,
    ip:   u8[16]     = [0; 16],
    port: u16        = 0,
    unix: bool       = false,
    path: u8[..103]  = [],
}

fn _same_endpoint(left: _Addr, right: _Addr) -> bool {
    if left.unix || right.unix { return left.unix && right.unix && left.path[..] == right.path[..]; }
    return left.v6 == right.v6 && left.port == right.port && left.ip == right.ip;
}

fn _is_any(addr: _Addr) -> bool {
    if addr.unix { return false; }
    for byte in addr.ip { if byte != 0 { return false; } }
    return true;
}

// Two bindings overlap when one connection could be meant for both: the same family and port, and
// either address is the wildcard or they are equal. Overlapping listeners cannot coexist.
fn _overlaps(left: _Addr, right: _Addr) -> bool {
    if left.unix || right.unix { return _same_endpoint(left, right); }
    return left.v6 == right.v6 && left.port == right.port && (_is_any(left) || _is_any(right) || left.ip == right.ip);
}

// A listener on the wildcard address takes a dial to any address of its family.
fn _listener_takes(listening: _Addr, target: _Addr) -> bool {
    if listening.unix || target.unix { return _same_endpoint(listening, target); }
    return listening.v6 == target.v6 && listening.port == target.port && (listening.ip == target.ip || _is_any(listening));
}

fn _parse_number(text: const u8[:], limit: i64) -> i64, bool {
    guard text.len > 0 && text.len <= 5 else { return 0, false; }
    var value = 0;
    for byte in text {
        guard byte >= '0' && byte <= '9' else { return 0, false; }
        value = value * 10 + (byte - '0');
    }
    return value, value <= limit;
}

fn _parse_v4(text: const u8[:], addr: _Addr&) -> bool {
    var part_count = 0;
    var part_start = 0;
    for index in text.len + 1 {
        if index == text.len || text[index] == '.' {
            guard part_count < 4 else { return false; }
            let value, ok = _parse_number(text[part_start..index], 255);
            guard ok && index - part_start <= 3 else { return false; }
            addr.ip[part_count] = value as u8;
            part_count++;
            part_start = index + 1;
        }
    }
    return part_count == 4;
}

fn _hex_value(byte: u8) -> i64 {
    if byte >= '0' && byte <= '9' { return byte - '0'; }
    if byte >= 'a' && byte <= 'f' { return byte - 'a' + 10; }
    if byte >= 'A' && byte <= 'F' { return byte - 'A' + 10; }
    return -1;
}

fn _parse_v6(text: const u8[:], addr: _Addr&) -> bool {
    var groups: i64[8] = [0; 8];
    var count = 0;
    var gap = -1;           // the group index where "::" stands, or -1
    var index = 0;
    guard text.len >= 2 else { return false; }
    if text[0] == ':' {
        guard text[1] == ':' else { return false; }
        gap = 0;
        index = 2;
    }
    while index < text.len {
        guard count < 8 else { return false; }
        var value = 0;
        var digits = 0;
        while index < text.len && _hex_value(text[index]) >= 0 {
            value = value * 16 + _hex_value(text[index]);
            digits++;
            index++;
        }
        guard digits > 0 && digits <= 4 else { return false; }
        groups[count] = value;
        count++;
        if index == text.len { break; }
        guard text[index] == ':' else { return false; }
        index++;
        guard index < text.len else { return false; }          // a single trailing colon
        if text[index] == ':' {
            guard gap < 0 else { return false; }               // only one "::"
            gap = count;
            index++;
        }
    }
    // Without "::" all eight groups are written out; with it, at least one is left for it to stand for.
    guard (gap < 0 && count == 8) || (gap >= 0 && count < 8) else { return false; }
    var full: i64[8] = [0; 8];
    if gap < 0 {
        full = groups;
    } else {
        for group in gap { full[group] = groups[group]; }
        let tail = count - gap;
        for group in tail { full[8 - tail + group] = groups[gap + group]; }
    }
    for group in 8 {
        addr.ip[group * 2] = (full[group] >> 8) as u8;
        addr.ip[group * 2 + 1] = (full[group] & 0xff) as u8;
    }
    return true;
}

// "ip:port" or "[ip]:port", numeric only, or "unix:/path" or "unix:///path" (the same path): an absolute path of at
// most 103 bytes with no NUL byte (and so no leading "@"). After "unix://" the path must begin with a single "/", so an
// authority and "unix:////x" do not parse; nothing is decoded or split. A host name does not parse.
fn _parse_address(text: const u8[:]) -> _Addr {
    var addr = _Addr { .. };
    guard text.len > 0 else { return addr; }
    if starts_with(text, "unix:") { return _parse_unix_address(text); }
    var port_at = 0;
    if text[0] == '[' {
        var close_bracket = -1;
        for byte, index in text { if byte == ']' { close_bracket = index; break; } }
        guard close_bracket > 1 && close_bracket + 1 < text.len && text[close_bracket + 1] == ':' else { return addr; }
        guard _parse_v6(text[1..close_bracket], addr) else { return addr; }
        addr.v6 = true;
        port_at = close_bracket + 2;
    } else {
        var colon = -1;
        for byte, index in text { if byte == ':' { colon = index; break; } }
        guard colon > 0 else { return addr; }
        guard _parse_v4(text[..colon], addr) else { return addr; }
        port_at = colon + 1;
    }
    let port, ok = _parse_number(text[port_at..], _LAST_PORT);
    guard ok else { return addr; }
    addr.port = port as u16;
    addr.ok = true;
    return addr;
}

// The "unix:" forms of _parse_address.
fn _parse_unix_address(text: const u8[:]) -> _Addr {
    var addr = _Addr { .. };
    var path = text[5..];
    if starts_with(path, "//") {
        path = path[2..];
        guard path.len > 0 && path[0] == '/' && !starts_with(path, "//") else { return addr; }
    }
    guard path.len > 0 && path.len <= _MAX_UNIX_PATH && path[0] == '/' else { return addr; }
    for byte in path { if byte == 0 { return addr; } }
    addr.unix = true;
    addr.path.append(path);
    addr.ok = true;
    return addr;
}

// The decimal digits of a value that is not negative (an address byte or a port).
fn _push_decimal(out: u8[..56]&, value: i64) {
    var digits: u8[6] = [0; 6];
    var count = 0;
    var rest = value;
    loop {
        digits[count] = ('0' + rest % 10) as u8;
        count++;
        rest /= 10;
        if rest == 0 || count == 6 { break; }
    }
    for position in count { out.push(digits[count - 1 - position]); }
}

// One IPv6 group in lower-case hex, without leading zeros.
fn _push_hex(out: u8[..56]&, value: i64) {
    var started = false;
    for position in 4 {
        let nibble = (value >> ((3 - position) * 4)) & 0xf;
        if nibble != 0 || started || position == 3 {
            started = true;
            out.push((if nibble < 10 { '0' + nibble } else { 'a' + nibble - 10 }) as u8);
        }
    }
}

// Where the longest run of two or more zero groups starts and how long it is; -1 when there is none.
// That run is written as "::".
fn _longest_zero_run(groups: i64[8]) -> i64, i64 {
    var best_start = -1;
    var best_length = 1;
    var group = 0;
    while group < 8 {
        if groups[group] == 0 {
            var run = 0;
            while group + run < 8 && groups[group + run] == 0 { run++; }
            if run > best_length { best_start = group; best_length = run; }
            group += run;
        } else {
            group++;
        }
    }
    return best_start, best_length;
}

fn _format_address(addr: _Addr) -> goose_io::Address {
    var out = goose_io::Address { .. };
    guard addr.ok && !addr.unix else { return out; }
    if addr.v6 {
        var groups: i64[8] = [0; 8];
        for group in 8 { groups[group] = ((addr.ip[group * 2] as i64) << 8) | addr.ip[group * 2 + 1]; }
        let gap_start, gap_length = _longest_zero_run(groups);
        out.text.push('[');
        var group = 0;
        while group < 8 {
            if group == gap_start {
                out.text.push(':');
                out.text.push(':');
                group += gap_length;
            } else {
                if group > 0 && group != gap_start + gap_length { out.text.push(':'); }
                _push_hex(out.text, groups[group]);
                group++;
            }
        }
        out.text.push(']');
    } else {
        for part in 4 {
            if part > 0 { out.text.push('.'); }
            _push_decimal(out.text, addr.ip[part]);
        }
    }
    out.text.push(':');
    _push_decimal(out.text, addr.port);
    return out;
}

// --- internals: tables ---------------------------------------------------------------------------

enum _SlotState {
    Free,       // the slot is unused
    Dialing,    // dial returned; the connect has not finished
    Opening,    // connected; its Opened is queued and not yet delivered
    Open,       // Opened was delivered
    Closed,     // its Closed is queued; nothing else will be delivered
}

enum _EventKind { Opened, Data, Writable, PeerEof, Closed, Input, Expired }

// What wake carries across threads: flat.
struct _WakeMsg { id: u32 = 0, value: i64 = 0, body: u8[..64] = [] }

// A taken wake waiting for delivery as Woken.
struct _Woken { value: i64 = 0, body: u8[..64] = [] }

// POSSIBLE BUG: waker() increments this global without synchronisation. Loops made on different
// threads that call waker() at the same time can be given the same id, and then take each other's wakes.
var _loops_made: u32 = 0;

// One end of a connection. Bytes sent to this end wait in its region of Loop._inbuf until its
// handler has been given them, so what a sender may still send is bounded by the receiver's
// unread bytes: that is the backpressure.
//
// (Two fields of the previous version, seen_rx and seen_sig, were never read or written and are gone.)
struct _Slot {
    // identity
    gen:               u32                 = 1,
    state:             _SlotState          = _SlotState.Free,
    listener:          u32                 = 0,     // the listener that accepted it, 0 for a dialled link
    peer:              i64                 = -1,    // the slot of the other end, -1 when there is none (any more)
    script:            i64                 = -1,    // the scripted peer that plays this end, -1 for a library's link
    // connecting
    silent:            bool                = false, // a dial to an address that never answers
    target:            _Addr               = _Addr { .. }, // where a dial goes
    remote:            _Addr               = _Addr { .. }, // the other end's address
    connect_at:        i64                 = 0,
    connect_deadline:  i64                 = 0,
    // lifecycle
    opened:            bool                = false, // its Opened was delivered
    configured:        bool                = false, // the handler of its Opened has returned: keep_open can no longer change
    keep_open:         bool                = false,
    local_closed:      bool                = false, // its owner called close or reset
    close_reason:      goose_io::CloseReason    = goose_io::CloseReason.Error,
    // reading
    unread_len:        i64                 = 0,     // unread bytes waiting for this end
    paused:            bool                = false,
    data_queued:       bool                = false, // a Data record for it is in the queue
    peer_finished:     bool                = false, // the other end finished sending (seen once unread_len reaches 0)
    eof_seen:          bool                = false,
    // writing
    write_shut:        bool                = false, // this end finished sending
    want_writable:     bool                = false, // a send was refused with Full
    want_room:         i64                 = 0,     // the largest send refused since the last Writable
    // the relay group
    relay_partner:     i64                 = -1,    // the slot this one is joined to, -1 when it is not relayed
    relay_finished:    bool                = false, // its stream ended and the end was carried to the partner
    carried:           i64                 = 0,     // bytes carried from this link by a relay
    // the peek group
    wait_for:          i64                 = 0,     // wait_input's byte count, 0 when not waiting
    input_given:       bool                = false, // the Input for the current wait_input was queued
    // the revoke group
    write_deadline_at: i64                 = 0,     // write_deadline, 0 for none
    // the limits group, indexed by _LIMIT_*
    limit_ms:          i64[5]              = [0, 0, 0, 0, 0],   // set_limit, 0 for off
    // POSSIBLE BUG: documented as "when it was armed", but set_limit only sets it when a limit is armed
    // again after it expired; the first arming leaves it at 0. Only IdleFromArming reads it as an arming time.
    limit_armed_at:    i64[5]              = [0, 0, 0, 0, 0],
    limit_fired:       bool[5]             = [false, false, false, false, false],
    // activity, for the limits and the relay's timeouts
    opened_at:         i64                 = 0,
    consumed:          i64                 = 0,     // bytes taken out of this end's region, ever
    received_total:    i64                 = 0,     // bytes put into this end's region, ever
    last_input_at:     i64                 = 0,     // when a byte was last read from the link (or arrived)
    last_activity_at:  i64                 = 0,     // when a byte was last read or written (or carried by a relay)
    half_open_at:      i64                 = -1,    // when the peer's stream ended on a link that stays open
    stall_since:       i64                 = -1,    // when bytes began to wait for the transport without moving
    seen_progress:     i64                 = 0,     // the progress count _watch saw last
    // bookkeeping that only faults read
    refusals:          i64                 = 0,     // fault WritablePerRefusal
    refused_once:      bool                = false, // a send was refused with Full at some time (fault WritableAfterClosedResult)
    closed_result:     bool                = false, // a send has returned Closed (fault ClosedResultNotFinal)
    writable_given:    bool                = false, // fault OneWritableOnly
}

struct _Listener { addr: _Addr = _Addr { .. }, active: bool = false }

// A dial to addr fails with this kind (fail_dials).
struct _Failing { addr: _Addr = _Addr { .. }, kind: goose_io::ConnectFailure = goose_io::ConnectFailure.Other }

fn _failed(kind: goose_io::ConnectFailure) -> goose_io::CloseReason { goose_io::CloseReason.ConnectFailed { kind: kind } }

// One queued event. `limit` is used by Expired only.
struct _Pending {
    kind:  _EventKind = _EventKind.Opened,
    slot:  i64        = 0,
    gen:   u32        = 0,
    limit: goose_io::Limit = goose_io::Limit.Idle,
}

// A scripted peer: the other end of one link, played by the test.
struct Peer { id: u32 = 0 }

enum _StepKind { Connect, Send, StopReading, ResumeReading, Shutdown, Close, Abort }

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
    script:     i64       = 0,
    kind:       _StepKind = _StepKind.Connect,
    after_ms:   i64       = 0,
    bytes_at:   i64       = 0,          // send: where its bytes start in Loop._step_bytes
    byte_count: i64       = 0,
    sent:       i64       = 0,
    done:       bool      = false,
    addr:       _Addr     = _Addr { .. },   // connect: where to
}

// A piece of what a scripted peer received, in Loop._captured.
struct _Chunk { script: i64 = 0, start: i64 = 0, length: i64 = 0 }

// --- the event loop --------------------------------------------------------------------------------

// One loop. Declare it as a local or global (`var io = goose_io_memory::Loop { .. };`) and pass it
// by reference; it cannot be copied or returned.
root struct Loop {
    cfg:            Config         = Config { .. },
    // links
    _slots:         _Slot[>..]     = [],
    _free:          i64[>..<]      = [],
    _inbuf:         u8[>..]        = [], // slot N owns [N * link_buffer, (N + 1) * link_buffer)
    _scratch:       u8[>..]        = [], // the bytes lent by the Data event being delivered
    _library_links: i64            = 0,  // links that are not scripted peers' ends and not free
    _live_slots:    i64            = 0,  // of those, the ones not closed either: what max_links limits
    _pending:       _Pending[>..<] = [],
    _pending_head:  i64            = 0,
    // addresses
    _listeners:     _Listener[>..] = [],
    _held:          _Addr[>..]     = [],
    _silent:        _Addr[>..]     = [],
    _failing:       _Failing[>..]  = [],
    _next_port:     i64            = 49152,
    // time
    _clock:         i64            = 0,
    _next_tick:     i64            = 0,
    _wake_at:       i64            = _FOREVER,
    _busy_passes:   i64            = 0,
    _passes:        i64            = 0,
    _started:       bool           = false,
    _started_at:    i64            = 0,
    _hit_limit:     bool           = false,
    // stopping
    _draining:      bool           = false,
    _finished:      bool           = false, // serve has returned: every operation does nothing (*A finished loop does nothing*)
    _stop_deadline: i64            = _FOREVER,
    // the wake group
    _waker_id:      u32            = 0,     // this loop's id, 0 until waker() is first called
    _woken_values:  _Woken[>..<]   = [],    // values taken from the queue, to be delivered as Woken
    _woken_head:    i64            = 0,
    _expect_wakes:  i64            = 0,     // scripting: wakes a test thread will still make; an idle loop waits for them
    // scripting
    _scripts:       _Script[>..]   = [],
    _steps:         _Step[>..]     = [],
    _step_bytes:    u8[>..]        = [],
    _captured:      u8[>..]        = [], // what scripted peers received, in the pieces of _chunks
    _chunks:        _Chunk[>..]    = [],
    // faults
    _last_remote:   _Addr          = _Addr { .. },   // fault StalePeerAddress
    _fault:         u8[>..]        = [],            // str() of the broken behaviour set by set_fault, empty for none
}

fn _faulty(io: Loop&, fault: Fault) -> bool { io._fault.len > 0 && io._fault[..] == str(fault) }

// The period of the regular Tick.
fn _tick_period(io: Loop&) -> i64 { if io._faulty(Fault.TickEvery250) { 250 } else { io.cfg.tick_ms } }

fn _start(io: Loop&) {
    guard !io._started else { return; }
    io._started = true;
    io._started_at = io._clock;
    io.cfg.max_send = max(io.cfg.max_send, _MIN_MAX_SEND);
    io.cfg.link_buffer = max(io.cfg.link_buffer, io.cfg.max_send);
    io.cfg.read_chunk = min(max(io.cfg.read_chunk, 1), io.cfg.link_buffer);
    // A period that does not move the clock would make every pass deliver a Tick and never end.
    io.cfg.tick_ms = max(io.cfg.tick_ms, 1);
    io.cfg.passes_per_ms = max(io.cfg.passes_per_ms, 1);
    io._next_tick = io._clock + io._tick_period();
}

// --- internals: slots ----------------------------------------------------------------------------

// The slot of a link whose handle is current (any state but free), or -1.
fn _slot_of(io: Loop&, link: goose_io::Link) -> i64 {
    if io._faulty(Fault.UnsetHandleAccepted) && link.gen == 0 {      // an unset handle names the first live link
        for slot in io._slots.len { if io._slots[slot].state != _SlotState.Free { return slot; } }
        return -1;
    }
    guard link.gen != 0 && link.slot < io._slots.len else { return -1; }
    let link_end .= io._slots[link.slot];
    let generation_matches = link_end.gen == link.gen || io._faulty(Fault.StaleHandleAccepted);
    guard link_end.state != _SlotState.Free && generation_matches else { return -1; }
    return link.slot;
}

fn _link_of(io: Loop&, slot: i64) -> goose_io::Link {
    goose_io::Link { slot: slot as u32, gen: io._slots[slot].gen }
}

fn _is_ended(link_end: _Slot) -> bool {
    link_end.state == _SlotState.Free || link_end.state == _SlotState.Closed
}

// `script_index` is the scripted peer that plays the new end, or -1 for a library's link.
fn _new_slot(io: Loop&, script_index: i64) -> i64 {
    var slot = 0;
    if io._free.len > 0 && !io._faulty(Fault.SlotsNeverReused) {
        slot = io._free[io._free.len - 1];
        io._free.pop();
        let generation = io._slots[slot].gen;
        io._slots[slot] = _Slot { gen: generation, .. };
    } else {
        slot = io._slots.len;
        io._slots.push(_Slot { .. });
        // POSSIBLE BUG: this can move _inbuf, and peek() hands out a slice of it. A handler that peeks and
        // then dials (or has a dial accepted in the same pass) holds a slice into the old buffer.
        // _scratch avoids this by being sized only in serve; peek has no such protection.
        io._inbuf.resize((slot + 1) * io.cfg.link_buffer, 0);
    }
    io._slots[slot].script = script_index;
    io._slots[slot].configured = script_index >= 0;           // a scripted end has no Opened handler: its keep-open is the test's
    if script_index < 0 { io._library_links++; io._live_slots++; }
    return slot;
}

fn _queue(io: Loop&, kind: _EventKind, slot: i64) {
    io._pending.push(_Pending { kind: kind, slot: slot, gen: io._slots[slot].gen, .. });
}

// Takes the first `count` unread bytes out of a slot's region (the caller has copied them) and
// moves the rest down.
fn _consume(io: Loop&, slot: i64, count: i64) {
    let link_end .= io._slots[slot];
    let base = slot * io.cfg.link_buffer;
    let rest = link_end.unread_len - count;
    if rest > 0 { io._inbuf[base..base + rest].move_from(io._inbuf[base + count..base + count + rest]); }
    link_end.unread_len = rest;
    link_end.consumed += count;
}

// The reason a relayed partner ends with when its link ends with `why`: never PeerReset.
fn _relay_partner_reason(io: Loop&, why: goose_io::CloseReason) -> goose_io::CloseReason {
    if why == goose_io::CloseReason.PeerClosed || why == goose_io::CloseReason.Local || why == goose_io::CloseReason.Shutdown { return why; }
    if io._faulty(Fault.RelayPartnerPeerReset) && why == goose_io::CloseReason.PeerReset { return why; }
    return goose_io::CloseReason.Error;
}

// Ends one slot only: its Closed is queued and nothing else will be delivered for it. A relayed
// pair ends as one (D3, D6 item 1); `abort` says whether this end is being aborted, and then the
// partner is aborted too.
recursive fn _mark_closed(io: Loop&, slot: i64, why: goose_io::CloseReason, abort: bool) {
    let link_end .= io._slots[slot];
    guard !_is_ended(link_end) else { return; }
    // an Opened that must not be delivered
    if io._faulty(Fault.OpenedBeforeFailure) && goose_io::is_connect_failed(why) { io._queue(_EventKind.Opened, slot); }
    if io._faulty(Fault.CancelledDialOpens) && link_end.state == _SlotState.Dialing && why == goose_io::CloseReason.Local {
        io._queue(_EventKind.Opened, slot);
    }
    link_end.state = _SlotState.Closed;
    link_end.close_reason = why;
    link_end.unread_len = 0;
    link_end.want_writable = false;
    if link_end.script < 0 { io._live_slots--; }
    io._queue(_EventKind.Closed, slot);

    guard link_end.relay_partner >= 0 else { return; }
    let partner = link_end.relay_partner;
    link_end.relay_partner = -1;
    let partner_end .= io._slots[partner];
    guard !_is_ended(partner_end) else { return; }
    partner_end.relay_partner = -1;
    let partner_why = io._relay_partner_reason(why);
    if io._faulty(Fault.RelayCloseEndsOne) && why == goose_io::CloseReason.Local { return; }      // the partner stays open
    let partner_abort = abort || partner_why == goose_io::CloseReason.Error || partner_why == goose_io::CloseReason.PeerReset;
    io._close(partner, partner_why, partner_abort);
}

// Ends a slot and tells the other end. `abort` discards what the other end has not read and ends
// it with PeerReset; otherwise the other end reads what is left and then sees end of stream.
// Prefer _close_gracefully and _abort where the choice is fixed.
recursive fn _close(io: Loop&, slot: i64, why: goose_io::CloseReason, abort: bool) {
    let link_end .= io._slots[slot];
    guard !_is_ended(link_end) else { return; }
    let peer = link_end.peer;
    // a close with bytes the peer has not read never completes
    if io._faulty(Fault.ClosedNeverDelivered) && !abort && why == goose_io::CloseReason.Local && peer >= 0 && io._slots[peer].unread_len > 0 { return; }
    link_end.peer = -1;
    io._mark_closed(slot, why, abort);
    guard peer >= 0 else { return; }
    let peer_end .= io._slots[peer];
    peer_end.peer = -1;
    if abort {
        io._mark_closed(peer, goose_io::CloseReason.PeerReset, false);
    } else {
        peer_end.peer_finished = true;
        if io._faulty(Fault.PeerCloseDropsData) { peer_end.unread_len = 0; }
    }
}

fn _close_gracefully(io: Loop&, slot: i64, why: goose_io::CloseReason) { io._close(slot, why, false); }

fn _abort(io: Loop&, slot: i64, why: goose_io::CloseReason) { io._close(slot, why, true); }

fn _fail_dial(io: Loop&, slot: i64, kind: goose_io::ConnectFailure) { io._close_gracefully(slot, _failed(kind)); }

// --- internals: binding --------------------------------------------------------------------------

fn _listen_failed(kind: goose_io::ListenErrorKind, code: i64) -> goose_io::Listener, goose_io::ListenError {
    return goose_io::Listener { .. }, goose_io::ListenError { kind: kind, code: code as i32 };
}

// The address a text names, as this loop understands it.
fn _addr(io: Loop&, text: const u8[:]) -> _Addr {
    var addr = _parse_address(text);
    if io._faulty(Fault.Ipv6Unsupported) && addr.v6 { addr = _Addr { .. }; }
    if !io.cfg.unix_paths && addr.unix { addr = _Addr { .. }; }
    if io._faulty(Fault.UnixRelativeAccepted) && !addr.ok && starts_with(text, "unix:") && text.len > 5 && text[5] != '/' && text[5] != '@' && text.len <= 108 {
        addr = _Addr { ok: true, unix: true, .. };
        addr.path.append(text[5..]);
    }
    if io._faulty(Fault.UnixTripleSlashRefused) && starts_with(text, "unix://") { addr = _Addr { .. }; }      // the URL spelling is refused
    if io._faulty(Fault.UnixAliasNotHeld) && addr.unix && starts_with(text, "unix://") && addr.path.len < _MAX_UNIX_PATH {
        // the URL spelling is a different endpoint
        var other: u8[..103] = [];
        other.push('~');
        other.append(addr.path[..]);
        addr.path = other;
    }
    if io._faulty(Fault.UnixLongestRefused) && addr.unix && addr.path.len > 100 { addr = _Addr { .. }; }      // a long path is refused
    return addr;
}

// No held address and no active listener overlaps addr.
fn _binding_free(io: Loop&, addr: _Addr) -> bool {
    if !io._faulty(Fault.HeldIgnored) {
        for held in io._held { if _overlaps(held, addr) { return false; } }
    }
    if io._faulty(Fault.UnixOverlapIgnored) && addr.unix { return true; }      // a path can be listened on twice
    for listener in io._listeners { if listener.active && _overlaps(listener.addr, addr) { return false; } }
    return true;
}

// The next port of the range for a system-chosen listener port or the remote port of an accepted
// link. It wraps inside the range and never leaves it.
fn _take_port(io: Loop&) -> i64 {
    let port = io._next_port;
    io._next_port++;
    if io._next_port > _LAST_PORT { io._next_port = _FIRST_EPHEMERAL_PORT; }
    return port;
}

fn _listener_index(io: Loop&, listener: goose_io::Listener) -> i64 {
    guard listener.id != 0 && listener.id <= io._listeners.len else { return -1; }
    guard io._listeners[listener.id - 1].active else { return -1; }
    return listener.id - 1;
}

// --- the contract: listening ---------------------------------------------------------------------

fn listen(io: Loop&, address: const u8[:]) -> goose_io::Listener, goose_io::ListenError {
    if io._finished { return _listen_failed(goose_io::ListenErrorKind.Other, _ERR_SHUT_DOWN); }
    io._start();
    var addr = io._addr(address);
    guard addr.ok else { return _listen_failed(goose_io::ListenErrorKind.BadAddress, _ERR_INVALID); }
    guard !io._draining || io._faulty(Fault.ListenAfterStop) else { return _listen_failed(goose_io::ListenErrorKind.Other, _ERR_SHUT_DOWN); }
    // A handle is never issued twice, so there are only so many: fail, never wrap.
    guard io._listeners.len < io.cfg.max_listeners && io._listeners.len < _MAX_LISTENER_HANDLES else {
        return _listen_failed(goose_io::ListenErrorKind.NoResources, _ERR_TOO_MANY_FILES);
    }
    if addr.port == 0 && !addr.unix {
        // One lap of the ephemeral range at most, skipping ports that are in use.
        var found = false;
        for _ in _EPHEMERAL_PORTS {
            addr.port = io._take_port() as u16;
            if io._binding_free(addr) { found = true; break; }
        }
        guard found else { return _listen_failed(goose_io::ListenErrorKind.NoResources, _ERR_ADDRESS_NOT_AVAILABLE); }
    }
    guard io._binding_free(addr) else { return _listen_failed(goose_io::ListenErrorKind.AddressInUse, _ERR_ADDRESS_IN_USE); }
    if io._faulty(Fault.ListenerHandleReused) {      // a stopped listener's handle comes back
        for listener, index in io._listeners {
            if !listener.active && _same_endpoint(listener.addr, addr) {
                io._listeners[index].active = true;
                return goose_io::Listener { id: (index + 1) as u32 }, goose_io::ListenError { .. };
            }
        }
    }
    io._listeners.push(_Listener { addr: addr, active: true });
    return goose_io::Listener { id: io._listeners.len as u32 }, goose_io::ListenError { .. };
}

fn listener_port(io: Loop&, listener: goose_io::Listener) -> u16 {
    let index = io._listener_index(listener);
    guard index >= 0 && !io._faulty(Fault.PortZeroReportsZero) else { return 0; }
    let addr = io._listeners[index].addr;
    if io._faulty(Fault.UnixPortInvented) && addr.unix { return 4242; }
    return addr.port;
}

fn stop_listening(io: Loop&, listener: goose_io::Listener) {
    if io._finished { return; }
    let index = io._listener_index(listener);
    guard index >= 0 else { return; }
    io._listeners[index].active = false;
    if io._faulty(Fault.StopListeningClosesLinks) {
        for slot in io._slots.len {
            if io._slots[slot].listener == listener.id && io._slots[slot].script < 0 { io._close_gracefully(slot, goose_io::CloseReason.Local); }
        }
    }
}

// --- the contract: links -------------------------------------------------------------------------

fn dial(io: Loop&, address: const u8[:], connect_ms: i64) -> goose_io::Link {
    // on a finished loop: the invalid link, no link issued and no connection started
    if io._finished && !io._faulty(Fault.FinishedDialIssues) { return goose_io::Link { .. }; }
    io._start();
    let link = io._dial(io._addr(address), connect_ms, -1);
    if io._faulty(Fault.DialReturnsInvalid) { return goose_io::Link { .. }; }
    return link;
}

fn _dial(io: Loop&, target: _Addr, connect_ms: i64, script_index: i64) -> goose_io::Link {
    let slot = io._new_slot(script_index);
    let link_end .= io._slots[slot];
    link_end.state = _SlotState.Dialing;
    let link = goose_io::Link { slot: slot as u32, gen: link_end.gen };
    let by_library = script_index < 0;
    if by_library && io._live_slots > io.cfg.max_links {
        io._fail_dial(slot, goose_io::ConnectFailure.NoResources);
        return link;
    }
    link_end.target = target;
    if !target.ok {
        let kind = if io._faulty(Fault.BadAddressAsRefused) { goose_io::ConnectFailure.Refused } else { goose_io::ConnectFailure.BadAddress };
        io._fail_dial(slot, kind);
        return link;
    }
    if io._faulty(Fault.DialFailsWhileDraining) && io._draining && by_library {
        io._fail_dial(slot, goose_io::ConnectFailure.NoResources);
        return link;
    }
    let timeout = if connect_ms > 0 { connect_ms } else { io.cfg.connect_timeout_ms };
    let divisor = if io._faulty(Fault.TimeoutEarly) { 2 } else { 1 };
    link_end.connect_at = io._clock;
    link_end.connect_deadline = io._clock + timeout / divisor;
    for silent_addr in io._silent { if _same_endpoint(silent_addr, target) { link_end.silent = true; } }
    return link;
}

fn peer_address(io: Loop&, link: goose_io::Link) -> goose_io::Address {
    let slot = io._slot_of(link);
    if slot < 0 && io._faulty(Fault.StalePeerAddress) { return _format_address(io._last_remote); }
    if io._finished && io._faulty(Fault.PeerAddressAfterFinish) {
        var invented = goose_io::Address { .. };
        invented.text.append("10.0.0.1:1");
        return invented;
    }
    guard slot >= 0 && io._slots[slot].opened else { return goose_io::Address { .. }; }
    if io._faulty(Fault.PeerAddressGoneOnClose) && io._slots[slot].state == _SlotState.Closed { return goose_io::Address { .. }; }
    return _format_address(io._slots[slot].remote);
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
    if io._finished { return 0; }
    if io._faulty(Fault.UnsetLinkHasRoom) && link.gen == 0 { return io.cfg.max_send; }
    let slot = io._slot_of(link);
    guard slot >= 0 else { return 0; }
    let link_end .= io._slots[slot];
    let sendable = link_end.state == _SlotState.Open || (io._faulty(Fault.RoomWhenClosed) && link_end.state == _SlotState.Closed);
    guard sendable && !link_end.write_shut else { return 0; }
    guard link_end.relay_partner < 0 else { return 0; }
    guard link_end.peer >= 0 else { return io.cfg.max_send; }
    let room = io.cfg.link_buffer - io._slots[link_end.peer].unread_len;
    return min(room, io.cfg.max_send);
}

fn max_send(io: Loop&) -> i64 {
    io._start();
    return io.cfg.max_send;
}

// While paused the link's bytes stay where they are, so its peer's sends fill up and are refused.
fn pause_reading(io: Loop&, link: goose_io::Link, paused: bool) {
    if io._finished { return; }
    let slot = io._slot_of(link);
    guard slot >= 0 else { return; }
    let link_end .= io._slots[slot];
    if link_end.relay_partner >= 0 { return; }      // a relayed link is read by its relay
    if io._faulty(Fault.PauseIgnored) { return; }
    if io._faulty(Fault.PauseBeforeOpenIgnored) && link_end.state == _SlotState.Dialing { return; }
    link_end.paused = paused;
}

fn _send(io: Loop&, link: goose_io::Link, first: const u8[:], second: const u8[:]) -> goose_io::SendStatus {
    if io._finished { return if io._faulty(Fault.SendAfterFinishSent) { goose_io::SendStatus.Sent } else { goose_io::SendStatus.Closed }; }
    let slot = io._slot_of(link);
    guard slot >= 0 else { return goose_io::SendStatus.Closed; }
    let link_end .= io._slots[slot];
    if io._faulty(Fault.SendClobbersLentBytes) && io._scratch.len > 0 { io._scratch[0] = 'X'; }
    if io._faulty(Fault.SendAfterCloseAccepted) && link_end.state == _SlotState.Closed { return goose_io::SendStatus.Sent; }
    if io._faulty(Fault.SendAfterShutdownAccepted) && link_end.write_shut { return goose_io::SendStatus.Sent; }
    if link_end.state == _SlotState.Closed || link_end.write_shut {
        if io._faulty(Fault.ClosedResultNotFinal) && link_end.closed_result { return goose_io::SendStatus.Sent; }
        link_end.closed_result = true;
        if io._faulty(Fault.ClosedResultEndsShutLink) && link_end.write_shut && link_end.state == _SlotState.Open {
            io._close_gracefully(slot, goose_io::CloseReason.PeerClosed);
        }
        return goose_io::SendStatus.Closed;
    }
    if link_end.state != _SlotState.Open { return if io._faulty(Fault.SendBeforeOpenSent) { goose_io::SendStatus.Sent } else { goose_io::SendStatus.NotOpen }; }
    // a relayed link is sent to by its relay only
    if link_end.relay_partner >= 0 && !io._faulty(Fault.RelayedSendAccepted) { return goose_io::SendStatus.Closed; }
    let deadline_passed = link_end.write_deadline_at > 0 && io._clock >= link_end.write_deadline_at;
    if deadline_passed {
        io._expire_deadline(slot);
        return goose_io::SendStatus.Closed;
    }
    let total = first.len + second.len;
    if total == 0 { return goose_io::SendStatus.Sent; }
    if total > io.cfg.max_send {
        if io._faulty(Fault.TooLargeGivesWritable) { link_end.want_writable = true; link_end.want_room = 1; }
        return goose_io::SendStatus.TooLarge;
    }
    if link_end.peer < 0 {
        // The other end is gone: the bytes are accepted and lost, and the link is reset.
        io._close_gracefully(slot, goose_io::CloseReason.PeerReset);
        return goose_io::SendStatus.Sent;
    }
    let peer_end .= io._slots[link_end.peer];
    // A link that waits for input reads no more than the peek bound into the library's view (see _input_ready), but the bytes
    // beyond it stay in the region, which stands for the kernel's buffer: the sender is held back by that buffer, as with a socket.
    let capacity = io.cfg.link_buffer;
    let free_space = capacity - peer_end.unread_len;
    let base = link_end.peer * io.cfg.link_buffer + peer_end.unread_len;
    if total > free_space {
        if io._faulty(Fault.NeverFull) { return goose_io::SendStatus.Sent; }        // accepted and lost
        // One Writable for however many refusals, once the largest of them would fit.
        if !link_end.want_writable || total > link_end.want_room { link_end.want_room = total; }
        link_end.want_writable = true;
        link_end.refused_once = true;
        link_end.refusals++;
        if io._faulty(Fault.Send2TakesFirstPart) && first.len > 0 && second.len > 0 && first.len <= free_space {
            io._inbuf[base..base + first.len].move_from(first);
            peer_end.unread_len += first.len;
        }
        return goose_io::SendStatus.Full;
    }
    if io._faulty(Fault.Send2SwapsParts) && first.len > 0 && second.len > 0 {
        io._inbuf[base..base + second.len].move_from(second);
        io._inbuf[base + second.len..base + total].move_from(first);
    } else {
        if first.len > 0 { io._inbuf[base..base + first.len].move_from(first); }
        if second.len > 0 { io._inbuf[base + first.len..base + total].move_from(second); }
    }
    peer_end.unread_len += total;
    peer_end.received_total += total;
    peer_end.last_input_at = io._clock;
    peer_end.last_activity_at = io._clock;
    link_end.last_activity_at = io._clock;
    if io._faulty(Fault.SendDropsLastByte) { peer_end.unread_len--; }
    return goose_io::SendStatus.Sent;
}

fn close(io: Loop&, link: goose_io::Link) {
    if io._finished { return; }
    let slot = io._slot_of(link);
    guard slot >= 0 else { return; }
    let link_end .= io._slots[slot];
    if link_end.state == _SlotState.Closed {
        if io._faulty(Fault.SecondCloseClosesAgain) { io._queue(_EventKind.Closed, slot); }
        return;
    }
    link_end.local_closed = true;
    // a link whose peer has not read what it was sent is kept until the end of the grace period
    if io._faulty(Fault.ShutdownOverridesLocal) && link_end.peer >= 0 && io._slots[link_end.peer].unread_len > 0 { return; }
    let reset_instead = io._faulty(Fault.CloseWithUnreadResets) && link_end.unread_len > 0;
    io._close(slot, goose_io::CloseReason.Local, reset_instead);
    if io._faulty(Fault.SlotFreedOnClose) { io._release(slot); }      // the slot is free before its Closed is delivered
}

// Closes at once. What the other end has not read is discarded and it ends with PeerReset.
fn reset(io: Loop&, link: goose_io::Link) {
    if io._finished { return; }
    let slot = io._slot_of(link);
    guard slot >= 0 else { return; }
    let link_end .= io._slots[slot];
    if link_end.state == _SlotState.Closed {
        if io._faulty(Fault.ResetAfterCloseClosesAgain) { io._queue(_EventKind.Closed, slot); }
        return;
    }
    let connecting = link_end.state == _SlotState.Dialing || link_end.state == _SlotState.Opening;
    if io._faulty(Fault.ResetDialOpens) && connecting { return; }      // a dial in progress is not abandoned
    link_end.local_closed = true;
    io._close(slot, goose_io::CloseReason.Local, !io._faulty(Fault.ResetIsGraceful));
}

// keep: the peer's end of stream is delivered as PeerEof and the link stays open for sending. It is configuration with a
// fixed window: while the link is dialling or inside the handler of its `Opened`. The setting applies when that handler
// returns, and a later call has no effect (*Keep-open is configured no later than Opened*).
fn set_keep_open_on_eof(io: Loop&, link: goose_io::Link, keep: bool) {
    if io._finished { return; }
    let slot = io._slot_of(link);
    guard slot >= 0 else { return; }
    let link_end .= io._slots[slot];
    if link_end.relay_partner >= 0 { return; }
    if link_end.configured && !io._faulty(Fault.KeepOpenLateHonoured) { return; }
    if io._faulty(Fault.KeepOpenWhileDiallingIgnored) && link_end.state == _SlotState.Dialing { return; }
    link_end.keep_open = keep;
}

// Ends this side's sending. The other end reads what was sent and then sees the end of the stream.
fn shutdown_write(io: Loop&, link: goose_io::Link) {
    if io._finished { return; }
    let slot = io._slot_of(link);
    guard slot >= 0 else { return; }
    let link_end .= io._slots[slot];
    if io._faulty(Fault.ShutdownBeforeOpenRemembered) && link_end.state == _SlotState.Dialing { link_end.write_shut = true; return; }
    guard link_end.state == _SlotState.Open && !link_end.write_shut && link_end.relay_partner < 0 else { return; }
    link_end.write_shut = true;
    if !io._faulty(Fault.WritableAfterShutdown) { link_end.want_writable = false; }
    let peer = link_end.peer;
    if peer >= 0 {
        io._slots[peer].peer_finished = true;
        // an end of stream seen before the other end's Opened handler has returned is acted on at once, with the
        // setting that end has so far
        if io._faulty(Fault.EarlyEofActedOn) && io._slots[peer].state == _SlotState.Opening && !io._slots[peer].keep_open {
            io._close_gracefully(peer, goose_io::CloseReason.PeerClosed);
        }
    }
    // The peer had finished already: both directions are done.
    if link_end.eof_seen { io._close_gracefully(slot, goose_io::CloseReason.PeerClosed); }
}

// --- the contract: the relay group -----------------------------------------------------------------

// The write deadline passed with bytes still unsent: they are discarded and the link ends Local.
fn _expire_deadline(io: Loop&, slot: i64) {
    let link_end .= io._slots[slot];
    link_end.write_deadline_at = 0;
    if link_end.peer >= 0 { io._slots[link_end.peer].unread_len = 0; }
    link_end.local_closed = true;
    io._close_gracefully(slot, goose_io::CloseReason.Local);
}

// Joins two open links: from now the loop moves each one's bytes to the other and carries the end of stream.
fn relay(io: Loop&, first: goose_io::Link, second: goose_io::Link) -> goose_io::RelayStatus {
    guard !io._finished else { return goose_io::RelayStatus.Closed; }
    let first_slot = io._slot_of(first);
    let second_slot = io._slot_of(second);
    guard first_slot >= 0 && second_slot >= 0 && first_slot != second_slot else { return goose_io::RelayStatus.Closed; }
    // the two ends of one connection cannot be joined: the relay would move a link's bytes into its own region
    let first_end .= io._slots[first_slot];
    let second_end .= io._slots[second_slot];
    guard first_end.state != _SlotState.Closed && second_end.state != _SlotState.Closed else { return goose_io::RelayStatus.Closed; }
    guard first_end.state == _SlotState.Open && second_end.state == _SlotState.Open else { return goose_io::RelayStatus.NotOpen; }
    let neither_relayed = first_end.relay_partner < 0 && second_end.relay_partner < 0;
    guard neither_relayed || io._faulty(Fault.RelayJoinsRelayed) else { return goose_io::RelayStatus.AlreadyRelayed; }
    guard first_end_peer_not(io, first_slot, second_slot) else { return goose_io::RelayStatus.Closed; }
    guard !first_end.write_shut && !second_end.write_shut else { return goose_io::RelayStatus.Closed; }
    first_end.relay_partner = second_slot;
    second_end.relay_partner = first_slot;
    first_end.paused = false;
    second_end.paused = false;
    first_end.wait_for = 0;
    second_end.wait_for = 0;
    return goose_io::RelayStatus.Started;
}

// Bytes the loop has carried from this link to its partner.
fn relayed_bytes(io: Loop&, link: goose_io::Link) -> i64 {
    let slot = io._slot_of(link);
    guard slot >= 0 else { return 0; }
    let link_end .= io._slots[slot];
    if io._faulty(Fault.RelayedBytesLostAtClose) && link_end.state == _SlotState.Closed { return 0; }
    if io._faulty(Fault.RelayedCountsHeld) { return link_end.carried + link_end.unread_len; }
    return link_end.carried;
}

// Scripting, not part of the contract: the transport under a link fails (the link ends with Error, and its relay partner too).
fn break_transport(io: Loop&, link: goose_io::Link) {
    let slot = io._slot_of(link);
    guard slot >= 0 && io._slots[slot].state != _SlotState.Closed else { return; }
    io._abort(slot, goose_io::CloseReason.Error);
}

// True when the two slots are the two ends of one connection.
fn first_end_peer_not(io: Loop&, first_slot: i64, second_slot: i64) -> bool { return io._slots[first_slot].peer != second_slot; }

// True when the relay has something to move now: bytes the partner's far end has room for, or an end of stream to pass.
// Bytes with no room wait without keeping the loop busy, so the clock can jump to the next due time.
fn _relay_work(io: Loop&, link_end: _Slot) -> bool {
    guard link_end.relay_partner >= 0 && link_end.state == _SlotState.Open else { return false; }
    let has_end_to_pass = link_end.peer_finished && !link_end.relay_finished;
    var has_room = false;
    let out = io._slots[link_end.relay_partner].peer;
    if link_end.unread_len > 0 { has_room = out < 0 || io._slots[out].unread_len < io.cfg.link_buffer; }
    return has_room || has_end_to_pass && link_end.unread_len == 0;
}

// Moves what relayed links have received to their partners, as far as the partner's buffer allows.
fn _pump_relays(io: Loop&) {
    for slot in io._slots.len {
        let source .= io._slots[slot];
        guard source.relay_partner >= 0 && source.state == _SlotState.Open else { continue; }
        let partner = source.relay_partner;
        let partner_end .= io._slots[partner];
        if partner_end.write_deadline_at > 0 && io._clock >= partner_end.write_deadline_at { io._expire_deadline(partner); continue; }
        if source.unread_len > 0 {
            if partner_end.peer < 0 { io._close_gracefully(partner, goose_io::CloseReason.PeerReset); continue; }
            let destination = partner_end.peer;
            let room = io.cfg.link_buffer - io._slots[destination].unread_len;
            let count = min(min(source.unread_len, room), io.cfg.read_chunk);
            if count > 0 {
                let from = slot * io.cfg.link_buffer;
                let to = destination * io.cfg.link_buffer + io._slots[destination].unread_len;
                io._inbuf[to..to + count].move_from(io._inbuf[from..from + count]);
                io._consume(slot, count);
                source.carried += count;
                io._slots[destination].unread_len += count;
                io._slots[destination].received_total += count;
                if io._faulty(Fault.RelayDropsLastByte) { io._slots[destination].unread_len--; }
                source.last_activity_at = io._clock;
                partner_end.last_activity_at = io._clock;
                io._room_opened(source.peer);
            }
        }
        if source.unread_len == 0 && source.peer_finished && !source.relay_finished {
            source.relay_finished = true;
            source.eof_seen = true;
            partner_end.write_shut = true;
            if partner_end.peer >= 0 { io._slots[partner_end.peer].peer_finished = true; }
            source.half_open_at = io._clock;
            if partner_end.relay_finished { io._close_gracefully(slot, goose_io::CloseReason.PeerClosed); }
        }
    }
}

// --- the contract: peek, revoke, limits, wake ------------------------------------------------------

// The most bytes peek shows and wait_input holds.
fn _peek_bound(io: Loop&) -> i64 {
    if io._faulty(Fault.BoundIgnored) { return io.cfg.link_buffer; }
    return min(max(io.cfg.peek_bound, 1), io.cfg.link_buffer);
}

// The bytes that have arrived and not been delivered, up to the bound; consumes nothing.
// (See the POSSIBLE BUG in _new_slot: the slice can be left pointing at a moved buffer.)
fn peek(io: Loop&, link: goose_io::Link) -> const u8[:] {
    let slot = io._slot_of(link);
    guard slot >= 0 && io._slots[slot].state == _SlotState.Open && io._slots[slot].relay_partner < 0 else { return ""; }
    let count = min(io._slots[slot].unread_len, io._peek_bound());
    let base = slot * io.cfg.link_buffer;
    return io._inbuf[base..base + count];
}

// Drops the first `byte_count` held bytes of an open, unrelayed link (at most what peek shows); returns how many.
// Delivers no Input and no Data; the rest stays held.
fn discard_input(io: Loop&, link: goose_io::Link, byte_count: i64) -> i64 {
    if io._finished { return 0; }
    let slot = io._slot_of(link);
    guard slot >= 0 && io._slots[slot].state == _SlotState.Open && io._slots[slot].relay_partner < 0 else { return 0; }
    let count = min(max(byte_count, 0), min(io._slots[slot].unread_len, io._peek_bound()));
    if io._faulty(Fault.DiscardInputKeeps) { return count; }
    if count > 0 {
        io._consume(slot, count);
        io._room_opened(io._slots[slot].peer);
    }
    return count;
}

// byte_count > 0: hold the link's bytes and deliver one Input when that many have arrived, the peer's stream ended,
// or the bound is reached. 0: deliver what is held as Data.
fn wait_input(io: Loop&, link: goose_io::Link, byte_count: i64) {
    if io._finished { return; }
    let slot = io._slot_of(link);
    guard slot >= 0 && io._slots[slot].state != _SlotState.Closed && io._slots[slot].relay_partner < 0 else { return; }
    let link_end .= io._slots[slot];
    link_end.wait_for = max(byte_count, 0);
    link_end.input_given = false;
}

// Whether the Input of this link end is due now.
fn _input_ready(io: Loop&, link_end: _Slot) -> bool {
    let waiting = link_end.state == _SlotState.Open && link_end.relay_partner < 0 && link_end.wait_for > 0;
    guard waiting && !link_end.input_given && !link_end.paused else { return false; }
    if io._faulty(Fault.InputEarly) { return link_end.unread_len > 0; }
    let want = min(link_end.wait_for, io._peek_bound());
    return link_end.unread_len >= want || (link_end.peer_finished && !io._faulty(Fault.PeerEndIgnored));
}

// Drops what was accepted on this link and not read by the other end; a Writable owed counts as if it had been sent.
//
// POSSIBLE BUG: unlike the other operations this does not check io._finished, so it still changes a
// finished loop (*A finished loop does nothing*). It also works on a relayed link, behind the relay's back.
fn discard_unsent(io: Loop&, link: goose_io::Link) -> i64 {
    if io._finished { return 0; }
    let slot = io._slot_of(link);
    guard slot >= 0 && io._slots[slot].state == _SlotState.Open && io._slots[slot].peer >= 0 && io._slots[slot].relay_partner < 0 else { return 0; }
    let peer_end .= io._slots[io._slots[slot].peer];
    let discarded = peer_end.unread_len;
    if io._faulty(Fault.DiscardKeepsBytes) { return discarded; }
    peer_end.unread_len = 0;
    io._room_opened(slot);
    return discarded;
}

// POSSIBLE BUG: no io._finished check, so this still changes a finished loop.
fn write_deadline(io: Loop&, link: goose_io::Link, at_ms: i64) {
    if io._finished { return; }
    let slot = io._slot_of(link);
    guard slot >= 0 && io._slots[slot].state != _SlotState.Closed else { return; }
    let link_end .= io._slots[slot];
    if io._faulty(Fault.DeadlineNotReplaced) && link_end.write_deadline_at > 0 && at_ms > link_end.write_deadline_at { return; }
    link_end.write_deadline_at = max(at_ms, 0);
}

// Scripting, not part of the contract: time passes inside the handler that calls this, as when the process is stopped.
fn pause_process(io: Loop&, ms: i64) { io._clock += ms; }

fn _limit_index(limit: goose_io::Limit) -> i64 {
    return match limit {
        Idle => _LIMIT_IDLE,
        Silent => _LIMIT_SILENT,
        Stalled => _LIMIT_STALLED,
        HalfOpen => _LIMIT_HALF_OPEN,
        Age => _LIMIT_AGE,
    };
}

fn _limit_value(index: i64) -> goose_io::Limit {
    if index == _LIMIT_IDLE { return goose_io::Limit.Idle; }
    if index == _LIMIT_SILENT { return goose_io::Limit.Silent; }
    if index == _LIMIT_STALLED { return goose_io::Limit.Stalled; }
    if index == _LIMIT_HALF_OPEN { return goose_io::Limit.HalfOpen; }
    return goose_io::Limit.Age;
}

fn set_limit(io: Loop&, link: goose_io::Link, limit: goose_io::Limit, ms: i64) {
    if io._finished { return; }
    let slot = io._slot_of(link);
    guard slot >= 0 && io._slots[slot].state != _SlotState.Closed else { return; }
    let link_end .= io._slots[slot];
    let index = _limit_index(limit);
    if io._faulty(Fault.ReplaceKeepsFirst) && link_end.limit_ms[index] > 0 && ms > 0 { return; }
    if ms <= 0 {
        link_end.limit_ms[index] = 0;
        link_end.limit_fired[index] = false;
        return;
    }
    link_end.limit_armed_at[index] = io._clock;
    link_end.limit_ms[index] = ms;
    link_end.limit_fired[index] = false;
}

// When limit `index` of this link end falls due, or _FOREVER.
fn _limit_due(io: Loop&, link_end: _Slot, index: i64) -> i64 {
    guard link_end.limit_ms[index] > 0 && !link_end.limit_fired[index] else { return _FOREVER; }
    let since_activity = max(link_end.last_activity_at, link_end.opened_at);
    var from = 0;
    if index == _LIMIT_IDLE {
        from = if io._faulty(Fault.IdleFromArming) { link_end.limit_armed_at[index] } else { since_activity };
    } else if index == _LIMIT_SILENT {
        from = if io._faulty(Fault.SilentCountsWrites) { since_activity } else { max(link_end.last_input_at, link_end.opened_at) };
    } else if index == _LIMIT_STALLED {
        if link_end.stall_since >= 0 { from = link_end.stall_since; }
        else if io._faulty(Fault.StalledAlways) { from = link_end.opened_at; }
        else { return _FOREVER; }
    } else if index == _LIMIT_HALF_OPEN {
        if link_end.half_open_at >= 0 { from = link_end.half_open_at; }
        else if io._faulty(Fault.HalfOpenAlways) { from = link_end.opened_at; }
        else { return _FOREVER; }
    } else {
        if io._faulty(Fault.AgeNeverExpires) { return _FOREVER; }
        from = if io._faulty(Fault.AgeResetByActivity) { since_activity } else { link_end.opened_at };
    }
    from = max(from, link_end.limit_armed_at[index]);
    return from + link_end.limit_ms[index];
}

// Tracks activity and stalls of the open library links; applies the relay's own timeouts.
fn _watch(io: Loop&) {
    for slot in io._slots.len {
        let link_end .= io._slots[slot];
        guard link_end.state == _SlotState.Open && link_end.script < 0 else { continue; }
        var waiting = false;                 // bytes this link sent are waiting for the transport
        var progress = link_end.consumed;
        if link_end.peer >= 0 {
            waiting = io._slots[link_end.peer].unread_len > 0;
            progress = io._slots[link_end.peer].consumed;
        }
        if link_end.relay_partner >= 0 {
            if io._slots[link_end.relay_partner].unread_len > 0 { waiting = true; }
            progress += io._slots[link_end.relay_partner].carried;
        }
        if io._faulty(Fault.StalledResetByReads) { progress += link_end.received_total; }
        if progress != link_end.seen_progress && !io._faulty(Fault.StalledNoProgressReset) {
            link_end.seen_progress = progress;
            link_end.last_activity_at = io._clock;
            if waiting { link_end.stall_since = io._clock; }
        }
        if waiting && link_end.stall_since < 0 { link_end.stall_since = io._clock; }
        if !waiting { link_end.stall_since = -1; }
        guard link_end.relay_partner >= 0 && link_end.stall_since >= 0 else { continue; }
        let stalled_for = io._clock - link_end.stall_since;
        if io.cfg.kernel_timeout_ms > 0 && stalled_for >= io.cfg.kernel_timeout_ms {
            io._abort(slot, goose_io::CloseReason.Error);
        } else if io.cfg.relay_stall_ms > 0 && stalled_for >= io.cfg.relay_stall_ms {
            io._close_gracefully(slot, goose_io::CloseReason.Local);
        }
    }
}

// Queues an Expired for every limit that is due and not yet reported.
fn _limits_check(io: Loop&) {
    for slot in io._slots.len {
        let link_end .= io._slots[slot];
        guard link_end.state == _SlotState.Open && link_end.script < 0 && link_end.configured else { continue; }
        for index in _LIMIT_KINDS {
            if io._clock >= io._limit_due(link_end, index) {
                if !io._faulty(Fault.ExpiredRepeats) { link_end.limit_fired[index] = true; }
                io._pending.push(_Pending { kind: _EventKind.Expired, slot: slot, gen: link_end.gen, limit: _limit_value(index) });
            }
        }
    }
}

// The next time something of limits, write deadlines or relay timeouts falls due.
fn _next_due(io: Loop&) -> i64 {
    var next = _FOREVER;
    for slot in io._slots.len {
        let link_end .= io._slots[slot];
        guard link_end.state == _SlotState.Open && link_end.script < 0 else { continue; }
        if link_end.write_deadline_at > 0 { next = min(next, link_end.write_deadline_at); }
        for index in _LIMIT_KINDS { next = min(next, io._limit_due(link_end, index)); }
        if link_end.relay_partner >= 0 && link_end.stall_since >= 0 {
            if io.cfg.relay_stall_ms > 0 { next = min(next, link_end.stall_since + io.cfg.relay_stall_ms); }
            if io.cfg.kernel_timeout_ms > 0 { next = min(next, link_end.stall_since + io.cfg.kernel_timeout_ms); }
        }
    }
    return next;
}

fn waker(io: Loop&) -> goose_io::Waker {
    if io._waker_id == 0 {
        _loops_made++;
        io._waker_id = _loops_made;
    }
    return goose_io::Waker { id: io._waker_id, gen: 1 };
}

// From any thread: one Woken on the loop's thread.
//
// POSSIBLE BUG: an unset Waker (id 0) sends a message that _take_wakes cannot tell from an empty
// queue, so that wake is dropped without a trace.
fn wake(io: Loop&, target: goose_io::Waker, value: i64) {
    guard target.id != 0 else { return; }
    qput(_WakeMsg { id: target.id, value: value });
}

// As wake, with up to 64 bytes that arrive in Woken.body (longer text is cut).
fn wake_with(io: Loop&, target: goose_io::Waker, value: i64, body: const u8[:]) {
    guard target.id != 0 else { return; }
    var m = _WakeMsg { id: target.id, value: value };
    let n = if body.len < m.body.cap { body.len } else { m.body.cap };
    m.body.append(body[..n]);
    qput(m);
}

// Scripting, not part of the contract: a test thread will make this many more wakes; an idle loop waits for them
// instead of moving its clock.
fn expect_wakes(io: Loop&, count: i64) { io._expect_wakes = count; }

// Moves this loop's wakes from the process queue to _woken_values. `wait`: block for one when none is queued.
fn _take_wakes(io: Loop&, wait: bool) {
    guard io._waker_id != 0 else { return; }
    loop {
        var message = qpoll<_WakeMsg>();
        if message.id == 0 {
            guard wait && io._expect_wakes > 0 else { return; }
            message = qget<_WakeMsg>();
        }
        // POSSIBLE BUG: a message for another loop is put back at the end of the queue and this loop
        // stops reading for this pass, so its own wakes queued behind it wait a pass. With `wait` set it
        // returns with nothing taken, and _advance may then move the clock while a wake is due.
        if message.id != io._waker_id { qput(message); return; }
        io._woken_values.push(_Woken { value: message.value, body: message.body });
        if io._expect_wakes > 0 { io._expect_wakes--; }
        if wait { return; }
    }
}

// --- the contract: time and the application side --------------------------------------------------

fn now_ms(io: Loop&) -> i64 { io._clock }

// Asks for a Tick at or after at_ms. Only the earliest request is kept, and the next Tick clears it.
fn tick_by(io: Loop&, at_ms: i64) {
    if io._finished { return; }
    if io._faulty(Fault.TickByIgnored) { return; }
    if at_ms < io._wake_at || io._faulty(Fault.TickByKeepsLatest) { io._wake_at = at_ms; }
}

// Every listener stops now. serve returns when the last link has closed, or grace_ms from now,
// after closing what is left with Shutdown. Of several calls the earliest end of grace stands.
fn stop(io: Loop&, grace_ms: i64) {
    if io._finished { return; }
    io._start();
    io._draining = true;
    for &listener in io._listeners { listener.active = false; }
    var deadline = io._clock + max(grace_ms, 0);
    if io._faulty(Fault.ShutdownEarly) { deadline = io._clock; }
    if deadline < io._stop_deadline || io._faulty(Fault.StopLatestWins) { io._stop_deadline = deadline; }
}

fn draining(io: Loop&) -> bool { io._draining || io._finished }

fn serve<F>(io: Loop&) {
    if io._finished {          // a second serve returns at once, without calling its handler
        if io._faulty(Fault.SecondServeRuns) {
            let event: goose_io::Event = goose_io::Event.Tick { now_ms: io._clock };
            F(io, event);
        }
        return;
    }
    io._start();
    // Sized here and never from an operation: a handler holds a slice of it while it calls operations.
    if io._scratch.len != io.cfg.read_chunk { io._scratch.resize(io.cfg.read_chunk, 0); }
    loop {
        io._passes++;
        io._run_due();
        io._pump_relays();
        io._take_wakes(false);
        io._watch();
        io._limits_check();
        io._queue_reads();
        if io._faulty(Fault.SetupEventsDropped) && io._passes == 1 {      // the events of what was set up before serve are discarded
            io._pending.clear();
            io._pending_head = 0;
        }
        // The order of one pass: a Tick if one is due, Woken, the link events, then PassEnd, always last.
        var ticked = false;
        if io._clock >= io._next_tick || io._clock >= io._wake_at {
            io._next_tick = io._clock + io._tick_period();
            io._wake_at = _FOREVER;
            ticked = true;
            let event: goose_io::Event = goose_io::Event.Tick { now_ms: io._clock };
            F(io, event);
        }
        while io._woken_head < io._woken_values.len {
            let position = if io._faulty(Fault.WakeOrderReversed) { io._woken_values.len - 1 - io._woken_head } else { io._woken_head };
            io._woken_head++;
            let event: goose_io::Event = goose_io::Event.Woken { value: io._woken_values[position].value, body: if io._faulty(Fault.WakeBodyDropped) { [] } else { io._woken_values[position].body } };
            F(io, event);
        }
        io._woken_values.clear();
        io._woken_head = 0;
        let link_events = io._deliver(F);
        let wants_pass_end = link_events > 0 || (io._faulty(Fault.IdlePassEnd) && ticked);
        if wants_pass_end && !io._faulty(Fault.NoPassEnd) {
            let event: goose_io::Event = goose_io::Event.PassEnd {};
            F(io, event);
        }
        if io._can_return() { break; }
        // Again after the handlers ran, so that what they moved counts as progress before the clock moves.
        // (Intent assumed: the previous version also watched twice per pass without saying why.)
        io._watch();
        io._advance();
        if io._hit_limit { break; }
    }
    io._finished = true;
}

// stop was called and nothing is left: no library link, no queued event, no awaited wake, and no
// scripted peer with something to read or a hang-up to make.
fn _can_return(io: Loop&) -> bool {
    guard io._draining && io._library_links == 0 else { return false; }
    guard io._pending_head >= io._pending.len && io._expect_wakes == 0 else { return false; }
    guard !io._peer_read_work() else { return false; }
    return !io._faulty(Fault.StopWaitsForGrace) || io._clock >= io._stop_deadline;
}

// --- internals: one pass -------------------------------------------------------------------------

// What has come due at the current time: the end of a grace period, connects, connect timeouts,
// write deadlines, and the steps of scripted peers.
fn _run_due(io: Loop&) {
    if io._draining && io._clock >= io._stop_deadline {
        for slot in io._slots.len {
            if io._slots[slot].script < 0 { io._close_gracefully(slot, goose_io::CloseReason.Shutdown); }
        }
    }
    for slot in io._slots.len {
        let link_end .= io._slots[slot];
        guard link_end.state == _SlotState.Dialing else { continue; }
        if !link_end.silent && io._clock >= link_end.connect_at { io._connect(slot); }
        else if io._clock >= link_end.connect_deadline { io._fail_dial(slot, goose_io::ConnectFailure.TimedOut); }
    }
    if !io._faulty(Fault.DeadlineOnlyAtSend) {
        for slot in io._slots.len {
            let link_end .= io._slots[slot];
            let deadline_passed = link_end.write_deadline_at > 0 && io._clock >= link_end.write_deadline_at;
            if link_end.state == _SlotState.Open && link_end.script < 0 && deadline_passed { io._expire_deadline(slot); }
        }
    }
    for script_index in io._scripts.len { io._run_script(script_index); }
}

// The scripted peer still waiting at this address that takes a dial to target, or -1.
fn _waiting_script(io: Loop&, target: _Addr) -> i64 {
    for script, script_index in io._scripts {
        if script.accepting && !script.taken && _listener_takes(script.addr, target) { return script_index; }
    }
    return -1;
}

// Finishes the dial in this slot: joins it to a listener's new link or a scripted peer, or fails it.
fn _connect(io: Loop&, dialled_slot: i64) {
    let target = io._slots[dialled_slot].target;
    var listener_index = -1;
    for listener, index in io._listeners {
        let ignored = io._faulty(Fault.UnixListenerIgnored) && listener.addr.unix;      // a dial to a path never reaches its listener
        if listener.active && _listener_takes(listener.addr, target) && !ignored { listener_index = index; break; }
    }
    for failing in io._failing {
        if _same_endpoint(failing.addr, target) { io._fail_dial(dialled_slot, failing.kind); return; }
    }
    var accepted_slot = -1;
    if listener_index >= 0 {
        if io._live_slots >= io.cfg.max_links {
            io._fail_dial(dialled_slot, goose_io::ConnectFailure.NoResources);
            return;
        }
        accepted_slot = io._new_slot(-1);
        io._slots[accepted_slot].listener = (listener_index + 1) as u32;
    } else {
        // no listener: the first scripted peer still waiting at this address takes the dial
        let script_index = io._waiting_script(target);
        if script_index >= 0 { io._scripts[script_index].taken = true; }
        if script_index < 0 || io._scripts[script_index].refuse {
            if script_index >= 0 { io._scripts[script_index].closed = true; }
            var kind = goose_io::ConnectFailure.Refused;
            if io._faulty(Fault.RefusedAsUnreachable) { kind = goose_io::ConnectFailure.Unreachable; }
            else if io._faulty(Fault.UnixRefusedAsBadAddress) && target.unix { kind = goose_io::ConnectFailure.BadAddress; }
            io._fail_dial(dialled_slot, kind);
            return;
        }
        accepted_slot = io._new_slot(script_index);
        io._scripts[script_index].slot = accepted_slot;
    }
    let accepted .= io._slots[accepted_slot];
    accepted.state = _SlotState.Opening;
    accepted.peer = dialled_slot;
    // the accepted end of a Unix link has no name: its remote formats as the empty value
    accepted.remote = if target.unix { target } else { _Addr { ok: true, v6: target.v6, ip: target.ip, port: io._take_port() as u16 } };
    let dialled .= io._slots[dialled_slot];
    dialled.state = _SlotState.Opening;
    dialled.peer = accepted_slot;
    dialled.remote = target;
    io._queue(_EventKind.Opened, accepted_slot);
    io._queue(_EventKind.Opened, dialled_slot);
}

// Every open link that has unread bytes gets one Data record; one whose peer has finished and
// that has read everything sees the end of the stream. A link waiting for input gets its Input.
fn _queue_reads(io: Loop&) {
    for slot in io._slots.len {
        let link_end .= io._slots[slot];
        if io._input_ready(link_end) && !io._faulty(Fault.InputNeverDelivered) {
            link_end.input_given = true;
            io._queue(_EventKind.Input, slot);
        }
        // An end of stream seen before the handler of the link's Opened has returned waits: the decision is made once the
        // link is configured (here: only an open, configured link is read).
        let readable = link_end.state == _SlotState.Open && link_end.configured && !link_end.data_queued;
        guard readable && link_end.relay_partner < 0 && link_end.wait_for == 0 else { continue; }
        let eof_unseen = link_end.peer_finished && !link_end.eof_seen;
        if io._faulty(Fault.PeerEofBeforeData) && link_end.keep_open && eof_unseen && link_end.unread_len > 0 {
            link_end.eof_seen = true;
            io._queue(_EventKind.PeerEof, slot);
        }
        if link_end.unread_len > 0 {
            if !link_end.paused {
                link_end.data_queued = true;
                io._queue(_EventKind.Data, slot);
            }
        } else if link_end.peer_finished && !link_end.eof_seen {
            link_end.eof_seen = true;
            if link_end.keep_open {
                link_end.half_open_at = io._clock;
                io._queue(_EventKind.PeerEof, slot);
                // A refused send must not wait for ever on a peer that is gone: the retry is
                // accepted and lost, and resets the link, as a send to a gone peer does.
                if link_end.want_writable && link_end.peer < 0 && !io._faulty(Fault.FullUnresolvedOnPeerClose) {
                    link_end.want_writable = false;
                    io._queue(_EventKind.Writable, slot);
                }
            }
            // Closed by default, and always once this end has finished sending too.
            let closes_by_default = !link_end.keep_open && !io._faulty(Fault.EofIgnoresDefault);
            if closes_by_default || link_end.write_shut { io._close_gracefully(slot, goose_io::CloseReason.PeerClosed); }
        }
    }
}

// Calls the handler for every queued event, in order, including those the handler itself causes.
// Returns how many it delivered.
fn _deliver<F>(io: Loop&) -> i64 {
    var delivered = 0;
    while io._pending_head < io._pending.len {
        let record = io._pending[io._pending_head];
        io._pending_head++;
        let link_end .= io._slots[record.slot];
        let current = link_end.state != _SlotState.Free && link_end.gen == record.gen;
        if current && link_end.script >= 0 {
            io._peer_deliver(record.kind, record.slot);
        } else if current {
            let link = goose_io::Link { slot: record.slot as u32, gen: record.gen };
            match record.kind {
                Opened => {
                    // Not delivered when the owner already closed the link (a cancelled dial).
                    if !link_end.local_closed || io._faulty(Fault.CancelledDialOpens) {
                        if link_end.state == _SlotState.Opening { link_end.state = _SlotState.Open; }
                        link_end.opened = true;
                        link_end.opened_at = io._clock;
                        link_end.last_input_at = io._clock;
                        link_end.last_activity_at = io._clock;
                        var listener_id = link_end.listener;
                        if io._faulty(Fault.OpenedWithoutListener) { listener_id = 0; }
                        else if io._faulty(Fault.WrongListenerNamed) && link_end.listener != 0 { listener_id = 1; }
                        let event: goose_io::Event = goose_io::Event.Opened { link: link, listener: goose_io::Listener { id: listener_id } };
                        delivered++;
                        F(io, event);
                        io._slots[record.slot].configured = true;       // the Opened handler has returned: keep-open is fixed now
                    }
                },
                Data => {
                    link_end.data_queued = false;
                    if link_end.state == _SlotState.Open && !link_end.paused && link_end.unread_len > 0 {
                        let count = min(link_end.unread_len, io.cfg.read_chunk);
                        let base = record.slot * io.cfg.link_buffer;
                        io._scratch[..count].move_from(io._inbuf[base..base + count]);
                        io._consume(record.slot, count);
                        io._room_opened(link_end.peer);
                        if io._faulty(Fault.DataCorrupted) { io._scratch[0] = io._scratch[0] ^ 1; }
                        let event: goose_io::Event = goose_io::Event.Data { link: link, bytes: io._scratch[..count] };
                        delivered++;
                        F(io, event);
                    }
                },
                Input => {
                    if link_end.state == _SlotState.Open && link_end.wait_for > 0 && !link_end.paused {
                        let available = min(link_end.unread_len, io._peek_bound());
                        let event: goose_io::Event = goose_io::Event.Input { link: link, available: available };
                        delivered++;
                        F(io, event);
                    }
                },
                Expired => {
                    if link_end.state == _SlotState.Open || io._faulty(Fault.ExpiredAfterClose) {
                        let event: goose_io::Event = goose_io::Event.Expired { link: link, limit: record.limit };
                        delivered++;
                        F(io, event);
                    }
                },
                Writable => {
                    // not after shutdown_write, even if it was queued before the call: nothing can fit now
                    let open = link_end.state == _SlotState.Open || io._faulty(Fault.WritableAfterClose);
                    let can_write = !link_end.write_shut || io._faulty(Fault.WritableAfterShutdown);
                    if open && can_write {
                        let event: goose_io::Event = goose_io::Event.Writable { link: link };
                        delivered++;
                        F(io, event);
                    }
                },
                PeerEof => {
                    if !link_end.local_closed {
                        let event: goose_io::Event = goose_io::Event.PeerEof { link: link };
                        delivered++;
                        F(io, event);
                    }
                },
                Closed => {
                    let lose_link = io._faulty(Fault.DialClosedLost) && goose_io::is_connect_failed(link_end.close_reason);
                    let reported = if lose_link { goose_io::Link { .. } } else { link };
                    let event: goose_io::Event = goose_io::Event.Closed { link: reported, why: link_end.close_reason };
                    delivered++;
                    if io._faulty(Fault.WritableAfterClosedResult) && link_end.refused_once {
                        // a Writable owed to the link is delivered as it ends
                        let writable: goose_io::Event = goose_io::Event.Writable { link: link };
                        F(io, writable);
                    }
                    let release_early = io._faulty(Fault.ClosedHandleStaleEarly);
                    if release_early { io._release(record.slot); }
                    F(io, event);
                    if !release_early { io._release(record.slot); }
                },
            }
        } else if record.kind == _EventKind.Closed && io._closed_outlives_slot() && record.gen != link_end.gen {
            // fault SlotFreedOnClose (and the close-again faults): the slot was freed, and its generation advanced,
            // when `close` was called, so the Closed of the link that was in it is delivered from the pending record
            let event: goose_io::Event = goose_io::Event.Closed { link: goose_io::Link { slot: record.slot as u32, gen: record.gen }, why: goose_io::CloseReason.Local };
            delivered++;
            F(io, event);
        }
    }
    io._pending.clear();
    io._pending_head = 0;
    return delivered;
}

// The faults under which a Closed can be queued for a slot that has since been freed.
fn _closed_outlives_slot(io: Loop&) -> bool {
    io._faulty(Fault.SlotFreedOnClose) || io._faulty(Fault.SecondCloseClosesAgain) || io._faulty(Fault.ResetAfterCloseClosesAgain)
}

// The reader of this sender's bytes took some: a sender that was refused may now fit.
fn _room_opened(io: Loop&, sender: i64) {
    guard sender >= 0 else { return; }
    let link_end .= io._slots[sender];
    guard link_end.state == _SlotState.Open && link_end.want_writable && link_end.peer >= 0 else { return; }
    if io._faulty(Fault.NoWritable) || (io._faulty(Fault.OneWritableOnly) && link_end.writable_given) { return; }
    let room = io.cfg.link_buffer - io._slots[link_end.peer].unread_len;
    let needed = if io._faulty(Fault.WritableOnFirstByte) { 1 } else { link_end.want_room };
    guard room >= needed else { return; }
    link_end.want_writable = false;
    link_end.writable_given = true;
    io._queue(_EventKind.Writable, sender);
    if io._faulty(Fault.WritablePerRefusal) {
        for _ in link_end.refusals - 1 { io._queue(_EventKind.Writable, sender); }
    }
    link_end.refusals = 0;
}

// The Closed of this slot has been delivered: the handle is stale from here on.
fn _release(io: Loop&, slot: i64) {
    let link_end .= io._slots[slot];
    io._last_remote = link_end.remote;
    if link_end.script < 0 { io._library_links--; }
    link_end.state = _SlotState.Free;
    if !io._faulty(Fault.GenerationNotAdvanced) {      // otherwise a slot comes back with the generation it had
        // A slot whose last generation has been used is retired: it is never issued again (a generation does not wrap),
        // so no slot and generation pair is issued twice.
        if link_end.gen == _LAST_GENERATION { return; }
        link_end.gen++;
    }
    io._free.push(slot);
}

// Scripting, not part of the contract: sets the generation of the next link a free slot issues, so that the
// retirement of an exhausted slot can be shown without 2^32 reuses. Does nothing for a slot that is not free.
fn age_slot(io: Loop&, slot: i64, next_gen: u32) {
    guard slot >= 0 && slot < io._slots.len && io._slots[slot].state == _SlotState.Free && next_gen != 0 else { return; }
    io._slots[slot].gen = next_gen;
}

// An open end with bytes it will be given, or an end of stream it has not been told of.
fn _has_read_work(link_end: _Slot) -> bool {
    guard link_end.relay_partner < 0 && link_end.wait_for == 0 else { return false; }
    let has_bytes = link_end.unread_len > 0 && !link_end.paused;
    let has_eof = link_end.unread_len == 0 && link_end.peer_finished && !link_end.eof_seen;
    return has_bytes || has_eof;
}

// This scripted peer has nothing left to do, the library has finished sending, and it is about to hang up
// (see _run_script).
fn _will_hang_up(io: Loop&, script_index: i64) -> bool {
    let script .= io._scripts[script_index];
    return script.saw_eof && script.slot >= 0 && io._slots[script.slot].state == _SlotState.Open && io._next_step(script_index) < 0;
}

// True while a scripted peer has something to read or a hang-up to make. A peer that was told to stop
// reading, and one whose next step is not yet due, have no such work: stop does not wait for them.
fn _peer_read_work(io: Loop&) -> bool {
    for link_end in io._slots {
        if link_end.script >= 0 && link_end.state == _SlotState.Open && _has_read_work(link_end) { return true; }
    }
    for script_index in io._scripts.len {
        if io._will_hang_up(script_index) { return true; }
    }
    return false;
}

// Nothing more can happen at this instant: move the clock to the next moment something is due.
fn _advance(io: Loop&) {
    var busy = io._pending_head < io._pending.len || io._wake_at <= io._clock;
    var next = min(io._next_tick, io._wake_at);
    if io._draining && io._library_links > 0 {
        if io._stop_deadline <= io._clock { busy = true; }
        else { next = min(next, io._stop_deadline); }
    }
    for link_end in io._slots {
        if link_end.state == _SlotState.Open {
            if _has_read_work(link_end) || _relay_work(io, link_end) || io._input_ready(link_end) { busy = true; }
        } else if link_end.state == _SlotState.Dialing {
            let due = if link_end.silent { link_end.connect_deadline } else { link_end.connect_at };
            if due <= io._clock { busy = true; }
            else { next = min(next, due); }
        }
    }
    let due_at = io._next_due();
    if due_at <= io._clock { busy = true; } else { next = min(next, due_at); }
    if io._woken_head < io._woken_values.len { busy = true; }
    for script_index in io._scripts.len {
        let script .= io._scripts[script_index];
        let step_index = io._next_step(script_index);
        if step_index < 0 {
            if io._will_hang_up(script_index) { busy = true; }
        } else if io._steps[step_index].kind == _StepKind.Connect || (script.connected && !script.blocked) {
            let due = script.ready_at + io._steps[step_index].after_ms;
            if due <= io._clock { busy = true; }
            else { next = min(next, due); }
        }
    }
    if !busy && io._expect_wakes > 0 {
        io._take_wakes(true);
        if io._woken_head < io._woken_values.len { busy = true; }
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
    let slot = io._slot_of(link);
    guard slot >= 0 && io._slots[slot].peer >= 0 else { return 0; }
    return io._slots[io._slots[slot].peer].unread_len;
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
fn peer_accept(io: Loop&, peer: Peer, address: const u8[:]) {
    guard io._is_peer(peer) else { return; }
    let script .= io._scripts[_script_index(peer)];
    script.addr = _parse_address(address);
    script.accepting = script.addr.ok;
    script.refuse = false;
}

// The peer waits at `address` and refuses one dial to it: the dial fails with ConnectFailed, Refused.
fn peer_refuse(io: Loop&, peer: Peer, address: const u8[:]) {
    io.peer_accept(peer, address);
    if io._is_peer(peer) { io._scripts[_script_index(peer)].refuse = true; }
}

// Step: connect to a listener on this loop.
fn peer_connect(io: Loop&, peer: Peer, address: const u8[:], after_ms: i64) {
    io._add_step(peer, _Step { kind: _StepKind.Connect, after_ms: after_ms, addr: _parse_address(address), .. });
}

// Step: send these bytes. More than fits goes out as the library reads; later steps wait for it.
fn peer_send(io: Loop&, peer: Peer, after_ms: i64, bytes: const u8[:]) {
    let bytes_at = io._step_bytes.len;
    io._step_bytes.append(bytes);
    io._add_step(peer, _Step { kind: _StepKind.Send, after_ms: after_ms, bytes_at: bytes_at, byte_count: bytes.len, .. });
}

// Step: stop reading, so the library's sends fill the link's bound and are refused.
fn peer_stop_reading(io: Loop&, peer: Peer, after_ms: i64) { io._add_step(peer, _Step { kind: _StepKind.StopReading, after_ms: after_ms, .. }); }

// Step: read again.
fn peer_resume_reading(io: Loop&, peer: Peer, after_ms: i64) { io._add_step(peer, _Step { kind: _StepKind.ResumeReading, after_ms: after_ms, .. }); }

// Step: finish sending and keep receiving (a half-close).
fn peer_shutdown(io: Loop&, peer: Peer, after_ms: i64) { io._add_step(peer, _Step { kind: _StepKind.Shutdown, after_ms: after_ms, .. }); }

// Step: close. The library reads what the peer sent and then sees a clean end.
fn peer_close(io: Loop&, peer: Peer, after_ms: i64) { io._add_step(peer, _Step { kind: _StepKind.Close, after_ms: after_ms, .. }); }

// Step: abort. The library's link ends with PeerReset and what it had not read is lost.
fn peer_abort(io: Loop&, peer: Peer, after_ms: i64) { io._add_step(peer, _Step { kind: _StepKind.Abort, after_ms: after_ms, .. }); }

// Everything the library has sent to the peer and the peer has read, in order.
fn peer_received(io: Loop&, peer: Peer) -> u8[>..] {
    var out: u8[>..] = [];
    guard io._is_peer(peer) else { return out; }
    let script_index = _script_index(peer);
    for chunk in io._chunks {
        if chunk.script == script_index { out.append(io._captured[chunk.start..chunk.start + chunk.length]); }
    }
    return out;
}

// The peer's link is open now.
fn peer_connected(io: Loop&, peer: Peer) -> bool { io._is_peer(peer) && io._scripts[_script_index(peer)].connected }

// The library finished sending to the peer (closed its link or called shutdown_write).
fn peer_saw_eof(io: Loop&, peer: Peer) -> bool { io._is_peer(peer) && io._scripts[_script_index(peer)].saw_eof }

// The library reset the peer's link.
fn peer_saw_reset(io: Loop&, peer: Peer) -> bool { io._is_peer(peer) && io._scripts[_script_index(peer)].saw_reset }

// The peer's link has ended, or its connect failed, or it refused its dial.
fn peer_closed(io: Loop&, peer: Peer) -> bool { io._is_peer(peer) && io._scripts[_script_index(peer)].closed }

fn _is_peer(io: Loop&, peer: Peer) -> bool { peer.id != 0 && peer.id <= io._scripts.len }

fn _script_index(peer: Peer) -> i64 { peer.id - 1 }

fn _add_step(io: Loop&, peer: Peer, step: _Step) {
    guard io._is_peer(peer) else { return; }
    var added = step;
    added.script = _script_index(peer);
    io._steps.push(added);
}

// The index of this scripted peer's first unfinished step, or -1.
fn _next_step(io: Loop&, script_index: i64) -> i64 {
    let script .= io._scripts[script_index];
    while script.cursor < io._steps.len {
        let step .= io._steps[script.cursor];
        if step.script == script_index && !step.done { return script.cursor; }
        script.cursor++;
    }
    return -1;
}

// Runs every step of this scripted peer that is due.
fn _run_script(io: Loop&, script_index: i64) {
    loop {
        let script .= io._scripts[script_index];
        let step_index = io._next_step(script_index);
        if step_index < 0 {
            // Nothing left to do and the library has finished sending: hang up.
            if script.saw_eof && script.slot >= 0 && io._slots[script.slot].state == _SlotState.Open {
                io._close_gracefully(script.slot, goose_io::CloseReason.Local);
            }
            return;
        }
        let step .= io._steps[step_index];
        if step.kind == _StepKind.Connect {
            guard io._clock >= script.ready_at + step.after_ms else { return; }
            step.done = true;
            script.ready_at = io._clock;
            // a peer plays one connection: a second connect step does nothing
            if !script.taken {
                script.taken = true;
                let link = io._dial(step.addr, 0, script_index);
                script.slot = link.slot;
            }
            continue;
        }
        if script.closed || (script.taken && script.slot < 0) {
            step.done = true;                 // its link is gone: the step can never run
            continue;
        }
        guard script.connected && !script.blocked && io._clock >= script.ready_at + step.after_ms else { return; }
        let slot = script.slot;
        let link = io._link_of(slot);
        match step.kind {
            Connect => {},                    // handled above
            Send => {
                if !io._run_send_step(script_index, step_index, link) { return; }      // blocked: wait for Writable
            },
            StopReading => { io._slots[slot].paused = true; },
            ResumeReading => { io._slots[slot].paused = false; },
            Shutdown => { io.shutdown_write(link); },
            Close => {
                io._slots[slot].local_closed = true;
                io._close_gracefully(slot, goose_io::CloseReason.Local);
            },
            Abort => {
                io._slots[slot].local_closed = true;
                io._abort(slot, goose_io::CloseReason.Local);
            },
        }
        step.done = true;
        script.ready_at = io._clock;
    }
}

// Sends as much of a send step as fits. Returns false when a send was refused with Full: the peer is
// then blocked until its Writable, and the step stays unfinished.
fn _run_send_step(io: Loop&, script_index: i64, step_index: i64, link: goose_io::Link) -> bool {
    let script .= io._scripts[script_index];
    let step .= io._steps[step_index];
    if io._slots[script.slot].write_shut { step.sent = step.byte_count; }
    while step.sent < step.byte_count {
        let room = io.send_room(link);
        let left = step.byte_count - step.sent;
        let start = step.bytes_at + step.sent;
        if room == 0 {
            // register the refusal so that a Writable comes, and wait for it
            let ask = min(left, io.cfg.max_send);
            let status = io._send(link, io._step_bytes[start..start + ask], "");
            if status == goose_io::SendStatus.Full { script.blocked = true; return false; }
            step.sent = step.byte_count;   // the link ended under it
        } else {
            let chunk = min(left, room);
            let status = io._send(link, io._step_bytes[start..start + chunk], "");
            if status == goose_io::SendStatus.Sent { step.sent += chunk; } else { step.sent = step.byte_count; }
        }
    }
    return true;
}

// An event for a peer's end of a link: the peer takes it, no handler sees it.
fn _peer_deliver(io: Loop&, kind: _EventKind, slot: i64) {
    let link_end .= io._slots[slot];
    let script .= io._scripts[link_end.script];
    match kind {
        Opened => {
            if !link_end.local_closed {
                if link_end.state == _SlotState.Opening { link_end.state = _SlotState.Open; }
                link_end.opened = true;
                link_end.keep_open = true;             // the test decides when a peer closes
                script.connected = true;
                script.ready_at = io._clock;
            }
        },
        Data => {
            link_end.data_queued = false;
            if link_end.state == _SlotState.Open && !link_end.paused && link_end.unread_len > 0 {
                let count = min(link_end.unread_len, io.cfg.read_chunk);
                let base = slot * io.cfg.link_buffer;
                io._chunks.push(_Chunk { script: link_end.script, start: io._captured.len, length: count });
                io._captured.append(io._inbuf[base..base + count]);
                io._consume(slot, count);
                io._room_opened(link_end.peer);
            }
        },
        Writable => { script.blocked = false; },
        PeerEof => { script.saw_eof = true; },
        Closed => {
            if link_end.close_reason == goose_io::CloseReason.PeerReset { script.saw_reset = true; }
            script.closed = true;
            script.connected = false;
            script.blocked = false;
            script.slot = -1;
            io._release(slot);
        },
        Input, Expired => {},                  // a scripted end neither waits for input nor has limits
    }
}

// --- scripting: the event loop's own decisions ----------------------------------------------------

// Closes a link as an event loop may on its own policy, with any reason (IdleTimeout, Error,
// LoopSpecific { code }, ...), so a library can be tested against each. The other end sees a clean end.
fn close_with_reason(io: Loop&, link: goose_io::Link, why: goose_io::CloseReason) {
    let slot = io._slot_of(link);
    if slot >= 0 { io._close_gracefully(slot, why); }
}

// --- scripting: addresses ------------------------------------------------------------------------

// Makes listen on this address fail with AddressInUse, as if another process held it.
fn hold(io: Loop&, address: const u8[:]) {
    let addr = _parse_address(address);
    if addr.ok { io._held.push(addr); }
}

// Makes a dial to this address fail at once with ConnectFailed of this kind, whatever listens
// there: Unreachable, Denied, NoResources, Other.
fn fail_dials(io: Loop&, address: const u8[:], kind: goose_io::ConnectFailure) {
    let addr = _parse_address(address);
    if addr.ok { io._failing.push(_Failing { addr: addr, kind: kind }); }
}

// Makes a dial to this address never answer: it ends only when its connect time passes.
fn silent(io: Loop&, address: const u8[:]) {
    let addr = _parse_address(address);
    if addr.ok { io._silent.push(addr); }
}

// --- faults --------------------------------------------------------------------------------------
//
// A fault is a deliberate break of one behaviour of the contract, so that the conformance suite can
// be shown to fail on it (see tests/conformance/faults.sh). Faults are chosen by name, so the order
// here means nothing. The previous version numbered them by position in a list and kept empty
// strings for retired ones (UserReadAtDial, and three in the relay and revoke groups); those are gone.

enum Fault {
    None,
    // handles
    StaleHandleAccepted, UnsetLinkHasRoom, ClosedHandleStaleEarly, UnsetHandleAccepted,
    SlotsNeverReused, GenerationNotAdvanced, SlotFreedOnClose,
    // opening and dialling
    PeerCloseDropsData, OpenedBeforeFailure, WrongListenerNamed, DialClosedLost, OpenedWithoutListener,
    DialReturnsInvalid, RefusedAsUnreachable, TimeoutEarly, BadAddressAsRefused, CancelledDialOpens,
    FinishedDialIssues,
    // listening and addresses
    HeldIgnored, PortZeroReportsZero, StopListeningClosesLinks, ListenerHandleReused, StalePeerAddress,
    Ipv6Unsupported, PeerAddressGoneOnClose, PeerAddressAfterFinish,
    // sending and reading
    DataCorrupted, SendClobbersLentBytes, SendDropsLastByte, SendBeforeOpenSent, SendAfterCloseAccepted,
    Send2SwapsParts, Send2TakesFirstPart, TooLargeGivesWritable, NeverFull, RoomWhenClosed,
    SendAfterShutdownAccepted, PauseIgnored, PauseBeforeOpenIgnored, SendAfterFinishSent,
    // Writable
    NoWritable, WritablePerRefusal, WritableOnFirstByte, OneWritableOnly, WritableAfterShutdown,
    FullUnresolvedOnPeerClose, WritableAfterClose, WritableAfterClosedResult, ClosedResultNotFinal,
    // closing and end of stream
    ResetIsGraceful, CloseWithUnreadResets, ClosedNeverDelivered, EofIgnoresDefault, PeerEofBeforeData,
    SecondCloseClosesAgain, KeepOpenWhileDiallingIgnored, KeepOpenLateHonoured, EarlyEofActedOn,
    ShutdownBeforeOpenRemembered, ClosedResultEndsShutLink, ResetDialOpens, ResetAfterCloseClosesAgain,
    ShutdownOverridesLocal,
    // time and stopping
    TickEvery250, TickByIgnored, TickByKeepsLatest, NoPassEnd, IdlePassEnd, StopWaitsForGrace, ShutdownEarly,
    ListenAfterStop, DialFailsWhileDraining, StopLatestWins, SecondServeRuns, SetupEventsDropped,
    // the unix group
    UnixListenerIgnored, UnixOverlapIgnored, UnixRefusedAsBadAddress, UnixPortInvented, UnixRelativeAccepted,
    UnixLongestRefused, UnixTripleSlashRefused, UnixAliasNotHeld,
    // the relay group
    RelayDropsLastByte, RelayedSendAccepted, RelayedCountsHeld, RelayedBytesLostAtClose, RelayPartnerPeerReset, RelayJoinsRelayed,
    RelayCloseEndsOne,
    // the peek and revoke groups
    BoundIgnored, DeadlineNotReplaced, DiscardInputKeeps, DiscardKeepsBytes, InputNeverDelivered,
    DeadlineOnlyAtSend, InputEarly, PeerEndIgnored,
    // the limits group
    ReplaceKeepsFirst, IdleFromArming, SilentCountsWrites, AgeResetByActivity, StalledResetByReads,
    StalledNoProgressReset, StalledAlways, HalfOpenAlways, ExpiredRepeats, ExpiredAfterClose, AgeNeverExpires,
    // the wake group
    WakeOrderReversed, WakeBodyDropped,
}

// Switches the loop to the fault of that name (a Fault variant without the "Fault." in front). A name that is no
// variant never matches in _faulty, so it does nothing.
fn set_fault(io: Loop&, name: const u8[:]) {
    io._fault.clear();
    io._fault.append("Fault.");
    io._fault.append(name);
}
