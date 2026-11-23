# Declarations for the epoll loops

Contract 0.4 asks a loop to say which capabilities it supplies, with one line each in the loop's own namespace
(`docs/event-loops.md`, "Declaring what a loop supplies"). The two epoll loops live in repositories of their own and pin
this package by commit, so nothing here breaks them until they move to a commit of contract 0.4 or later. This note is for
their owners, for that day. It was made by reading both repositories at their latest commit, and no change was made to them.

## goose-io-epoll

It passes the core and half-close, sizing, abort, inspection and batching (its `README.md` and `epoll.goose` say so), and
not unix. Add to `engine.goose`, beside the other functions of `Loop`:

```goose
fn supplies_half_close(io: Loop&) -> goose_io::Supplied { return goose_io::Supplied {}; }
fn supplies_sizing(io: Loop&) -> goose_io::Supplied { return goose_io::Supplied {}; }
fn supplies_abort(io: Loop&) -> goose_io::Supplied { return goose_io::Supplied {}; }
fn supplies_inspection(io: Loop&) -> goose_io::Supplied { return goose_io::Supplied {}; }
fn supplies_batching(io: Loop&) -> goose_io::Supplied { return goose_io::Supplied {}; }
```

## goose-io-epoll-ext

It passes the same and relay, peek, revoke, wake and limits (`groups.goose`). Add the five above and, in `groups.goose`:

```goose
fn supplies_relay(io: Loop&) -> goose_io::Supplied { return goose_io::Supplied {}; }
fn supplies_peek(io: Loop&) -> goose_io::Supplied { return goose_io::Supplied {}; }
fn supplies_revoke(io: Loop&) -> goose_io::Supplied { return goose_io::Supplied {}; }
fn supplies_wake(io: Loop&) -> goose_io::Supplied { return goose_io::Supplied {}; }
fn supplies_limits(io: Loop&) -> goose_io::Supplied { return goose_io::Supplied {}; }
```

It does not supply unix, and so declares nothing for it: an undeclared capability answers `goose_io::Absent`.

## What else the rename reaches

Each loop's build then needs only the declarations, because `goose_io::require_<capability>(io)` in its conformance program
now also checks the declaration (a loop that has the operations and no declaration fails with `supplies_<capability>`). Both
loops also use the old words, which are theirs to change when they like:

- `conformance.sh`: the option `--group` is `--capability` in this package's `tests/conformance/run.sh`, and the sixth column
  of `tests/conformance/checks.tsv` is named `capability`.
- `conformance.goose`: its second argument is the name of a capability; the part functions `conformance_<capability>_part` are unchanged.
- Comments and the epoll-event-loop spec of `goose-io-epoll-ext` ("its five groups") say group where this package now says
  capability. `openspec/specs/epoll-event-loop/spec.md` is in that repository, not in this one, so this change carries no delta for it.
