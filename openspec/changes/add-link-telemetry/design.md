## Context

The contract reports a link's peer address (inspection), its relayed bytes (relay) and its time in a state (limits). It does not report the transport's measurements. tcprouter logs bytes and durations it counts itself. The research attached to this proposal listed `TCP_INFO`, `TCP_CM_INQ` and `SO_MAX_PACING_RATE` under "CongestionControl" and "LinkTelemetry".

## Goals / Non-Goals

**Goals:**

- One read of a link's transport state, portable by naming quantities, not socket structures.
- Unknown stated as unknown.

**Non-Goals:**

- Events on changes (a library samples when it decides).
- Every field of `TCP_INFO`: the ones a library decides by.

## Decisions

### D1. A struct read on demand

`LinkStats` is a plain struct returned by value, so one call is one system call on a real loop. *Alternative:* an operation per field. Rejected: a decision reads several fields of one moment.

### D2. -1 for unknown

Zero is a real round-trip time on loopback and a real retransmit count. -1 cannot be confused with a measurement.

### D3. Read only

Pacing changes timing and is a hint (`add-transport-hints`, its D5). Keeping this capability read-only means a loop can supply it with nothing but counters.

### D4. Declaration, optional use and the fallback

The capability is declared as every capability is (`rename-groups-to-capabilities`, design D2): a default `fn supplies_link_telemetry<Io>(io: Io&) -> Absent` and a query `fn has_link_telemetry<Io>(io: Io&)` in `goose_io.goose`, and in a loop that supplies it `fn supplies_link_telemetry(io: Loop&) -> goose_io::Supplied`. `require_link_telemetry` names `link_stats` and requires the declaration. A wrapping loop forwards the declaration through `goose_io::has_link_telemetry(w.inner)`.

A library uses it optionally: the `Supplied` branch reads `io.link_stats(link).rtt_us`, the other uses its own measure (time from send to reply, or bytes counted). The example's backend choice falls back to round-robin.

### D5. Documentation: the capability's page

The change adds `docs/capabilities/link-telemetry.md` with the fixed sections of `document-capabilities` (D2), so a library author can understand the capability and know when to reach for it without reading the normative contract:

- **What it is:** `link_stats` and every field of `LinkStats`, with the unknown rule; links to the normative section.
- **When to use it:** choosing between backends by measured transport state, shedding load as round-trip times grow, logging transport quality. When not: deciding whether a link moves at all (limits are cheaper and need no polling), or reading on every `Data` (sample on `Tick`).
- **How it is commonly used:** sample on `Tick` for the links that matter; log a link's stats in its `Closed` handler; treat -1 as unknown in every comparison; mistakes: comparing -1 as a value, reading per event on a busy loop.
- **Examples:** quoted, through `// doc:begin`/`// doc:end`, from `examples/capabilities/least_rtt.goose`, a small library (a forwarder that sends each new client to the backend whose links report the lowest round-trip time), and its test `tests/examples/capabilities/least_rtt_test.goose`, which runs on the in-memory loop and on the core-only loop, where it takes the fallback path.
- **Required or optional:** the `// Needs:` and `// Uses if supplied:` headers and the branch on `goose_io::has_link_telemetry`.
- **Supplied by:** the in-memory loop; not the core-only loop; the wrapper when its inner loop does; the mechanism each candidate loop would use (`TCP_INFO` and `TCP_CM_INQ` on Linux, `TCP_CONNECTION_INFO` on macOS, `TCP_INFO` on FreeBSD; the loop's own counters everywhere), linked to the mapping documents.

The page, its index row, the example and its test land in the same change as the operations, and the capability page check (`tests/checks/capability_pages.sh`) fails until they do. `docs/contract.md` gains a section for the capability that holds the normative rules and links to the page.

## Risks / Trade-offs

- [The fields differ between systems] → each is defined by meaning and the mapping documents record its source per system; unknown is -1.
- [A capability no program uses yet] → it is specified, tested in memory and documented, and implemented on a real loop only when a program needs it. Its page says which loops supply it, so a library author is not misled.

## Migration Plan

Additive. A loop that does not supply the capability is unchanged: the default declaration answers `Absent`. No library changes. The change lands on a branch after `rename-groups-to-capabilities` and `document-capabilities`. Nothing is pushed or tagged without the owner's approval. Reverting is a revert of the merge.

## Open Questions

- Should `LinkStats` carry the congestion window? Left out: it is in segments on some systems and bytes on others, and no library in view decides by it.
