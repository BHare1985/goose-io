# I/O contract (initial draft)

## Provider surface

A concrete provider satisfies the following compile-time/UFCS method set. The
contract is one surface, even where implementations internally separate socket
creation from readiness polling.

| Method | Return | Semantics |
|---|---|---|
| listen(address, backlog) | Link, IoError | Create a nonblocking listener |
| accept(listener) | Link, Address, IoError | Accept one connection or return WouldBlock |
| dial(address) | Link, IoError | Start/complete a nonblocking outbound connection |
| try_read(link, dst) | bytes, IoError | One nonblocking read attempt |
| try_write(link, src) | bytes, IoError | One nonblocking write attempt; partial writes are valid |
| shutdown_write(link) | IoError | Half-close the write direction |
| close(link) | — | Close and invalidate the resource |
| watch(link, interest) | IoError | Arm readiness notification |
| modify(link, interest) | IoError | Change armed readiness |
| unwatch(link) | IoError | Remove readiness registration |
| poll(timeout_ms, events) | event count | Return readiness, timer, and wake events |
| timer_start(deadline_ns) | Timer, IoError | Arm an absolute monotonic deadline |
| timer_cancel(timer) | IoError | Cancel a deadline |
| wake() | IoError | Wake a blocked poller from another thread |

A custom implementation such as tcprouter implements these methods against its
existing worker/reactor; it does not need to use the reference epoll implementation.

## Read/write rules

try_read and try_write never block the calling worker. They return WouldBlock
when no progress can be made immediately. A successful write may accept fewer
bytes than requested; callers must retain and retry the unwritten suffix. A
zero-byte receive is EOF, not WouldBlock.

The provider does not retain caller read/write slices after the nonblocking
function returns. A future direct submission extension for io_uring/IOCP can
add explicit in-flight buffer ownership without changing the base contract.

## Coroutine integration

The scheduler consumes a yielded Wait value and records the coroutine frame
against that wait. It resumes the same frame when a matching IoEvent arrives.
Nested coroutine yields propagate through callers. This is a target integration
example, not currently compiler-verified; goose-io does not implement the
coroutine runtime or scheduler.

The contract does not introduce callback registration or an application-owned
dispatch_link function.

## Event routing

A scheduler may have many coroutine frames waiting on one resource. The
scheduler owns those wait lists and decides which frames to resume. The reactor
only reports resource readiness. Protocol libraries own protocol state, and
connection-pool libraries own query/request correlation.

A wake event is untagged. Cross-thread task queues carry their own queue entries;
wake() only interrupts a blocked poll call so the owning worker can drain queues.

## Handle rules

Link and Timer are opaque (slot, generation) handles. Slot reuse increments its
generation. A stale generation must never address a new object that inherited
the slot. Raw descriptors and event-loop keys are backend details.

## Reference reactor boundary

The initial EpollReactor is a readiness reactor. Socket creation and nonblocking
try_read/try_write are provider methods. The first cut includes an epoll
registration/timer/wakeup engine; socket primitives and other OS backends are
follow-on work.
