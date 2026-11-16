# Mapping: tcprouter's engine

Candidate provider: the epoll engine of tcprouter (`~/dev/cnamecloud/tcprouter`), read at commit `05995d1`
(`handler.goose`, `engine.goose`, `conn.goose`, `address.goose`, `src/c_sys.c`). Nothing was built or run: a row is
**checked** when the code named in it was read and does what the row says, and **unverified** when it was not, or
when the code was read and the row records what is missing. The contract is `docs/contract.md`.

tcprouter's handler API is the shape the contract was taken from (design D1), so most rows are present already. What is
new is `listen`, `listener_port`, `stop_listening`, `peer_address`, `send2`, `tick_by` and the `Link` and `Listener` types;
what differs in behaviour is listed under *Adapter work*.

## Unverified rows, and the rows that need an adapter that changes behaviour

1. `Closed` after a dial that fails inside `dial` carries user value 0, not the value set after `dial` returned
   (settled below; needs a change), and `user` called inside the handler of any `Closed` returns 0, because the slot is
   freed before the event is delivered.
2. `Writable` is delivered below a fixed low-water mark, not once the largest refused send would fit.
3. `close` ends with a plain `close(2)`, which can reset a connection that has unread input (see *Closing*).
4. `listener_port`, `peer_address`, `stop_listening`, runtime `listen`: no such call exists; plain system calls
   are to be added to `src/c_sys.c`.
5. `Opened` and `Data` do not carry the fields the contract's events carry (`user` on `Opened`, `tag` on `Data`).

### Does a `Closed` queued inside `dial` report a user value set afterwards?

No. Read in `conn.goose`, `_close_connection`: it queues the `Closed` (`_queue_closed`, which copies `s.user` into
the pending record at that moment) and then sets `s.live = false` and bumps `s.gen`, in the same call. In
`handler.goose`, `_deliver_events` re-reads the user value at delivery only `if s.live && s.gen == r.gen`; for a
dial that failed inside `dial` the slot is dead by then, so the value copied at queue time, 0, is what the event
carries. The contract requires the value set after `dial` returns (*The user value survives an immediate dial
failure*). Adapter work: do not free the slot of a dial that failed inside `dial` until its `Closed` has been
delivered (mark it dead for sends and `close`, live for `set_user` and `user`; `_user_slot` already admits a dialling
slot), or keep the failure in a small side table keyed by slot and generation that `set_user` can write to.

## Operations and events

| Contract item | tcprouter | Status | Adapter work |
|---|---|---|---|
| `listen` | Listeners are fixed at start: `Config.listeners`, one `_listen_fds[li]` each, accepted in `_accept_ready_connections` (`conn.goose`). No call opens one later. | checked: `conn.goose`, `handler.goose` (no such public function) | Add `listen(address, tag)`: create, bind and listen with a new `c_listen` call, add the fd to epoll, return a `Listener` that is an index into a never-reused table (u32). A bind failure maps to `AddressInUse` by errno. Port 0 must be accepted; `_parse_address` rejects a zero port, so listen needs its own check. |
| `listener_port` | None. `src/c_sys.c` has no `getsockname`. | checked: absent | Add `c_local_port(fd)`. |
| `stop_listening` | Listeners are closed only by drain (`draining` doc, `handler.goose`). | checked: absent | Close one listener's fd and remove it from epoll; links accepted from it stay. |
| `dial` | `dial` returns a `Conn` at once; connect failure is one `Closed` and no `Opened` (`handler.goose`, RT-14c in `_close_connection`). `_parse_address` accepts numeric `ip:port` and `[ip6]:port` and refuses host names (`address.goose`). | checked: `handler.goose` `dial`, `address.goose` `_parse_address` | Map the failure to a kind (see *Connect failures*). A zone identifier: unverified whether `_parse_ipv6` rejects `%`; add a test. |
| `peer_address` | None. No `getpeername` in `src/c_sys.c`. | checked: absent | Add `c_peer_address(fd)` and the formatting rule of the contract (lower case, longest zero run as `::`). |
| `send` | `send` returns `bool`, decides before copying, queue of 4 pool buffers (`handler.goose` `send`). | checked | Map `false` to `SendStatus`: `Closed` for a stale or closing link, `NotOpen` for a dialling one (`_user_slot` sees it, `_handler_slot` does not), `TooLarge` when `new_buffers > 4` (no `Writable` is promised, RT-19b), `Full` otherwise. |
| `send2` | None. | checked: absent | The size test of `send` with the sum of both lengths, then two appends; the decision is made before either is copied. |
| `send_room` | `send_room` (`handler.goose`): free room of the queue, 0 for a stale, closing or write-shut link and before `Opened` (a dialling slot is not a handler slot). | checked | None. |
| `max_send` | `buffer_size * 4` (64 KB at the default, comment in `send`). | checked: comment, `send_room` | Refuse a configuration where it is below 4096. |
| `pause_reading` | `pause_reading`: `paused` and `_update_epoll_interest` (`handler.goose`). Bytes stay in the kernel. | checked | None. |
| `set_keep_open_on_eof` | `set_keep_open_on_eof`. Off by default: the peer's end of stream closes the link after the queue is flushed (`PeerClosed`). On: `PeerEof` once, link stays open (`_read_for_handler`). | checked | None. A half-close timeout (`HalfCloseTimeout`) is the provider's own limit, which the contract allows. |
| `shutdown_write` | `shutdown_write`: `shut_wr_pending`, then `c_shutdown_wr` once the queue is out; closes with `PeerClosed` when the peer has finished too (`_flush_output`). | checked | None. |
| `close` | `close`: cancels a dial; otherwise `_begin_close`, which closes once the queue is empty (`_flush_output`). | checked | See *Closing*: the final `c_close` can reset a link with unread input. |
| `reset` | `reset`: `c_reset` (`SO_LINGER` 1, 0) then `_close_connection` (`src/c_sys.c`, `handler.goose`). | checked | None. |
| `set_user` | `set_user`; works on a dialling `Conn` (`_user_slot`). | checked | None. |
| `user` | `user`; 0 for a stale handle (`handler.goose`). `_user_slot` needs `s.live`, and `_close_connection` clears it before the `Closed` is delivered, so `user(c)` called inside the handler of `Closed` returns 0 (the event itself carries the value read at delivery or queue time). | checked: `handler.goose` `_user_slot`, `conn.goose` `_close_connection` | The contract keeps the handle valid, `user` and `peer_address` included, until the handler of `Closed` returns (*The handle is still valid while Closed is handled*). Keep the slot (and its generation) until the handler has returned; the same change serves the dial failure above. |
| `now_ms` | `w._now_ms`, set each pass from `c_boottime_ms()`, monotonic. Private. | checked | Export an accessor. |
| `tick_by` | None. The loop sleeps at most 100 ms, or until `_dial_due` (`_wait_limit`, `_note_dial_due`). | checked | Generalise `_dial_due` to a `_wake_at` that keeps the earliest request; the first `Tick` at or after it clears it. |
| `serve` | `serve<F>(w)`, one worker, one thread, the block called with `(w, event)` (`engine.goose`). | checked: signature | The adapter's loop type is the worker; its block receives contract events. |
| `stop` | `drain`, a message posted to the worker: listeners closed, links end by themselves or at the deadline, reason `Drained` (`handler.goose` comment on `draining`). | checked: comment | `stop(grace)` called from the handler sets draining directly on the worker's own thread; `Drained` becomes `Shutdown`. Of several calls the earliest deadline stands: unverified. |
| `draining` | `draining(w)` (`handler.goose`). | checked | None. |
| `Opened` | `Opened { conn, tag, listener: u16, sni }` (`engine.goose`). | checked | Add `user: 0`; `listener` is an index: return the matching `Listener` handle. The tag is the one of the route that chose `Handle(tag)`; configure it as the listener's tag. |
| `Data` | One read into a pool buffer; one pending `Data` per connection, the buffer returned after the block (`_read_for_handler`, `_data_delivered`). The event has no tag. | checked | Add `tag`. Maximum bytes per event is `buffer_size`. |
| `Writable` | `want_writable`; delivered when the queue holds less than one buffer (`_flush_output`: `_output_bytes() < buffer_size`). It does not remember the size that was refused. | checked | Remember the largest refused size and deliver `Writable` only when `send_room` is at least that (*Writable follows Full once*). A refusal resolved by the connection closing is already covered by `Closed`. |
| `PeerEof` | Delivered once, only with keep-open (`_read_for_handler`). | checked | None. |
| `Closed` | Exactly once, always last (`engine.goose` `Event` comment). Reasons differ: `ByHandler` is `Local`, `Drained` is `Shutdown`, `PeerClosed`, `PeerReset`, `IdleTimeout`, `HalfCloseTimeout`, `Error` as named, `ConnectFailed` needs a kind; `Fenced`, `InspectTimeout`, `InvalidHello` have no portable name. | checked | Translate; the three extras are `Provider { code }`. |
| `Tick` | At least every 100 ms (`engine.goose` `Event` comment; the 100 ms wait in `_wait_limit`). | checked | None. |
| `PassEnd` | `want_pass_end(w, on)` opts in; one per pass that delivered handler events; none for Tick-only or idle passes; sends during it cause no second one (`handler.goose` `_finish_pass`). | checked | The contract has no switch: call `want_pass_end(true)` always. |

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

None: every row has a workable mapping. The three rows that change behaviour (user value after an immediate
failure, the `Writable` size, the close that can reset) are fixes inside the engine, not changes to the contract.
