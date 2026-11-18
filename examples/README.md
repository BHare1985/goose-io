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
| [`loops/epoll/`](loops/epoll/) | the epoll event loop as it stands in this repository's change `epoll-event-loop` | Linux |

## Event loops in repositories of their own

These are event loops on real sockets (Linux). They live next to this repository while they are examples; each has a README.

- **goose-io-epoll**: the plain epoll loop. It supplies the core and the half-close, sizing, abort, inspection and batching groups and passes the conformance suite on them. It is the generic layer of tcprouter's engine with the proxy removed and the contract's names in place. Read it to see what a conforming loop is.
- **goose-io-epoll-ext**: the same loop with what a performant TCP proxy needs added: forwarding between two sockets by the loop, and the other features of the groups proposed in `openspec/changes/add-stream-groups` (peek, revoke, wake, files, loans, parts, addresses). tcprouter is meant to import this one. Until those groups are in the contract, what it adds is loop-specific.

A library is written against the contract, not against either loop; both run the example libraries above unchanged.
