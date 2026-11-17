# Proposal

## Why

The contract carries `unix://` addresses, and an event loop that supplies the unix group makes socket files on a shared file system. The contract says nothing about the file. Three things go wrong in a loop that does not take care:

- `listen` on a path that already exists replaces or removes it, so a library can take another service's socket path.
- The new socket file is created with the process's default mode, which is often readable and writable by other users.
- The file is left behind when the loop finishes, so the next `listen` on the path fails with `AddressInUse` for no live reason, or a different process takes the path.

These are properties of the event loop, not of a library, so they belong in the contract and in each loop's mapping document.

## What Changes

- Add requirements to the unix group: `listen` on a path that exists SHALL fail with `AddressInUse` and SHALL NOT remove or replace it; a socket file the loop creates SHALL be accessible by its owner only unless the application says otherwise; a socket file the loop created SHALL be removed when its listener is stopped and when the loop finishes.
- Add a conformance case set for what the in-memory loop can show (the path is not replaced, the path is free after `stop_listening` and after `serve` returns), and a document check that each `docs/event-loops/*.md` has a "Unix" section stating how the loop meets the three requirements, or that it supplies no unix group.
- Add to `memory.goose` the path table behavior needed for the cases.

Out of scope: setting the mode or owner through the contract (the application sets it through the event loop's own configuration); abstract names (`unix://@name`), which have no file; peer credentials.

## Capabilities

### New Capabilities

- `unix-socket-permissions`: what an event loop does to the socket file.

### Modified Capabilities

None.

## Impact

- **goose-io:** `docs/contract.md`, `memory.goose`, `conformance/`, `tests/conformance/checks.tsv`, `tests/checks/event_loops.sh`, every `docs/event-loops/*.md`.
- **Event loops:** a loop with a unix group must follow the three requirements; the mapping documents say how.
- **Independent** of the view proposals, and may be applied before or after them.
- **Cannot be tested:** the in-memory loop has no file system, so the mode cannot be conformance-tested; the mapping documents state it and the epoll loop's own tests cover it when it is built.
