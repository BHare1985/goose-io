## Context

- The contract's core moves bytes only as `Data` (lent to the library) and `send` (copied into the loop). That is right for libraries that read and write bytes (a Postgres client, an HTTP server) and cannot express work in which a library never needs the bytes (forwarding between two sockets), work that needs to look before consuming (choosing a handler from a TLS hello), a limit on when bytes may still be written, and a message from another thread. Kernel mechanisms exist for each: `splice` and io_uring splice, `MSG_PEEK` with `SO_RCVLOWAT`, `eventfd` and `IORING_OP_MSG_RING`.
- tcprouter's engine does these today (its forward pump, its hello peek, its write-time fence, its cross-thread messages) and must lose none of them when it moves onto goose-io, and it times out connections whose bytes it never sees once a relay carries them. They are the five groups here.
- The contract already has the means to add capabilities that only some loops supply: groups. A group is a named package of operations and events; a loop supplies it or not; a library names it in its header; the build fails, naming the operation, on a loop that lacks it; the suite runs it as its own entry point; the in-memory loop supplies it with a fault for each check. No rule of the core depends on a group, and no group replaces a core operation.
- This change is the contract, the in-memory loop and the suite only. Implementing a group on a real loop (the epoll loops, an io_uring loop) and using it in tcprouter are later work, after the loops and tcprouter exist without groups.

## Goals / Non-Goals

**Goals:**

- The five intents are expressible as groups stated by behaviour (bytes, order, backpressure, ends, errors), so that an epoll loop, an io_uring loop and the in-memory loop can implement each differently and one suite tells which is right.
- Groups are optional: a loop pays for none it does not supply, and a library says which it needs.

**Non-Goals:**

- Naming a kernel mechanism in the contract. `relay` does not say `splice`; `peek` does not say `MSG_PEEK`.
- A fallback between groups ("use relay if present, else copy"): postponed to a later change (D6 item 2). Until then a library names the groups it needs with `require_*`, and a loop without one fails to build.
- Implementing the groups on a real loop or in tcprouter, handing a link to another thread or process, datagrams, TLS, per-socket tuning.

## Decisions

### D1. Groups, not hooks and not loop-specific functions

Hooks in a loop (a seam an outside extension fills) keep the contract small but make a program depend on one loop's internals, break the loop's rules without a check, and allow one extension per loop. Loop-specific functions leave the feature outside the contract: no portability, no suite, no in-memory test, no stated interaction with the rest. Groups give each feature a meaning, a suite and a fault; the cost is a larger contract, taken one group at a time and only for a feature with a user. All five have one: tcprouter.

### D2. Operations state intent; the loop picks the mechanism

| Group | Intent | Mechanisms a loop may use |
|---|---|---|
| relay | carry bytes between two links | userspace buffers and a pump, `splice` through a pipe, io_uring splice, an eBPF sockmap redirect |
| peek | look at unread bytes and wait for enough | `MSG_PEEK`, `SO_RCVLOWAT`, a provided-buffer ring that is not consumed |
| revoke | take back unsent bytes; stop writing at a time | the loop's own send queue and a clock read at each write; cancelling a submission that has not started |
| wake | deliver a value from another thread | `eventfd`, a pipe, `IORING_OP_MSG_RING` |
| limits | tell the library when a link has been quiet, or half-closed, for too long | a timer wheel or a heap in the loop and the loop's wait set to the earliest due time; `timerfd`; io_uring linked timeouts |

A loop that implements an operation by a plain copy conforms; the point of the operation is that a loop that can do better may.

### D3. relay

A relayed link is a sixth state of the link table ("relayed", between open and closing). What every operation does in it:

| Operation | relayed |
|---|---|
| `send`, `send2`, `send_room` | `Closed`, 0; the relay owns the sending of the link (the same meaning of `Closed` as after `shutdown_write`: the library knows from what it called) |
| `pause_reading`, `set_keep_open_on_eof`, `shutdown_write` | no effect |
| `close`, `reset` | end both links of the pair; each gets one `Closed`, reason `Local` |
| `peer_address` | the address, as when open |
| `relayed_bytes` | bytes carried from this link |

The pair ends as one: when both streams have ended each link gets `Closed` with `PeerClosed`; an error, a reset or a limit on one link ends the other. The reasons are fixed by D6 item 1. Backpressure is the loop's: it stops reading a link when its partner cannot take more; the loop's memory for a pair is bounded by one buffer for each direction.

### D4. peek

The loop holds unread bytes until the library releases them. `wait_input(link, n)` withholds `Data` and delivers one `Input { link, available }` when `n` bytes or the peer's end have arrived. `peek(link)` is a view of the held bytes, valid until the handler returns, and consumes nothing. `wait_input(link, 0)` releases: the held bytes arrive as `Data` in order. This is what a hello-routing proxy needs: a connection waiting for a hello holds no buffer of the library's, and the hello can be replayed to a second backend because nothing consumed it. A library may also `relay` a link after a peek; the held bytes are then the first bytes carried. A paused link holds its bytes and delivers no `Input` until resumed; the peer's end of stream is reported (`PeerEof` or `Closed`) after the released `Data`.

### D5. revoke and wake

A proxy's fences require that no byte is written after a deadline, including bytes queued before it, and that the clock is read at each write: a process stopped between the start of a pass and a write must not write late. `write_deadline` states exactly that, and `discard_unsent` is the other half (a library that revokes a lease takes back what the loop has not written). A loop that cannot recall bytes it has already handed to the transport says so (an io_uring loop with a send in flight); the spec binds only the bytes not yet handed over. The end reason of a link whose deadline passed is `Local`, because the library set the deadline; a new close reason was refused (it would change the core's `CloseReason`).

`waker()` returns a copyable fixed-size handle, and `wake` is the only operation callable from any thread. The contract states that a loop belongs to the thread that serves it; this group makes one stated exception. `Woken` goes to every library like `Tick`: the application's glue decides who handles it. Ordering is per calling thread.

### D5b. limits

**What the core already gives.** `tick_by(at_ms)` and `Tick` let a library keep its own deadlines: tcprouter's connect timeout, its fences' deadline table and its drain deadline need nothing more, because the library knows when they start and what ends them. A `Tick` comes at least every 100 ms and at the earliest requested time, and an idle loop waking ten times a second is not a cost worth a group. A general timer table in the loop was considered and not made: it would replace what a library already does with a small heap, for no behaviour tcprouter lacks.

**What the core cannot give.** A relayed link delivers no `Data` and no `Writable`, so the library cannot tell whether the pair is idle. The library could poll `relayed_bytes` of every pair on a tick, which is a call per connection per tick, thousands a second at 10,000 connections, and it is the library doing the loop's work. The same holds for a half-closed pair: the loop knows when one stream ended and the library does not. tcprouter's idle timeout (RT-7b), half-close timeout (RT-7c, RT-15f) and the rule that bytes a socket takes while its queue drains count as activity (RT-19c) therefore need the loop. `limits` gives that, and the other states a loop alone can see (below).

**Shape.** One operation, one event, five kinds of "too long in a state":
- `set_limit(link, kind, ms)`; `ms` 0 turns a kind off; a second call for a kind replaces it; kinds are independent. `Expired { link, limit }` is a link event, once for each arming.
- `Idle`: no byte read from or written to the transport for `ms`. A byte a relay carries counts for both links of the pair, and so does a byte the transport accepts while a queue drains (RT-19c). tcprouter's idle timeout (RT-7b).
- `Silent`: no byte read for `ms` (from the opening if none), whatever the library sends. The peer that connects and says nothing, or stops sending mid-request, while the library keeps writing: the generic slow-client and handshake guard; tcprouter's inspect timeout (RT-3d) is this.
- `Stalled`: the loop has bytes waiting for the link, or a relay has bytes from the partner, and the transport accepts none for `ms`. This is the deadlock case: two peers each waiting for the other, or a peer that sends but never reads, which `Idle` misses because the peer's own bytes keep it busy, and which holds the loop's buffers for the pair. It does not run when nothing waits.
- `HalfOpen`: `ms` after the peer's stream ended on a link that stays open (kept open by `set_keep_open_on_eof`, or relayed), whatever crosses since, so a handler that keeps sending after `PeerEof` is still bounded (RT-7c, RT-15f).
- `Age`: `ms` after the link opened, whatever happens: a handshake deadline (arm it, then `set_limit(link, Age, 0)` when the handshake is done), a cap on a session's life, a lease.

The kinds are the states a loop can see and a library cannot once a relay carries the bytes, or cannot see cheaply otherwise. One operation with a kind keeps the contract small and lets a later kind be added without a new group. Mutual deadlock of the library's own logic (it waits on a link that never answers) is `Silent` or `Idle` with a limit the library chooses; the loop cannot know what a library waits for.

**The loop reports, the library closes.** `Expired` does not close the link. tcprouter closes with different reasons for idle, half-close timeout and fence (its stats and logs say which), a handler may extend a limit, and a close is what libraries already do; so the loop supplies the fact and the library the policy. A library that wants a limit to end the link arms it and closes on `Expired`, one line. A new close reason was refused for the reason given in D5. Closing one link of a relayed pair ends both (D3). Each arming delivers at most one `Expired`; the library arms again if it wants another. The core's rule that the loop never delivers an event for a link after its `Closed` holds.

**Timing.** The loop sleeps until the earliest due limit, so `Expired` is delivered in the first pass that begins at or after the due time and not at the next 100 ms `Tick`. Activity in a pass moves the due time of its link before limits are checked, so a link that sent a byte in the pass in which it fell due is not expired. The clock is the loop's (`now_ms`), read once per pass; a loop may choose a clock that keeps counting while the machine is suspended (the epoll loops use `CLOCK_BOOTTIME`, as tcprouter does for its fences, RT-6c), and the contract does not require it.

**What stays out.** Fences (no byte after a tag's deadline) stay `write_deadline` of revoke, and a tag table, the connect timeout of a dial (RT-7a, RT-13k) and the drain deadline stay in the library on `tick_by`. The stall limit of a relayed pair whose peer never reads (D6 item 1) stays the loop's own configured limit and reports `Local` on both links; a library that wants its own period uses `Stalled`.

### D6. Decisions taken (formerly the open questions)

1. **What each link of a failed relayed pair carries.** The link where the failure happened carries the true cause, and the partner never carries `PeerReset` (it would blame the partner's peer and count one reset twice).
   - A reset by one peer: that link `PeerReset`, the partner `Error`.
   - Any other failure of one link (a transport error, a kernel timeout of a link that never reads): that link `Error`, the partner `Error`.
   - A limit of the loop's own (a stall limit the loop enforces on a peer that never reads, the bound): both links `Local`.
   - A `close` or `reset` by the library on one link: both `Local` (unchanged).
   - Both streams ended: both `PeerClosed` (unchanged).
   - The library sees both links' events, so the originating link gives it the root cause; the relay still ends the pair as one (the alternative, a relay that stops and leaves the other link to the library, was considered and rejected: it makes every proxy write the same cleanup). The in-memory loop scripts the cases: reset, error, a loop limit, a peer that never reads (with the loop's stall limit, and with a scripted kernel timeout).
2. **Fallback when a loop lacks a group.** Postponed to a later change. For now a library that needs a group names it with its `require_*` check and a loop without the group fails to build; no spike is made and no overload mechanism is promised.
3. **Held bytes and the bound.** The bound is configuration: every loop exposes it (the in-memory loop's is configurable so the suite can test the edge) and documents its default. At the bound the loop stops reading the link and delivers `Input` with `available` equal to the bound even when `n` is larger; the library then decides (close, relay, or `wait_input(link, 0)`). Nothing past the bound is read.
4. **`Input` carries a count, not bytes.** `Input { link, available }` says that bytes are held; the bytes stay where they are (in the kernel for a loop that can leave them there) until the library calls `peek`, which shows them without consuming, or `relay`, which can carry them without a copy to user memory. A library that decides without looking (by listener or source address) pays no copy. A view in the event would force the loop to read every link's first bytes up front.

### D7. Implementation order (in this repository)

In the in-memory loop, in the order relay, peek, revoke, wake, limits: spec scenario, suite check that fails, the loop's code, the fault for the check; then the combination checks, then the table and the documents. Real loops come after, as separate work.

## Risks / Trade-offs

- **The contract grows by five groups** → each is optional, has its own suite, and has a user.
- **`relay` forbids a loop from splicing in some situations** (a spliced link cannot deliver `Data`) → that is the group's definition: a relayed link delivers none. A library that must see the bytes does not relay.
- **A group's rules and another's interact** (`write_deadline` on a relayed link, `peek` then `relay`, `wait_input` on a paused link) → each combination is stated in the spec or D3 and D4, and checked by a test that supplies both groups, outside any group's entry point.
- **Adding variants to `Event` breaks exhaustive matches** → the same break `PassEnd` caused; recorded as a compile-time-only breaking change; the example libraries have catch-all arms.
- **A real loop may be unable to meet a rule** (recalling bytes in flight) → the spec binds only what a loop can promise and says where the limit is; a loop records what it tried, as the contract already requires.

## Migration Plan

- Work on a branch of goose-io after `epoll-event-loop` is accepted; nothing is pushed or tagged without the owner's approval. The groups are additive; reverting is a revert of the merge. The contract version goes to 0.3 (a minor increase while the major is zero).
- `add-stream-extras` applies after this change.

## Open Questions

- None. D6 items 1 to 4 are decided; a fallback between groups is a later change.
