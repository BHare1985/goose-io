## Context

- The contract's core moves bytes only as `Data` (lent to the library) and `send` (copied into the loop). That is right for libraries that read and write bytes (a Postgres client, an HTTP server) and cannot express work in which a library never needs the bytes (forwarding between two sockets), work that needs to look before consuming (choosing a handler from a TLS hello), a limit on when bytes may still be written, and a message from another thread. Kernel mechanisms exist for each: `splice` and io_uring splice, `MSG_PEEK` with `SO_RCVLOWAT`, `eventfd` and `IORING_OP_MSG_RING`.
- tcprouter's engine does these today (its forward pump, its hello peek, its write-time fence, its cross-thread messages) and must lose none of them when it moves onto goose-io. They are the four groups here.
- The contract already has the means to add capabilities that only some loops supply: groups. A group is a named package of operations and events; a loop supplies it or not; a library names it in its header; the build fails, naming the operation, on a loop that lacks it; the suite runs it as its own entry point; the in-memory loop supplies it with a fault for each check. No rule of the core depends on a group, and no group replaces a core operation.
- This change is the contract, the in-memory loop and the suite only. Implementing a group on a real loop (the epoll loops, an io_uring loop) and using it in tcprouter are later work, after the loops and tcprouter exist without groups.

## Goals / Non-Goals

**Goals:**

- The four intents are expressible as groups stated by behaviour (bytes, order, backpressure, ends, errors), so that an epoll loop, an io_uring loop and the in-memory loop can implement each differently and one suite tells which is right.
- Groups are optional: a loop pays for none it does not supply, and a library says which it needs.

**Non-Goals:**

- Naming a kernel mechanism in the contract. `relay` does not say `splice`; `peek` does not say `MSG_PEEK`.
- A fallback between groups ("use relay if present, else copy"): an open question (D6), and a separate change if wanted.
- Implementing the groups on a real loop or in tcprouter, handing a link to another thread or process, datagrams, TLS, per-socket tuning.

## Decisions

### D1. Groups, not hooks and not loop-specific functions

Hooks in a loop (a seam an outside extension fills) keep the contract small but make a program depend on one loop's internals, break the loop's rules without a check, and allow one extension per loop. Loop-specific functions leave the feature outside the contract: no portability, no suite, no in-memory test, no stated interaction with the rest. Groups give each feature a meaning, a suite and a fault; the cost is a larger contract, taken one group at a time and only for a feature with a user. All four have one: tcprouter.

### D2. Operations state intent; the loop picks the mechanism

| Group | Intent | Mechanisms a loop may use |
|---|---|---|
| relay | carry bytes between two links | userspace buffers and a pump, `splice` through a pipe, io_uring splice, an eBPF sockmap redirect |
| peek | look at unread bytes and wait for enough | `MSG_PEEK`, `SO_RCVLOWAT`, a provided-buffer ring that is not consumed |
| revoke | take back unsent bytes; stop writing at a time | the loop's own send queue and a clock read at each write; cancelling a submission that has not started |
| wake | deliver a value from another thread | `eventfd`, a pipe, `IORING_OP_MSG_RING` |

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

The pair ends as one: when both streams have ended each link gets `Closed` with `PeerClosed`; an error, a reset or a limit on one link ends the other. The reason the other link carries is open (D6). Backpressure is the loop's: it stops reading a link when its partner cannot take more; the loop's memory for a pair is bounded by one buffer for each direction.

### D4. peek

The loop holds unread bytes until the library releases them. `wait_input(link, n)` withholds `Data` and delivers one `Input { link, available }` when `n` bytes or the peer's end have arrived. `peek(link)` is a view of the held bytes, valid until the handler returns, and consumes nothing. `wait_input(link, 0)` releases: the held bytes arrive as `Data` in order. This is what a hello-routing proxy needs: a connection waiting for a hello holds no buffer of the library's, and the hello can be replayed to a second backend because nothing consumed it. A library may also `relay` a link after a peek; the held bytes are then the first bytes carried. A paused link holds its bytes and delivers no `Input` until resumed; the peer's end of stream is reported (`PeerEof` or `Closed`) after the released `Data`.

### D5. revoke and wake

A proxy's fences require that no byte is written after a deadline, including bytes queued before it, and that the clock is read at each write: a process stopped between the start of a pass and a write must not write late. `write_deadline` states exactly that, and `discard_unsent` is the other half (a library that revokes a lease takes back what the loop has not written). A loop that cannot recall bytes it has already handed to the transport says so (an io_uring loop with a send in flight); the spec binds only the bytes not yet handed over. The end reason of a link whose deadline passed is `Local`, because the library set the deadline; a new close reason was refused (it would change the core's `CloseReason`).

`waker()` returns a copyable fixed-size handle, and `wake` is the only operation callable from any thread. The contract states that a loop belongs to the thread that serves it; this group makes one stated exception. `Woken` goes to every library like `Tick`: the application's glue decides who handles it. Ordering is per calling thread.

### D6. Open questions the first tasks settle

1. **What the partner of a failed relayed link carries.** Candidates: `PeerReset` for a reset and `Error` for any other failure; `Local` for the loop's own limit. Settled by reading how a proxy ends both sides today and by the in-memory loop's scripted failures; the spec is amended before the checks are written.
2. **Compile-time detection of a group.** A library that wants relay when present and a `Data` and `send` path when not needs to ask whether a loop has `relay`. A spike with two overloads shows whether Goose resolves by the operations a type has. If not, the answer is a documented pattern (one library, two build variants chosen by the application) and not a contract feature.
3. **Held bytes and the bound.** `peek` holds at most the loop's per-link bound; a hello over the bound ends in the library's hands. The spec states the bound as "the loop's bound for a link" and a loop documents it; the in-memory loop's bound is configurable so the suite can test the edge.
4. **Whether `Input` carries the bytes.** A view in the event would save a call, but a held view that outlives the handler is what `peek` exists to avoid. The design keeps the event small.

### D7. Implementation order (in this repository)

In the in-memory loop, in the order relay, peek, revoke, wake: spec scenario, suite check that fails, the loop's code, the fault for the check; then the combination checks, then the table and the documents. Real loops come after, as separate work.

## Risks / Trade-offs

- **The contract grows by four groups** → each is optional, has its own suite, and has a user.
- **`relay` forbids a loop from splicing in some situations** (a spliced link cannot deliver `Data`) → that is the group's definition: a relayed link delivers none. A library that must see the bytes does not relay.
- **A group's rules and another's interact** (`write_deadline` on a relayed link, `peek` then `relay`, `wait_input` on a paused link) → each combination is stated in the spec or D3 and D4, and checked by a test that supplies both groups, outside any group's entry point.
- **Adding variants to `Event` breaks exhaustive matches** → the same break `PassEnd` caused; recorded as a compile-time-only breaking change; the example libraries have catch-all arms.
- **A real loop may be unable to meet a rule** (recalling bytes in flight) → the spec binds only what a loop can promise and says where the limit is; a loop records what it tried, as the contract already requires.

## Migration Plan

- Work on a branch of goose-io after `epoll-event-loop` is accepted; nothing is pushed or tagged without the owner's approval. The groups are additive; reverting is a revert of the merge. The contract version goes to 0.3 (a minor increase while the major is zero).
- `add-stream-extras` applies after this change.

## Open Questions

- D6 items 1 to 4, settled by the first tasks.
