// SPDX-License-Identifier: Apache-2.0
// Shared, backend-neutral I/O types.
namespace goose_io;

import std;

enum IoError {
    None,
    WouldBlock,
    Eof,
    UnexpectedEof,
    Closed,
    Cancelled,
    TimedOut,
    InvalidArgument,
    CapacityExceeded,
    Unsupported,
    System,
}

struct Link {
    slot:       u32 = 0xFFFFFFFF,
    generation: u32 = 0,
}

struct Timer {
    slot:       u32 = 0xFFFFFFFF,
    generation: u32 = 0,
}

struct Address {
    host: const u8[:] = "",
    port: u16 = 0,
}

enum Interest {
    None,
    Readable,
    Writable,
    ReadWrite,
}

const EVENT_NONE:      u32 = 0;
const EVENT_READABLE:  u32 = 1 << 0;
const EVENT_WRITABLE:  u32 = 1 << 1;
const EVENT_ERROR:     u32 = 1 << 2;
const EVENT_PEER_EOF:  u32 = 1 << 3;
const EVENT_TIMER:     u32 = 1 << 4;
const EVENT_WAKE:      u32 = 1 << 5;

enum Wait {
    Readable { link: Link },
    Writable { link: Link },
    Timer { timer: Timer },
    Wake,
}

struct IoEvent {
    link: Link = Link { .. },
    timer: Timer = Timer { .. },
    flags: u32 = EVENT_NONE,
    error: IoError = IoError.None,
    timestamp_ns: u64 = 0,
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

fn interest_flags(_: Interest.None) -> u32 { return EVENT_NONE; }
fn interest_flags(_: Interest.Readable) -> u32 { return EVENT_READABLE; }
fn interest_flags(_: Interest.Writable) -> u32 { return EVENT_WRITABLE; }
fn interest_flags(_: Interest.ReadWrite) -> u32 { return EVENT_READABLE | EVENT_WRITABLE; }
