## Why

A server that restarts to deploy a new version closes its listeners and the new process opens them again. Between the two, connections are refused, and those queued on the old socket are reset. Production servers avoid this by keeping the listening socket open across the restart: systemd socket activation hands the process sockets it already bound (`LISTEN_FDS`), and nginx, HAProxy and Envoy pass their listening sockets to the new process over a unix socket (`SCM_RIGHTS`). Neither fits today's contract, where a listener exists only through `listen`, which binds. The research behind this proposal called it "ProcessHandoff". Moving open links between loops is `add-link-handoff`. This change moves only listeners, and only between processes, which is what a restart needs.

## What Changes

- Add the listener-inheritance capability: `adopt_listener(address)` returns a listener for a socket the process inherited already listening on `address`, without binding, or fails with the new kind `NotInherited` when there is none.
- `export_listeners(to)` sends every listener of the loop, with the connections queued on it, to the process waiting on the unix path `to`, and stops them accepting in this loop. It returns how many it sent.
- State that how a loop comes to hold inherited listeners (systemd's environment, or a unix path to receive on) is the loop's configuration, set by the application.
- Declare the capability as every capability is declared (`supplies_listener_inheritance` and `goose_io::has_listener_inheritance`, from `rename-groups-to-capabilities`), with a compile-time check `require_listener_inheritance` naming every operation. Raise the contract's minor version by one.
- Add a conformance entry point for the capability, a check for every scenario, an implementation in the in-memory loop (a process-wide table standing for the hand-over), and a named fault for every check.
- Add `docs/capabilities/listener-inheritance.md`, the page that explains what the capability is, when a library would use it and when not, and how it is commonly used, with a checked example (`examples/capabilities/graceful_restart.goose`). Add its row to the index, as `document-capabilities` requires of every new capability.

Out of scope: moving open links to another process, moving listeners between loops of one process (use `listen_shared` from `add-shared-listen`), the upgrade protocol around the hand-over (signals, health checks), and systemd's notification protocol.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: adds the listener inheritance capability: the operations `adopt_listener(address) -> Listener, ListenError` and `export_listeners(to) -> i64`, and the listen error kind `NotInherited`, and the rules that bind a loop that supplies it.
- `provider-conformance`: adds the listener inheritance suite, its in-memory implementation and faults, and the rule for listing a real loop as supplying it.
- `contract-documentation`: adds the requirement that `docs/capabilities/listener-inheritance.md` exists and covers a restart that refuses no connection, step by step, what moves with a listener, and the two ways a process inherits listeners.

## Impact

- **goose-io code:** `goose_io.goose` (the listen error kind `NotInherited` and the two operations, the declaration and query, `require_listener_inheritance`, minor version), `memory.goose`, `conformance/`, `tests/conformance/`, `tests/unit/`, the new example and its test. Pure Goose.
- **Libraries:** a library that matches `ListenErrorKind` with no default arm adds `NotInherited`. A server library gains nothing to do: the application chooses between `listen` and `adopt_listener`.
- **Event loops:** unchanged unless they choose to supply the capability; a loop that does not supply it gets the default declaration, `Absent`, and needs no change. The mapping documents of the candidate loops gain a row (`LISTEN_FDS`/`LISTEN_FDNAMES` from systemd and `SCM_RIGHTS` over a unix socket on Linux and the BSDs; a process-wide table between in-memory loops).
- **Documents:** `docs/capabilities/listener-inheritance.md`, its index row, a section in `docs/contract.md`, the `ListenErrorKind` table of `docs/contract.md`, `docs/history.md`.
- **Order:** applies after `rename-groups-to-capabilities` and `document-capabilities` are accepted. It is independent of `add-stream-extras` and of the other capability proposals: it modifies no requirement another one modifies, so they apply in any order, and whichever lands later rebases only the version number, and any change that also adds a `ListenErrorKind` value.
- **Toolchain:** none new.
