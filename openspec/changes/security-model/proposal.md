# Proposal

## Why

goose-io says in several places what it does not do, but nowhere says what it protects. Two readers need that:

- An application author needs to know what the contract guarantees when a library is hostile or wrong, and what it does not (it is a cooperation contract and not a sandbox, and a library in the same process can do anything the process can).
- A contributor adding an operation needs to know it must be classified (does a library call it, or only the application?) and what a hostile caller could do with it. Without that, `serve` and `stop` ended up reachable from a library by accident.

The view, limits, policy and socket-file proposals each close one threat. A reader should find the threats, and which proposal answers which, in one place.

## What Changes

- Add `docs/security.md`: the model (what is trusted, what is not), a table classifying every operation as library or application, a table of threats with the proposal that answers each, and what is out of scope.
- Add `tests/checks/security.sh`: every operation of the contract has a row in the classification table, and every threat row names a proposal or says "out of scope".
- Add a rule to `CONTRIBUTING.md`: a change that adds an operation or an event states its class and its security impact in its design.
- Link the document from `README.md` and `docs/libraries.md`.

Out of scope: code; the mechanisms themselves, which belong to the proposals that name them; process isolation, TLS, and supply chain.

## Capabilities

### New Capabilities

- `security-model`: the stated threat model, the operation classes, and the check that keeps them complete.

### Modified Capabilities

None.

## Impact

- **goose-io:** `docs/security.md`, `tests/checks/security.sh`, `CONTRIBUTING.md`, `README.md`, `docs/libraries.md`, the check list in `CONTRIBUTING.md` and `layout.sh`'s layout section.
- **Applied first:** the other proposals link to the document and refer to its threat names.
- **Risk:** a document that overstates protection. The text says plainly that nothing here isolates code in one process.
