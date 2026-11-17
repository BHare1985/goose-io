# Design

## Context

See `proposal.md` for why. What exists:

- The contract is generic over the event loop type. A library's functions take `io: Io&` and call `io.send(...)`, so whatever type the application passes is the library's whole view of the network. A prototype showed that `struct View<Io> { io: Io&, table: Table&, me: i64 }` compiles, is built on the stack for each call, and lets the unchanged echo library run through it. With a hostile library holding a leaked handle, `send` on the raw loop reached the peer and `send` through a view returned `Closed` and reached nothing.
- Layering already exists in the contract (section 7) and in `tests/support/wrapper.goose`. That wrapper keeps its inner loop in a module global because Goose does not allow one root struct to own another. A view avoids this by holding a reference for the length of one call.
- `LinkMap` keys state by link and is dense by slot. A registry reuses it.
- The contract's operations include `serve` and `stop`, which belong to the application but are enforced nowhere: any library can call `stop`.
- Today an application either offers each event to the libraries in turn (`examples/gateway.goose`) or learns owners from claims (`examples/dispatch.goose`). The second cannot learn the owner of a link a library dials for itself until that library claims its first event.

## Goals / Non-Goals

**Goals:**
- A library can act only on links and listeners it made, and is shown only the events of its own links.
- No change to any library or event loop; adoption per library.
- Ownership decided by the application's wiring and never by a library's say-so.
- One table lookup per operation and per event.

**Non-Goals:**
- A sandbox. A library can still read memory or reach around its view (a module global, an import of the loop). Real isolation of untrusted code is a separate process.
- Quotas and address policy (separate proposals, built on this one).
- Removing a library at run time, or per-library event queues.
- Hiding that a link exists from the application.

## Decisions

**D1. A view is a value that the application builds for each call.** It holds the real `io`, the registry and the library's number. The application builds one as it calls a library (`lib.event(view(io, reg, me), ev)`), so no struct owns a loop and no view outlives the call. Rejected: a long-lived view stored in the application, which Goose's ownership rules do not allow for a reference to a loop; and a wrapper with the loop in a module global, which cannot be instantiated twice and so cannot give two libraries two views.

**D2. The registry is the one shared table.** It holds `links: LinkMap<Owner>` (an `Owner` is a library number), `listener_owner` (an array indexed by listener id, never reused, so lookup is one index), and the count of libraries. Memory is the loop's peak slot count times the size of an entry (8 bytes with the generation) plus a few bytes for each listener ever made. Library numbers come from `registry.add_library()`, in the order the application chooses.

**D3. Ownership is provenance.** A view's `dial` puts the link it got from the loop in the registry under its library; a view's `listen` records the listener. The registry learns an accepted link's owner when it routes the link's `Opened`, from the listener's owner. A library's return value (`true` for "mine") is not read at all. Rejected: learning owners from claims, which lets a library take another's link by claiming its first event.

**D4. Library operations and application operations are separate.** A library operation is a core operation other than `serve` and `stop`. A view supplies the ten library operations and, for each group the loop supplies, that group's operations. It does not supply `serve` or `stop`, so a library that calls them fails to compile and the error names the call. `require_library(io)` lets a layer check that it supplies exactly that set. Rejected: a view whose `stop` does nothing, which would let a library believe it had stopped the loop.

**D5. A foreign handle is an invalid handle.** The results are the ones the contract already gives for an invalid or stale handle, so a library that handles a stale link correctly handles this:

| Call | On a link or listener the library does not own |
|---|---|
| `send`, `send2` | `Closed` |
| `send_room` | 0 |
| `peer_address` | the empty value |
| `close`, `reset`, `pause_reading`, `set_keep_open_on_eof`, `shutdown_write` | no effect |
| `stop_listening` | no effect |
| `listener_port` | 0 |

`now_ms`, `max_send` and `draining` are not about a link and pass through. `tick_by` passes through here; `library-resource-limits` bounds it.

**D6. The application routes with the registry.** Two calls: `route(reg, ev)` returns the library an event is for (a number, `-1` for none, `TICK` for every library) and, for the `Opened` of an accepted link, records the owner; `done(reg, ev)` drops the entry after the library has handled a `Closed`. The application then calls only that library's event function with that library's view. The libraries' own ownership checks stay as they are (defence in depth). Rejected: a `deliver` helper that takes a block, because the libraries have different types, so the application's `match` on the library number is the simplest dispatch.

**D7. Where it lives.** `scope.goose` in the repository root, a pure-Goose file beside `goose_io.goose` and `deadlines.goose`, with its own namespace. `require_library` goes in `goose_io.goose`, because it is part of the contract surface. This keeps the contract file the same size and lets an application that does not want views not import them.

**D8. Views stack.** A view over a view, or over `tests/support/wrapper.goose`, works because each presents the same contract to the one above. A layer that needs ownership (a view) goes next to the libraries; a layer that changes bytes (TLS, logging) goes beneath it.

**D9. Tests are a matrix.** Every library operation is called with: a link the library owns, a link another library owns, a stale handle, a handle never issued, the invalid link, and a guessed slot and generation. The expected result for each is in D5. The example libraries run unchanged through views with their existing tests. `tests/checks/view_ops.sh` fails when an operation named in the contract's `require_*` checks has no function in `scope.goose`, so adding an operation to the contract cannot leave a hole in the view.

**D10. Cost is measured, not claimed.** The benchmark gains arms: offering in turn, routing by link, and a view plus the registry, for 2, 10 and 100 libraries. The figures go into `bench/README.md`. No gate: the point is a stated number.

**D11. What it does not protect.** A hostile library can still read process memory, loop forever in a handler (nothing preempts it), exhaust memory in its own state, and call anything it can import. The view protects against a library that uses `io` to reach what it does not own.

## Risks / Trade-offs

- [The view is the trusted code, and a missing operation or a wrong rule is a hole] → The matrix of D9, the view_ops check, and the hostile-library example.
- [A group's operation added later has no view function] → The same check fails the build of the change that adds it.
- [Each operation costs a lookup, and each event a lookup] → One lookup of a few nanoseconds (`bench/README.md`); D10 states it.
- [An application that forgets to call `done` leaves entries] → Harmless: a slot's next link has another generation and `put` replaces the entry.
- [A library that dials for itself cannot be refused by the application] → Out of scope here; `library-address-policy` refuses it in the view.

## Migration Plan

Nothing to migrate. An application adopts a view for a library by passing `view(io, reg, n)` where it passed `io`, and by calling `route` and `done`. A library does not change. `examples/scoped.goose` shows the whole change next to `examples/dispatch.goose`.

## Open Questions

- Should the application close an accepted link that no library owns by default, or should `route` say only that there is none? This design names none and leaves the decision to the application; the example closes it. A later proposal may add a default.
- Removing a library at run time (close its links, drop its entries) is left out. Decide with the first application that needs it.
