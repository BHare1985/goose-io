# Proposal

## Why

`scoped-library-views` stops a library from acting on what it does not own. It does not stop a library from using up what everyone shares. On one event loop:

- A library that dials in a loop takes every link the loop has, and every other library's dials then fail with `NoResources`.
- A flood of connections to one library's listener takes the same links, and the loop has already accepted them.
- A library that calls `tick_by` with the current time on every `Tick` makes the loop wake at once, again and again, so the loop does no other work and the virtual clock in the in-memory loop does not advance.
- A library can listen on many addresses until the event loop's listener table is full.

The contract bounds memory for each link (a send that does not fit returns `Full`) and says that an event loop reports exhaustion as `NoResources`, but it has no way to give each library its own share.

## What Changes

- Add per-library **limits**, set when the application adds a library to the registry: a maximum of links (dialled and accepted together), a maximum of listeners, and a minimum interval for `tick_by`. There is no default: the application passes limits explicitly, with `unbounded()` available for a library it trusts.
- A view that refuses a `dial` returns the invalid link and issues no link. A view that refuses a `listen` returns a `ListenError` of kind `NoResources`.
- An accepted link that would take a library over its link limit is closed by the registry's routing before the library sees it, and counted.
- A view clamps `tick_by` to at least the minimum interval after the last wake-up it asked for, so a library cannot make the loop spin.
- The registry keeps counters for each library (links open, dials and listens refused, links refused, wake-ups clamped), readable by the application.
- Relax the contract: a layer beneath a library may refuse a dial, and then `dial` returns the invalid link, as on a finished loop.

Out of scope: limits on bytes held for each link (the event loop already bounds them); a limit on time spent in a handler (nothing preempts a handler); limits for an event loop used without views.

## Capabilities

### New Capabilities

- `library-resource-limits`: per-library limits enforced by the view and the registry.

### Modified Capabilities

- `io-contract`: the one exception to *Dialling never blocks and always ends in one event* becomes two: a finished loop, and a layer that refuses the dial.

## Impact

- **goose-io:** `scope.goose` (`Limits`, the counters, the checks in `dial`, `listen`, `tick_by` and `route`), `tests/unit/`, `examples/scoped.goose` (a library that floods), `docs/contract.md`, `docs/libraries.md`.
- **Libraries:** a library must already check `is_valid` on the link `dial` returns, because of the finished loop; the example libraries do. A library that does not is already wrong.
- **Depends on:** `scoped-library-views`, applied first.
- **Risk:** an application that sets a limit too low fails its own dials with an invalid link and no event, which a library may mishandle. The counters and the docs say so.
