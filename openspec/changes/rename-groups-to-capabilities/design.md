# Design

## Context

The contract (`goose_io.goose`) is the core plus eleven optional parts, which every document, spec and test calls "groups". A loop supplies a group by having its operations. A library depends on a group by calling `require_<group>(io)` or by calling the operations, and in both cases the build fails on a loop without them. Nothing lets a library ask whether the loop has a group. Goose has no traits and no way to test whether a method exists, so "has it" can only be written as an overload that the loop opts into.

Nine more parts are planned or proposed: files, loans, parts and addresses (`add-stream-extras`), and the advanced capabilities proposed beside this change. Most make an existing behaviour cheaper: relay instead of copying, loans instead of `send`, the kernel's TLS instead of a TLS library. A library that cannot use them optionally must pick between portability and speed.

Constraints:

- No run-time cost. A loop's parts are fixed by its type, so the answer must be known when the program is built.
- No new language features. This must work on Goose v2026.4.
- Loops outside the repository (`goose-io-epoll-ext`) must keep building. Breaking them is acceptable only at compile time and only for a one-line fix.
- Required use (`require_*`) must not change for libraries.

## Goals / Non-Goals

**Goals:**

- One word, "capability", for every optional part, in specs, documents, code identifiers and tests.
- A compile-time declaration for each capability, with a default of "not supplied".
- A pattern a library can copy to use a capability when present and fall back otherwise, with an example and tests on both kinds of loop.
- Wrappers that pass through exactly what they wrap.

**Non-Goals:**

- Run-time negotiation, or a capability that a loop has on some links and not on others (a loop that can do relay only for TCP still declares relay, and the relay rules already say what happens to a link it cannot relay).
- Documentation pages per capability (`document-capabilities`).
- Any new capability.
- Renaming OpenSpec's spec areas: `io-contract` and `provider-conformance` keep their ids.

## Decisions

### D1. "Capability" replaces "group", and the core stays the core

Each optional part names something a loop *can do*, which is what a library asks about. "Group" names how operations are bundled, which a library never asks about. The core is not a capability: every loop has it, and nothing asks whether it is there. The capability names do not change, so `require_relay` and `RelaySuite` read the same as before.

The rename follows the precedent of `simplify-contract` (provider → event loop): one change renames everything, `tests/checks/vocabulary.sh` stops the old word from coming back, and `docs/history.md` and the archived changes keep the old word.

The vocabulary check matches the word `group` as a whole word, and allows: the CI concurrency key (`group:` in `.github/workflows/ci.yml`), regular-expression `.group(` calls in `bench/*.py`, `openspec/changes/archive/`, `docs/history.md`, and this change's own artifacts. Any other use needs an entry in the check's allow-list, with a reason.

*Alternatives:* "extras" (already used for the whole set, and does not name one part) or "features" (Cargo-like, but suggests flags you switch on when building, which is not how a loop works).

### D2. A declaration is an overload the loop adds, with a contract default

```goose
// goose_io.goose
struct Supplied {}
struct Absent {}
fn supplies_relay<Io>(io: Io&) -> Absent { return Absent {}; }  // the default for every loop
fn has_relay<Io>(io: Io&) { return io.supplies_relay(); }         // the query libraries call

// a loop that supplies relay, in its own namespace
fn supplies_relay(io: Loop&) -> goose_io::Supplied { return goose_io::Supplied {}; }
```

There is one `supplies_<c>` and one `has_<c>` for each of the eleven capabilities, including batching and unix, which have no operations.

This was tried on Goose v2026.4 (scratchpad probes against `goose_io_memory::Loop` and `core_only::Core`). The loop's exact overload wins over the generic default only when it is called with method syntax inside the contract's namespace. A free call from another namespace does not see the loop's overload. That is why libraries go through `goose_io::has_relay(io)` and never call `supplies_relay` themselves. It also means the loop defines its overload unqualified, in its own namespace.

The answer is a type, not a bool. `const if` can branch on `same<S, goose_io::Supplied>`, and the branch not taken is never type-checked, so a library can name `io.relay(...)` in a branch that a core-only loop never compiles. A `bool` constant would not do this: both branches of a run-time `if` are type-checked.

*Alternatives:* a `let CAPABILITIES` bitmask on the loop (Goose cannot read a constant through a generic type parameter, and a run-time mask would type-check both branches); detecting the operations themselves (Goose cannot test whether an overload exists); a separate build per loop with `#if`-style flags (the language has none).

### D3. Optional use is a branch on the query's type

```goose
fn forward<Io>(io: Io&, f: Forward&, ev: goose_io::Event) {
    _forward(io, goose_io::has_relay(io), f, ev);
}
fn _forward<Io, S>(io: Io&, s: S, f: Forward&, ev: goose_io::Event) {
    const if same<S, goose_io::Supplied> {
        // relay the two links; the library sees no Data for them
    } else {
        // copy: send what arrives, pause_reading on Full, resume on Writable
    }
}
```

The header of a library names both kinds of use:

```
// Needs: core only.
// Uses if supplied: relay (bytes pass in the loop, not through this library).
```

`tests/examples/needs_check.sh` reads both lines. An operation of a capability the library does not name under `Needs:` must be named under `Uses if supplied:`, and must appear only in a `const if` branch on that capability. The check stays a text inspection: it finds operation names, and it finds `has_<c>` with the matching `const if`. The compiler enforces the rest, because a core-only build of every example (D6) fails if a relay call is outside its branch.

*Alternative:* a run-time `if io.supports(RELAY)`. Rejected, because both branches would be type-checked, so it could not build on a loop without relay.

### D4. `require_<c>` also requires the declaration

`require_relay(io)` keeps its operation checks and adds `_is_supplied(io.supplies_relay())`, where `fn _is_supplied(s: Supplied) {}`. A loop that has the operations but forgot the declaration fails with an error inside `require_relay` naming `supplies_relay` and `Absent`. A loop that declares relay but lacks `relayed_bytes` fails on `relayed_bytes`, as it does today. So the two always agree on any loop that runs the check, and every loop's root program runs the check of each capability it claims (`provider-conformance`: an event loop says which capabilities it passes).

The suite's entry point for a capability (`goose_io_conformance::run_relay` and the others) calls `require_<c>`, so a loop cannot pass a capability's suite without declaring it.

A library that branches on the declaration but meets a loop that declares relay without having it gets a build error inside its relay branch, which names the missing operation. That is the spec's "a library meets a false declaration".

### D5. Wrappers forward the declaration through the contract

```goose
fn supplies_relay<I>(w: Wrap<I>&) { return goose_io::has_relay(w.inner); }
```

A wrapper forwards each capability it passes through. It must call `goose_io::has_relay`, not `w.inner.supplies_relay()`, for the same reason as D2: from the wrapper's namespace, the inner loop's overload is not visible. This was tried with a wrapper over the in-memory loop (answers `Supplied`) and over a core-only loop (answers `Absent`). `tests/support/wrapper.goose` forwards the capabilities it passes through. `tests/support/kit.goose` forwards all eleven, since it passes everything through.

### D6. A new example shows optional use, and it runs on both kinds of loop

`examples/forward/forward.goose` accepts on a front address and forwards each link to a backend address, relaying when supplied and copying otherwise (D3). Its tests (`tests/examples/forward_test.goose`) run twice from one source: once on the in-memory loop and once on `core_only::Core`. Both runs check what the client and the backend observe (bytes intact and in order, a close passes through), and only one assertion differs: the library sees `Data` only on the core-only loop.

The gateway example is not changed. It forwards whole lines and edits them, which relay cannot do.

### D7. Identifiers and files follow the word

| Before | After |
|---|---|
| `CoreGroup`, `RelayGroup`, … (`conformance/support.goose`) | `CoreSuite`, `RelaySuite`, … |
| `GROUP_CORE` … `GROUP_NONE` | `CAPABILITY_CORE` … `CAPABILITY_NONE` (the numbers do not change) |
| `Info.group` | `Info.capability` |
| `tests/conformance/checks.tsv` column `group` | column `capability` |
| `tests/conformance/groups_check.sh` | `tests/conformance/capabilities_check.sh` |
| `tests/unit/groups_test.goose` | `tests/unit/capabilities_test.goose` |
| `check_group` (`tests/checks/event_loops.sh`) | `check_capability` |
| CI step names "… groups …" | "… capabilities …" |

`CAPABILITY_CORE` keeps the name, even though the core is not a capability (D1). It labels the core's checks in the same table, and a separate name would split one column into two.

### D8. Version and compatibility

The contract's minor version goes up one step from the version the change lands on. A loop outside the repository keeps building until its root program calls `require_<c>`, which it does in its conformance build, and then it gets an error naming `supplies_<c>`. The fix is one line per capability. `goose-io-epoll-ext` and the epoll loop of `epoll-event-loop` get these lines in their own repositories, and tasks here record that.

## Risks / Trade-offs

- [The method-syntax overload rule (D2, D5) is subtle, and a loop author who defines `goose_io::supplies_relay` qualified gets an ambiguity error] → `docs/event-loops.md` shows the exact line to add, `require_*` catches a missing declaration, and the unit tests include a loop in another namespace and a wrapper.
- [A future Goose release changes overload resolution so that the default always wins or never wins] → `tests/unit/capabilities_test.goose` checks both answers on loops in two namespaces, so CI fails on the toolchain upgrade, not in a user's program.
- [Text-based `needs_check.sh` misses an optional use hidden behind a helper function] → the core-only build of every example (D6) catches any relay call outside a `const if` branch, because it fails to compile.
- [Renaming identifiers in the suite breaks an outside loop that names `RelayGroup` directly] → outside loops call `run_<c>` entry points, not the suite structs. A search of `goose-io-epoll-ext` finds no use of the structs (task 5.2 confirms it).
- [The rename collides with `add-stream-extras`, which is not finished] → that change is updated alongside this one to use "capability" and the declarations, and whichever lands second rebases its delta specs.

## Migration Plan

1. Land the declarations (`Supplied`, `Absent`, the defaults and queries) and add them to the in-memory loop, the test loops and the wrapper, while `require_*` does not yet check them. Everything builds.
2. Make `require_*` and the suite entry points check the declaration. The in-tree loops already declare, so everything builds.
3. Rename identifiers, files, scripts and documents, and turn on the vocabulary check.
4. Add the forward example and its two-loop tests.
5. Outside loops add their declaration lines. Until they do, only their conformance build fails, with an error naming the missing declaration.

Rollback: revert the change. Declarations an outside loop has added are harmless without it, because nothing calls them.

## Open Questions

- Should `has_<c>` also be offered as one aggregate (`goose_io::capabilities(io)` returning a struct of eleven types) for documentation tools? Not needed now. Revisit if `document-capabilities` wants a generated table per loop.
