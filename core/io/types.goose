// SPDX-License-Identifier: Apache-2.0
// The backend-neutral vocabulary shared by frameworks, drivers, and reactors.
namespace goose_io;

import std;

enum IoErrorKind {
    None,
    WouldBlock,
    Eof,
    Refused,
    TimedOut,
    Reset,
    Unreachable,
    ResourceExhausted,
    AddressInUse,
    AddressNotAvailable,
    PermissionDenied,
    Closed,
    Cancelled,
    InvalidArgument,
    Unsupported,
    System,
}

struct IoError {
    kind: IoErrorKind = IoErrorKind.None,
    code: i32 = 0,
}

struct Link {
    slot: u32 = 0xFFFFFFFF,
    generation: u32 = 0,
}

struct Timer {
    slot: u32 = 0xFFFFFFFF,
    generation: u32 = 0,
}

struct Address {
    v6: bool = false,
    ip: u8[16] = [0; 16],
    port: u16 = 0,
}

struct ListenOptions {
    backlog: i32 = 1024,
    reuse_port: bool = false,
}

enum Interest {
    Accept { listener: Link },
    Connected { link: Link },
    Readable { link: Link },
    Writable { link: Link },
    Timer { timer: Timer },
}

struct WaitSet {
    interests: Interest[..4] = [],
}

enum Completion {
    AcceptReady { listener: Link },
    Connected { link: Link },
    Readable { link: Link },
    Writable { link: Link },
    PeerEof { link: Link },
    Closed { link: Link, error: IoError },
    Timer { timer: Timer, now_ns: u64 },
    Wake,
}

fn link_is_valid(link: Link) -> bool {
    return link.slot != 0xFFFFFFFF && link.generation != 0;
}

fn timer_is_valid(timer: Timer) -> bool {
    return timer.slot != 0xFFFFFFFF && timer.generation != 0;
}

fn same_link(a: Link, b: Link) -> bool {
    return a.slot == b.slot && a.generation == b.generation;
}

fn same_timer(a: Timer, b: Timer) -> bool {
    return a.slot == b.slot && a.generation == b.generation;
}
