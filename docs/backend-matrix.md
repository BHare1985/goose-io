# Backend roadmap and conformance

## Backend status

| Backend | Status | Intended mechanism |
|---|---|---|
| Linux epoll | **Implemented reference provider** | Nonblocking TCP, level-triggered epoll, eventfd wake, monotonic timer table |
| Linux io_uring | Roadmap | Native poll/operation completions normalized to the shared contract |
| macOS / BSD kqueue | Roadmap | `EVFILT_READ`, `EVFILT_WRITE`, `EVFILT_TIMER`, `EVFILT_USER` |
| Windows IOCP | Roadmap | `AcceptEx`, `ConnectEx`, read/write completions normalized to the contract |

RIO is not part of the base contract. It may be evaluated later as an optional Windows optimization.

## Portability rules

- Public types never expose native descriptors or backend event structures.
- Every backend uses the same `Link`, `Timer`, `Interest`, `WaitSet`, `Completion`, and `IoError` semantics.
- Handles are generation checked; stale events never target a reused slot.
- Reads/writes obey the same partial-progress and `WouldBlock` rules.
- Timers use documented monotonic one-shot semantics.
- Wakeups interrupt polling but carry no application payload.
- Completion-oriented native APIs are normalized behind the same public contract.

## Conformance gates

Before a backend is marked implemented, it must pass tests for:

1. listen, accept readiness, multiple queued accepts, and accept returning `WouldBlock` after draining;
2. connect success, refusal, timeout, cancellation, and exactly one terminal outcome;
3. readable/writable notifications, partial reads/writes, and `WouldBlock`;
4. peer EOF, half-close, reset, and close behavior;
5. stale `Link` and `Timer` values after slot reuse;
6. timer expiry/cancellation races and timer-vs-socket readiness;
7. wake while poll is blocked and repeated/coalesced wake calls;
8. closing watched descriptors and queued stale native events;
9. high connection churn, descriptor reuse, and resource exhaustion;
10. scheduler coalescing of duplicate waiters and removal of losing interests.

A deterministic fake provider should run on every CI platform. Native tests must run on their actual operating systems. Successful compilation alone is not enough to claim support.
