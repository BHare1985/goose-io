## Context

A listener exists only through `listen` (core). `stop_listening` (inspection) closes the socket. systemd passes sockets as descriptors 3 onward with `LISTEN_FDS` and names them with `LISTEN_FDNAMES`. nginx's binary upgrade passes them through the environment, and Envoy's hot restart and HAProxy's seamless reload over a unix socket with `SCM_RIGHTS`. The research attached to this proposal listed this with link migration as "ProcessHandoff".

## Goals / Non-Goals

**Goals:**

- A restart that refuses no connection and resets none that were queued.
- Both common ways of inheriting: from a supervisor and from the previous process.

**Non-Goals:**

- Moving open links between processes.
- The upgrade protocol: when to start the new process and when the old one exits are the application's.

## Decisions

### D1. Adopt by address

An address is what the application already gives `listen`, so `adopt_listener(address)` then `listen(address)` on `NotInherited` is one line of difference. *Alternative:* by systemd name or index. Rejected: names exist only under systemd, and the address identifies the socket in both cases.

### D2. A new listen error kind

The fall back to `listen` must be decided by kind, not by parsing a message. `NotInherited` is one enum value; a library with a default arm needs no change.

### D3. Export sends all listeners at once

A restart moves the whole server. Sending all of a loop's listeners in one call keeps the old process from accepting on some and not others. A program with several loops exports from each.

### D4. Receiving is configuration

The new process must be ready to receive before its first `adopt_listener`, which is before the library runs. So how the loop receives (the systemd environment, or a path to receive on) is set when the application constructs it, as other loop settings are.

### D5. Declaration, optional use and the fallback

The capability is declared as every capability is (`rename-groups-to-capabilities`, design D2): a default `fn supplies_listener_inheritance<Io>(io: Io&) -> Absent` and a query `fn has_listener_inheritance<Io>(io: Io&)` in `goose_io.goose`, and in a loop that supplies it `fn supplies_listener_inheritance(io: Loop&) -> goose_io::Supplied`. `require_listener_inheritance` names `adopt_listener` and `export_listeners` and requires the declaration. A wrapping loop forwards the declaration through `goose_io::has_listener_inheritance(w.inner)`.

An application uses it optionally at start: the `Supplied` branch tries `adopt_listener` and falls back to `listen` on `NotInherited`, and at shutdown exports before draining. The other branch listens and stops listening as today.

### D6. Documentation: the capability's page

The change adds `docs/capabilities/listener-inheritance.md` with the fixed sections of `document-capabilities` (D2), so a library author can understand the capability and know when to reach for it without reading the normative contract:

- **What it is:** `adopt_listener`, `export_listeners` and `NotInherited`; what moves with a listener; links to the normative section.
- **When to use it:** zero-downtime restarts and upgrades, and servers started by systemd socket activation. When not: a server that may refuse for a moment, or several loops of one process (shared-listen).
- **How it is commonly used:** start: adopt, else listen; restart: start the new process, export to it, drain links, exit; mistakes: exporting before the new process receives (returns -1, nothing lost), closing links at export (they drain).
- **Examples:** quoted, through `// doc:begin`/`// doc:end`, from `examples/capabilities/graceful_restart.goose`, a small library (an old server that exports its listener and drains its links, and a new one that adopts it, with a client that connects throughout and is never refused), and its test `tests/examples/capabilities/graceful_restart_test.goose`, which runs on the in-memory loop, with two in-memory loops standing for the two processes.
- **Required or optional:** the `// Needs:` and `// Uses if supplied:` headers and the branch on `goose_io::has_listener_inheritance`.
- **Supplied by:** the in-memory loop; not the core-only loop; the wrapper when its inner loop does; the mechanism each candidate loop would use (`LISTEN_FDS`/`LISTEN_FDNAMES` from systemd and `SCM_RIGHTS` over a unix socket on Linux and the BSDs; a process-wide table between in-memory loops), linked to the mapping documents.

The page, its index row, the example and its test land in the same change as the operations, and the capability page check (`tests/checks/capability_pages.sh`) fails until they do. `docs/contract.md` gains a section for the capability that holds the normative rules and links to the page.

## Risks / Trade-offs

- [A new process that crashes after adopting loses the listener] → the page says a supervisor (systemd) holding the socket is the safer way, and export returns -1 when nothing receives.
- [A capability no program uses yet] → it is specified, tested in memory and documented, and implemented on a real loop only when a program needs it. Its page says which loops supply it, so a library author is not misled.

## Migration Plan

Additive. A loop that does not supply the capability is unchanged: the default declaration answers `Absent`. A library that matches `ListenErrorKind` with no default arm adds `NotInherited`. The change lands on a branch after `rename-groups-to-capabilities` and `document-capabilities`. Nothing is pushed or tagged without the owner's approval. Reverting is a revert of the merge.

## Open Questions

- Should `export_listeners` take a single listener? Not until a program moves part of a server.
