// SPDX-License-Identifier: Apache-2.0
// Linux reference reactor smoke tests. Native execution requires Goose + epoll.
// RUN: goose build -O2 -o %t.exe %s
// RUN: %t.exe | %FileCheck %s

import std;
import goose_io from "../..";

fn test_timer_and_wakeup() {
    var reactor = goose_io::new_epoll_reactor();
    assert(reactor.is_open);
    defer goose_io::close_epoll_reactor(reactor);
    let now = goose_io::native_monotonic_ns();
    let timer, timer_err = goose_io::epoll_timer_start(reactor, now + 2000000);
    assert(timer_err == goose_io::IoError.None);
    var events: goose_io::IoEvent[..64] = [];
    let n = goose_io::epoll_poll(reactor, 100, events);
    assert(n > 0);
    var saw_timer = false;
    for i in n {
        if (events[i].flags & goose_io::EVENT_TIMER) != 0 &&
            goose_io::same_timer(events[i].timer, timer) { saw_timer = true; }
    }
    assert(saw_timer);
    assert(goose_io::epoll_wake(reactor) == goose_io::IoError.None);
    events.clear();
    let woke = goose_io::epoll_poll(reactor, 100, events);
    assert(woke > 0);
    var saw_wake = false;
    for i in woke {
        if (events[i].flags & goose_io::EVENT_WAKE) != 0 { saw_wake = true; }
    }
    assert(saw_wake);
    print("EPOLL_TIMER_WAKE: ok");
}

fn main() {
    // CHECK: EPOLL_TIMER_WAKE: ok
    test_timer_and_wakeup();
    // CHECK: ALL_REACTOR_CONTRACT_TESTS_PASSED
    print("ALL_REACTOR_CONTRACT_TESTS_PASSED");
}
