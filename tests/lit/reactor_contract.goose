// SPDX-License-Identifier: Apache-2.0
// Linux reference provider smoke test. Requires Goose + Linux epoll.
// RUN: goose build -O2 -o %t.exe %s
// RUN: %t.exe | %FileCheck %s

import std;
import goose_io from "../..";

fn test_epoll_timer_and_wake() {
    var io = goose_io::EpollIo { .. };
    assert(io.open().kind == goose_io::IoErrorKind.None);

    let timer, timer_error = io.after(io.monotonic_ns() + 2000000);
    assert(timer_error.kind == goose_io::IoErrorKind.None);
    assert(goose_io::timer_is_valid(timer));

    var completions: goose_io::Completion[128] = [goose_io::Completion.Wake; 128];
    let n = io.poll(100, completions);
    assert(n > 0);
    var saw_timer = false;
    for i in n {
        match completions[i] {
            Timer { timer: fired, now_ns: _ } => {
                if goose_io::same_timer(fired, timer) { saw_timer = true; }
            },
            _ => {},
        }
    }
    assert(saw_timer);

    assert(io.wake().kind == goose_io::IoErrorKind.None);
    let woke = io.poll(100, completions);
    assert(woke > 0);
    var saw_wake = false;
    for i in woke {
        match completions[i] {
            Wake => saw_wake = true,
            _ => {},
        }
    }
    assert(saw_wake);
    io.close();
    print("EPOLL_TIMER_WAKE: ok");
}

fn main() {
    // CHECK: EPOLL_TIMER_WAKE: ok
    test_epoll_timer_and_wake();
    // CHECK: ALL_REACTOR_CONTRACT_TESTS_PASSED
    print("ALL_REACTOR_CONTRACT_TESTS_PASSED");
}
