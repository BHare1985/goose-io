// SPDX-License-Identifier: Apache-2.0
// Linux epoll implementation of the goose-io provider contract.
namespace goose_io;

import std;
import core.io.types;

const _MAX_LINKS: i64 = 65536;
const _MAX_TIMERS: i64 = 4096;
const _MAX_EVENTS: i32 = 128;
const _MAX_TIMEOUT_MS: i64 = 2147483647;
const _WAKE_KEY: u64 = 0xFFFFFFFFFFFFFFFF;

const _READ: u32 = 1;
const _WRITE: u32 = 2;
const _ERROR: u32 = 4;
const _PEER_EOF: u32 = 8;
const _WAKE: u32 = 16;

const _ADD: i32 = 1;
const _DEL: i32 = 2;
const _MOD: i32 = 3;

const _EAGAIN: i32 = 11;
const _ECONNREFUSED: i32 = 111;
const _ETIMEDOUT: i32 = 110;
const _ECONNRESET: i32 = 104;
const _ENETUNREACH: i32 = 101;
const _EHOSTUNREACH: i32 = 113;
const _EMFILE: i32 = 24;
const _ENFILE: i32 = 23;
const _ENOMEM: i32 = 12;
const _ENOBUFS: i32 = 105;
const _EPIPE: i32 = 32;
const _ENOTCONN: i32 = 107;
const _EIO: i32 = 5;
const _EACCES: i32 = 13;
const _EPERM: i32 = 1;
const _EADDRINUSE: i32 = 98;
const _EADDRNOTAVAIL: i32 = 99;
const _EINVAL: i32 = 22;
const _EBADF: i32 = 9;
const _EAFNOSUPPORT: i32 = 97;

struct _NativeEvent { events: u32, data: u64 }
enum _Kind { Listener, Connecting, Stream, Failed }

struct _LinkSlot {
    fd: i32 = -1,
    generation: u32 = 1,
    kind: _Kind = _Kind.Stream,
    interest: u32 = 0,
    read_paused: bool = false,
    peer_eof_seen: bool = false,
    live: bool = false,
}

struct _TimerSlot {
    deadline_ns: u64 = 0,
    generation: u32 = 1,
    live: bool = false,
}

struct EpollIo {
    _native: i64 = -1,
    _links: _LinkSlot[>..] = [],
    _timers: _TimerSlot[>..] = [],
    last_error: IoError = IoError { .. },
    is_open: bool = false,
}

extern fn c_epoll_create() -> i64 = "goose_io_epoll_create";
extern fn c_epoll_ctl(ep: i64, op: i32, fd: i32, events: u32, data: u64) -> i32 = "goose_io_epoll_ctl";
extern fn c_epoll_wait(ep: i64, out: _NativeEvent&, max: i32, timeout_ms: i32) -> i32 = "goose_io_epoll_wait";
extern fn c_epoll_wake(ep: i64) -> i32 = "goose_io_epoll_wake";
extern fn c_epoll_close(ep: i64) = "goose_io_epoll_close";
extern fn c_listen(v6: bool, ip: const u8[16]&, port: u16, reuseport: bool, backlog: i32) -> i32 = "goose_io_listen";
extern fn c_accept(fd: i32, peer_v6: bool&, peer_ip: u8[16]&, peer_port: u16&) -> i32 = "goose_io_accept";
extern fn c_connect_start(v6: bool, ip: const u8[16]&, port: u16) -> i32 = "goose_io_connect_start";
extern fn c_connect_result(fd: i32) -> i32 = "goose_io_connect_result";
extern fn c_socket_error(fd: i32) -> i32 = "goose_io_socket_error";
extern fn c_recv(fd: i32, dst: u8&, len: i64) -> i64 = "goose_io_recv";
extern fn c_send(fd: i32, src: const u8&, len: i64) -> i64 = "goose_io_send";
extern fn c_shutdown_write(fd: i32) -> i32 = "goose_io_shutdown_write";
extern fn c_close(fd: i32) = "goose_io_close";
extern fn c_reset(fd: i32) = "goose_io_reset";
extern fn c_monotonic_ns() -> u64 = "goose_io_monotonic_ns";

fn _key(link: Link) -> u64 {
    return ((link.generation as u64) << 32) | (link.slot as u64);
}

fn _decode(key: u64) -> Link {
    return Link { slot: key as u32, generation: (key >> 32) as u32 };
}

fn _error(code: i32) -> IoError {
    if code == 0 { return IoError { .. }; }
    let n = if code < 0 { -code } else { code };
    if n == _EAGAIN { return IoError { kind: IoErrorKind.WouldBlock, code: n }; }
    if n == _EPIPE || n == _ENOTCONN || n == _EBADF { return IoError { kind: IoErrorKind.Closed, code: n }; }
    if n == _ECONNREFUSED { return IoError { kind: IoErrorKind.Refused, code: n }; }
    if n == _ETIMEDOUT { return IoError { kind: IoErrorKind.TimedOut, code: n }; }
    if n == _ECONNRESET { return IoError { kind: IoErrorKind.Reset, code: n }; }
    if n == _ENETUNREACH || n == _EHOSTUNREACH { return IoError { kind: IoErrorKind.Unreachable, code: n }; }
    if n == _EMFILE || n == _ENFILE || n == _ENOMEM || n == _ENOBUFS {
        return IoError { kind: IoErrorKind.ResourceExhausted, code: n };
    }
    if n == _EADDRINUSE { return IoError { kind: IoErrorKind.AddressInUse, code: n }; }
    if n == _EADDRNOTAVAIL { return IoError { kind: IoErrorKind.AddressNotAvailable, code: n }; }
    if n == _EACCES || n == _EPERM { return IoError { kind: IoErrorKind.PermissionDenied, code: n }; }
    if n == _EINVAL { return IoError { kind: IoErrorKind.InvalidArgument, code: n }; }
    if n == _EAFNOSUPPORT { return IoError { kind: IoErrorKind.Unsupported, code: n }; }
    return IoError { kind: IoErrorKind.System, code: n };
}

fn _find_link(io: const EpollIo&, link: Link) -> i64 {
    guard io.is_open && link_is_valid(link) && link.slot < io._links.len else { return -1; }
    let i = link.slot as i64;
    guard io._links[i].live && io._links[i].generation == link.generation else { return -1; }
    return i;
}

fn _find_timer(io: const EpollIo&, timer: Timer) -> i64 {
    guard io.is_open && timer_is_valid(timer) && timer.slot < io._timers.len else { return -1; }
    let i = timer.slot as i64;
    guard io._timers[i].live && io._timers[i].generation == timer.generation else { return -1; }
    return i;
}

fn _register(io: EpollIo&, fd: i32, kind: _Kind, interest: u32) -> Link, IoError {
    guard io.is_open && fd >= 0 else {
        return Link { .. }, IoError { kind: IoErrorKind.Closed, .. };
    }
    var slot: i64 = -1;
    for i in io._links.len {
        if !io._links[i].live { slot = i; break; }
    }
    if slot < 0 {
        if io._links.len >= _MAX_LINKS {
            c_close(fd);
            return Link { .. }, IoError { kind: IoErrorKind.ResourceExhausted, .. };
        }
        io._links.push(_LinkSlot { .. });
        slot = io._links.len - 1;
    }
    let link = Link { slot: slot as u32, generation: io._links[slot].generation };
    let rc = c_epoll_ctl(io._native, _ADD, fd, interest, _key(link));
    if rc < 0 { c_close(fd); return Link { .. }, _error(rc); }
    io._links[slot].fd = fd;
    io._links[slot].kind = kind;
    io._links[slot].interest = interest;
    io._links[slot].read_paused = false;
    io._links[slot].peer_eof_seen = false;
    io._links[slot].live = true;
    return link, IoError { .. };
}

fn _apply_interest(io: EpollIo&, slot: i64) -> IoError {
    let link = Link { slot: slot as u32, generation: io._links[slot].generation };
    var mask = io._links[slot].interest;
    if io._links[slot].read_paused { mask &= ~_READ; }
    let rc = c_epoll_ctl(io._native, _MOD, io._links[slot].fd, mask, _key(link));
    return if rc < 0 { _error(rc) } else { IoError { .. } };
}

fn _retire(io: EpollIo&, slot: i64, abort: bool) {
    if !io._links[slot].live { return; }
    let fd = io._links[slot].fd;
    let _ = c_epoll_ctl(io._native, _DEL, fd, 0, 0);
    if abort { c_reset(fd); } else { c_close(fd); }
    io._links[slot].fd = -1;
    io._links[slot].interest = 0;
    io._links[slot].read_paused = false;
    io._links[slot].peer_eof_seen = false;
    io._links[slot].live = false;
    io._links[slot].generation += 1;
    if io._links[slot].generation == 0 { io._links[slot].generation = 1; }
}

fn open(io: EpollIo&) -> IoError {
    if io.is_open { return IoError { .. }; }
    io._native = c_epoll_create();
    if io._native < 0 { return _error(io._native as i32); }
    io.is_open = true;
    return IoError { .. };
}

fn close(io: EpollIo&) {
    if !io.is_open { return; }
    for i in io._links.len { _retire(io, i, false); }
    c_epoll_close(io._native);
    io._native = -1;
    io.is_open = false;
    for i in io._timers.len {
        io._timers[i].live = false;
        io._timers[i].deadline_ns = 0;
        io._timers[i].generation += 1;
        if io._timers[i].generation == 0 { io._timers[i].generation = 1; }
    }
}

fn listen(io: EpollIo&, address: Address, options: ListenOptions) -> Link, IoError {
    guard io.is_open && address.port != 0 && options.backlog > 0 else {
        return Link { .. }, IoError { kind: IoErrorKind.InvalidArgument, .. };
    }
    let fd = c_listen(address.v6, address.ip, address.port, options.reuse_port, options.backlog);
    if fd < 0 { return Link { .. }, _error(fd); }
    return _register(io, fd, _Kind.Listener, 0);
}

fn accept(io: EpollIo&, listener: Link) -> Link, Address, IoError {
    let i = _find_link(io, listener);
    guard i >= 0 && io._links[i].kind == _Kind.Listener else {
        return Link { .. }, Address { .. }, IoError { kind: IoErrorKind.InvalidArgument, .. };
    }
    var peer_v6 = false;
    var peer_ip: u8[16] = [0; 16];
    var peer_port: u16 = 0;
    let fd = c_accept(io._links[i].fd, peer_v6, peer_ip, peer_port);
    if fd < 0 { return Link { .. }, Address { .. }, _error(fd); }
    let peer = Address { v6: peer_v6, ip: peer_ip, port: peer_port };
    let link, err = _register(io, fd, _Kind.Stream, 0);
    return link, peer, err;
}

fn dial(io: EpollIo&, address: Address) -> Link, IoError {
    guard io.is_open && address.port != 0 else {
        return Link { .. }, IoError { kind: IoErrorKind.InvalidArgument, .. };
    }
    let fd = c_connect_start(address.v6, address.ip, address.port);
    if fd < 0 { return Link { .. }, _error(fd); }
    // A connecting socket is watched for writability until SO_ERROR resolves it.
    return _register(io, fd, _Kind.Connecting, _WRITE);
}

fn try_read(io: EpollIo&, link: Link, dst: u8[:]) -> i64, IoError {
    let i = _find_link(io, link);
    guard i >= 0 && io._links[i].kind == _Kind.Stream else {
        return 0, IoError { kind: IoErrorKind.InvalidArgument, .. };
    }
    if dst.len == 0 { return 0, IoError { .. }; }
    let n = c_recv(io._links[i].fd, dst[0], dst.len);
    if n == 0 { return 0, IoError { kind: IoErrorKind.Eof, .. }; }
    if n < 0 { return 0, _error(n as i32); }
    return n, IoError { .. };
}

fn try_write(io: EpollIo&, link: Link, src: const u8[:]) -> i64, IoError {
    let i = _find_link(io, link);
    guard i >= 0 && io._links[i].kind == _Kind.Stream else {
        return 0, IoError { kind: IoErrorKind.InvalidArgument, .. };
    }
    if src.len == 0 { return 0, IoError { .. }; }
    let n = c_send(io._links[i].fd, src[0], src.len);
    if n < 0 { return 0, _error(n as i32); }
    return n, IoError { .. };
}

fn shutdown_write(io: EpollIo&, link: Link) -> IoError {
    let i = _find_link(io, link);
    guard i >= 0 && io._links[i].kind == _Kind.Stream else {
        return IoError { kind: IoErrorKind.InvalidArgument, .. };
    }
    let rc = c_shutdown_write(io._links[i].fd);
    return if rc == 0 { IoError { .. } } else { _error(rc) };
}

fn close(io: EpollIo&, link: Link) {
    let i = _find_link(io, link);
    if i >= 0 { _retire(io, i, false); }
}

fn reset(io: EpollIo&, link: Link) {
    let i = _find_link(io, link);
    if i >= 0 { _retire(io, i, true); }
}

fn pause_reading(io: EpollIo&, link: Link, paused: bool) -> IoError {
    let i = _find_link(io, link);
    guard i >= 0 && io._links[i].kind != _Kind.Failed else {
        return IoError { kind: IoErrorKind.InvalidArgument, .. };
    }
    io._links[i].read_paused = paused;
    return _apply_interest(io, i);
}

fn _link_of(interest: Interest) -> Link {
    return match interest {
        Accept { listener } => listener,
        Connected { link } => link,
        Readable { link } => link,
        Writable { link } => link,
        Timer { timer: _ } => Link { .. },
    };
}

fn _bits_of(interest: Interest) -> u32 {
    return match interest {
        Accept { listener: _ } => _READ,
        Connected { link: _ } => _WRITE,
        Readable { link: _ } => _READ,
        Writable { link: _ } => _WRITE,
        Timer { timer: _ } => 0,
    };
}

fn watch(io: EpollIo&, interest: Interest) -> IoError {
    match interest {
        Timer t => {
            return if _find_timer(io, t.timer) >= 0 { IoError { .. } } else { IoError { kind: IoErrorKind.InvalidArgument, .. } };
        },
        _ => {},
    }
    let link = _link_of(interest);
    let bits = _bits_of(interest);
    let i = _find_link(io, link);
    guard i >= 0 else { return IoError { kind: IoErrorKind.InvalidArgument, .. }; }
    match interest {
        Accept { listener: _ } => {
            guard io._links[i].kind == _Kind.Listener else { return IoError { kind: IoErrorKind.InvalidArgument, .. }; }
        },
        Connected { link: _ } => {
            guard io._links[i].kind == _Kind.Connecting else { return IoError { kind: IoErrorKind.InvalidArgument, .. }; }
            return IoError { .. }; // dial() already arms writable while connecting
        },
        Readable { link: _ } => {
            guard io._links[i].kind == _Kind.Stream else { return IoError { kind: IoErrorKind.InvalidArgument, .. }; }
        },
        Writable { link: _ } => {
            guard io._links[i].kind == _Kind.Stream else { return IoError { kind: IoErrorKind.InvalidArgument, .. }; }
        },
        Timer { timer: _ } => return IoError { .. },
    }
    return _apply_interest(io, i) if (io._links[i].interest & bits) != 0 else _change_interest(io, link, bits, 0);
}

fn _change_interest(io: EpollIo&, link: Link, set_bits: u32, clear_bits: u32) -> IoError {
    let i = _find_link(io, link);
    guard i >= 0 else { return IoError { kind: IoErrorKind.InvalidArgument, .. }; }
    io._links[i].interest = (io._links[i].interest | set_bits) & ~clear_bits;
    return _apply_interest(io, i);
}

fn unwatch(io: EpollIo&, interest: Interest) -> IoError {
    match interest {
        Timer t => {
            return if _find_timer(io, t.timer) >= 0 { IoError { .. } } else { IoError { kind: IoErrorKind.InvalidArgument, .. } };
        },
        _ => {},
    }
    let link = _link_of(interest);
    let bits = _bits_of(interest);
    let i = _find_link(io, link);
    guard i >= 0 else { return IoError { kind: IoErrorKind.InvalidArgument, .. }; }
    match interest {
        Connected { link: _ } => {
            guard io._links[i].kind == _Kind.Connecting || io._links[i].kind == _Kind.Stream || io._links[i].kind == _Kind.Failed else {
                return IoError { kind: IoErrorKind.InvalidArgument, .. };
            }
            return IoError { .. }; // connect interest is one-shot and removed on completion
        },
        Accept { listener: _ } => {
            guard io._links[i].kind == _Kind.Listener else { return IoError { kind: IoErrorKind.InvalidArgument, .. }; }
        },
        Readable { link: _ } | Writable { link: _ } => {
            guard io._links[i].kind == _Kind.Stream else { return IoError { kind: IoErrorKind.InvalidArgument, .. }; }
        },
        Timer { timer: _ } => return IoError { .. },
    }
    return _change_interest(io, link, 0, bits);
}

fn after(io: EpollIo&, deadline_ns: u64) -> Timer, IoError {
    guard io.is_open else { return Timer { .. }, IoError { kind: IoErrorKind.Closed, .. }; }
    var slot: i64 = -1;
    for i in io._timers.len {
        if !io._timers[i].live { slot = i; break; }
    }
    if slot < 0 {
        if io._timers.len >= _MAX_TIMERS {
            return Timer { .. }, IoError { kind: IoErrorKind.ResourceExhausted, .. };
        }
        io._timers.push(_TimerSlot { .. });
        slot = io._timers.len - 1;
    }
    io._timers[slot].deadline_ns = deadline_ns;
    io._timers[slot].live = true;
    return Timer { slot: slot as u32, generation: io._timers[slot].generation }, IoError { .. };
}

fn cancel_timer(io: EpollIo&, timer: Timer) -> bool {
    let i = _find_timer(io, timer);
    if i < 0 { return false; }
    io._timers[i].live = false;
    io._timers[i].deadline_ns = 0;
    io._timers[i].generation += 1;
    if io._timers[i].generation == 0 { io._timers[i].generation = 1; }
    return true;
}

fn _timeout(io: const EpollIo&, requested_ms: i32, now_ns: u64) -> i32 {
    var result = requested_ms;
    for i in io._timers.len {
        if io._timers[i].live {
            if io._timers[i].deadline_ns <= now_ns { return 0; }
            let ns = io._timers[i].deadline_ns - now_ns;
            var ms = (ns / 1000000) as i64;
            if ns % 1000000 != 0 { ms++; }
            if ms > _MAX_TIMEOUT_MS { ms = _MAX_TIMEOUT_MS; }
            if result < 0 || ms < result { result = ms as i32; }
        }
    }
    return result;
}

fn _emit_timers(io: EpollIo&, now_ns: u64, out: Completion[128]&, count: i32) -> i32 {
    var n = count;
    for i in io._timers.len {
        if n >= 128 { break; }
        if io._timers[i].live && now_ns >= io._timers[i].deadline_ns {
            let timer = Timer { slot: i as u32, generation: io._timers[i].generation };
            out[n] = Completion.Timer { timer: timer, now_ns: now_ns };
            n++;
            io._timers[i].live = false;
            io._timers[i].deadline_ns = 0;
            io._timers[i].generation += 1;
            if io._timers[i].generation == 0 { io._timers[i].generation = 1; }
        }
    }
    return n;
}

fn poll(io: EpollIo&, timeout_ms: i32, out: Completion[128]&) -> i32 {
    if !io.is_open { io.last_error = IoError { kind: IoErrorKind.Closed, .. }; return -1; }
    if timeout_ms < -1 { io.last_error = IoError { kind: IoErrorKind.InvalidArgument, .. }; return -1; }
    io.last_error = IoError { .. };
    var n: i32 = _emit_timers(io, c_monotonic_ns(), out, 0);
    if n > 0 { return n; }

    var events: _NativeEvent[128] = [_NativeEvent { 0, 0 }; 128];
    let rc = c_epoll_wait(io._native, events[0], _MAX_EVENTS, _timeout(io, timeout_ms, c_monotonic_ns()));
    if rc < 0 { io.last_error = _error(rc); return -1; }
    let now = c_monotonic_ns();

    for k in rc {
        if n >= 126 { break; }
        let key = events[k].data;
        let flags = events[k].events;
        if key == _WAKE_KEY { out[n] = Completion.Wake; n++; continue; }
        let link = _decode(key);
        let i = _find_link(io, link);
        if i < 0 { continue; }

        if io._links[i].kind == _Kind.Connecting {
            let err = c_connect_result(io._links[i].fd);
            if err == 0 {
                io._links[i].kind = _Kind.Stream;
                io._links[i].interest &= ~_WRITE;
                let _ = _apply_interest(io, i);
                out[n] = Completion.Connected { link: link };
            } else {
                let _ = c_epoll_ctl(io._native, _DEL, io._links[i].fd, 0, 0);
                io._links[i].kind = _Kind.Failed;
                io._links[i].interest = 0;
                out[n] = Completion.Closed { link: link, error: _error(err) };
            }
            n++;
            continue;
        }

        if io._links[i].kind == _Kind.Listener {
            if (flags & _ERROR) != 0 && n < 128 {
                let err = c_socket_error(io._links[i].fd);
                io._links[i].interest = 0;
                let _ = _apply_interest(io, i);
                out[n] = Completion.Closed { link: link, error: _error(if err == 0 { _EIO } else { err }) };
                n++;
            } else if (flags & _READ) != 0 && n < 128 {
                out[n] = Completion.AcceptReady { listener: link }; n++;
            }
            continue;
        }

        if (flags & _READ) != 0 && n < 128 { out[n] = Completion.Readable { link: link }; n++; }
        if (flags & _WRITE) != 0 && n < 128 { out[n] = Completion.Writable { link: link }; n++; }
        if (flags & _PEER_EOF) != 0 && !io._links[i].peer_eof_seen && n < 128 {
            io._links[i].peer_eof_seen = true;
            out[n] = Completion.PeerEof { link: link }; n++;
        }
        if (flags & _ERROR) != 0 && n < 128 {
            let err = c_socket_error(io._links[i].fd);
            io._links[i].interest = 0;
            let _ = _apply_interest(io, i);
            out[n] = Completion.Closed { link: link, error: _error(if err == 0 { _EIO } else { err }) };
            n++;
        }
    }
    return _emit_timers(io, now, out, n);
}

fn wake(io: EpollIo&) -> IoError {
    guard io.is_open else { return IoError { kind: IoErrorKind.Closed, .. }; }
    let rc = c_epoll_wake(io._native);
    return if rc == 0 { IoError { .. } } else { _error(rc) };
}

fn monotonic_ns(_: EpollIo&) -> u64 { return c_monotonic_ns(); }
