## Context

`listen` gives `Opened` as soon as a connection is accepted. Clients that never send cost the server an event, a slot and the timer it arms. tcprouter arms a `Silent` limit for exactly this case. Kernel filters keep such connections out of the accept queue. The research attached to this proposal lists this under "DeferredAccept".

## Goals / Non-Goals

**Goals:**

- Wake a server only for connections that have sent something.
- Bound the wait, so a slow but honest client is still served.
- Conform without a kernel filter.

**Non-Goals:**

- Filtering by protocol (a complete HTTP request).
- Dropping silent connections without the library's knowledge after the timeout: the library decides.

## Decisions

### D1. A listener operation

Deferring is a property of how a listener accepts, and `listen` is core and unchanged. *Alternative:* a `listen_with` taking options. Rejected for this change: each listener option is its own capability (shared-listen, early-data), so a loop declares exactly what it supplies.

### D2. Opened at the timeout, not a silent drop

Linux accepts at the timeout, while FreeBSD's filter waits forever. Delivering `Opened` at `ms` is the behaviour a user-space hold can give on every system, and it leaves the decision to close to the library.

### D3. Opened and the first Data in one pass

The point is that the library is woken once with something to do. Delivering both in one pass lets it answer in the same pass.

### D4. Declaration, optional use and the fallback

The capability is declared as every capability is (`rename-groups-to-capabilities`, design D2): a default `fn supplies_deferred_accept<Io>(io: Io&) -> Absent` and a query `fn has_deferred_accept<Io>(io: Io&)` in `goose_io.goose`, and in a loop that supplies it `fn supplies_deferred_accept(io: Loop&) -> goose_io::Supplied`. `require_deferred_accept` names `defer_accept` and requires the declaration. A wrapping loop forwards the declaration through `goose_io::has_deferred_accept(w.inner)`.

A server uses it optionally: after `listen`, the `Supplied` branch calls `io.defer_accept(listener, 1000)`. The other branch does nothing, and the server, which already handles links that open and send later, behaves as today. No other path is needed.

### D5. Documentation: the capability's page

The change adds `docs/capabilities/deferred-accept.md` with the fixed sections of `document-capabilities` (D2), so a library author can understand the capability and know when to reach for it without reading the normative contract:

- **What it is:** `defer_accept`, when `Opened` is delivered and what happens at the timeout; links to the normative section.
- **When to use it:** servers of protocols where the client speaks first (HTTP, TLS, line protocols), under many idle or hostile connections. When not: protocols where the server speaks first (SMTP, banners), or a library that must count every connection.
- **How it is commonly used:** call it once after `listen` with a time a little above the slowest honest client; keep the `Silent` limit for links that send a byte and stall; mistakes: deferring a server-speaks-first protocol, relying on deferral to drop floods (it only delays them).
- **Examples:** quoted, through `// doc:begin`/`// doc:end`, from `examples/capabilities/deferred_server.goose`, a small library (a line server that defers accept, so every `Opened` it sees has a request behind it), and its test `tests/examples/capabilities/deferred_server_test.goose`, which runs on the in-memory loop and on the core-only loop, where it takes the fallback path.
- **Required or optional:** the `// Needs:` and `// Uses if supplied:` headers and the branch on `goose_io::has_deferred_accept`, and the note that the other path is to do nothing.
- **Supplied by:** the in-memory loop; not the core-only loop; the wrapper when its inner loop does; the mechanism each candidate loop would use (`TCP_DEFER_ACCEPT` on Linux, `SO_ACCEPTFILTER` `dataready` on FreeBSD, a user-space hold elsewhere), linked to the mapping documents.

The page, its index row, the example and its test land in the same change as the operations, and the capability page check (`tests/checks/capability_pages.sh`) fails until they do. `docs/contract.md` gains a section for the capability that holds the normative rules and links to the page.

## Risks / Trade-offs

- [A server-speaks-first protocol deferred by mistake] → the page says so in its first section, and the example's test shows the cost: the client waits the full time.
- [A capability no program uses yet] → it is specified, tested in memory and documented, and implemented on a real loop only when a program needs it. Its page says which loops supply it, so a library author is not misled.

## Migration Plan

Additive. A loop that does not supply the capability is unchanged: the default declaration answers `Absent`. No library changes. The change lands on a branch after `rename-groups-to-capabilities` and `document-capabilities`. Nothing is pushed or tagged without the owner's approval. Reverting is a revert of the merge.

## Open Questions

- Should the loop report how many connections ended while deferred? Left to the loop's own statistics.
