## Context

Section 11 of `docs/contract.md` names libpq, hiredis, libcurl and c-ares as clients that need descriptor readiness, and says it cannot be in the contract because loops without descriptors cannot supply it. Optional capabilities remove that objection. Their C APIs ask for read and write interest through add/remove or "want read/want write" callbacks, which map onto one-shot readiness with re-arming. One-shot is also what every substrate offers portably: `EPOLLONESHOT`, kqueue `EV_DISPATCH`, io_uring's single poll request.

## Goals / Non-Goals

**Goals:**

- Host C client libraries that own their sockets on any loop with descriptors.
- Be suppliable by readiness and completion loops alike.
- Test the rules without real descriptors.

**Non-Goals:**

- Timers, signals or files.
- Edge- or level-triggered modes: one-shot only.

## Decisions

### D1. One-shot with re-arm

Level-triggered readiness would flood a library that waits for the C client to want the next read. Edge-triggered loses an event if the library does not drain. One-shot plus `arm` is portable and matches C clients' want-read and want-write callbacks.

### D2. The library owns the descriptor

The C library opened it and will close it. A loop that closed it would race with the library. So the loop only watches, and `unwatch` must come first, which is the rule of every readiness API.

### D3. A library event

`Ready` belongs to the library that made the watch, like `Woken` and `Tick`, not to a link. It is not a link, so the core's link rules do not apply.

### D4. Simulated descriptors in memory

The in-memory loop has no descriptors. Its fixture makes numbered stand-ins that a test marks ready, enough to test one-shot, re-arm and unwatch. Real descriptors are tested by a loop that supplies the capability, in its own suite run.

### D5. Declaration, optional use and the fallback

The capability is declared as every capability is (`rename-groups-to-capabilities`, design D2): a default `fn supplies_descriptor_readiness<Io>(io: Io&) -> Absent` and a query `fn has_descriptor_readiness<Io>(io: Io&)` in `goose_io.goose`, and in a loop that supplies it `fn supplies_descriptor_readiness(io: Loop&) -> goose_io::Supplied`. `require_descriptor_readiness` names `watch_descriptor`, `arm` and `unwatch` and requires the declaration. A wrapping loop forwards the declaration through `goose_io::has_descriptor_readiness(w.inner)`.

A library that wraps a C client usually requires the capability (`// Needs:` header and `require_descriptor_readiness`). One that can do without it uses it optionally: the `Supplied` branch drives the client through `Ready`, the other runs the client's own blocking loop on a thread and reports through `wake_with`, or refuses to start with a clear error.

### D6. Documentation: the capability's page

The change adds `docs/capabilities/descriptor-readiness.md` with the fixed sections of `document-capabilities` (D2), so a library author can understand the capability and know when to reach for it without reading the normative contract:

- **What it is:** `watch_descriptor`, `arm`, `unwatch`, `Ready`, `Watch` and `Interest`; one-shot delivery and ownership; links to the normative section.
- **When to use it:** hosting a C library that owns its sockets (libpq, hiredis, libcurl multi, c-ares). When not: any connection the library can open with `dial`, which keeps the contract's guarantees and works on every loop.
- **How it is commonly used:** watch when the C client gives a socket, map its want-read and want-write to `arm`, call its process function on `Ready`, unwatch before it closes; drive its timers with `tick_by`; mistakes: forgetting to re-arm, closing before `unwatch`, reading the descriptor from two places.
- **Examples:** quoted, through `// doc:begin`/`// doc:end`, from `examples/capabilities/foreign_client.goose`, a small library (an adapter that drives a small C-style client (a pipe and a state machine standing for libpq) through `watch_descriptor`, `Ready` and `arm`), and its test `tests/examples/capabilities/foreign_client_test.goose`, which runs on the in-memory loop, over simulated descriptors, and on the core-only loop, where it refuses to start.
- **Required or optional:** the `// Needs:` and `// Uses if supplied:` headers and the branch on `goose_io::has_descriptor_readiness`.
- **Supplied by:** the in-memory loop; not the core-only loop; the wrapper when its inner loop does; the mechanism each candidate loop would use (`EPOLLONESHOT` on epoll, `EV_DISPATCH` on kqueue, `IORING_OP_POLL_ADD` on io_uring; not the in-memory loop with real descriptors), linked to the mapping documents.

The page, its index row, the example and its test land in the same change as the operations, and the capability page check (`tests/checks/capability_pages.sh`) fails until they do. `docs/contract.md` gains a section for the capability that holds the normative rules and links to the page.

## Risks / Trade-offs

- [A C library blocks the loop] → the page says to use only a library's non-blocking interface; the capability cannot prevent a blocking call.
- [Simulated descriptors miss a real loop's bug] → the third standard requirement makes every real loop pass the suite on real descriptors before it is listed.
- [A capability no program uses yet] → it is specified, tested in memory and documented, and implemented on a real loop only when a program needs it. Its page says which loops supply it, so a library author is not misled.

## Migration Plan

Additive. A loop that does not supply the capability is unchanged: the default declaration answers `Absent`. No library changes. The change lands on a branch after `rename-groups-to-capabilities` and `document-capabilities`. Nothing is pushed or tagged without the owner's approval. Reverting is a revert of the merge.

## Open Questions

- Should a readiness adapter for whole event-loop APIs (libuv-style) be a library on this capability? Section 12 keeps it open; decide with the first C client hosted.
