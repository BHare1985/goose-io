// SPDX-License-Identifier: Apache-2.0
// Generic UFCS entry points for the shared asynchronous I/O provider contract.
namespace goose_io;

import std;
import core.io.types;

// Provider requirements:
//   listen(address, options) -> Link, IoError
//   accept(listener) -> Link, Address, IoError
//   dial(address) -> Link, IoError
//   try_read(link, dst) -> bytes_read, IoError
//   try_write(link, src) -> bytes_written, IoError
//   pause_reading(link, paused)
//   close(link), reset(link), shutdown_write(link)
//   watch(interest), unwatch(interest)
//   after(deadline_ns) -> Timer, IoError
//   cancel_timer(timer) -> bool
//   poll(timeout_ms, completions) -> count (-1 on error; inspect last_error)
//   wake()
//
// Static generic/UFCS dispatch is intentional. Frameworks and async client
// libraries use the same provider without importing one another.

fn io_listen<Io>(io: Io&, address: Address, options: ListenOptions) -> Link, IoError {
    guard address.port != 0 && options.backlog > 0 else {
        return Link { .. }, IoError { kind: IoErrorKind.InvalidArgument, .. };
    }
    return io.listen(address, options);
}

fn io_accept<Io>(io: Io&, listener: Link) -> Link, Address, IoError {
    guard link_is_valid(listener) else {
        return Link { .. }, Address { .. }, IoError { kind: IoErrorKind.InvalidArgument, .. };
    }
    return io.accept(listener);
}

fn io_dial<Io>(io: Io&, address: Address) -> Link, IoError {
    guard address.port != 0 else {
        return Link { .. }, IoError { kind: IoErrorKind.InvalidArgument, .. };
    }
    return io.dial(address);
}

fn io_try_read<Io>(io: Io&, link: Link, dst: u8[:]) -> i64, IoError {
    guard link_is_valid(link) else {
        return 0, IoError { kind: IoErrorKind.InvalidArgument, .. };
    }
    guard dst.len > 0 else { return 0, IoError { .. }; }
    return io.try_read(link, dst);
}

fn io_try_write<Io>(io: Io&, link: Link, src: const u8[:]) -> i64, IoError {
    guard link_is_valid(link) else {
        return 0, IoError { kind: IoErrorKind.InvalidArgument, .. };
    }
    guard src.len > 0 else { return 0, IoError { .. }; }
    return io.try_write(link, src);
}

fn io_shutdown_write<Io>(io: Io&, link: Link) -> IoError {
    guard link_is_valid(link) else { return IoError { kind: IoErrorKind.InvalidArgument, .. }; }
    return io.shutdown_write(link);
}

fn io_close<Io>(io: Io&, link: Link) {
    if link_is_valid(link) { io.close(link); }
}

fn io_reset<Io>(io: Io&, link: Link) {
    if link_is_valid(link) { io.reset(link); }
}

fn io_pause_reading<Io>(io: Io&, link: Link, paused: bool) -> IoError {
    guard link_is_valid(link) else { return IoError { kind: IoErrorKind.InvalidArgument, .. }; }
    return io.pause_reading(link, paused);
}

fn io_watch<Io>(io: Io&, interest: Interest) -> IoError {
    return io.watch(interest);
}

fn io_unwatch<Io>(io: Io&, interest: Interest) -> IoError {
    return io.unwatch(interest);
}

fn io_after<Io>(io: Io&, deadline_ns: u64) -> Timer, IoError {
    return io.after(deadline_ns);
}

fn io_cancel_timer<Io>(io: Io&, timer: Timer) -> bool {
    if !timer_is_valid(timer) { return false; }
    return io.cancel_timer(timer);
}

fn io_poll<Io>(io: Io&, timeout_ms: i32, out: Completion[128]&) -> i32 {
    guard timeout_ms >= -1 else { return -1; }
    return io.poll(timeout_ms, out);
}

fn io_wake<Io>(io: Io&) -> IoError {
    return io.wake();
}
