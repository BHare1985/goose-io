// The extension seam. An extension is a type of the application's own, in a namespace of its own, passed to `serve<X, F>(io, x)`. The
// loop calls its hooks where it would otherwise do nothing for a socket it does not own, and gives it facilities to own links.
// With no extension the hooks are those of `_NoExt`, which do nothing and are resolved at compile time, so they cost nothing.
//
// The hooks (all take the loop first; the extension's own state is `x`):
//
//   on_accept(io, listener, fd) -> bool        a socket was accepted; true means the extension took it (it calls ext_open)
//   on_event(io, slot, second, events)         an event for a slot the extension owns; `second` is its second socket (ext_register)
//   on_ready(io)                               once per pass, after the events: the extension runs the work it queued, and handles ext_pop_woken
//   has_work() -> bool                         the extension has work left, so the loop must not sleep
//   on_sweep(io, now)                          every 250 ms: the extension's own timeouts
//   on_stop(io)                                the grace period of stop ended: the extension ends its links
//
// What the extension may do: own sockets (open a slot with ext_open, register more with ext_register, free it with ext_free), borrow pool
// buffers, count in the loop's statistics. A link of an extension is not a contract link: it has no Opened, no Closed and no events for libraries.
// What it may not do: touch a link that is not its own. Its state for a slot lives in the extension, indexed by the slot.
namespace epoll;

import std;
import goose_io;
import .sys;
import .engine;

struct _NoExt {}

fn on_accept(x: _NoExt&, io: Loop&, listener: u32, fd: i32) -> bool { return false; }
fn on_event(x: _NoExt&, io: Loop&, slot: i64, second: bool, events: u32) {}
fn on_ready(x: _NoExt&, io: Loop&) {}
fn has_work(x: _NoExt&) -> bool { return false; }
fn on_sweep(x: _NoExt&, io: Loop&, now: i64) {}
fn on_stop(x: _NoExt&, io: Loop&) {}

// Takes a slot for a socket the extension owns, counts it as accepted open link, and returns its index (the generation is ext_gen).
fn ext_open(io: Loop&, fd: i32, listener: u32) -> i64 {
    return io._fresh_link(fd, listener, _EXT);
}

fn ext_gen(io: Loop&, slot: i64) -> u32 { return io._links[slot].gen; }

// True while `slot` is a live slot of an extension with generation `gen`.
fn ext_live(io: Loop&, slot: i64, gen: u32) -> bool {
    return slot >= 0 && slot < io._links.len && io._links[slot].state == _EXT && io._links[slot].gen == gen;
}

// Registers `fd` (the slot's first socket, or its second when `second`) with epoll; edge-triggered when `edge`. False when epoll refuses.
fn ext_register(io: Loop&, slot: i64, fd: i32, second: bool, events: u32, edge: bool) -> bool {
    let kind = if second { _EVENT_KIND_EXT2 } else { _EVENT_KIND_LINK };
    let mask = if edge { events | 0x80000000 } else { events };
    return c_epoll_ctl(io._epoll_fd, c_EPOLL_CTL_ADD, fd, mask, _pack_event_data(kind, slot, io._links[slot].gen)) >= 0;
}

// Frees the slot at once: closes the slot's first socket (the extension closes its own others), advances the generation and counts the
// close under `reason`.
fn ext_free(io: Loop&, slot: i64, reason: goose_io::CloseReason) {
    let s .= io._links[slot];
    if s.state != _EXT { return; }
    if s.fd >= 0 { c_close(s.fd); s.fd = -1; }
    s.state = _FREE;
    s.registered = false;
    s.mask = 0;
    s.gen = s.gen + 1;
    io._live--;
    io._stats.open--;
    io._stats.closed[_reason_index(reason)]++;
    if s.gen <= _MAX_GEN { io._free_links.push(slot as u32); }
}

fn ext_slot_count(io: Loop&) -> i64 { return io._links.len; }
fn ext_is_ext(io: Loop&, slot: i64) -> bool { return io._links[slot].state == _EXT; }
fn ext_now(io: Loop&) -> i64 { return io._now_ms; }

// A pool buffer: its number, or -1 when all are in use.
fn ext_take_buffer(io: Loop&) -> i32 { return io._take_buffer(); }
fn ext_buffer(io: Loop&, id: i32) -> u8[:] { return io._buffer_slice(id); }
fn ext_give_buffer(io: Loop&, id: i32) { io._give_back_buffer(id); }

// Waits for a pool buffer on behalf of `slot` (kind 0 or 1, the extension's own meaning); when one comes back the entry is given
// to the extension by ext_pop_woken in on_ready. The wait is counted in buffer_waits.
fn ext_wait_buffer(io: Loop&, slot: i64, kind: i64) {
    io._waiting_reads.push(_pack_event_data(if kind == 0 { _WAITER_EXT_A } else { _WAITER_EXT_B }, slot, io._links[slot].gen));
    io._stats.buffer_waits++;
}

// The next wait whose buffer has come back: false when there is none. Fills the slot, its generation and the kind given to ext_wait_buffer.
fn ext_pop_woken(io: Loop&, slot: i64&, gen: u32&, kind: i64&) -> bool {
    if io._ext_woken.len == 0 { return false; }
    let e = io._ext_woken[io._ext_woken.len - 1];
    io._ext_woken.pop();
    slot = (e >> 32) as i64;
    gen = ((e >> 8) & 0xffffff) as u32;
    kind = if (e & 0xff) == _WAITER_EXT_A { 0 } else { 1 };
    return true;
}

fn ext_has_woken(io: Loop&) -> bool { return io._ext_woken.len > 0; }

// The loop's counters, for the extension to count in.
fn ext_stats(io: Loop&) -> Stats& { return io._stats; }

// Starts a non-blocking connect to the numeric address `text`: the socket, or the negative error number (BadAddress is -22).
fn ext_connect(io: Loop&, text: const u8[:]) -> i32 {
    var p = _ParsedAddress { false, [0; 16], 0 };
    if !_parse_address(text, p, false) { return -22; }
    return c_connect_start(p.v6, p.ip, p.port);
}

// What a connect's failure number means, in the contract's kinds.
fn ext_connect_kind(err: i32) -> goose_io::ConnectFailure { return _connect_kind(err); }
