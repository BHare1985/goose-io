## Why

A server that runs one event loop per core needs each loop to accept connections. With `listen` only one loop can hold an address, so the others get `AddressInUse`, and the program must accept on one loop and move links to the others (`add-link-handoff`), paying a hand-off for every connection. `SO_REUSEPORT` on Linux and the BSDs lets several sockets listen on one address and has the kernel spread connections among them, so each loop accepts its own share with no hand-off. The research behind this proposal called it "ListenerSharing".

## What Changes

- Add the shared-listen capability: `listen_shared(address)` listens as `listen` does, except that any number of shared listeners, in any loops of the process, may hold the same address, and each connection is accepted by exactly one of them.
- State the conflict rules: a plain `listen` and a shared one on the same address conflict with `AddressInUse`, and so do shared listeners of different users or programs where the system says so.
- Declare the capability as every capability is declared (`supplies_shared_listen` and `goose_io::has_shared_listen`, from `rename-groups-to-capabilities`), with a compile-time check `require_shared_listen` naming every operation. Raise the contract's minor version by one.
- Add a conformance entry point for the capability, a check for every scenario, an implementation in the in-memory loop (a process-wide address table, round-robin), and a named fault for every check.
- Add `docs/capabilities/shared-listen.md`, the page that explains what the capability is, when a library would use it and when not, and how it is commonly used, with a checked example (`examples/capabilities/loop_per_core.goose`). Add its row to the index, as `document-capabilities` requires of every new capability.

Out of scope: steering connections to a chosen listener (eBPF `SO_ATTACH_REUSEPORT_EBPF`), sharing a listener's handle between loops (each loop holds its own listener), and unix paths, which cannot be shared.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: adds the shared listen capability: the operation `listen_shared(address) -> Listener, ListenError`, and the rules that bind a loop that supplies it.
- `provider-conformance`: adds the shared listen suite, its in-memory implementation and faults, and the rule for listing a real loop as supplying it.
- `contract-documentation`: adds the requirement that `docs/capabilities/shared-listen.md` exists and covers how connections are spread, what happens to connections waiting on a listener that stops, and when sharing is better than handing links off.

## Impact

- **goose-io code:** `goose_io.goose` (`listen_shared`, the declaration and query, `require_shared_listen`, minor version), `memory.goose`, `conformance/`, `tests/conformance/`, `tests/unit/`, the new example and its test. Pure Goose.
- **Libraries:** none changes. An application that runs a loop per core calls `listen_shared` on each.
- **Event loops:** unchanged unless they choose to supply the capability; a loop that does not supply it gets the default declaration, `Absent`, and needs no change. The mapping documents of the candidate loops gain a row (`SO_REUSEPORT` on Linux and the BSDs, `SO_REUSEPORT_LB` on FreeBSD; not on systems where it does not balance).
- **Documents:** `docs/capabilities/shared-listen.md`, its index row, a section in `docs/contract.md`, `docs/history.md`.
- **Order:** applies after `rename-groups-to-capabilities` and `document-capabilities` are accepted. It is independent of `add-stream-extras` and of the other capability proposals: it modifies no requirement another one modifies, so they apply in any order, and whichever lands later rebases only the version number.
- **Toolchain:** none new.
