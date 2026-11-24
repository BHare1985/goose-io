## Context

Section 11 of `docs/contract.md` puts socket options in the event loop's configuration and advises loops to disable Nagle, as tcprouter does. The research attached to this proposal lists the per-socket options real servers set (nginx `tcp_nopush`, Envoy's per-cluster `TCP_NODELAY`, Redis and Postgres clients' `TCP_NODELAY`, gRPC's keepalive, `TCP_NOTSENT_LOWAT` in HTTP/2 servers). The same research suggested an automatic `MSG_MORE` within a pass, flushed on `PassEnd`. That is a loop's own optimisation, allowed today, and needs no operation. This change keeps configuration for the common case and adds a per-link override for libraries whose links differ.

## Goals / Non-Goals

**Goals:**

- A per-link way to ask for each common transport behaviour, stated by intent and not by socket option.
- A rule that makes every hint safe to ignore, so the in-memory loop, the wrapper, a TLS wrapping loop and any loop without the option conform without pretending.
- Hints observable in the in-memory loop, so their timing rules are tested.

**Non-Goals:**

- Exposing raw `setsockopt`: a library must not need to know the system.
- Buffer sizes, backlog and congestion algorithm: they stay configuration.
- Guaranteeing a hint's effect on the network: only its effect on when bytes are handed over is stated.

## Decisions

### D1. One operation and an enum, not an operation per option

`set_hint(link, hint, value)` with `Hint` keeps the capability one operation, and a new hint is a new enum value. *Alternative:* `set_no_delay`, `set_cork` and so on. Rejected: five operations for one idea, and each new option would be a new operation of the contract.

### D2. Intent names, not option names

`NoDelay` is close to its option. `Coalesce` covers `TCP_CORK`, `MSG_MORE` and an io_uring loop's linked sends. `SendLowWater` covers `TCP_NOTSENT_LOWAT` and a loop's own queue bound. A loop maps each name to what it has.

### D3. A hint changes timing only

The rule of the first requirement is what lets a loop ignore a hint and still conform, and what lets a library set one without a fallback path. `set_hint` returning whether it was applied lets a test, or a library that reports its settings, tell the difference.

### D4. Coalescing is bounded by the pass

`TCP_CORK` held forever would stall a reply. The contract bounds the hold by the end of the pass, which every loop has, so a library that sends in a burst and then returns to the loop loses no latency beyond the pass. A library that wants an earlier flush turns the hint off, which hands the bytes over.

### D5. Pacing is a hint

The research proposed a separate congestion capability with `set_pacing_rate`. Pacing changes timing only, so it fits the hint rule and needs no capability of its own. Reading the congestion state is `add-link-telemetry`.

### D6. Declaration, optional use and the fallback

The capability is declared as every capability is (`rename-groups-to-capabilities`, design D2): a default `fn supplies_transport_hints<Io>(io: Io&) -> Absent` and a query `fn has_transport_hints<Io>(io: Io&)` in `goose_io.goose`, and in a loop that supplies it `fn supplies_transport_hints(io: Loop&) -> goose_io::Supplied`. `require_transport_hints` names `set_hint` and requires the declaration. A wrapping loop forwards the declaration through `goose_io::has_transport_hints(w.inner)`.

A library uses hints optionally: `const if same<goose_io::has_transport_hints(io), goose_io::Supplied> { io.set_hint(link, goose_io::Hint.NoDelay, 1) }`. On a loop without the capability nothing happens and the loop's configuration applies. No fallback path is needed, because a hint never changes what is delivered.

### D7. Documentation: the capability's page

The change adds `docs/capabilities/transport-hints.md` with the fixed sections of `document-capabilities` (D2), so a library author can understand the capability and know when to reach for it without reading the normative contract:

- **What it is:** `set_hint` and the five hints, with the rule that a hint changes timing only; links to the normative section.
- **When to use it:** links of one loop that want different treatment (RPC beside bulk, idle beside busy, a slow client to pace). When not: every link wants the same thing (configure the loop), or the library needs a delivery guarantee (a hint gives none).
- **How it is commonly used:** `NoDelay` on request-reply links at `Opened`; `Coalesce` around a burst of `send`s that `PassEnd` ends; `SendLowWater` with `Writable` for a sender that produces fresh data on demand; `KeepAlive` beside a `Silent` limit; mistakes: expecting `Coalesce` to delay past the pass, treating `false` as an error.
- **Examples:** quoted, through `// doc:begin`/`// doc:end`, from `examples/capabilities/rpc_and_bulk.goose`, a small library (a server with a request-reply port that sets `NoDelay` and a bulk port that sets `Coalesce` and `SendLowWater`), and its test `tests/examples/capabilities/rpc_and_bulk_test.goose`, which runs on the in-memory loop and on the core-only loop, where it takes the fallback path.
- **Required or optional:** the `// Needs:` and `// Uses if supplied:` headers and the branch on `goose_io::has_transport_hints`, and the note that a hint needs no other path.
- **Supplied by:** the in-memory loop; not the core-only loop; the wrapper when its inner loop does; the mechanism each candidate loop would use (`TCP_NODELAY`, `TCP_CORK`/`MSG_MORE`, `SO_KEEPALIVE`, `TCP_NOTSENT_LOWAT`, `SO_MAX_PACING_RATE`; ignored by loops without them), linked to the mapping documents.

The page, its index row, the example and its test land in the same change as the operations, and the capability page check (`tests/checks/capability_pages.sh`) fails until they do. `docs/contract.md` gains a section for the capability that holds the normative rules and links to the page.

## Risks / Trade-offs

- [Hints differ between systems] → each is stated by intent and its effect on handing bytes over; the mapping documents record what each loop does.
- [`SendLowWater` interacts with sizing's `send_room`] → the requirement bounds `send_room` by the low water, and the suite checks both on the in-memory loop.
- [A capability no program uses yet] → it is specified, tested in memory and documented, and implemented on a real loop only when a program needs it. Its page says which loops supply it, so a library author is not misled.

## Migration Plan

Additive. A loop that does not supply the capability is unchanged: the default declaration answers `Absent`. No library changes. The change lands on a branch after `rename-groups-to-capabilities` and `document-capabilities`. Nothing is pushed or tagged without the owner's approval. Reverting is a revert of the merge.

## Open Questions

- Should a loop's configured defaults be readable (a `hint(link, kind)` query)? Not until a library needs it.
- Is `QuickAck` worth a hint? Left out: its effect lasts only until the next ack on Linux and it has no portable meaning.
