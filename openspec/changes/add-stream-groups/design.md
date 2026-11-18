## Context

- The contract's core moves bytes only as `Data` (lent to the library) and `send` (copied into the loop). That is right for libraries that read and write bytes (a Postgres client, an HTTP server) and cannot express work in which a library never needs the bytes (forwarding between two sockets, serving a file), work that needs to look before consuming (choosing a handler from a TLS hello), and work that comes from outside the loop (another thread). Kernel mechanisms exist for each: `splice` and io_uring splice, `sendfile`, `MSG_ZEROCOPY`, `MSG_PEEK` with `SO_RCVLOWAT`, `eventfd` and `IORING_OP_MSG_RING`.
- tcprouter's engine does the first three of these today (its forward pump, its hello peek, its write-time fence, its cross-thread messages) and must lose none of them when it moves onto goose-io. The measured parity of the epoll loop (`openspec/changes/epoll-event-loop`) covers its handler path and a fixed-target forward; it does not cover these features through the contract.
- The contract already has the means to add capabilities that only some loops supply: groups. A group is a named package of operations and events; a loop supplies it or not; the library names it in its header; the build fails, naming the operation, on a loop that lacks it; the suite runs it as its own entry point; the in-memory loop supplies it with a fault for each check. No rule of the core depends on a group.
- The epoll loop is now two sources, `goose-io-epoll` (plain) and `goose-io-epoll-ext` (the loop plus what a performant proxy needs), kept in `.implementations/` and linked from `examples/README.md`. This change is what lets the second be described in the contract's terms instead of as loop-specific functions.

## Goals / Non-Goals

**Goals:**

- Every intent a stream program has is expressible as a core operation or a group, so that moving a program onto goose-io loses no feature and lets a loop choose any kernel mechanism below the operation.
- Each group is stated by behaviour (bytes, order, backpressure, ends, errors), so that the epoll loop, a future io_uring loop and the in-memory loop can implement it differently and the same suite tells which is right.
- Groups are optional, and a library says which it needs. A loop pays for none it does not supply.

**Non-Goals:**

- Naming a kernel mechanism in the contract. `relay` does not say `splice`; `peek` does not say `MSG_PEEK`.
- A fallback mechanism between groups ("use relay if present, else copy"). It is an open question (D8) and a separate change if wanted.
- Handing a link to another thread or process, datagrams, TLS and kernel TLS, per-socket tuning (configuration of the loop), and porting tcprouter.

## Decisions

### D1. Groups, not hooks and not loop-specific functions

Three ways to let a program reach beyond the core were weighed. Hooks in the loop (a seam an outside extension fills) keep the contract small but make the program depend on one loop's internals, break the loop's own rules without a check, and allow one extension per loop. Loop-specific functions (what `goose-io-epoll-ext` has now) are quick but leave the feature outside the contract: no portability, no suite, no in-memory test, no stated interaction with the rest. Groups give each feature a meaning, a suite and a fault; the cost is a larger contract, taken one group at a time and only for features with a real user. The first four groups (relay, peek, revoke, wake) have one, tcprouter. The other four (files, loans, parts, addresses) close gaps that an HTTP server or a gateway would meet; they are specified here and implemented after the first four.

### D2. Operations state intent; the loop picks the mechanism

| Group | Intent | Mechanisms a loop may use |
|---|---|---|
| relay | carry bytes between two links | userspace buffers and a pump (epoll), `splice` through a pipe, io_uring splice, an eBPF sockmap redirect |
| peek | look at unread bytes and wait for enough | `MSG_PEEK`, `SO_RCVLOWAT`, a provided-buffer ring that is not consumed |
| revoke | take back unsent bytes; stop writing at a time | the loop's own send queue and a clock read at each write; cancelling a submission that has not started |
| wake | deliver a value from another thread | `eventfd`, a pipe, `IORING_OP_MSG_RING` |
| files | send a file's bytes | `sendfile`, io_uring splice from a file, a read and send |
| loans | send from a lent buffer without a copy | `MSG_ZEROCOPY`, `IORING_OP_SEND_ZC`, a copy |
| parts | send several ranges as one | `writev`, `sendmsg`, a join |
| addresses | local end and original destination | `getsockname`, `SO_ORIGINAL_DST`, `IP_TRANSPARENT` |

A loop that implements an operation by a plain copy conforms; the point of the operation is that a loop that can do better may.

### D3. relay

A relayed link is a sixth state of the link table of the contract ("relayed", between open and closing). What every operation does in it:

| Operation | relayed |
|---|---|
| `send`, `send2`, `send_room` (and `send_parts`, `send_file`, `send_loan`) | `Closed`, 0; the relay owns the sending of the link (the same meaning of `Closed` as after `shutdown_write`: the library knows from what it called) |
| `pause_reading`, `set_keep_open_on_eof`, `shutdown_write` | no effect |
| `close`, `reset` | end both links of the pair; each gets one `Closed`, reason `Local` |
| `peer_address`, `local_address` | the address, as when open |
| `relayed_bytes` | bytes carried from this link |

The pair ends as one: when both streams have ended each link gets `Closed` with `PeerClosed`; an error, a reset or a limit on one link ends the other. The reason the *other* link carries is open (D8). Backpressure is the loop's: it stops reading a link when its partner cannot take more, as tcprouter's pump does; the loop's memory for a pair is one buffer for each direction at most, which is the bound the suite checks.

### D4. peek

The loop holds unread bytes until the library releases them. `wait_input(link, n)` withholds `Data` (the bytes stay in the loop or the kernel, not in the library) and delivers one `Input { link, available }` when `n` bytes or the peer's end have arrived. `peek(link)` is a view of the held bytes, valid until the handler returns, and consumes nothing. `wait_input(link, 0)` releases: the held bytes arrive as `Data` in order. This is what tcprouter's SNI routing does today with `MSG_PEEK` and `SO_RCVLOWAT`: a connection waiting for a hello holds no buffer of the loop's, and the hello can be replayed to a second backend because nothing consumed it. A library may also `relay` a link after a peek; the held bytes are then the first bytes carried. How `peek` combines with `pause_reading` (a paused link holds its bytes and delivers no `Input` until resumed) and with the peer's end of stream (`PeerEof` after the released `Data`) is stated in the spec's scenarios and in D8.

### D5. revoke and the clock

tcprouter's fences and deadlines require that no byte is written after a deadline, including bytes queued before it, and that the clock is read at each write: a process stopped between the start of a pass and a write must not write late. `write_deadline` states exactly that, and `discard_unsent` is the other half (a library that revokes a lease takes back what the loop has not written). A loop that cannot recall bytes it has already handed to the transport says so in its documentation (an io_uring loop with a send in flight); the spec binds only the bytes not yet handed over. The end reason of a link whose deadline passed is `Local`, because the library set the deadline; a new close reason was considered and refused (it would change the core's `CloseReason`).

### D6. wake

`waker()` returns a copyable handle (a fixed-size struct holding what the loop needs: a descriptor or a ring id and an index), and `wake` is the only operation of the contract callable from any thread. The contract states "a loop belongs to the thread that serves it"; this group makes one exception and states it. `Woken` goes to every library like `Tick`: the application's glue decides who handles it. Ordering is per calling thread; across threads it is the order the loop saw them.

### D7. The four smaller groups

`files` (an opaque `File`, `send_file` as `send` of a range), `loans` (a lent buffer, `send_loan` that takes ownership on `Sent`), `parts` (`send2` generalised) and `addresses` (`local_address` and `original_destination`) are specified in the same terms as the first four and implemented after them. `files` and `loans` are the two that add a new handle type; both are fixed-size and stale-checked the way `Link` is.

### D8. Open questions the first tasks settle

1. **What the partner of a failed relayed link carries.** Candidates: `PeerReset` for a reset and `Error` for any other failure; `Local` for the loop's own limit. tcprouter closes both with the reason of the failing side. A spike on the epoll loop and a reading of tcprouter's `RT-20` rows decides, and the spec is amended before the checks are written.
2. **Compile-time detection of a group.** A library that wants relay when present and a plain `Data` and `send` path when not needs to ask whether a loop has `relay`. A spike with a generic function over two overloads (one needing `relay`) shows whether Goose resolves by the operations a type has. If not, the answer is a documented pattern (one library, two build variants chosen by the application) and not a contract feature.
3. **Held bytes and the bound.** `peek` holds at most the loop's per-link bound (the size of one pool buffer on the epoll loop); a hello over the bound ends in the library's hands. tcprouter's hello can be 16 KiB, so the bound of the epoll loop must be at least that for peek. A spike measures the memory of waiting links (tcprouter's idle-link number is the reference).
4. **Whether `Input` should carry the bytes.** A view in the event would save a call, but a held view that outlives the handler is what `peek` exists to avoid. The design keeps the event small.

### D9. The audit comes before the port

tcprouter's `design/05-requirements.md` has a row for each behaviour. Before a port is called complete, each row is placed in one of: carried by the core, carried by a group of this change, carried by tcprouter's own code on top, or not carried (a proposal for a group or an amendment to one here). The result is a table kept with the change (`audit.md`), reviewed by the owner. A row that no operation can carry is a finding about this change, not a feature to drop.

### D10. Implementation order and where

1. In the in-memory loop, in the order relay, peek, revoke, wake, then parts, addresses, loans, files: spec scenario, suite check that fails, the loop's code, the fault for the check. The suite and the table of checks grow with it.
2. In `goose-io-epoll-ext` in the same order for the first four, then the rest. The pump of `forward.goose` becomes the implementation of `relay`; the hello peek of tcprouter's `conn.goose` becomes `peek`; its `_tag_allows` clock read becomes `write_deadline`; `messages.goose`' pipes become `wake`.
3. The gates of the epoll loop (`bench/`) run with every group present and unused, to show that the groups cost nothing on the plain path, and the relay gate of `bench/gate_forward.sh` runs against a forwarder written on `relay` and tcprouter's `forward_server`.
4. The io_uring mapping document gains a row for each group and what it would use; it is not built here.

## Risks / Trade-offs

- **The contract grows by eight groups** → each is optional, has its own suite, and the first four have a user. The last four are cheap to define and cheap to leave unimplemented; they are in this change so the contract's list of groups is complete when the audit runs, not because a library needs them today.
- **`relay` forbids a loop from splicing in some situations** (a spliced link cannot deliver `Data`) → that is the group's definition: a relayed link delivers none. A library that must see the bytes does not relay.
- **A group's rules and another's interact** (`write_deadline` on a relayed link, `peek` then `relay`, `wait_input` on a paused link) → each combination is stated in the spec or D3 and D4, and checked by a test that supplies both groups, outside any group's entry point.
- **Adding variants to `Event` breaks exhaustive matches** → the same break `PassEnd` caused and the example libraries already have catch-all arms; recorded as a compile-time-only breaking change.
- **An io_uring loop may be unable to meet a rule** (recalling bytes in flight) → the spec binds only what a loop can promise and says where the limit is; a loop records what it tried (the rule the contract already has for a requirement a backend cannot meet).
- **Speculative groups** (files, loans, addresses, parts) → implemented last and only after the first four pass; if a user for one does not appear, the group stays specified and unimplemented.

## Migration Plan

- Work on a branch of goose-io after `epoll-event-loop` is accepted; nothing is pushed or tagged without the owner's approval. The groups are additive; reverting is a revert of the merge.
- The contract version goes to 0.3 (a minor increase while the major is zero).
- tcprouter's port starts only after the audit table exists.

## Open Questions

- D8 items 1 to 4 are settled by the first tasks (spikes), and the spec is amended where they change it.
- Whether `goose-io-epoll-ext` stays one source with every group or splits into one source for each loop variant. Settled when the first four pass.
