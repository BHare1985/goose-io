# Mapping: uSockets

Candidate event loop: uSockets upstream (`github.com/uNetworking/uSockets`), pinned at commit
`166a04810c9fa970fc22096a7b35b792378364fb` ("Set last_write_failed when us_socket_write2 writes partially (#265)").
Read from source, not only from `libusockets.h`: `src/socket.c`, `src/loop.c`, `src/context.c`, `src/bsd.c`,
`src/eventing/epoll_kqueue.c` and the header. Nothing was built or run. A row is **checked** when the code named was
read and does what the row says, **unverified** when only a declaration was read or the point was not examined.

## Unverified rows, and the rows that need an adapter that changes behaviour

Unverified (declaration read, behaviour not):

- `listener_port`: `us_socket_local_port` was read as a declaration; that it accepts a listen socket cast to
  `us_socket_t` follows from the layout (`loop.c` uses `&listen_socket->s`) and was not run.
- `now_ms`, `Tick` period, `tick_by`: `us_timer_set` was read as a declaration (`libusockets.h`); the epoll timer in
  `eventing/epoll_kqueue.c` was not read.
- `stop`: `us_loop_run` returns when `num_polls` is zero (`eventing/epoll_kqueue.c`, checked); that closing every
  listener and socket reaches zero in all cases was not examined.

Changing behaviour (all checked in source):

1. Reading cannot be paused by a call: there is none. The lever is `us_poll_change` (see `pause_reading`), and
   a short write undoes it.
2. A close cannot flush and cannot be deferred: `us_socket_close` closes the descriptor and calls `on_close` before it
   returns.
3. The receive buffer is one buffer for the whole loop, reused at once when it was filled (`goto read_more`).
4. A failed connect carries code 0, whatever the reason; closing for an error carries code 0 too.
5. `us_socket_context_connect` and `listen` resolve host names with `getaddrinfo`.

## Operations and events

### Core

Every event loop supplies these.

| Contract item | uSockets | Status | Adapter work |
|---|---|---|---|
| `listen` | `us_socket_context_listen(ssl, ctx, <host-name>, port, options, ext_size)`; `bsd_create_listen_socket` resolves its host-name argument with `getaddrinfo`, binds, listens with backlog 512 (`bsd.c`). Each accepted socket calls `on_open` (`loop.c`, accept branch of `us_internal_dispatch_ready_poll`). | checked | Parse the address text first (numeric only) and hand uSockets the numeric text so nothing is resolved. A bind failure returns NULL with errno possibly clobbered by the `close` that follows it: probe with a throwaway `bind` to the same address to tell `AddressInUse`. |
| `listener_port` | `us_socket_local_port(ssl, s)` | unverified: declaration | Call it on the listen socket (cast). Port 0 binds a system-chosen port. |
| `dial` | `us_socket_context_connect`; `bsd_create_connect_socket` calls `getaddrinfo` then `connect` on a non-blocking descriptor (`bsd.c`); the socket polls writable as a semi-socket (`loop.c`). | checked | Numeric text only. Returns at once; success is `on_open`, failure `on_connect_error` (below). |
| `send` | `us_socket_write(ssl, s, data, length, msg_more)`: writes what the kernel takes, returns the count, and on a short write sets `last_write_failed` and asks for writable (`socket.c`). | checked | Keep a bounded queue in the adapter and write from it: accept the whole send into the queue or refuse; `Full` while the queue is at its bound; `TooLarge` above its largest entry. Never rely on the count. |
| `max_send` | None. | n/a | A configuration value of at least 4096. |
| `pause_reading` | No call upstream. `us_poll_change(p, loop, events)` (declared in `libusockets.h`) with `us_poll_events(p) & ~LIBUS_SOCKET_READABLE` stops the poll for input; `us_poll_events` is read in `eventing/epoll_kqueue.c`. | checked | **Re-apply after every short write**: `us_socket_write` and `us_socket_write2` call `us_poll_change(READABLE|WRITABLE)` on a short write (`socket.c`), which re-enables reading. The `on_writable` path keeps the current `READABLE` bit (`loop.c`), so it does not. Also re-apply when the low-priority queue relinks a socket with `| LIBUS_SOCKET_READABLE` (`loop.c`, only for contexts that use `is_low_prio`; not the plain TCP case). |
| `close` | `us_socket_close(ssl, s, code, reason)`: unlinks, `us_poll_stop`, `bsd_close_socket` (`close(2)`), queues the socket for freeing after the iteration, and **calls `on_close` before returning** (`socket.c`). It does not flush. | checked | Do not call it from `close`. Mark the link closing, flush the queue, `us_socket_shutdown`, keep reading and discarding until the peer's end of stream or a limit, then call `us_socket_close`; queue the `Closed` and deliver it after the handler returns. See *Closing*. |
| `now_ms` | None. | n/a | A monotonic clock read at the top of each iteration (`pre_cb`). |
| `tick_by` | `us_create_timer(loop, fallthrough, ext_size)`, `us_timer_set(timer, cb, ms, repeat_ms)` | unverified: declaration | One adapter timer: the regular 100 ms `Tick`, moved earlier by `tick_by`. `us_socket_timeout` has a granularity of `LIBUS_TIMEOUT_GRANULARITY` (4 s, `libusockets.h`) and is not usable for `connect_ms`. |
| `serve` | `us_loop_run(loop)` blocks in `epoll_wait` with no timeout and runs while `num_polls` is non-zero; it calls `pre_cb` and `post_cb` each iteration (`eventing/epoll_kqueue.c`, `loop.c`). | checked | The unsolved point (see below): how events reach the Goose handler. |
| `stop` | None. The loop returns when no polls remain. | checked: absent | On `stop`: close the listeners, close each link at the grace deadline with `Shutdown`, and stop the timers so `num_polls` reaches zero. `us_loop_run` blocks with no timeout, so the adapter's timer must wake it. |
| `draining` | None. | n/a | A flag. |
| `Opened` | `on_open(s, is_client, ip, ip_length)`: called for a finished connect (`loop.c`: `on_open(s, 1, 0, 0)`) and, through `us_adopt_accepted_socket`, for an accepted socket. | checked for connect; accept: the call was read, `us_adopt_accepted_socket` itself was not | Queue `Opened` with the link; for an accepted socket name the listener handle of the listen socket that accepted it (none for a dial). Nothing else is attached. |
| `Data` | `on_data(s, data, length)` with `data` in the loop's one receive buffer (`LIBUS_RECV_BUFFER_LENGTH` 512 KB). When a read fills the buffer the loop reads again at once (`goto read_more`, `loop.c`), overwriting it. | checked | Copy the bytes into the adapter's own buffer inside `on_data`, or call Goose synchronously there. A deferred, lent slice is not possible: it would be overwritten before the handler runs. At most one `Data` pending per link: stop the poll for input (as in `pause_reading`) while one is queued. |
| `Writable` | `on_writable(s)`: runs when the poll is writable after a failed write (`loop.c`). | checked | Drain the adapter's queue; when the room that the largest refused send needs is free, queue `Writable` once. |
| `Closed` | `on_close(s, code, reason)`, called inside the close operations, with `code` 0 for an error. | checked | Queue it and deliver after the handler returns; the reason comes from the adapter's own state (`Local`, `PeerClosed`, `PeerReset`, `Shutdown`), not from `code`. See *Closing*. |
| `Tick` | The adapter's timer. | unverified | Deliver as the first event of a pass. |

### Half-close

Only a loop that supplies the half-close group needs these.

| Contract item | uSockets | Status | Adapter work |
|---|---|---|---|
| `set_keep_open_on_eof` | None. On end of stream the loop stops polling for input and calls `on_end` (`loop.c`). If the application had already called `us_socket_shutdown`, the loop closes the socket instead. | checked | Keep the flag in the socket extension. Default (off): in `on_end` flush the queue, then close the way `close` does (reason `PeerClosed`). On: deliver `PeerEof` from `on_end` and keep the link open. |
| `shutdown_write` | `us_socket_shutdown(ssl, s)`: marks the poll `SOCKET_SHUT_DOWN`, stops polling for output, `shutdown(2)`s (`socket.c`). The source comment says the application must track the peer's end itself: no "both sides finished" event. | checked | Call it once the adapter's queue is empty. When the peer has already ended, or ends later, close with `PeerClosed`. |
| `PeerEof` | `on_end(s)` (`loop.c`). | checked | Only for a link with keep-open. |

### Sizing

Only a loop that supplies the sizing group needs these.

| Contract item | uSockets | Status | Adapter work |
|---|---|---|---|
| `send_room` | None. | n/a | The queue's free room, capped at `max_send`. |
| `send2` | `us_socket_write2(ssl, s, header, header_length, payload, payload_length)` (non-SSL): one `bsd_write2` call; a short write is flagged (`socket.c`, the fix of the pinned commit). | checked | Append both parts to the queue as one entry. |

### Abort

Only a loop that supplies the abort group needs this.

| Contract item | uSockets | Status | Adapter work |
|---|---|---|---|
| `reset` | None. | checked: absent | `setsockopt(SO_LINGER, 1, 0)` on the descriptor (`us_socket_get_native_handle`), then `us_socket_close`. Discard the adapter's queue. |

### Inspection

Only a loop that supplies the inspection group needs these.

| Contract item | uSockets | Status | Adapter work |
|---|---|---|---|
| `peer_address` | `us_socket_remote_address(ssl, s, buf, &length)` | unverified: declaration | Format the bytes as the contract's text. A closed link must give empty. |
| `stop_listening` | `us_listen_socket_close(ssl, ls)` | unverified: declaration | Links accepted from it are other sockets and stay open. |

### Batching

Only a loop that supplies the batching group needs this.

| Contract item | uSockets | Status | Adapter work |
|---|---|---|---|
| `PassEnd` | `post_cb(loop)` after each iteration (`loop.c`, `us_internal_loop_post`). | checked | Deliver one `PassEnd` from there if the iteration delivered a link event. |


## What a loop with only the core costs

An event loop on this substrate that supplies only the core does the adapter work of the core rows above, listed here, and none of the work of the groups: no `shutdown_write` or `PeerEof` (so a library that must answer after the peer finishes sending cannot run on it), no `send_room` or `send2`, no `reset`, no `peer_address` or `stop_listening`, and no `PassEnd`. Each group is a separate, later addition.

- `listen`: Parse the address text first (numeric only) and hand uSockets the numeric text so nothing is resolved. A bind failure returns NULL with errno possibly clobbered by the `close` that follows it: probe with a throwaway `bind` to the same address to tell `AddressInUse`.
- `listener_port`: Call it on the listen socket (cast). Port 0 binds a system-chosen port.
- `dial`: Numeric text only. Returns at once; success is `on_open`, failure `on_connect_error` (below).
- `send`: Keep a bounded queue in the adapter and write from it: accept the whole send into the queue or refuse; `Full` while the queue is at its bound; `TooLarge` above its largest entry. Never rely on the count.
- `max_send`: A configuration value of at least 4096.
- `pause_reading`: **Re-apply after every short write**: `us_socket_write` and `us_socket_write2` call `us_poll_change(READABLE|WRITABLE)` on a short write (`socket.c`), which re-enables reading. The `on_writable` path keeps the current `READABLE` bit (`loop.c`), so it does not. Also re-apply when the low-priority queue relinks a socket with `| LIBUS_SOCKET_READABLE` (`loop.c`, only for contexts that use `is_low_prio`; not the plain TCP case).
- `close`: Do not call it from `close`. Mark the link closing, flush the queue, `us_socket_shutdown`, keep reading and discarding until the peer's end of stream or a limit, then call `us_socket_close`; queue the `Closed` and deliver it after the handler returns. See *Closing*.
- `now_ms`: A monotonic clock read at the top of each iteration (`pre_cb`).
- `tick_by`: One adapter timer: the regular 100 ms `Tick`, moved earlier by `tick_by`. `us_socket_timeout` has a granularity of `LIBUS_TIMEOUT_GRANULARITY` (4 s, `libusockets.h`) and is not usable for `connect_ms`.
- `serve`: The unsolved point (see below): how events reach the Goose handler.
- `stop`: On `stop`: close the listeners, close each link at the grace deadline with `Shutdown`, and stop the timers so `num_polls` reaches zero. `us_loop_run` blocks with no timeout, so the adapter's timer must wake it.
- `draining`: A flag.
- `Opened`: Queue `Opened` with the link; for an accepted socket name the listener handle of the listen socket that accepted it (none for a dial). Nothing else is attached.
- `Data`: Copy the bytes into the adapter's own buffer inside `on_data`, or call Goose synchronously there. A deferred, lent slice is not possible: it would be overwritten before the handler runs. At most one `Data` pending per link: stop the poll for input (as in `pause_reading`) while one is queued.
- `Writable`: Drain the adapter's queue; when the room that the largest refused send needs is free, queue `Writable` once.
- `Closed`: Queue it and deliver after the handler returns; the reason comes from the adapter's own state (`Local`, `PeerClosed`, `PeerReset`, `Shutdown`), not from `code`. See *Closing*.
- Slots: the adapter keeps one record for each link in a table indexed by the `Link` slot and takes a freed slot (from a free list) before it extends the table, so slots are dense (*Slot numbers are dense*); a slot is freed only after the `Closed` handlers return.
- `Tick`: Deliver as the first event of a pass.
- The peer's end of stream: the core still closes the link with `PeerClosed` once what was accepted is out, which is the default of the `set_keep_open_on_eof` row, without the switch to turn it off.

## How events reach a Goose handler

This was the open question of the research (design D9) and the reading above settles part of it. `us_loop_run` does not
return per iteration, but it calls `pre_cb` and `post_cb` every iteration, so the adapter can run the application's handler from `post_cb` if Goose
code can be called from C there. The application's handler is a compile-time block (not a function pointer), so a C
`post_cb` cannot name it. Two ways that do not need a block value in C: the adapter collects flat event records in
C during the iteration and a Goose `serve` function drives the loop one step at a time through a build that adds a
return-per-iteration entry point to uSockets (a small, local patch); or the adapter is written as the Goose loop over
uSockets' own `bsd.c` functions (as tcprouter and c_proxy are over their own thin C layer), using uSockets for the
parts that are not the loop. Neither is verified; both leave the contract unchanged. Copying received bytes is
required either way (row `Data`).

## Closing

`us_socket_close` is `close(2)` at once. A socket that still has unread input resets the connection on Linux and the
peer can lose bytes it was sent; bytes the adapter had accepted but not yet written would be dropped. So `close` is
the adapter's own sequence: flush the adapter's queue (a short write waits for `on_writable`), `us_socket_shutdown`,
then keep the link in a closing state that reads and discards until the peer's end of stream (`on_end`; after a
shutdown the loop closes the socket itself on the peer's FIN, `loop.c`) or a limit of the adapter's choosing (a timer,
for a peer that never reads), and only then `us_socket_close`. The link's one `Closed` carries reason `Local`
either way. `reset` skips all of it.

## Connect failures

`on_connect_error(s, 0)` is called with code 0 for every failure, before the descriptor is closed (`loop.c`:
`on_connect_error(s, 0); us_socket_close_connecting(0, s)`). The descriptor is still open inside the callback, so
`getsockopt(SO_ERROR)` on it gives the cause:

| Cause | Kind |
|---|---|
| address text is not numeric (adapter, before the call) | `BadAddress` |
| the adapter's connect timer | `TimedOut` |
| the adapter's link table is full | `NoResources` |
| `ECONNREFUSED` | `Refused` |
| `ENETUNREACH`, `EHOSTUNREACH` | `Unreachable` |
| `EACCES`, `EPERM` | `Denied` |
| `EMFILE`, `ENFILE`, `ENOBUFS`, `ENOMEM` | `NoResources` |
| other | `Other` |

## Known gaps

None: each row has a mapping. The three that need the most (`close` without losing bytes, `Data` lent for the event,
the path to the Goose handler) are adapter code over uSockets, with the strategies considered below.

| Row | Strategies considered | Result |
|---|---|---|
| `close` | (a) `us_socket_close` after the queue drains: can reset on unread input. (b) `us_socket_shutdown` and wait for the peer's FIN: waits for ever for a peer that never reads. (c) (b) with a limit: workable. | (c) |
| `Data` | (a) lend the loop's receive buffer: overwritten by `goto read_more` or the next socket. (b) stop the poll for input and call Goose inside `on_data`: no copy, but needs a synchronous call into Goose. (c) copy into an adapter buffer: workable, one copy. | (c), or (b) once a call into Goose is possible |
| `AddressInUse` | (a) errno after `listen` returns NULL: unreliable (the failing `bind` is followed by `close`). (b) a throwaway `bind`: workable. | (b) |
