# Proposal

## Why

Many servers that a library on this contract has to reach listen on a Unix domain socket as well as, or instead of, TCP: PostgreSQL's default on the same machine, Redis, anything behind a local proxy. The contract excludes them ("What the contract covers" lists Unix sockets among what an event loop is not required to do), with a note in `docs/contract.md` that `unix:/path` can be added as an address form without changing any operation. The first real client ported to the contract, a PostgreSQL pool, runs into it: its existing source builds `unix:/dir/.s.PGSQL.5432` for a same-machine server, and the contract can only answer `BadAddress`.

The contract is now a core plus optional groups, and a group is the place for something an event loop may supply and a library asks for by name. A Unix address form is that: no operation or event of the core changes, a loop without it stays conforming, and a library that does not use it never notices.

## What Changes

- Add a sixth group of extras, **unix**: an event loop that supplies it accepts `unix:/absolute/path` in `listen` and `dial`, naming a connection-oriented stream socket, with the operations, events and rules the core already has. The group adds no operation, event or type, so, like batching, it has no compile-time check.
- A loop that does not supply the group answers `BadAddress` to the text, as it does to any address it does not accept, and a library already handles that.
- The path is absolute, at most 103 bytes (the smallest `sun_path` of the common systems, less the terminator), with no NUL byte and no leading `@`. Abstract names and relative paths are malformed.
- A listener on a path has no port: `listener_port` returns 0. A path is held by one listener and `AddressInUse` follows a second `listen`; a dial to a path nothing listens on is `Refused`.
- `peer_address` returns the empty value for a link made on a path (`Address` holds 56 bytes, and the peer of an accepted Unix connection has no name). This rule binds a loop that supplies both the unix and inspection groups.
- The in-memory event loop supplies the group, treating a path as the name of an endpoint, and can be configured to refuse the form; the core-only loop of the tests refuses it.
- The conformance suite gets a unix entry point and its checks, each with a recorded fault, and the fixture gains one field: a path the loop may use.
- Raise the contract's minor version to 0.2, and update `docs/contract.md`, `docs/event-loops.md` and `README.md`: six groups, and Unix sockets no longer listed as not covered.

Out of scope: abstract-namespace sockets, relative paths, other socket types, peer credentials, descriptor passing, and any socket-backed event loop (the reference epoll loop is the separate change `epoll-event-loop`, which may add the group when it is applied). The mapping documents of candidate loops (`docs/event-loops/`) get no row, since the group has no operation or event. Changes to libraries are separate.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: adds the requirements of the unix group (the form, its path rules, a held path and no port, no peer text), and amends the five requirements that say addresses are numeric, that name five groups, that a failed dial's `BadAddress` is for non-numeric text, and that Unix sockets are not covered.
- `provider-conformance`: adds the unix group's suite and its checks, and the in-memory event loop's support for the form and its ability to refuse it.

## Impact

- **goose-io:** `memory.goose` (address parsing and matching, scripted peers, the configuration, the faults), `goose_io.goose` (the version and comments), `conformance/support.goose`, `conformance/suite.goose` and `conformance/net.goose` (the group, its entry point and checks, the fixture field), `tests/conformance/` (the check table, the runners, the group check), `tests/support/core_only.goose`, `tests/unit/`, `docs/contract.md`, `docs/event-loops.md`, `README.md`.
- **Event loops and libraries:** no operation's signature changes, so no event loop breaks and no library needs a change. A library that wants a path passes `unix:/path` to `dial` or `listen`; the group's compile-time view is a loop's own claim, as for batching.
- **Other changes:** `epoll-event-loop` says its loop supplies "every group"; with a sixth group that is the owner's call at the time it is applied, and nothing there is edited by this change.
- **Downstream:** the goose-postgres adaptation changes by a few lines once this is applied (the last task group), so that a host of `/var/run/postgresql` works as on goose-http.
- **Risk:** only the in-memory loop supplies the group until a socket-backed loop does, so the form is exercised by name matching, not by a file system.
