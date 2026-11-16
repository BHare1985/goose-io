# Mapping: libevent

Candidate event loop: libevent, release `release-2.1.13-stable` (commit `79ddfb460847999b807cba76d04e73891f29c6ee`).
Read from source and headers: `include/event2/bufferevent.h`, `listener.h`, `event.h`, `buffer.h`, `evutil.c`
(`evutil_parse_sockaddr_port`), `bufferevent_sock.c`. Nothing was built or run. The mapping is through the
`bufferevent` interface, the one a client library would use. A row is **checked** when the code named was read and does
what the row says, **unverified** when only a declaration was read or the point was not examined.

## Unverified rows, and the rows that need an adapter that changes behaviour

Unverified (declaration read, behaviour not):

- `listen`, `listener_port`, `stop_listening`: `evconnlistener_new_bind`, `evconnlistener_get_fd`,
  `evconnlistener_disable` were read as declarations; the port is read back with `getsockname` on the listener's fd.
- `peer_address`: not examined (the callback of `evconnlistener` receives the address of an accepted socket).
- `Tick`, `tick_by`, `now_ms`, `PassEnd`: timers (`event_new` with `evtimer`) and `event_base_gettimeofday_cached` were
  not read beyond the declaration of `event_base_loop` flags; no per-iteration hook was examined.
- `set_user`, `user`: the callback argument (`cbarg`) is the usual place; not read.

Changing behaviour (checked in source or header):

1. There is no `shutdown` of the write side in `bufferevent_sock.c`; it has to be `shutdown(2)` on
   `bufferevent_getfd` after the output buffer is empty.
2. The output buffer is unbounded (`bufferevent_get_output` is an `evbuffer`); the adapter bounds it by checking
   `evbuffer_get_length` before it adds.
3. `evutil_parse_sockaddr_port` is lenient: `ipv6` and `[ipv6]` without a port parse (port 0), `atoi` accepts trailing
   junk, and `evutil_parse_sockaddr_port` is documented for IP literals only but its handling of `%` was not
   examined; the adapter validates the text itself.
4. `BEV_OPT_DEFER_CALLBACKS` is needed so that no callback runs inside an operation.

## Operations and events

### Core

Every event loop supplies these.

| Contract item | libevent | Status | Adapter work |
|---|---|---|---|
| `listen` | `evconnlistener_new_bind(base, cb, arg, flags, backlog, sockaddr, len)`; flags `LEV_OPT_REUSEABLE`, `LEV_OPT_CLOSE_ON_FREE` (`listener.h`) | unverified: declaration | Validate the text with the contract's grammar and build the `sockaddr` directly; `AddressInUse` from the `EADDRINUSE` the creation leaves in `errno`. |
| `listener_port` | `evconnlistener_get_fd` then `getsockname` | unverified: declaration | Read it back after binding port 0. |
| `dial` | `bufferevent_socket_new(base, -1, options)` then `bufferevent_socket_connect(bev, sockaddr, len)`; `BEV_EVENT_CONNECTED` or `BEV_EVENT_ERROR` in the event callback (`bufferevent.h`, `bufferevent_sock.c`) | checked: header; `bufferevent_socket_connect_hostname` exists and must not be used | Pass a `sockaddr` built from the numeric text: nothing is resolved. |
| `send` | `bufferevent_write(bev, data, size)` appends to an `evbuffer` that has no bound | checked: header | Test `evbuffer_get_length(bufferevent_get_output(bev)) + size` against a bound first; `Full` otherwise; `Sent` once added. |
| `max_send` | None. | n/a | A configuration value of at least 4096. |
| `pause_reading` | `bufferevent_disable(bev, EV_READ)` and `bufferevent_enable(bev, EV_READ)` | checked: header | Unread bytes stay in the kernel. |
| `close` | `bufferevent_free` after the output drains (`BEV_OPT_CLOSE_ON_FREE`) | unverified | See *Closing*. |
| `set_user` | The callback argument | unverified | A per-link record. |
| `now_ms` | `event_base_gettimeofday_cached` | unverified | Monotonic: use `CLOCK_MONOTONIC`, or `event_base_update_cache_time`. |
| `tick_by` | An `evtimer` | unverified | One timer, the regular 100 ms `Tick` moved earlier by `tick_by`. |
| `serve` | `event_base_loop(base, EVLOOP_ONCE)` runs until events are active and returns (`event.h`) | checked: flag declared | The adapter drives the loop one step at a time from Goose and delivers the queued events after each. |
| `stop` | `event_base_loopexit(base, &timeval)` | checked: declared | As for libuv: the adapter closes listeners, sets the deadline, closes each link at it with `Shutdown`. |
| `draining` | None. | n/a | A flag. |
| `Opened` | `BEV_EVENT_CONNECTED` for a dial; the listener callback for an accepted socket | unverified | Queue `Opened`. |
| `Data` | The read callback with the input `evbuffer`; `evbuffer_pullup` gives a contiguous slice that is valid until the buffer is drained | checked: header | In the read callback queue the event holding the slice; drain the `evbuffer` only after the handler has returned; `bufferevent_disable(EV_READ)` meanwhile so there is one pending `Data`. |
| `Writable` | The write callback at the low watermark | checked: header | Queue `Writable` once the room that the largest refused send needs is free. |
| `Closed` | The adapter's own, after `bufferevent_free` or on `BEV_EVENT_ERROR` | n/a | Reason from the adapter's state; `EVUTIL_SOCKET_ERROR()` after `BEV_EVENT_ERROR` gives `PeerReset` (`ECONNRESET`) or `Error`. |
| `Tick` | The adapter's timer | unverified | The first event of a pass. |

### Half-close

Only a loop that supplies the half-close group needs these.

| Contract item | libevent | Status | Adapter work |
|---|---|---|---|
| `set_keep_open_on_eof` | `BEV_EVENT_EOF` in the event callback | checked: header | Off: flush and close as `close` does (`PeerClosed`). On: queue `PeerEof` and disable reading. |
| `shutdown_write` | None in the `bufferevent` interface. | checked: absent in `bufferevent_sock.c` | When the output `evbuffer` is empty (a write callback fires at the low watermark, `bufferevent_setwatermark`), call `shutdown(fd, SHUT_WR)` on `bufferevent_getfd`. |
| `PeerEof` | `BEV_EVENT_EOF` | checked: header | Only for a link with keep-open. |

### Sizing

Only a loop that supplies the sizing group needs these.

| Contract item | libevent | Status | Adapter work |
|---|---|---|---|
| `send_room` | `evbuffer_get_length(output)` | checked | The bound minus it, capped at `max_send`. |
| `send2` | Two `bufferevent_write` calls | checked: header | The bound is tested against the sum of both before either is written. |

### Abort

Only a loop that supplies the abort group needs this.

| Contract item | libevent | Status | Adapter work |
|---|---|---|---|
| `reset` | None. | checked: absent | `setsockopt(SO_LINGER, 1, 0)` on `bufferevent_getfd`, then `bufferevent_free`. |

### Inspection

Only a loop that supplies the inspection group needs these.

| Contract item | libevent | Status | Adapter work |
|---|---|---|---|
| `peer_address` | `getpeername` on `bufferevent_getfd` | unverified | Format as the contract's text. |
| `stop_listening` | `evconnlistener_disable` or free | unverified | Accepted links stay. |
| `user` | As above | unverified | The record outlives the free until `Closed` has been delivered. |

### Batching

Only a loop that supplies the batching group needs this.

| Contract item | libevent | Status | Adapter work |
|---|---|---|---|
| `PassEnd` | None examined. | unverified | After each `event_base_loop(EVLOOP_ONCE)` that delivered a link event. |


## What a loop with only the core costs

An event loop on this substrate that supplies only the core does the adapter work of the core rows above, listed here, and none of the work of the groups: no `shutdown_write` or `PeerEof` (so a library that must answer after the peer finishes sending cannot run on it), no `send_room` or `send2`, no `reset`, no `peer_address`, `stop_listening` or `user`, and no `PassEnd`. Each group is a separate, later addition.

- `listen`: Validate the text with the contract's grammar and build the `sockaddr` directly; `AddressInUse` from the `EADDRINUSE` the creation leaves in `errno`.
- `listener_port`: Read it back after binding port 0.
- `dial`: Pass a `sockaddr` built from the numeric text: nothing is resolved.
- `send`: Test `evbuffer_get_length(bufferevent_get_output(bev)) + size` against a bound first; `Full` otherwise; `Sent` once added.
- `max_send`: A configuration value of at least 4096.
- `pause_reading`: Unread bytes stay in the kernel.
- `close`: See *Closing*.
- `set_user`: A per-link record.
- `now_ms`: Monotonic: use `CLOCK_MONOTONIC`, or `event_base_update_cache_time`.
- `tick_by`: One timer, the regular 100 ms `Tick` moved earlier by `tick_by`.
- `serve`: The adapter drives the loop one step at a time from Goose and delivers the queued events after each.
- `stop`: As for libuv: the adapter closes listeners, sets the deadline, closes each link at it with `Shutdown`.
- `draining`: A flag.
- `Opened`: Queue `Opened`.
- `Data`: In the read callback queue the event holding the slice; drain the `evbuffer` only after the handler has returned; `bufferevent_disable(EV_READ)` meanwhile so there is one pending `Data`.
- `Writable`: Queue `Writable` once the room that the largest refused send needs is free.
- `Closed`: Reason from the adapter's state; `EVUTIL_SOCKET_ERROR()` after `BEV_EVENT_ERROR` gives `PeerReset` (`ECONNRESET`) or `Error`.
- `Tick`: The first event of a pass.
- The peer's end of stream: the core still closes the link with `PeerClosed` once what was accepted is out, which is the default of the `set_keep_open_on_eof` row, without the switch to turn it off.

## Closing

`bufferevent_free` with `BEV_OPT_CLOSE_ON_FREE` closes the descriptor (plain `close(2)`); unread input resets the
connection on Linux. `close` is therefore: stop accepting sends, wait until the output `evbuffer` is empty, call
`shutdown(fd, SHUT_WR)`, keep reading and discarding (the read callback drains the input without queuing `Data`) until
`BEV_EVENT_EOF` or a limit of the adapter's choosing (an `evtimer`), then `bufferevent_free`. `Closed` carries `Local`.
`reset` skips all of it.

## Connect failures

After `BEV_EVENT_ERROR` on a connect, `EVUTIL_SOCKET_ERROR()` (the last socket error) is the cause:

| Cause | Kind |
|---|---|
| address text not numeric (adapter, before the call) | `BadAddress` |
| the adapter's connect timer | `TimedOut` |
| the adapter's link table full | `NoResources` |
| `ECONNREFUSED` | `Refused` |
| `ENETUNREACH`, `EHOSTUNREACH` | `Unreachable` |
| `EACCES`, `EPERM` | `Denied` |
| `EMFILE`, `ENFILE`, `ENOBUFS`, `ENOMEM` | `NoResources` |
| `BEV_EVENT_TIMEOUT` from `bufferevent_set_timeouts`, other | `Other` (use the adapter's timer for `TimedOut`, not the bufferevent's) |

## Known gaps

None: every row has a workable mapping.

| Row | Strategies considered | Result |
|---|---|---|
| `shutdown_write` | (a) a `bufferevent` call: none exists. (b) `shutdown(2)` on the descriptor after the output is empty: workable. | (b) |
| `send` bounded | (a) a facility in `bufferevent.h` that bounds the output queue: none was found. (b) a bound checked by the adapter before each write: workable. | (b) |
