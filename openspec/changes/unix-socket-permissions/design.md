# Design

## Context

`add-unix-sockets` put `unix://` addresses in the contract and left the file to the event loop. The in-memory loop has a path table but no files. The epoll proposal records an open question about the unix group; this proposal gives its answer a contract to meet.

## Goals / Non-Goals

**Goals:** a library cannot take or leave behind a socket file by accident; the default is safe.
**Non-Goals:** a mode or owner in the contract, abstract names, peer credentials.

## Decisions

**D1. An existing path fails with `AddressInUse`; the loop never unlinks a path to listen.** The common server habit of removing a stale socket first lets any library take any path. A stale file left by a crashed process is the application's to remove, deliberately. Rejected: unlink-then-bind, which is the hole.

**D2. Owner-only by default, set through the loop's configuration.** The contract has no mode because a mode is an operating-system word, and the contract keeps those out. A loop creates the file with the safe mode (`0600`, applied through the process umask or an explicit change before the file is reachable) unless its own configuration says otherwise. The documents say how each loop does it.

**D3. The loop removes only what it created.** It records the paths it made. A `listen` that failed with `AddressInUse` made nothing, so nothing is removed on stop. This is the property that makes D1 safe: no sequence of calls removes a file another party made.

**D4. Conformance covers the path, not the mode.** The in-memory loop's path table can show D1 and D3 (and the existing `AddressInUse` case for TCP is the model). The mode is stated in the document and tested by the loop's own tests.

**D5. The check is on the documents.** `event_loops.sh` requires a "Unix" section in each mapping document, as it requires "Closing" and "Known gaps". A loop that has no unix group says so there.

## Risks / Trade-offs

- [A crashed process leaves a file that blocks the next start] → The application removes it, knowing it is stale. The document tells the application so; this is the cost of D1.
- [Removing a file on finish can fail] → A failure to remove is not reported to a library; the loop's own log says so. Stated in the documents.
- [An owner-only mode stops a client of another user from connecting] → The application sets the mode it wants through the loop; the default is the safe one.

## Open Questions

- Does the epoll loop supply the unix group? That is the owner's decision and is recorded in `epoll-event-loop`. If it does not, its document says so and the requirements do not apply to it.
