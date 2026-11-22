## Why

A program with one loop per thread sometimes needs to move a connection from the loop that has it to another: an acceptor that reads the first request and sends the link to the worker that owns that tenant, a loop that is shutting down and gives its links to the others, a session that must live on the thread that holds its state. Envoy and Seastar do this with connection handoff. Today a link cannot leave its loop: the only option is to relay it through a pair of links, which keeps the first loop busy for the link's life. The research behind this proposal called it "ConnectionMigration" and "LinkMigration", and paired it with passing sockets to another process, which is `add-listener-inheritance` here.

## What Changes

- Add the link-handoff capability: `hand_off(link)` takes an open link away from its loop and returns a `Ticket`. The link gets its `Closed` with the new reason `HandedOff` and the connection stays open.
- `adopt(ticket)`, called on another loop of the same kind in the same process, returns a new link for the connection, whose `Opened` follows. Bytes the first loop had accepted are sent before any the new one accepts. Bytes received and not delivered are delivered as the new link's first `Data`.
- A `Ticket` is a small value that can be sent between threads, for example in the body of `wake_with`. `drop_ticket` closes a connection whose ticket will not be adopted.
- Declare the capability as every capability is declared (`supplies_link_handoff` and `goose_io::has_link_handoff`, from `rename-groups-to-capabilities`), with a compile-time check `require_link_handoff` naming every operation. Raise the contract's minor version by one.
- Add a conformance entry point for the capability, a check for every scenario, an implementation in the in-memory loop (links moved between in-memory loops), and a named fault for every check.
- Add `docs/capabilities/link-handoff.md`, the page that explains what the capability is, when a library would use it and when not, and how it is commonly used, with a checked example (`examples/capabilities/acceptor_workers.goose`). Add its row to the index, as `document-capabilities` requires of every new capability.

Out of scope: passing a link to another process (`SCM_RIGHTS` for links), adopting on a loop of another kind, and carrying a link's settings (keep-open, limits, hints): the adopting library sets them at `Opened`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: adds the link handoff capability: the operations `hand_off(link) -> Ticket`, `adopt(ticket) -> Link` and `drop_ticket(ticket)`, the type `Ticket`, and the close reason `HandedOff`, and the rules that bind a loop that supplies it.
- `provider-conformance`: adds the link handoff suite, its in-memory implementation and faults, and the rule for listing a real loop as supplying it.
- `contract-documentation`: adds the requirement that `docs/capabilities/link-handoff.md` exists and covers what moves with the link and what does not, how a ticket crosses threads, and when handing off beats sharing a listener or relaying.

## Impact

- **goose-io code:** `goose_io.goose` (the type `Ticket`, the close reason `HandedOff` and the three operations, the declaration and query, `require_link_handoff`, minor version), `memory.goose`, `conformance/`, `tests/conformance/`, `tests/unit/`, the new example and its test. Pure Goose.
- **Libraries:** a library that matches `CloseReason` with no default arm adds `HandedOff`. None that use `_ =>` change.
- **Event loops:** unchanged unless they choose to supply the capability; a loop that does not supply it gets the default declaration, `Absent`, and needs no change. The mapping documents of the candidate loops gain a row (moving the descriptor between epoll sets or io_uring rings in one process; a link table between in-memory loops).
- **Documents:** `docs/capabilities/link-handoff.md`, its index row, a section in `docs/contract.md`, the `CloseReason` table of `docs/contract.md`, `docs/history.md`.
- **Order:** applies after `rename-groups-to-capabilities` and `document-capabilities` are accepted. It is independent of `add-stream-extras` and of the other capability proposals: it modifies no requirement another one modifies, so they apply in any order, and whichever lands later rebases only the version number, and any change that also adds a `CloseReason` value.
- **Toolchain:** none new.
