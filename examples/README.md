# Examples

What is here and where the others are. This list grows as examples are added; add a line when you add one.

## In this repository

| Example | What it shows | Needs |
|---|---|---|
| [`echo/`](echo/) | the smallest library: an echo server | core |
| [`lineserver/`](lineserver/) | a server that answers newline-delimited requests | core and half-close |
| [`lineclient/`](lineclient/) | a pooled, pipelining client with deadlines and reconnects | core |
| [`gateway.goose`](gateway.goose) | the line server and client on one loop | core and half-close |
| [`dispatch.goose`](dispatch.goose) | the application's glue: each event goes to the library that owns its link | core |

## Event loops and a library in repositories of their own

These are examples of how to implement and use goose-io. They are not authoritative: a loop or a library does not have to look like them, and others are encouraged to write their own. To have yours listed here, add a line (name, link, what it supplies or needs). Each has a README and fetches this package by commit.

- **[goose-io-epoll](https://github.com/BHare1985/goose-io-epoll)**: an event loop on real sockets (Linux, epoll). It supplies the core and the half-close, sizing, abort, inspection and batching capabilities and passes the conformance suite on them. Read it to see what a conforming loop is, and derive a new loop from it.
- **[goose-io-epoll-ext](https://github.com/BHare1985/goose-io-epoll-ext)**: the same loop with the proxy capabilities added (relay, peek, revoke, wake, limits) and a forwarding pump, for programs that move many bytes between sockets.
- **[goose-io-tcpproxy](https://github.com/BHare1985/goose-io-tcpproxy)**: a library, a TCP proxy (forwarding by listener, SNI inspection, handler mode, tags and fences, messages, policy). It is generic over the event loop and needs the proxy capabilities; the application makes the loop and the proxy side by side.

A library is written against the contract, not against a loop: the example libraries above run unchanged on the in-memory loop and on the loops here.
