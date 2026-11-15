// SPDX-License-Identifier: Apache-2.0
// Generic UFCS contract entry points. A provider satisfies this contract by
// implementing the corresponding methods in its own namespace.
namespace goose_io;

import std;
import core.io.types;

// Socket-provider requirements:
//   listen(address, backlog) -> Link, IoError
//   accept(listener) -> Link, Address, IoError
//   dial(address) -> Link, IoError
//   try_read(link, dst) -> bytes_read, IoError
//   try_write(link, src) -> bytes_written, IoError
//   shutdown_write(link) -> IoError
//   close(link)
//
// Reactor-provider requirements:
//   watch(link, interest) -> IoError
//   modify(link, interest) -> IoError
//   unwatch(link) -> IoError
//   poll(timeout_ms, out_events) -> count
//   timer_start(deadline_ns) -> Timer, IoError
//   timer_cancel(timer)
//   wake()

fn io_listen<Io>(io: Io&, address: Address, backlog: i32 = 128) -> Link, IoError {
    guard address.host.len > 0 && address.port != 0 && backlog > 0 else {
        return Link { .. }, IoError.InvalidArgument;
    }
    return io.listen(address, backlog);
}

fn io_accept<Io>(io: Io&, listener: Link) -> Link, Address, IoError {
    guard link_is_valid(listener) else {
        return Link { .. }, Address { .. }, IoError.InvalidArgument;
    }
    return io.accept(listener);
}

fn io_dial<Io>(io: Io&, address: Address) -> Link, IoError {
    guard address.host.len > 0 && address.port != 0 else {
        return Link { .. }, IoError.InvalidArgument;
    }
    return io.dial(address);
}

fn io_try_read<Io>(io: Io&, link: Link, dst: u8[:]) -> i64, IoError {
    guard link_is_valid(link) else { return 0, IoError.InvalidArgument; }
    guard dst.len > 0 else { return 0, IoError.None; }
    return io.try_read(link, dst);
}

fn io_try_write<Io>(io: Io&, link: Link, src: const u8[:]) -> i64, IoError {
    guard link_is_valid(link) else { return 0, IoError.InvalidArgument; }
    guard src.len > 0 else { return 0, IoError.None; }
    return io.try_write(link, src);
}

fn io_shutdown_write<Io>(io: Io&, link: Link) -> IoError {
    guard link_is_valid(link) else { return IoError.InvalidArgument; }
    return io.shutdown_write(link);
}

fn io_close<Io>(io: Io&, link: Link) {
    if link_is_valid(link) { io.close(link); }
}

fn reactor_watch<R>(r: R&, link: Link, interest: Interest) -> IoError {
    guard link_is_valid(link) else { return IoError.InvalidArgument; }
    return r.watch(link, interest);
}

fn reactor_modify<R>(r: R&, link: Link, interest: Interest) -> IoError {
    guard link_is_valid(link) else { return IoError.InvalidArgument; }
    return r.modify(link, interest);
}

fn reactor_unwatch<R>(r: R&, link: Link) -> IoError {
    guard link_is_valid(link) else { return IoError.InvalidArgument; }
    return r.unwatch(link);
}

fn reactor_poll<R>(r: R&, timeout_ms: i32, out_events: IoEvent[..64]&) -> i32 {
    out_events.clear();
    guard timeout_ms >= -1 else { return 0; }
    return r.poll(timeout_ms, out_events);
}

fn reactor_timer_start<R>(r: R&, deadline_ns: u64) -> Timer, IoError {
    return r.timer_start(deadline_ns);
}

fn reactor_timer_cancel<R>(r: R&, timer: Timer) -> IoError {
    guard timer_is_valid(timer) else { return IoError.InvalidArgument; }
    return r.timer_cancel(timer);
}

fn reactor_wake<R>(r: R&) -> IoError {
    return r.wake();
}
