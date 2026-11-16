# Mapping: libuv

Candidate provider: libuv, release `v1.53.0` (commit `840404ce8ba7cc0204be52389a6cfff9f2c90fb6`, 2026-09-24).
Read from source and header: `include/uv.h`, `src/unix/stream.c`, `src/unix/tcp.c`, `src/unix/core.c`,
`src/uv-common.c`. Nothing was built or run, and only the Unix implementation was read (not Windows). A row is
**checked** when the code named was read and does what the row says, **unverified** when only a declaration was read or
the point was not examined.

## Unverified rows, and the rows that need an adapter that changes behaviour

Unverified (declaration read, behaviour not):

- `listen`, `listener_port`, `stop_listening`, `peer_address`: `uv_listen`, `uv_accept`, `uv_tcp_getsockname`,
  `uv_tcp_getpeername` were read as declarations in `uv.h`.
- `tick_by`, `Tick`, `now_ms`: `uv_timer_start`, `uv_now` read as declarations; that `uv_now` is cached per iteration
  is documented in `uv.h`, not read in `src/unix/core.c`.
- `PassEnd`: no per-iteration hook was examined (`uv_prepare`, `uv_check`, `uv_idle` exist in `uv.h`).
- the mapping of connect and read errors to kinds relies on libuv's error names (`UV_ECONNREFUSED` and others); the
  translation table in `src/unix/` was not read.

Changing behaviour (checked in source):

1. `uv_write` has no bound: a send queues however many bytes (`stream.c`, `uv_write2`, `write_queue_size`); the
   adapter must bound it.
2. `uv_ip6_addr` accepts a zone identifier (`%eth0`) and ignores an unknown one (`uv-common.c`), so the adapter has
   to reject text with `%` itself.
3. `uv_shutdown` and `uv_close` are queued and run from the loop; a close callback is never inside the call
   (good: this is what the contract wants), but nothing flushes before `uv_close`.
4. `uv_try_write` and `uv_write` do not tell the adapter how much is waiting in the kernel: `Writable` has to come from
   the adapter's own accounting.

## Operations and events

| Contract item | libuv | Status | Adapter work |
|---|---|---|---|
| `listen` | `uv_tcp_init`, `uv_tcp_bind`, `uv_listen(stream, backlog, cb)`; `uv_accept` in the callback | unverified: declarations | Parse the address with the contract's grammar first, then fill a `sockaddr` (do not call `uv_ip6_addr` on unchecked text, see above). `UV_EADDRINUSE` from bind maps to `AddressInUse`. |
| `listener_port` | `uv_tcp_getsockname` | unverified: declaration | Bind to port 0 and read the port back. |
| `stop_listening` | `uv_close` on the listening handle | unverified | Links accepted from it are other handles. |
| `dial` | `uv_tcp_connect(req, handle, sockaddr, cb)`; the callback gets a status (`stream.c`, `uv__stream_connect`) | checked: `uv__stream_connect` exists and is the completion path | The adapter parses the numeric address; a failed parse is `BadAddress` delivered as the one `Closed`. The callback status gives the kind. |
| `peer_address` | `uv_tcp_getpeername` | unverified: declaration | Format as the contract's text. |
| `send` | `uv_write(req, stream, bufs, nbufs, cb)` copies nothing and queues without limit (`stream.c`, `uv_write2`); `uv_stream_get_write_queue_size` reports queued bytes | checked | Copy into an adapter buffer and bound it (`Full` above the bound); `Sent` once copied. The request is freed in the write callback. |
| `send2` | `uv_write` with two `uv_buf_t` | checked: `uv_write2` takes `nbufs` | Both or neither: the bound is tested against the sum before either is queued. |
| `send_room` | `uv_stream_get_write_queue_size` | checked | The bound minus the queued bytes, capped at `max_send`. |
| `max_send` | None. | n/a | A configuration value of at least 4096. |
| `pause_reading` | `uv_read_stop(stream)` and `uv_read_start` | checked: `uv_read_stop` in `uv.h`, `uv__read` in `stream.c` | A pending `Data` is delivered before the stop takes effect; the contract allows exactly one already received. |
| `set_keep_open_on_eof` | `read_cb` is called with `UV_EOF` (`stream.c`, around `uv__read`) | checked | Keep the flag in the per-link record. Off: flush, then close as `close` does (reason `PeerClosed`). On: queue `PeerEof` and `uv_read_stop`. |
| `shutdown_write` | `uv_shutdown(req, stream, cb)`: the `shutdown(2)` is deferred until the write queue drains (`stream.c`, comment in `uv_shutdown`, `uv__drain`) | checked | Exactly the contract's "once accepted bytes are out". Returns `UV_ENOTCONN` if already shut: ignore. When the peer has also ended, close with `PeerClosed`. |
| `close` | `uv_shutdown` then `uv_close(handle, close_cb)`; the close callback runs from the loop (`core.c`, `uv__run_closing_handles`) | checked | See *Closing*. The `Closed` is queued from the close callback and delivered after the handler that called `close` has returned. |
| `reset` | `uv_tcp_close_reset(handle, close_cb)`: `SO_LINGER` 1, 0 then `uv_close` (`tcp.c`); fails with `UV_EINVAL` if a shutdown is in progress | checked | If `UV_EINVAL`, close with `uv_close` after setting the option directly. |
| `set_user` | The handle's `data` pointer | unverified | A per-link record indexed by the `Link` slot; `uv_handle_set_data`. |
| `user` | As above | unverified | The record outlives the close callback until `Closed` has been delivered. |
| `now_ms` | `uv_now(loop)`, milliseconds, updated at the start of each iteration | unverified | `uv_update_time` before reading it when called mid-iteration. |
| `tick_by` | `uv_timer_start(timer, cb, timeout_ms, repeat_ms)` | unverified: declaration | One timer: the regular 100 ms `Tick`, moved earlier by `tick_by`. |
| `serve` | `uv_run(loop, UV_RUN_ONCE)` returns after each iteration (`uv.h`, `UV_RUN_ONCE`) | checked: enum | The adapter drives the loop one iteration at a time from Goose and delivers the queued events after each. This is what the research found libuv can do and uSockets cannot. |
| `stop` | `uv_stop(loop)`; `uv_loop_alive` | checked: declarations | On `stop`: close listeners, set the deadline, close each link at it with `Shutdown`; `serve` returns when no link remains (the adapter's own count). |
| `draining` | None. | n/a | A flag. |
| `Opened` | The connect callback with status 0; for accepted links, the connection callback after `uv_accept` | unverified for accept | Queue `Opened`. |
| `Data` | `alloc_cb(handle, suggested, buf)` lets the adapter supply the buffer; `read_cb(stream, nread, buf)` is called with the bytes (`stream.c`, `uv__read`) | checked: `uv__read` and its `read_cb` calls; `alloc_cb` read as a declaration | Give libuv a buffer the adapter owns; in `read_cb` stop reading (`uv_read_stop`) and queue the event; the slice is lent until the handler returns, then the buffer is reused and reading resumes. No copy is forced. |
| `Writable` | The write callback (`uv__write_callbacks`, `stream.c`) | checked | The adapter's queue drained: queue `Writable` once the room that the largest refused send needs is free. |
| `PeerEof` | `read_cb` with `UV_EOF` (`stream.c`) | checked | Only for a link with keep-open. |
| `Closed` | The close callback | checked | Reason from the adapter's state: `Local`, `PeerClosed`, `PeerReset` (`UV_ECONNRESET`), `Shutdown`, `ConnectFailed`, `Error`. |
| `Tick` | The adapter's timer | unverified | Delivered as the first event of a pass. |
| `PassEnd` | None examined. | unverified | After the events of one `uv_run` iteration have been delivered, if any was a link event. |

## Closing

`uv_close` closes the descriptor; with unread input in the socket that is a reset on Linux, and accepted bytes still in
libuv's write queue are cancelled (libuv documents `UV_ECANCELED` for them; not read in source). So `close` is: stop accepting new sends, let the
write queue drain, `uv_shutdown` (the `shutdown(2)` is deferred until the queue is empty), keep reading and discarding
(`alloc_cb` and `read_cb` stay active, no `Data` is delivered), and `uv_close` when `UV_EOF` arrives or a limit of the
adapter's choosing passes (a timer; a peer that never reads must not hold the link for ever). `Closed` carries `Local`
in both cases. `reset` is `uv_tcp_close_reset`.

## Connect failures

The connect callback's status is a libuv error name:

| Cause | Kind |
|---|---|
| address text not numeric, or with a zone identifier (adapter, before the call) | `BadAddress` |
| the adapter's connect timer | `TimedOut` |
| the adapter's link table full | `NoResources` |
| `UV_ECONNREFUSED` | `Refused` |
| `UV_ENETUNREACH`, `UV_EHOSTUNREACH` | `Unreachable` |
| `UV_EACCES`, `UV_EPERM` | `Denied` |
| `UV_EMFILE`, `UV_ENFILE`, `UV_ENOBUFS`, `UV_ENOMEM` | `NoResources` |
| `UV_ETIMEDOUT` from the kernel, any other | `Other` |

## Known gaps

None: every row has a workable mapping. libuv is the one substrate examined that can return to the caller after each
iteration, which settles how events reach a Goose handler for it.

| Row | Strategies considered | Result |
|---|---|---|
| `send` bounded | (a) rely on `uv_write` and check `uv_stream_get_write_queue_size` before each send: this is the bound, taken from libuv's own count; (b) an adapter queue. | (a) is enough for the count, but a request must still own its bytes until the callback: the adapter copies. |
| `Data` lent for the event | (a) alloc and read callbacks with a per-link buffer: workable, no copy. | (a) |
