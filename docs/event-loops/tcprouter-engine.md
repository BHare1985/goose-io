# Mapping: tcprouter's engine

Candidate event loop: the epoll engine of tcprouter (`~/dev/cnamecloud/tcprouter`), read at commit `05995d1`
(`handler.goose`, `engine.goose`, `conn.goose`, `address.goose`, `src/c_sys.c`). Nothing was built or run: a row is
**checked** when the code named in it was read and does what the row says, and **unverified** when it was not, or
when the code was read and the row records what is missing. The contract is `docs/contract.md`.

tcprouter's handler API is the shape the contract was taken from (design D1), so most rows are present already. What is
new is `listen`, `listener_port`, `stop_listening`, `peer_address`, `send2`, `tick_by` and the `Link` and `Listener` types;
what differs in behaviour is listed under *Adapter work*.

**Applied.** The rows below are done in [`examples/loops/epoll/`](../../examples/loops/epoll/) at commit `2db84df`, which passes the core and each group of
the suite except unix (not supplied), in fifty repetitions, and the system-call, throughput and memory gates against tcprouter `e021769`
(`bench/BASELINE.md`, `bench/results/`). The loop was derived directly from tcprouter's generic layer rather than imported and adapted in steps;
`close` ends the link at once and keeps the socket as an orphan until the peer ends (see *Closing*, and the design of the change); a Tick comes at least every 90 ms.

## Unverified rows, and the rows that need an adapter that changes behaviour

1. The slot of a link is freed (and its generation bumped) when its `Closed` is queued, before the event is delivered, so
   `peer_address` inside the handler of a `Closed` answers empty and a link made in that handler can take the slot. The
   contract keeps the handle valid, and the slot unreused, until the handlers of its `Closed` have returned (settled below).
2. `Writable` is delivered below a fixed low-water mark, not once the largest refused send would fit.
3. `close` ends with a plain `close(2)`, which can reset a connection that has unread input (see *Closing*).
4. `listener_port`, `peer_address`, `stop_listening`, runtime `listen`: no such call exists; plain system calls
   are to be added to `src/c_sys.c`.
5. `Opened` carries a listener index and a tag, and `Data` neither; the contract's events carry the link, and `Opened` the `Listener` handle that accepted it.

### Does a `Closed` queued inside `dial` find its link?

Yes, with one change. Nothing is attached to a link in the contract, so there is no value to read at delivery: a library
keeps the link `dial` returned and finds its state when the `Closed` carries that link. The one thing to fix is the one in
item 1: in `conn.goose`, `_close_connection` queues the `Closed` and sets `s.live = false` and bumps `s.gen` in the same call,
so for a dial that failed inside `dial` the slot is dead, and could be reused, before the `Closed` is delivered. Adapter work:
do not free the slot of a link, a failed dial included, until its `Closed` has been delivered and its handlers have returned
(mark it dead for sends and `close`, live for `peer_address`).

## Operations and events

### Core

Every event loop supplies these.

| Contract item | tcprouter | Status | Adapter work |
|---|---|---|---|
| `listen` | Listeners are fixed at start: `Config.listeners`, one `_listen_fds[li]` each, accepted in `_accept_ready_connections` (`conn.goose`). No call opens one later. | checked: `conn.goose`, `handler.goose` (no such public function) | Add `listen(address)`: create, bind and listen with a new `c_listen` call, add the fd to epoll, return a `Listener` that is an index into a never-reused table (u32). A bind failure maps to `AddressInUse` by errno. Port 0 must be accepted; `_parse_address` rejects a zero port, so listen needs its own check. **Done**, commit `2db84df`. |
| `listener_port` | None. `src/c_sys.c` has no `getsockname`. | checked: absent | Add `c_local_port(fd)`. **Done**, commit `2db84df`. |
| `dial` | `dial` returns a `Conn` at once; connect failure is one `Closed` and no `Opened` (`handler.goose`, RT-14c in `_close_connection`). `_parse_address` accepts numeric `ip:port` and `[ip6]:port` and refuses host names (`address.goose`). | checked: `handler.goose` `dial`, `address.goose` `_parse_address` | Map the failure to a kind (see *Connect failures*). A zone identifier: unverified whether `_parse_ipv6` rejects `%`; add a test. **Done**, commit `2db84df`. |
| `send` | `send` returns `bool`, decides before copying, queue of 4 pool buffers (`handler.goose` `send`). | checked | Map `false` to `SendStatus`: `Closed` for a stale or closing link, `NotOpen` for a dialling one (`_user_slot` sees it, `_handler_slot` does not), `TooLarge` when `new_buffers > 4` (no `Writable` is promised, RT-19b), `Full` otherwise. **Done**, commit `2db84df`. |
| `max_send` | `buffer_size * 4` (64 KB at the default, comment in `send`). | checked: comment, `send_room` | Refuse a configuration where it is below 4096. **Done**, commit `2db84df`. |
| `pause_reading` | `pause_reading`: `paused` and `_update_epoll_interest` (`handler.goose`). Bytes stay in the kernel. | checked | None. **Done**, commit `2db84df`. |
| `close` | `close`: cancels a dial; otherwise `_begin_close`, which closes once the queue is empty (`_flush_output`). | checked | See *Closing*: the final `c_close` can reset a link with unread input. **Done**, commit `2db84df`. |
| `now_ms` | `w._now_ms`, set each pass from `c_boottime_ms()`, monotonic. Private. | checked | Export an accessor. **Done**, commit `2db84df`. |
| `tick_by` | None. The loop sleeps at most 100 ms, or until `_dial_due` (`_wait_limit`, `_note_dial_due`). | checked | Generalise `_dial_due` to a `_wake_at` that keeps the earliest request; the first `Tick` at or after it clears it. **Done**, commit `2db84df`. |
| `serve` | `serve<F>(w)`, one worker, one thread, the block called with `(w, event)` (`engine.goose`). | checked: signature | The adapter's loop type is the worker; its block receives contract events. **Done**, commit `2db84df`. |
| `stop` | `drain`, a message posted to the worker: listeners closed, links end by themselves or at the deadline, reason `Drained` (`handler.goose` comment on `draining`). | checked: comment | `stop(grace)` called from the handler sets draining directly on the worker's own thread; `Drained` becomes `Shutdown`. Of several calls the earliest deadline stands: unverified. **Done**, commit `2db84df`. |
| `draining` | `draining(w)` (`handler.goose`). | checked | None. **Done**, commit `2db84df`. |
| `Opened` | `Opened { conn, tag, listener: u16, sni }` (`engine.goose`). | checked | Drop the tag; `listener` is an index: return the matching `Listener` handle for an accepted link and none for a dialled one. **Done**, commit `2db84df`. |
| `Data` | One read into a pool buffer; one pending `Data` per connection, the buffer returned after the block (`_read_for_handler`, `_data_delivered`). The event carries the link. | checked | Maximum bytes per event is `buffer_size`. **Done**, commit `2db84df`. |
| `Writable` | `want_writable`; delivered when the queue holds less than one buffer (`_flush_output`: `_output_bytes() < buffer_size`). It does not remember the size that was refused. | checked | Remember the largest refused size and deliver `Writable` only when `send_room` is at least that (*Writable follows Full once*). A refusal resolved by the connection closing is already covered by `Closed`. **Done**, commit `2db84df`. |
| `Closed` | Exactly once, always last (`engine.goose` `Event` comment). Reasons differ: `ByHandler` is `Local`, `Drained` is `Shutdown`, `PeerClosed`, `PeerReset`, `IdleTimeout`, `HalfCloseTimeout`, `Error` as named, `ConnectFailed` needs a kind; `Fenced`, `InspectTimeout`, `InvalidHello` have no portable name. | checked | Translate; the three extras are `LoopSpecific { code }`. **Done**, commit `2db84df`. |
| `Tick` | At least every 100 ms (`engine.goose` `Event` comment; the 100 ms wait in `_wait_limit`). | checked | None. **Done**, commit `2db84df`. |

### Half-close

Only a loop that supplies the half-close group needs these.

| Contract item | tcprouter | Status | Adapter work |
|---|---|---|---|
| `set_keep_open_on_eof` | `set_keep_open_on_eof`. Off by default: the peer's end of stream closes the link after the queue is flushed (`PeerClosed`). On: `PeerEof` once, link stays open (`_read_for_handler`). | checked | None. A half-close timeout (`HalfCloseTimeout`) is the event loop's own limit, which the contract allows. **Done**, commit `2db84df`. |
| `shutdown_write` | `shutdown_write`: `shut_wr_pending`, then `c_shutdown_wr` once the queue is out; closes with `PeerClosed` when the peer has finished too (`_flush_output`). | checked | None. **Done**, commit `2db84df`. |
| `PeerEof` | Delivered once, only with keep-open (`_read_for_handler`). | checked | None. **Done**, commit `2db84df`. |

### Sizing

Only a loop that supplies the sizing group needs these.

| Contract item | tcprouter | Status | Adapter work |
|---|---|---|---|
| `send_room` | `send_room` (`handler.goose`): free room of the queue, 0 for a stale, closing or write-shut link and before `Opened` (a dialling slot is not a handler slot). | checked | None. **Done**, commit `2db84df`. |
| `send2` | None. | checked: absent | The size test of `send` with the sum of both lengths, then two appends; the decision is made before either is copied. **Done**, commit `2db84df`. |

### Abort

Only a loop that supplies the abort group needs this.

| Contract item | tcprouter | Status | Adapter work |
|---|---|---|---|
| `reset` | `reset`: `c_reset` (`SO_LINGER` 1, 0) then `_close_connection` (`src/c_sys.c`, `handler.goose`). | checked | None. **Done**, commit `2db84df`. |

### Inspection

Only a loop that supplies the inspection group needs these.

| Contract item | tcprouter | Status | Adapter work |
|---|---|---|---|
| `peer_address` | None. No `getpeername` in `src/c_sys.c`. | checked: absent | Add `c_peer_address(fd)` and the formatting rule of the contract (lower case, longest zero run as `::`). **Done**, commit `2db84df`. |
| `stop_listening` | Listeners are closed only by drain (`draining` doc, `handler.goose`). | checked: absent | Close one listener's fd and remove it from epoll; links accepted from it stay. **Done**, commit `2db84df`. |

### Batching

Only a loop that supplies the batching group needs this.

| Contract item | tcprouter | Status | Adapter work |
|---|---|---|---|
| `PassEnd` | `want_pass_end(w, on)` opts in; one per pass that delivered handler events; none for Tick-only or idle passes; sends during it cause no second one (`handler.goose` `_finish_pass`). | checked | The contract has no switch: call `want_pass_end(true)` always. **Done**, commit `2db84df`. |


## What a loop with only the core costs

An event loop on this substrate that supplies only the core does the adapter work of the core rows above, listed here, and none of the work of the groups: no `shutdown_write` or `PeerEof` (so a library that must answer after the peer finishes sending cannot run on it), no `send_room` or `send2`, no `reset`, no `peer_address` or `stop_listening`, and no `PassEnd`. Each group is a separate, later addition.

- `listen`: Add `listen(address)`: create, bind and listen with a new `c_listen` call, add the fd to epoll, return a `Listener` that is an index into a never-reused table (u32). A bind failure maps to `AddressInUse` by errno. Port 0 must be accepted; `_parse_address` rejects a zero port, so listen needs its own check.
- `listener_port`: Add `c_local_port(fd)`.
- `dial`: Map the failure to a kind (see *Connect failures*). A zone identifier: unverified whether `_parse_ipv6` rejects `%`; add a test.
- `send`: Map `false` to `SendStatus`: `Closed` for a stale or closing link, `NotOpen` for a dialling one (`_user_slot` sees it, `_handler_slot` does not), `TooLarge` when `new_buffers > 4` (no `Writable` is promised, RT-19b), `Full` otherwise.
- `max_send`: Refuse a configuration where it is below 4096.
- `close`: See *Closing*: the final `c_close` can reset a link with unread input.
- `now_ms`: Export an accessor.
- `tick_by`: Generalise `_dial_due` to a `_wake_at` that keeps the earliest request; the first `Tick` at or after it clears it.
- `serve`: The adapter's loop type is the worker; its block receives contract events.
- `stop`: `stop(grace)` called from the handler sets draining directly on the worker's own thread; `Drained` becomes `Shutdown`. Of several calls the earliest deadline stands: unverified.
- `Opened`: Drop the tag; `listener` is an index: return the matching `Listener` handle for an accepted link and none for a dialled one.
- `Data`: Maximum bytes per event is `buffer_size`.
- `Writable`: Remember the largest refused size and deliver `Writable` only when `send_room` is at least that (*Writable follows Full once*). A refusal resolved by the connection closing is already covered by `Closed`.
- `Closed`: Translate; the three extras are `LoopSpecific { code }`.
- Slots: the engine keeps its connections in a slot table with a generation; give a new link a freed slot before extending the table (a free list; unverified whether `conn.goose` already takes the first free slot), and free a slot only after the `Closed` handlers return (*Slot numbers are dense*), which is also the fix for the slot that is freed before its `Closed` is delivered.
- The peer's end of stream: the core still closes the link with `PeerClosed` once what was accepted is out, which is the default of the `set_keep_open_on_eof` row, without the switch to turn it off.

## Closing

`close` queues nothing new: `_begin_close` sets `closing` and `_flush_output` closes the connection when the output
queue is empty, with `_close_connection`, which ends in `c_close(fd)`. `close(2)` on a socket that still has unread
input sends a reset on Linux, and the peer can lose bytes it was sent (*Close does not lose accepted bytes*). The
engine does not read after `close`: an input arriving from the peer between the last `Data` and the close is unread.
Adapter work: after the queue is empty call `shutdown(WR)`, keep the link in a closing state in which it reads and
discards input, and close the descriptor when the peer's end of stream arrives or after a limit (reuse
`Limits.half_close_timeout_ms`), so a peer that never reads cannot hold the link for ever. The `Closed` event is
delivered then, with reason `Local`, which the contract allows to come after the pass that called `close`; `stop`
counts such a link as present. A peer that never reads: the same limit ends it, still with `Local`.

## Connect failures

`conn.goose` `_dial_finished` reads the result with `c_connect_result` (`SO_ERROR`) and then discards it: every failure is
`ConnectFailed`. The adapter must keep the error number and the timer:

| Cause | Kind |
|---|---|
| address text is not numeric (`_parse_address` false) | `BadAddress` (exact) |
| `connect_ms` passed (`_expire_dials`) | `TimedOut` (exact) |
| `max_conns_per_worker` exceeded in `dial` | `NoResources` (exact) |
| `ECONNREFUSED` | `Refused` |
| `ENETUNREACH`, `EHOSTUNREACH` | `Unreachable` |
| `EACCES`, `EPERM` | `Denied` |
| `EMFILE`, `ENFILE`, `ENOBUFS`, `ENOMEM`, `EADDRNOTAVAIL` | `NoResources` |
| anything else, including `ETIMEDOUT` from the kernel's own connect timer | `Other` (a kernel `ETIMEDOUT` after `connect_ms` was not reached is `Other`, not `TimedOut`) |

## Known gaps

None: every row has a workable mapping. The three rows that change behaviour (the slot freed before its `Closed`,
the `Writable` size, the close that can reset) are fixes inside the engine, not changes to the contract.
