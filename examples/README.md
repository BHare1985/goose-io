# Examples

What is here and where the others are. This list grows as examples are added; add a line when you add one.

## In this repository

| Example | What it shows | Needs |
|---|---|---|
| [`echo/`](echo/) | the smallest library: an echo server | core |
| [`lineserver/`](lineserver/) | a server that answers newline-delimited requests | core and half-close |
| [`lineclient/`](lineclient/) | a pooled, pipelining client with deadlines and reconnects | core |
| [`forward/`](forward/) | a forwarder that relays where the loop can and copies where it cannot | core, and relay if supplied |
| [`gateway.goose`](gateway.goose) | the line server and client on one loop | core and half-close |
| [`dispatch.goose`](dispatch.goose) | the application's glue: each event goes to the library that owns its link | core |

### One for each capability

Small programs, one for each capability that has no example above, each with a page in [`docs/capabilities/`](../docs/capabilities/) that quotes it. They are examples to read and copy from, not libraries to depend on.

| Example | Capability | What it shows |
|---|---|---|
| [`capabilities/frames.goose`](capabilities/frames.goose) | sizing | length-prefixed frames sent with `send2`, cut to `send_room` |
| [`capabilities/reject.goose`](capabilities/reject.goose) | abort | a client that does not greet is reset |
| [`capabilities/access_log.goose`](capabilities/access_log.goose) | inspection | the peer's address at `Opened`; `stop_listening` while draining |
| [`capabilities/batch_reply.goose`](capabilities/batch_reply.goose) | batching | replies queued in a pass and sent on `PassEnd` |
| [`capabilities/sniff.goose`](capabilities/sniff.goose) | peek | the first bytes decide what the connection is |
| [`capabilities/fenced_writer.goose`](capabilities/fenced_writer.goose) | revoke | `write_deadline` at a fence, `discard_unsent` on cancel |
| [`capabilities/worker_reply.goose`](capabilities/worker_reply.goose) | wake | a worker thread answers through `wake_with` |
| [`capabilities/idle_reaper.goose`](capabilities/idle_reaper.goose) | limits | `Idle` and `Age` on a relayed pair |

Half-close, unix and relay are shown by `lineserver/`, `tests/examples/unix_dial_test.goose` and `forward/`.

## Event loops and a library in repositories of their own

These are examples of how to implement and use goose-io. They are not authoritative: a loop or a library does not have to look like them, and others are encouraged to write their own. To have yours listed here, add a line (name, link, what it supplies or needs). Each has a README and fetches this package by commit.

- **[goose-io-epoll](https://github.com/BHare1985/goose-io-epoll)**: an event loop on real sockets (Linux, epoll). It supplies the core and the half-close, sizing, abort, inspection and batching capabilities and passes the conformance suite on them. Read it to see what a conforming loop is, and derive a new loop from it.
- **[goose-io-epoll-ext](https://github.com/BHare1985/goose-io-epoll-ext)**: the same loop with the proxy capabilities added (relay, peek, revoke, wake, limits) and a forwarding pump, for programs that move many bytes between sockets.
- **[goose-io-tcpproxy](https://github.com/BHare1985/goose-io-tcpproxy)**: a library, a TCP proxy (forwarding by listener, SNI inspection, handler mode, tags and fences, messages, policy). It is generic over the event loop and needs the proxy capabilities; the application makes the loop and the proxy side by side.

A library is written against the contract, not against a loop: the example libraries above run unchanged on the in-memory loop and on the loops here.
