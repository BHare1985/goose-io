# Mapping: io_uring

Candidate event loop: an io_uring engine, from c_proxy's (`~/dev/cnamecloud/c_proxy`, commit `7f6fc2c`, file `proxy.c`).
c_proxy is a forwarding proxy, not a handler API: it uses io_uring to copy between two descriptors. So the rows say
which io_uring operations c_proxy already uses for each contract item, and mark as **unverified** the ones it does
not use. A row is **checked** when the code named was read and does what the row says, **unverified** otherwise.
Nothing was built or run. The kernel interface was not read; the opcode and flag names are those `proxy.c` uses.

## Unverified rows, and the rows that need an adapter that changes behaviour

Unverified (c_proxy does not use the operation, or it was not read):

- `listener_port`, `peer_address`, `stop_listening` (runtime), `reset`, `max_send`,
  `send_room`, `send2`: not used by c_proxy; plain system calls and adapter state.
- `Closed` reasons other than the ones the engine sees on a completion (`res` of the operation).
- `tick_by` and `Tick` beyond a periodic timeout (the engine has one sweep timeout, `io_uring_prep_timeout`).
- `PassEnd` (no batching hook is used; see the row).

Changing behaviour (checked):

1. `IORING_OP_SHUTDOWN` is avoided on purpose: `proxy.c` calls `shutdown(2)` directly because the opcode "is always
   punted to io-wq (slow, and unordered with respect to a later close)". `shutdown_write` is a system call.
2. Receive uses a provided-buffer ring (`IOSQE_BUFFER_SELECT`, `IORING_CQE_F_BUFFER`): the kernel picks the buffer,
   and the buffer belongs to the adapter until it is put back. That is what lends `Data` without a copy, and it also
   means a pending `Data` holds one of a fixed set of buffers.
3. A failed connect is one completion with a negative `res` (the errno): the kind comes from it directly, and the
   timeout is a linked timeout (`IOSQE_IO_LINK` and `io_uring_prep_link_timeout`).

## Operations and events

### Core

Every event loop supplies these.

| Contract item | io_uring (c_proxy) | Status | Adapter work |
|---|---|---|---|
| `listen` | `socket`, `bind`, `listen` by system call at start; accept by `io_uring_prep_multishot_accept` (`proxy.c`) | checked: accept | A runtime listener: the same calls, then the multishot accept. `bind` failure by errno gives `AddressInUse`. |
| `listener_port` | `getsockname` | unverified | Plain call after binding port 0. |
| `dial` | `io_uring_prep_socket`, `IORING_OP_CONNECT` via `io_uring_prep_connect` with a linked timeout (`submit_connect`); `TCP_NODELAY` by a ring socket command (`SOCKET_URING_OP_SETSOCKOPT`) | checked | The connect result is the completion's `res`. The link slot is allocated at `dial` and its generation bumped on reuse (`conn_alloc`, `& 0xffffff`). |
| `send` | `io_uring_prep_send(sqe, fd, buf, len, MSG_NOSIGNAL \| MSG_DONTWAIT)` from a buffer the engine holds (`copy_send`) | checked | A per-link bounded output queue in adapter buffers; `Sent` once copied; `Full` at the bound; one `SEND` in flight per link, the next after its completion. A short send completes with fewer bytes: send the rest. |
| `max_send` | None. | n/a | A configuration value of at least 4096. |
| `pause_reading` | Do not re-arm the receive: a receive in flight completes once, and the engine re-submits (`copy_recv`) only when it wants more | checked | Do not call `copy_recv`-style submission while paused; a receive already in flight delivers one `Data` (the contract allows one already received). |
| `close` | `io_uring_prep_close` batched, no completion on success (`fd_close`); `close(2)` direct on the epoll path | checked | See *Closing*. |
| `now_ms` | A clock read when the loop wakes (`w->now`) | checked | `CLOCK_MONOTONIC`. |
| `tick_by` | `io_uring_prep_timeout` (the engine's sweep timer, `proxy.c`) | checked: one periodic timeout | One timeout request: the regular 100 ms `Tick`, replaced by an earlier one when `tick_by` asks (`IORING_TIMEOUT_UPDATE` or cancel and resubmit; unverified). |
| `serve` | `io_uring_submit_and_wait` / `io_uring_submit_and_wait_timeout` then a pass over the completions (`proxy.c`) | checked | One loop = one ring on one thread (`IORING_SETUP_SINGLE_ISSUER \| DEFER_TASKRUN`); the pass delivers events through the contract's queue. |
| `stop` | None; the process drains by closing listeners | unverified | `stop(grace)`: cancel the accepts, close each link at the deadline with `Shutdown`. |
| `draining` | None. | n/a | A flag. |
| `Opened` | The accept completion (multishot, `IORING_CQE_F_MORE`) or the connect completion | checked | Queue `Opened`. |
| `Data` | A receive completion with `IORING_CQE_F_BUFFER`; the buffer id is `flags >> IORING_CQE_BUFFER_SHIFT` (`on_recv`) | checked | Lend the buffer; return it to the ring (`buf_put`) after the handler returns. One `Data` pending per link: re-arm the receive only then. When the buffer ring is empty the receive completes with `-ENOBUFS` (`on_recv`): park the link until a buffer comes back, as c_proxy does (`wq_push`). |
| `Writable` | The send completion | checked | Queue `Writable` when room for the largest refused send has opened. |
| `Closed` | The connection ends when its in-flight operations are all complete (`c->inflight` reaches 0) and the slot is released | checked: `inflight` counter | Queue the `Closed` then; reason from the adapter's state or the completion's `-errno` (`-ECONNRESET` is `PeerReset`). |
| `Tick` | The timeout completion | checked | The first event of a pass. |

### Half-close

Only a loop that supplies the half-close group needs these.

| Contract item | io_uring (c_proxy) | Status | Adapter work |
|---|---|---|---|
| `set_keep_open_on_eof` | A receive completing with `res == 0` is the peer's end of stream (`on_recv` handling; `dir_finish`) | checked: the `res == 0` path ends the direction | Keep the flag; off: flush and close as `close` does; on: queue `PeerEof` and do not re-arm the receive. |
| `shutdown_write` | `shutdown(fd, SHUT_WR)` by system call (`dir_finish`), never the ring opcode | checked: comment in `conn_kill` | Call it once the output queue is empty. When the peer has also ended, close with `PeerClosed`. |
| `PeerEof` | A receive completing with `res == 0` | checked | Only with keep-open. |

### Sizing

Only a loop that supplies the sizing group needs these.

| Contract item | io_uring (c_proxy) | Status | Adapter work |
|---|---|---|---|
| `send_room` | None. | n/a | The queue's free room, capped at `max_send`. |
| `send2` | `IORING_OP_SENDMSG` with two `iovec`, or two copies into one entry | unverified | Whole-or-nothing decision on the sum, then one entry. |

### Abort

Only a loop that supplies the abort group needs this.

| Contract item | io_uring (c_proxy) | Status | Adapter work |
|---|---|---|---|
| `reset` | None used. | unverified | `setsockopt(SO_LINGER, 1, 0)` (or the ring socket command) then close. |

### Inspection

Only a loop that supplies the inspection group needs these.

| Contract item | io_uring (c_proxy) | Status | Adapter work |
|---|---|---|---|
| `peer_address` | `getpeername` | unverified | Plain call; the accept completion can also carry the address if requested. |
| `stop_listening` | `io_uring_prep_cancel64` of the accept (`proxy.c`) then `close` | checked: cancel, `fd_close` | Links accepted stay. |

### Batching

Only a loop that supplies the batching group needs this.

| Contract item | io_uring (c_proxy) | Status | Adapter work |
|---|---|---|---|
| `PassEnd` | The end of a batch of completions (`io_uring_submit_and_wait_timeout` with a batch count, `cfg.batch_n`) | checked: batch wait | One per pass that delivered a link event. |


## What a loop with only the core costs

An event loop on this substrate that supplies only the core does the adapter work of the core rows above, listed here, and none of the work of the groups: no `shutdown_write` or `PeerEof` (so a library that must answer after the peer finishes sending cannot run on it), no `send_room` or `send2`, no `reset`, no `peer_address` or `stop_listening`, and no `PassEnd`. Each group is a separate, later addition.

- `listen`: A runtime listener: the same calls, then the multishot accept. `bind` failure by errno gives `AddressInUse`.
- `listener_port`: Plain call after binding port 0.
- `dial`: The connect result is the completion's `res`. The link slot is allocated at `dial` and its generation bumped on reuse (`conn_alloc`, `& 0xffffff`).
- `send`: A per-link bounded output queue in adapter buffers; `Sent` once copied; `Full` at the bound; one `SEND` in flight per link, the next after its completion. A short send completes with fewer bytes: send the rest.
- `max_send`: A configuration value of at least 4096.
- `pause_reading`: Do not call `copy_recv`-style submission while paused; a receive already in flight delivers one `Data` (the contract allows one already received).
- `close`: See *Closing*.
- `now_ms`: `CLOCK_MONOTONIC`.
- `tick_by`: One timeout request: the regular 100 ms `Tick`, replaced by an earlier one when `tick_by` asks (`IORING_TIMEOUT_UPDATE` or cancel and resubmit; unverified).
- `serve`: One loop = one ring on one thread (`IORING_SETUP_SINGLE_ISSUER \| DEFER_TASKRUN`); the pass delivers events through the contract's queue.
- `stop`: `stop(grace)`: cancel the accepts, close each link at the deadline with `Shutdown`.
- `draining`: A flag.
- `Opened`: Queue `Opened`.
- `Data`: Lend the buffer; return it to the ring (`buf_put`) after the handler returns. One `Data` pending per link: re-arm the receive only then. When the buffer ring is empty the receive completes with `-ENOBUFS` (`on_recv`): park the link until a buffer comes back, as c_proxy does (`wq_push`).
- `Writable`: Queue `Writable` when room for the largest refused send has opened.
- `Closed`: Queue the `Closed` then; reason from the adapter's state or the completion's `-errno` (`-ECONNRESET` is `PeerReset`).
- Slots: a fixed-file table is dense by construction (the slot is the index of the registered file) when a freed index is reused before a new one is taken; keep a free list of indexes and free a slot only after the `Closed` handlers return (*Slot numbers are dense*).
- `Tick`: The first event of a pass.
- The peer's end of stream: the core still closes the link with `PeerClosed` once what was accepted is out, which is the default of the `set_keep_open_on_eof` row, without the switch to turn it off.

## Closing

c_proxy closes by `io_uring_prep_close`, or `close(2)` on the epoll path, after both directions have been read to end
of stream: "have been read to EOF, so close() alone sends the last FIN" (`proxy.c`, comment above the finish of a
direction). That is the safe order: the peer's end of stream has been read, so there is no unread input to reset the
connection. For the contract, `close` is the same sequence as for the other event loops: let the output queue drain,
`shutdown(fd, SHUT_WR)`, keep receiving and discarding until the receive completes with 0 or a limit (a linked
timeout on the receive) passes, then close. A peer that never reads: the limit ends it, `Closed` with `Local`.
`reset` is the socket option and a close.

## Connect failures

A connect completion has a negative `res` of `-errno`; a linked timeout that fires cancels the connect, which then
completes with `-ECANCELED`:

| Cause | Kind |
|---|---|
| address text not numeric (adapter, before the call) | `BadAddress` |
| `-ECANCELED` from the linked timeout | `TimedOut` |
| the adapter's link table full | `NoResources` |
| `-ECONNREFUSED` | `Refused` |
| `-ENETUNREACH`, `-EHOSTUNREACH` | `Unreachable` |
| `-EACCES`, `-EPERM` | `Denied` |
| `-EMFILE`, `-ENFILE`, `-ENOBUFS`, `-ENOMEM` | `NoResources` |
| other | `Other` |

## The keep-open window

The contract fixes `set_keep_open_on_eof` to the time a link is dialling or its `Opened` is being handled (*Keep-open is
configured no later than Opened*). On this substrate a receive of end of stream can complete before the `Opened` event has
been given to the library: hold it until the handler of `Opened` has returned, then act on it with the setting the
library made there (close with `PeerClosed` by default, or deliver `PeerEof` after the `Data` and keep the link open).

## Known gaps

None: every row has a mapping. io_uring is a completion substrate, which is why the contract lends `Data` for one
event and takes sends whole into an adapter buffer (design D2): both are what the ring needs.

| Row | Strategies considered | Result |
|---|---|---|
| `shutdown_write` | (a) `IORING_OP_SHUTDOWN`: punted to io-wq and unordered with a later close (c_proxy's comment). (b) `shutdown(2)` as a system call once the queue is empty: workable. | (b) |
