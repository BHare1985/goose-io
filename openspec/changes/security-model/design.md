# Design

## Context

The earlier analysis found that libraries on one loop are offered each other's events, can act on any handle they hold or guess, and can call `stop`; tags were as spoofable as links. The other four proposals answer parts of that. This one writes the model down so that the parts are seen together and stay complete.

## Goals / Non-Goals

**Goals:** one document with the model, the classes and the threats; a check that stops it going stale.
**Non-Goals:** mechanisms, process isolation, TLS, supply chain.

## Decisions

**D1. Say first that this is not a sandbox.** Libraries are Goose code in one process and can do what the process can (open files, call C). The views stop mistakes and an unprivileged-by-convention library, not a determined one. Stating this first stops the later tables being read as a guarantee.

**D2. Two classes of operation.** Library operations: `listen`, `listener_port`, `stop_listening`, `dial`, `peer_address`, `send`, `send2`, `send_room`, `max_send`, `pause_reading`, `set_keep_open_on_eof`, `shutdown_write`, `close`, `reset`, `now_ms`, `tick_by`, `draining`. Application operations: `serve` and `stop`. `now_ms` and `draining` are class library with no effect on others. The table in the document is the source; this list is the starting point and the first task checks it against the contract.

**D3. A table of threats, each with an answer.**

| Threat | Answer |
|---|---|
| A library acts on a link it does not own | `scoped-library-views` |
| A library reads another library's payload | `scoped-library-views` |
| A library stops the loop | `scoped-library-views` (`serve` and `stop` are not library operations) |
| A library uses up links, listeners or wake-ups | `library-resource-limits` |
| A library connects to an address it was not given | `library-address-policy` |
| A library takes or leaves a socket file | `unix-socket-permissions` |
| A library takes the CPU in a handler | out of scope: nothing preempts a handler |
| Code in the process reads or writes memory it was not given | out of scope: one process; Goose's own memory safety applies |
| Eavesdropping or tampering on the wire | out of scope: a TLS library above the contract |
| A malicious dependency | out of scope: supply chain |

**D4. A check, not a promise.** `tests/checks/security.sh` reads the operations from `docs/contract.md` (the same source `event_loops.sh` uses), requires a row in the class table for each, requires each threat row to name an answer or "out of scope", and requires the two links. A new operation without a row fails the build.

**D5. A contributor rule.** One paragraph in `CONTRIBUTING.md`: classify the operation and say what a hostile caller could do. It is a rule for designs, enforced by review and by D4.

**D6. The document names proposals until they are applied.** Until a proposal is archived the row cites its change name; at archive the row cites the capability. A row naming an unapplied change says "proposed".

## Risks / Trade-offs

- [The document overstates protection] → D1 and the out-of-scope rows; reviewed in the first task.
- [The check reads prose and breaks on rewording] → It reads table rows with a fixed first column, as `event_loops.sh` does.
- [The tables drift from the contract] → That is what the check is for.

## Open Questions

- Should `now_ms` and `draining` be listed as a third class (anyone)? They are listed as library operations with no effect on others unless the review finds otherwise.
