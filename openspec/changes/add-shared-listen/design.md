## Context

`listen` gives `AddressInUse` for an address an active listener holds (core, *Listening*). tcprouter runs one loop. A loop per core is the usual way to use more cores with a loop that runs on one thread, and `SO_REUSEPORT` is the usual way to feed it. Linux resets connections queued on a closed reuseport socket unless `net.ipv4.tcp_migrate_req` is set, which is why the third requirement only asks a loop to document it.

## Goals / Non-Goals

**Goals:**

- Several loops of one process accept on one address with no hand-off.
- Keep `listen`'s conflict rule for everything else.

**Non-Goals:**

- Choosing which loop gets a connection.
- Sharing across processes of different users.

## Decisions

### D1. A separate operation, not a flag on listen

`listen` is core, and its `AddressInUse` rule is what protects a program from a second copy of itself. Sharing must be asked for on every listener that shares.

### D2. Exactly one acceptor per connection

This is the property a library relies on. Balance is the system's, and the contract does not promise it.

### D3. Waiting connections on stop are documented, not promised

Moving them is possible on recent Linux with a system setting and impossible elsewhere. A rule every loop could keep would be "may be reset", so the page tells programs to stop listening only when draining.

### D4. Declaration, optional use and the fallback

The capability is declared as every capability is (`rename-groups-to-capabilities`, design D2): a default `fn supplies_shared_listen<Io>(io: Io&) -> Absent` and a query `fn has_shared_listen<Io>(io: Io&)` in `goose_io.goose`, and in a loop that supplies it `fn supplies_shared_listen(io: Loop&) -> goose_io::Supplied`. `require_shared_listen` names `listen_shared` and requires the declaration. A wrapping loop forwards the declaration through `goose_io::has_shared_listen(w.inner)`.

An application uses it optionally: the `Supplied` branch starts a loop per thread with `listen_shared`, the other starts one loop with `listen` (or one acceptor loop that hands links off, when link-handoff is supplied). The choice is made once, at start.

### D5. Documentation: the capability's page

The change adds `docs/capabilities/shared-listen.md` with the fixed sections of `document-capabilities` (D2), so a library author can understand the capability and know when to reach for it without reading the normative contract:

- **What it is:** `listen_shared` and its conflict rules; links to the normative section.
- **When to use it:** a loop per core, each serving any connection. When not: one loop must see every connection (rate limits across the process, a single accept log); the system does not balance (the page lists them); unix paths.
- **How it is commonly used:** start N loops, each calling `listen_shared` before running; stop each listener when draining; mistakes: expecting even balance, stopping one listener of several outside a drain.
- **Examples:** quoted, through `// doc:begin`/`// doc:end`, from `examples/capabilities/loop_per_core.goose`, a small library (an echo server that starts a loop per thread, each with a shared listener on the same address), and its test `tests/examples/capabilities/loop_per_core_test.goose`, which runs on the in-memory loop, with two in-memory loops on one address.
- **Required or optional:** the `// Needs:` and `// Uses if supplied:` headers and the branch on `goose_io::has_shared_listen`.
- **Supplied by:** the in-memory loop; not the core-only loop; the wrapper when its inner loop does; the mechanism each candidate loop would use (`SO_REUSEPORT` on Linux and the BSDs, `SO_REUSEPORT_LB` on FreeBSD; not on systems where it does not balance), linked to the mapping documents.

The page, its index row, the example and its test land in the same change as the operations, and the capability page check (`tests/checks/capability_pages.sh`) fails until they do. `docs/contract.md` gains a section for the capability that holds the normative rules and links to the page.

## Risks / Trade-offs

- [Uneven balance] → the kernel's hash spreads by connection; the page says the contract promises no balance, only one acceptor.
- [A capability no program uses yet] → it is specified, tested in memory and documented, and implemented on a real loop only when a program needs it. Its page says which loops supply it, so a library author is not misled.

## Migration Plan

Additive. A loop that does not supply the capability is unchanged: the default declaration answers `Absent`. No library changes. The change lands on a branch after `rename-groups-to-capabilities` and `document-capabilities`. Nothing is pushed or tagged without the owner's approval. Reverting is a revert of the merge.

## Open Questions

- Should steering by a program (eBPF) be a later capability? Not until a program needs it.
