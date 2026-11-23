# Moving a loop to contract 0.4

Contract 0.4 asks a loop to say which capabilities it supplies, with one line each in the loop's own namespace
(`docs/event-loops.md`, "Declaring what a loop supplies"). A loop in a repository of its own pins this package by commit, so
nothing breaks until it moves to a commit of contract 0.4 or later. This note is for the owners of such loops, for that day.
It applies to any loop; the loops listed in `examples/README.md` are the examples of it.

## The declarations

For each capability the loop passes the suite for, add one line next to its operations (here the loop's type is `Loop`):

```goose
fn supplies_relay(io: Loop&) -> goose_io::Supplied { return goose_io::Supplied {}; }
```

The capabilities are half_close, sizing, abort, inspection, batching, unix, relay, peek, revoke, wake and limits. Declare
exactly those the loop supplies and none other: a capability left undeclared answers `goose_io::Absent`, and a loop that
declares one without its operations fails `goose_io::require_<capability>` with the name of the missing operation. The core
needs no declaration. Batching and unix have no operation, so their declaration is the whole of what a loop does to supply
them.

A loop that wraps another forwards each answer with `goose_io::has_<capability>(inner)` (see the wrapper in
`tests/support/wrapper.goose`).

## The examples

The two loops of `examples/README.md` need these lines when they move to 0.4:

- [goose-io-epoll](https://github.com/BHare1985/goose-io-epoll) passes the core and half-close, sizing, abort, inspection and
  batching: five declarations (`half_close`, `sizing`, `abort`, `inspection`, `batching`).
- [goose-io-epoll-ext](https://github.com/BHare1985/goose-io-epoll-ext) passes those and relay, peek, revoke, wake and limits:
  ten declarations.

Neither supplies unix, so neither declares it.

## What else the move reaches

`goose_io::require_<capability>(io)` in a loop's conformance program now also checks the declaration. The words changed too:
the conformance script's option for choosing one part of the suite is `--capability` (it was `--group`), the sixth column of
`tests/conformance/checks.tsv` is `capability`, and prose that said "group" says "capability". A loop's own scripts and
comments that use the old words are the owner's to change when they like.
