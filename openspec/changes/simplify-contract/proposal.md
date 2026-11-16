# Proposal

## Why

The aim of goose-io is that anyone can write an event loop (a uSockets one, a custom one, one in the style of tokio) and every library written against the contract runs on it. Version 0.1 asks too much of the person writing the loop. It requires all 21 operations and 7 events, and the whole of the conformance suite, before a loop may call itself conforming. Most of that is not needed to run a library:

- The line client, the more demanding of the two example libraries, uses eight operations: `dial`, `send`, `max_send`, `close`, `set_user`, `now_ms`, `tick_by` and `draining`. It never uses `send2`, `send_room`, `peer_address`, `reset`, `shutdown_write`, `listener_port`, `stop_listening` or `user`.
- Of the 56 checks of the suite, 30 use core operations alone, 22 call one extra operation (several only incidentally: `dial_refused` calls `stop_listening` just to get a dead port) and 4 call several.
- A loop that cannot do half-close, abort, or batching cannot run even one conformance part, because the suite is one driver that compiles all of its checks.

The word "provider" is also in the way. It is the author's word, it appears several hundred times in the specification, documents and code, and it is not what people call the thing. People write an event loop.

This change makes the contract small and the rest optional, and renames the roles.

## What Changes

- **A core and groups of extras.** The core is 13 operations (`listen`, `listener_port`, `dial`, `send`, `max_send`, `pause_reading`, `close`, `set_user`, `now_ms`, `tick_by`, `serve`, `stop`, `draining`) and 5 events (`Opened`, `Data`, `Writable`, `Closed`, `Tick`). Everything else is in one of five groups an event loop may add: **half-close** (`shutdown_write`, `set_keep_open_on_eof`, `PeerEof`), **sizing** (`send_room`, `send2`), **abort** (`reset`), **inspection** (`peer_address`, `stop_listening`, `user`) and **batching** (`PassEnd`). A library uses what it needs; if the loop lacks an operation it needs, the library does not compile.
- **The rules stay where a library cannot do without them**, and only there: `Opened` first and exactly one `Closed` last, no event delivered from inside an operation, `send` taken whole or refused (`Full` then `Writable`), bytes lent for one event, `close` loses no accepted byte, and a failed dial is one `Closed` with a kind. Rules of an extra bind only the loops that supply it.
- **One word for each role.** "Provider" becomes "event loop"; "host" becomes "application"; "library" stays. The compile-time check `require_provider` becomes one function for the core and one for each group.
- **The conformance suite is split by group** and each group runs on its own, so a loop that supplies the core runs the core checks and nothing that needs more. It is a tool and not a gate: a loop says which groups it passes. Each check needs the core and at most one group.
- **Contract version 0.2** (the rename and the removal of `require_provider` are breaking; the contract is at major version 0).
- **BREAKING** `goose_io::require_provider` and `provider_close` of the in-memory loop are renamed; documents move (`docs/providers.md` to `docs/event-loops.md`, `docs/providers/` to `docs/event-loops/`).

Out of scope: any change to what an operation does (the behaviour of every operation that is kept is unchanged); new operations; the example event loops (uSockets, tcprouter's engine, io_uring), which remain later changes and now start from a smaller contract; renaming the capability ids `io-contract` and `provider-conformance` (see the design).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: adds the requirement that the contract is a core and groups of extras; moves the requirements of half-close, sizing, abort, inspection and batching into their groups; states that `pause_reading` and `listener_port` are core; renames the roles; contract version 0.2.
- `provider-conformance`: the suite is run by group and is a tool and not a gate; the vocabulary changes. Its capability id is kept.

Both capabilities' requirements are those of the change `define-contract-v1` and `harden-memory-provider`. This change is applied after `define-contract-v1` has been archived, so that its modifications have requirements to modify.

## Impact

- **Specification:** about ten requirements of `io-contract` change in substance and the wording of the rest is swept; the whole of the `provider-conformance` requirement list is restated.
- **Code:** `goose_io.goose` (the compile-time checks), `memory.goose`, `tests/support/wrapper.goose`, the suite in `conformance/`, `examples/`, the tests.
- **Documents:** `docs/contract.md`, `docs/libraries.md`, `docs/providers.md` and `docs/providers/` (moved and renamed), `README.md`, `CONTRIBUTING.md`.
- **CI and scripts:** the workflow and the scripts run each group; no new tool.
- **Risk carried forward:** the contract has still been exercised only by the in-memory loop and the wrapper over it. A smaller core is easier for a real loop to meet; whether it is small enough is shown by the first real one.
