# Proposal

## Why

A library may `dial` and `listen` on any address string. A library that is given a URL by its user and dials it can be made to connect to a service the application never meant it to reach: a loopback admin port, a cloud metadata address, a unix socket path such as `/var/run/docker.sock`. This is server-side request forgery, and a library written for one protocol should not be able to reach an address that belongs to another. The same holds for `listen`: a library that opens `0.0.0.0:22` or a unix path in a shared directory takes something it was not given.

The event loop cannot decide this: it does not know which library is asking. A view does.

## What Changes

- Add an **address policy** to each library, given when the application adds the library to the registry. A policy is a list of allow rules; an address that matches no rule is refused. There is no default, and `allow_all()` is available for a library the application trusts.
- A rule for TCP names an address range (IPv4 or IPv6 CIDR) and a port range, separately for `dial` and `listen`. A rule for unix sockets names a path prefix.
- A view checks the address before the call reaches the loop. A refused `dial` returns the invalid link; a refused `listen` returns a `ListenError` of kind `Denied`.
- Add `Denied` to `ListenErrorKind`.
- A unix path with a `..` component is refused before it is matched, so a prefix cannot be escaped by name. The documents say what a path rule cannot do (symlinks are the operating system's, resolved after the check).
- Helpers: `allow_all()`, `loopback_only()`, `deny_unix()`.

Out of scope: resolving host names (an address is already the form the contract defines); firewalling a process; checking the address a peer reports.

## Capabilities

### New Capabilities

- `library-address-policy`: allow-lists for the addresses a library may dial and listen on.

### Modified Capabilities

None. `ListenErrorKind.Denied` is added to the contract in the same change; it is stated in the new capability so as not to reopen `io-contract`.

## Impact

- **goose-io:** `scope.goose` (`Policy`, the rules, the match, and the checks in `dial` and `listen`), `goose_io.goose` (`Denied` in `ListenErrorKind`), `tests/unit/`, `examples/scoped.goose` (a library that dials a forbidden address), `docs/contract.md`, `docs/libraries.md`.
- **Event loops:** an event loop that maps `ListenErrorKind` must map the new kind (it never produces it). A conformance case is not needed: the kind is made by the view alone.
- **Depends on:** `scoped-library-views`, applied first.
- **Risk:** a policy that is too strict fails a library's dials with no event. See the limits proposal for the same result.
