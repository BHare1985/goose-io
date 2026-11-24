## Why

`docs/contract.md` section 11 says an event loop never resolves names, and that resolution is "needed before the first real client: a resolver library on the contract, or a wake from another thread so a resolver thread can" report back. Wake is now in code, so a library can already run `getaddrinfo` on a thread of its own. But every client library would bring that thread, and a library cannot share it with the next one. Many loops already have a resolver: libuv's `uv_getaddrinfo` on its thread pool, libevent's evdns, c-ares beside any readiness loop, and an io_uring loop can run a resolver thread of its own. Making resolution a capability lets a client library dial a host name on any loop that resolves, and fall back to the thread-and-wake path on one that does not.

## What Changes

- Add the name-resolution capability: `resolve(host, port, timeout_ms)` starts a lookup and returns a `Query`. Its result arrives as the event `Resolved { query, status, count }`, and `resolved_address(query, i)` gives the `i`-th address, in an order a client should try them, while that event is handled.
- `cancel_resolve(query)` ends a lookup: no `Resolved` follows.
- `ResolveStatus` is `Found`, `NotFound`, `TimedOut`, `Failed` or `Cancelled`, for logs and fallbacks.
- Keep `dial` as it is: it still takes an address, never a host name, so the core's rule that a loop never resolves on its own path stays.
- Declare the capability as every capability is declared (`supplies_name_resolution` and `goose_io::has_name_resolution`, from `rename-groups-to-capabilities`), with a compile-time check `require_name_resolution` naming every operation. Raise the contract's minor version by one.
- Add a conformance entry point for the capability, a check for every scenario, an implementation in the in-memory loop (a scripted table of names), and a named fault for every check.
- Add `docs/capabilities/name-resolution.md`, the page that explains what the capability is, when a library would use it and when not, and how it is commonly used, with a checked example (`examples/capabilities/dial_by_name.goose`). Add its row to the index, as `document-capabilities` requires of every new capability.

Out of scope: connection racing between addresses ("happy eyeballs", a client library's job, which `docs/capabilities/name-resolution.md` shows), DNS records other than addresses (SRV, TXT), caching rules beyond the system's, and DNS over TLS or HTTPS.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: adds the name resolution capability: the operations `resolve`, `resolved_address` and `cancel_resolve`, the event `Resolved`, and the types `Query` and `ResolveStatus`, and the rules that bind a loop that supplies it.
- `provider-conformance`: adds the name resolution suite, its in-memory implementation and faults, and the rule for listing a real loop as supplying it.
- `contract-documentation`: adds the requirement that `docs/capabilities/name-resolution.md` exists and covers a lookup from `resolve` to `Resolved`, the order of the addresses and how to try them, and the fallback of a resolver thread with wake.

## Impact

- **goose-io code:** `goose_io.goose` (the types `Query` and `ResolveStatus`, the event `Resolved` and the three operations, the declaration and query, `require_name_resolution`, minor version), `memory.goose`, `conformance/`, `tests/conformance/`, `tests/unit/`, the new example and its test. Pure Goose.
- **Libraries:** none changes. A client library may resolve when the loop supplies it, and use its own resolver thread with wake otherwise.
- **Event loops:** unchanged unless they choose to supply the capability; a loop that does not supply it gets the default declaration, `Absent`, and needs no change. The mapping documents of the candidate loops gain a row (`getaddrinfo` on a thread pool (libuv), evdns (libevent), c-ares on a readiness loop, a resolver thread with a wake in an io_uring loop).
- **Documents:** `docs/capabilities/name-resolution.md`, its index row, a section in `docs/contract.md`, `docs/history.md`.
- **Order:** applies after `rename-groups-to-capabilities` and `document-capabilities` are accepted. It is independent of `add-stream-extras` and of the other capability proposals: it modifies no requirement another one modifies, so they apply in any order, and whichever lands later rebases only the version number.
- **Toolchain:** none new.
