## Context

Section 11 of `docs/contract.md`: "An event loop never resolves; a host name given to `dial` fails with `ConnectFailed`, `BadAddress`." The same row names a resolver library or a wake as the way forward, and section 12 keeps name resolution open. The wake capability (`wake_with`, a 64-byte body) is in code, so the fallback is available on every loop with wake. `Address` holds 56 bytes of text.

## Goals / Non-Goals

**Goals:**

- Let a client library dial a host name on any loop that resolves, with one call and one event.
- Bound every lookup in time.
- Keep `dial` unchanged.

**Non-Goals:**

- Connection racing (happy eyeballs): shown on the page, done by the client.
- Record types other than addresses.

## Decisions

### D1. Resolve, then dial

A separate step keeps `dial` as the core defines it and makes the cost of a lookup visible. *Alternative:* `dial_name(host, port)`. Rejected: it hides which address was tried and makes racing impossible to write.

### D2. A count in the event, addresses by call

Putting a list of addresses in `Resolved` would make every `Event` as large as the list. `count` and `resolved_address` keep the event small and the addresses lent until the handler returns, like `Data`'s bytes.

### D3. Order is the system's

`getaddrinfo` orders addresses by RFC 6724. The contract passes that order on, so a client that tries addresses in order does what the system advises.

### D4. Wake is the fallback

On a loop without the capability, a library runs a lookup on a thread and sends each address back in a `wake_with` body (an `Address` fits in 64 bytes). The example and the page show both paths, so a client library is never without one.

### D5. Declaration, optional use and the fallback

The capability is declared as every capability is (`rename-groups-to-capabilities`, design D2): a default `fn supplies_name_resolution<Io>(io: Io&) -> Absent` and a query `fn has_name_resolution<Io>(io: Io&)` in `goose_io.goose`, and in a loop that supplies it `fn supplies_name_resolution(io: Loop&) -> goose_io::Supplied`. `require_name_resolution` names `resolve`, `resolved_address` and `cancel_resolve` and requires the declaration. A wrapping loop forwards the declaration through `goose_io::has_name_resolution(w.inner)`.

A client library uses it optionally: the `Supplied` branch calls `io.resolve(host, port, ms)` and dials from `Resolved`. The branch for a loop with wake but no resolution starts a resolver thread that sends each address in a `wake_with` body. On a loop with neither, the library accepts only addresses.

### D6. Documentation: the capability's page

The change adds `docs/capabilities/name-resolution.md` with the fixed sections of `document-capabilities` (D2), so a library author can understand the capability and know when to reach for it without reading the normative contract:

- **What it is:** `resolve`, `Resolved`, `resolved_address`, `cancel_resolve` and `ResolveStatus`; the address order; links to the normative section.
- **When to use it:** any client given a host name. When not: addresses known in advance (dial them), or a library that must control DNS itself (its own resolver over descriptor readiness).
- **How it is commonly used:** resolve, dial the first address in the `Resolved` handler, on `ConnectFailed` dial the next, optionally race a second after 250 ms; mistakes: keeping addresses past the handler, passing a host name to `dial`.
- **Examples:** quoted, through `// doc:begin`/`// doc:end`, from `examples/capabilities/dial_by_name.goose`, a small library (a client that resolves a host name and tries each address in turn until one opens, with the resolver-thread fallback), and its test `tests/examples/capabilities/dial_by_name_test.goose`, which runs on the in-memory loop and on the core-only loop, where it takes the fallback path.
- **Required or optional:** the `// Needs:` and `// Uses if supplied:` headers and the branch on `goose_io::has_name_resolution`.
- **Supplied by:** the in-memory loop; not the core-only loop; the wrapper when its inner loop does; the mechanism each candidate loop would use (`getaddrinfo` on a thread pool (libuv), evdns (libevent), c-ares on a readiness loop, a resolver thread with a wake in an io_uring loop), linked to the mapping documents.

The page, its index row, the example and its test land in the same change as the operations, and the capability page check (`tests/checks/capability_pages.sh`) fails until they do. `docs/contract.md` gains a section for the capability that holds the normative rules and links to the page.

## Risks / Trade-offs

- [A blocking resolver stalls the loop] → the requirement bounds time on the loop's clock, and every candidate mechanism runs off the loop's thread; the page says a loop must never call `getaddrinfo` on its own thread.
- [A capability no program uses yet] → it is specified, tested in memory and documented, and implemented on a real loop only when a program needs it. Its page says which loops supply it, so a library author is not misled.

## Migration Plan

Additive. A loop that does not supply the capability is unchanged: the default declaration answers `Absent`. No library changes. The change lands on a branch after `rename-groups-to-capabilities` and `document-capabilities`. Nothing is pushed or tagged without the owner's approval. Reverting is a revert of the merge.

## Open Questions

- Should `Resolved` carry the time to live of the records? Not until a client caches.
