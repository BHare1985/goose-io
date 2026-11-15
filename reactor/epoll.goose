// SPDX-License-Identifier: Apache-2.0
// Linux epoll + eventfd reference reactor.
namespace goose_io;

import std;
import core.io.types;

const EPOLL_MAX_LINKS: i64 = 1024;
const EPOLL_MAX_TIMERS: i64 = 256;
const EPOLL_EVENT_CAP: i64 = 64;

struct EpollRegistration {
    fd: i64 = -1,
    generation: u32 = 1,
    interest: Interest = Interest.None,
    in_use: bool = false,
}

struct EpollTimerSlot {
    deadline_ns: u64 = 0,
    generation: u32 = 1,
    in_use: bool = false,
}

struct EpollReactor {
    native: i64 = -1,
    links: EpollRegistration[..1024] = [EpollRegistration { .. }; 1024],
    timers: EpollTimerSlot[..256] = [EpollTimerSlot { .. }; 256],
    is_open: bool = false,
}

extern fn native_epoll_create() -> i64 = "goose_io_epoll_create";
extern fn native_epoll_add(epfd: i64, fd: i64, key: u64, flags: u32) -> i32 = "goose_io_epoll_add";
extern fn native_epoll_mod(epfd: i64, fd: i64, key: u64, flags: u32) -> i32 = "goose_io_epoll_mod";
extern fn native_epoll_del(epfd: i64, fd: i64) -> i32 = "goose_io_epoll_del";
extern fn native_epoll_wait(epfd: i64, keys: u64[:], flags: u32[:], timeout_ms: i32) -> i32 = "goose_io_epoll_wait";
extern fn native_epoll_wake(epfd: i64) -> i32 = "goose_io_epoll_wake";
extern fn native_epoll_close(epfd: i64) = "goose_io_epoll_close";
extern fn native_monotonic_ns() -> u64 = "goose_io_monotonic_ns";

const NATIVE_WAKE_KEY: u64 = 0xFFFFFFFFFFFFFFFF;

fn make_link_key(link: Link) -> u64 {
    return ((link.generation as u64) << 32) | (link.slot as u64);
}

fn decode_link_key(key: u64) -> Link {
    return Link { slot: key as u32, generation: (key >> 32) as u32 };
}

fn epoll_flags(interest: Interest) -> u32 {
    return match interest {
        None => 0,
        Readable => EVENT_READABLE,
        Writable => EVENT_WRITABLE,
        ReadWrite => EVENT_READABLE | EVENT_WRITABLE,
    };
}

fn new_epoll_reactor() -> EpollReactor {
    let native = native_epoll_create();
    return EpollReactor { native: native, is_open: native >= 0, .. };
}

fn close_epoll_reactor(r: EpollReactor&) {
    if !r.is_open { return; }
    native_epoll_close(r.native);
    r.native = -1;
    r.is_open = false;
    for i in r.links.len {
        r.links[i].in_use = false;
        r.links[i].fd = -1;
    }
    for i in r.timers.len {
        r.timers[i].in_use = false;
    }
}

fn epoll_find_slot(r: const EpollReactor&, link: Link) -> i64 {
    guard r.is_open && link_is_valid(link) && link.slot < r.links.len else { return -1; }
    let slot = link.slot as i64;
    guard r.links[slot].in_use && r.links[slot].generation == link.generation else { return -1; }
    return slot;
}

fn epoll_watch_fd(r: EpollReactor&, fd: i64, interest: Interest) -> Link, IoError {
    guard r.is_open && fd >= 0 && interest != Interest.None else {
        return Link { .. }, IoError.InvalidArgument;
    }
    for i in r.links.len {
        if !r.links[i].in_use {
            let link = Link { slot: i as u32, generation: r.links[i].generation };
            let rc = native_epoll_add(r.native, fd, make_link_key(link), epoll_flags(interest));
            guard rc == 0 else { return Link { .. }, IoError.System; }
            r.links[i].fd = fd;
            r.links[i].interest = interest;
            r.links[i].in_use = true;
            return link, IoError.None;
        }
    }
    return Link { .. }, IoError.CapacityExceeded;
}

fn epoll_modify(r: EpollReactor&, link: Link, interest: Interest) -> IoError {
    let slot = epoll_find_slot(r, link);
    guard slot >= 0 && interest != Interest.None else { return IoError.InvalidArgument; }
    let rc = native_epoll_mod(r.native, r.links[slot].fd, make_link_key(link), epoll_flags(interest));
    guard rc == 0 else { return IoError.System; }
    r.links[slot].interest = interest;
    return IoError.None;
}

fn epoll_unwatch(r: EpollReactor&, link: Link) -> IoError {
    let slot = epoll_find_slot(r, link);
    guard slot >= 0 else { return IoError.InvalidArgument; }
    let rc = native_epoll_del(r.native, r.links[slot].fd);
    guard rc == 0 else { return IoError.System; }
    r.links[slot].fd = -1;
    r.links[slot].interest = Interest.None;
    r.links[slot].in_use = false;
    r.links[slot].generation += 1;
    if r.links[slot].generation == 0 { r.links[slot].generation = 1; }
    return IoError.None;
}

fn epoll_timer_start(r: EpollReactor&, deadline_ns: u64) -> Timer, IoError {
    guard r.is_open && deadline_ns > 0 else { return Timer { .. }, IoError.InvalidArgument; }
    for i in r.timers.len {
        if !r.timers[i].in_use {
            let timer = Timer { slot: i as u32, generation: r.timers[i].generation };
            r.timers[i].deadline_ns = deadline_ns;
            r.timers[i].in_use = true;
            return timer, IoError.None;
        }
    }
    return Timer { .. }, IoError.CapacityExceeded;
}

fn epoll_timer_cancel(r: EpollReactor&, timer: Timer) -> IoError {
    guard timer_is_valid(timer) && timer.slot < r.timers.len else { return IoError.InvalidArgument; }
    let slot = timer.slot as i64;
    guard r.timers[slot].in_use && r.timers[slot].generation == timer.generation else {
        return IoError.InvalidArgument;
    }
    r.timers[slot].in_use = false;
    r.timers[slot].deadline_ns = 0;
    r.timers[slot].generation += 1;
    if r.timers[slot].generation == 0 { r.timers[slot].generation = 1; }
    return IoError.None;
}

fn epoll_emit_expired_timers(r: EpollReactor&, now_ns: u64, out: IoEvent[..64]&) {
    for i in r.timers.len {
        if r.timers[i].in_use && now_ns >= r.timers[i].deadline_ns && out.len < out.cap {
            let timer = Timer { slot: i as u32, generation: r.timers[i].generation };
            let _ = out.try_push(IoEvent { timer: timer, flags: EVENT_TIMER, timestamp_ns: now_ns, .. });
            r.timers[i].in_use = false;
            r.timers[i].deadline_ns = 0;
            r.timers[i].generation += 1;
            if r.timers[i].generation == 0 { r.timers[i].generation = 1; }
        }
    }
}

fn epoll_timeout_with_timers(r: const EpollReactor&, requested_ms: i32, now_ns: u64) -> i32 {
    var effective = requested_ms;
    for i in r.timers.len {
        if r.timers[i].in_use {
            if r.timers[i].deadline_ns <= now_ns { return 0; }
            let remaining_ns = r.timers[i].deadline_ns - now_ns;
            let remaining_ms = ((remaining_ns + 999999) / 1000000) as i64;
            if effective < 0 || remaining_ms < effective { effective = remaining_ms as i32; }
        }
    }
    return effective;
}

fn epoll_poll(r: EpollReactor&, timeout_ms: i32, out: IoEvent[..64]&) -> i32 {
    out.clear();
    guard r.is_open && timeout_ms >= -1 else { return 0; }
    var keys: u64[64] = [0; 64];
    var flags: u32[64] = [0; 64];
    let before_ns = native_monotonic_ns();
    let effective_timeout = epoll_timeout_with_timers(r, timeout_ms, before_ns);
    let count = native_epoll_wait(r.native, keys[..], flags[..], effective_timeout);
    let now_ns = native_monotonic_ns();
    if count > 0 {
        for i in count {
            if keys[i] == NATIVE_WAKE_KEY {
                let _ = out.try_push(IoEvent { flags: EVENT_WAKE, timestamp_ns: now_ns, .. });
            } else {
                let link = decode_link_key(keys[i]);
                let slot = epoll_find_slot(r, link);
                if slot >= 0 {
                    let _ = out.try_push(IoEvent {
                        link: link,
                        flags: flags[i],
                        error: if (flags[i] & EVENT_ERROR) != 0 { IoError.System } else { IoError.None },
                        timestamp_ns: now_ns,
                        ..
                    });
                }
            }
        }
    }
    epoll_emit_expired_timers(r, now_ns, out);
    return out.len as i32;
}

fn epoll_wake(r: EpollReactor&) -> IoError {
    guard r.is_open else { return IoError.Closed; }
    return if native_epoll_wake(r.native) == 0 { IoError.None } else { IoError.System };
}

fn watch(r: EpollReactor&, link: Link, interest: Interest) -> IoError { return epoll_modify(r, link, interest); }
fn modify(r: EpollReactor&, link: Link, interest: Interest) -> IoError { return epoll_modify(r, link, interest); }
fn unwatch(r: EpollReactor&, link: Link) -> IoError { return epoll_unwatch(r, link); }
fn poll(r: EpollReactor&, timeout_ms: i32, out: IoEvent[..64]&) -> i32 { return epoll_poll(r, timeout_ms, out); }
fn timer_start(r: EpollReactor&, deadline_ns: u64) -> Timer, IoError { return epoll_timer_start(r, deadline_ns); }
fn timer_cancel(r: EpollReactor&, timer: Timer) -> IoError { return epoll_timer_cancel(r, timer); }
fn wake(r: EpollReactor&) -> IoError { return epoll_wake(r); }
