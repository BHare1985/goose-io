# Design

## Context

Contract 0.1 (`define-contract-v1`, committed on `contract-v1`) is complete and passes its own suite on the in-memory loop and on a wrapper over it. It is also the full contract: 21 operations, 7 events, and a conformance suite that is one driver compiling every check. A loop author must supply all of it before any check runs. See `proposal.md` for why that is the wrong cost for the aim (anyone can write a loop).

What the repository shows, found by reading it and not by guessing:

```
  What the example libraries call (ops)        client: dial send max_send close set_user now_ms tick_by draining
                                               server: the same sort, plus pause_reading, set_keep_open_on_eof
  What the 56 checks call, by group            core only 30 | sizing 9 | inspection 8 | half-close 4 | abort 1
                                               calling two or more groups 4
  What every check needs through a helper      listener_port (to dial a port the loop chose)
  What every backpressure check needs          pause_reading (to make a peer that does not read)
```

The last two lines changed my first proposal: I had put `listener_port` and `pause_reading` among the extras. They are core, because the suite runs both ends of every link on the one loop and so, without them, cannot reach a port the loop chose or make a peer that does not read (needed for every `Full` and `Writable` check).

## Goals / Non-goals

**Goals:**
- A loop that supplies 13 operations and 5 events conforms to the core, and every library that uses only those runs on it.
- Everything else is a named group a loop may add, and a library that needs a group fails to compile on a loop without it.
- One word for each role, used everywhere.
- The suite can be run for the core alone, and for each group alone.

**Non-goals:**
- No change to what any operation does. The behaviour of every kept operation is as in 0.1; this change decides who must supply it.
- No weakening of a core rule (D3).
- No new operation, and no implementation of a real event loop.

## Decisions

### D1. Vocabulary: event loop, library, application

| Was | Is | Notes |
|---|---|---|
| provider | event loop (a `Loop` in code) | what owns the thread and the sockets: uSockets, a custom loop, a tokio-style runtime |
| host | application | the program that runs the loop and passes events to libraries |
| library | library | unchanged |

Identifiers that change: `goose_io::require_provider` (D4); `CloseReason.Provider { code }` becomes `LoopSpecific { code }`; the in-memory loop's `provider_close` becomes `close_with_reason`; `docs/providers.md` becomes `docs/event-loops.md` and `docs/providers/` becomes `docs/event-loops/`; test file names with "provider" follow. Comments and documents are rewritten, and `tests/checks/vocabulary.sh` fails on the old words (D10).

The capability ids `io-contract` and `provider-conformance` are **kept**: OpenSpec does not rename a capability, and the id is not read by anyone who writes a loop. The requirement texts under them use the new words. This leaves "provider" in one directory name under `openspec/specs/`; the alternative (a new capability `loop-conformance` and a retired old one) was weighed and rejected as churn for a name that only maintainers see. Open question 1.

### D2. The core, and the groups

```
   +----------------------------------------------------------+
   | CORE (every loop)                                        |
   |  listen listener_port dial send max_send pause_reading   |
   |  close set_user now_ms tick_by serve stop draining       |
   |  events: Opened Data Writable Closed Tick                |
   +--------+---------+---------+------------+----------------+
            |         |         |            |
      half-close   sizing     abort     inspection    batching
      shutdown_    send_room  reset      peer_address  PassEnd
      write        send2                 stop_listening
      set_keep_                          user
      open_on_eof
      PeerEof
```

Why each is where it is:

- **`draining` is core** because a library learns that the loop is stopping only through it, and every library must close its idle links then (both examples do). It is a flag.
- **`listener_port` and `pause_reading` are core** (above).
- **`set_user` is core and `user` is not.** An event carries the user value; a library does not have to ask for it.
- **`stop_listening` is inspection.** `stop` already ends every listener; stopping one is rare.
- **Half-close** is separated because many loops and libraries want the default (the peer's end of stream closes the link) and nothing else; `PeerEof` is delivered only to a link that opted in, so it never occurs without `set_keep_open_on_eof`.
- **`PassEnd` is batching and is a hint.** A library must not need it for correctness, so a loop that never sends it is fine; the example libraries do not depend on it.

The `Event` and `SendStatus` and `CloseReason` types keep every variant. A loop that does not supply a group never constructs its events, and a `match` in a library has an arm that never runs.

### D3. No core rule is weakened

The rules that cost an adapter the most, taken from the mapping documents, are all kept in the core: `Writable` only once the largest refused send fits (tcprouter has to remember a size), a user value that survives an immediate dial failure and is readable in the `Closed` handler (tcprouter has to keep the slot), `close` that loses no accepted byte (every substrate needs a drain-and-discard step), and no event from inside an operation (uSockets calls its close callback inside `us_socket_close`). Each is something a library would otherwise have to guard against on every loop, which is the problem the contract exists to remove.

This change makes loops easier to write by making operations optional, not by making the core's promises weaker. Whether a core rule is too expensive is a question for the first real loop to answer; the mappings are source reading and nothing was built. Open question 2.

### D4. Compile-time checks, one per part

`require_provider<Io>` is replaced by `require_core<Io>`, `require_half_close<Io>`, `require_sizing<Io>`, `require_abort<Io>` and `require_inspection<Io>`. The batching group has no operation (only the event `PassEnd`), so there is nothing for a compile-time check to name and it has none; the conformance suite is what shows that a loop delivers `PassEnd` as the contract says. Each names every operation of its part once with the contract's types and never runs, as `require_provider` did. A loop's root program calls the core check and the check of each group it supplies that has one. The version is 0.2 (`VERSION_MINOR` 2) and `require_provider` is removed, not kept as an alias: the contract is at major version 0 and nothing outside this repository uses it.

### D5. The suite runs by group

The driver today calls one `run_step` that chains every check, so building it for a loop without `send2` fails: Goose compiles every branch of a generic function for the type it is given, taken or not. The suite therefore has to be several entry points, each of which compiles only its own checks.

Design: the driver becomes generic over a group marker as well as the loop (`_drive<Io, G>(g: G&, ...)`), and each group supplies its `info` and `step` as functions taking its marker type as the first parameter, which Goose resolves by overload (it already does for `same(Link, Link)` and `same(Listener, Listener)`). The entry points are `conformance_core_part`, `conformance_half_close_part` and so on. The core keeps its six parts (part 0 and one for each scenario of `stop`); each group runs in one process. `checks.tsv` gains a `group` column; `run.sh` and `faults.sh` read it; `table_check.sh` requires that the group of each check is the one its calls need. The spike (task 3.1, scratch files) confirmed it: a driver `run<Io, G>(g: G&, io: Io&)` calling `g.step(k, io)`, with `step` overloaded on the marker struct in one module for each group and all of them imported by the driver, built and ran for the core marker against a loop that had `send` and no `send2`, and for the sizing marker against the same loop it failed to build with the error naming `send2`. Only the chosen group's functions are instantiated, so no fallback is needed.

Auditing the checks (task 3.4) follows one rule: **a check of the core calls no operation of a group, and a check of a group calls the core and that group only.** The 30 core-only checks stay. Of the 26 others:

- Many call an extra incidentally. `dial_refused` calls `stop_listening` to get a dead port; it takes it from a new fixture field `refused` instead, an address nothing listens on. `send_before_open` and `send_after_close` also call `send2`; their `send2` lines move to the sizing check of the same requirement.
- Four call several groups (`reset_aborts_the_peer`, `send_room_is_zero_when_closed`, `handles_stale_reuse`, `handles_unset`). Each is split: the part about the core stays in a core check, and each group's part goes to a check of that group. `handles_valid_in_closed` splits the same way: the `Closed` event carries the user value (core), and `user` and `peer_address` answer inside the handler (inspection).
- Every check that is split or rewritten still needs a fault that makes it fail (`faults.sh` requires it), so no coverage is dropped silently.

### D6. A core-only loop to prove it

A claim that a loop with only the core conforms needs a loop with only the core. `tests/support/core_only.goose` is a loop over the in-memory loop that supplies the 13 operations and 5 events and nothing else, as the existing wrapper is, and the core suite and the line client's tests run on it in their own processes. That makes the first scenario of the spec ("a loop that supplies only the core") a test and not an assertion, and it is the file an author of a real loop can read to see the smallest possible shape.

### D7. The conformance suite is a tool

A loop reports which groups it passes; the README table gains a column for each. Nothing stops anyone using a loop that passes less. The suite and its faults are unchanged in kind; only the unit of running changes. CI runs the core and each group, and the wrapper over each.

### D8. Libraries say what they need

Each example library's header names its needs (client: core; server: core and half-close) and its test calls the matching `require_*` check, so a library that starts to need more is noticed. The gateway needs the union.

### D9. Sequencing

The deltas modify and rename requirements that exist only in `define-contract-v1`, which is complete and verified from a fresh clone but not archived. `openspec validate` already says so (the archive "would refuse this delta: source not found"). So `define-contract-v1` is archived first, which moves its requirements into `openspec/specs/`, and this change is applied after. Checked in a scratch copy of the tree: with `define-contract-v1` archived, `openspec validate simplify-contract --strict` passes and the change archives (9 requirements added, 17 modified, 4 removed, 7 renamed). Two rules of OpenSpec shaped the deltas: a modified requirement must keep every scenario name it has, so the scenarios of the group rules stay in the requirements that already state them (worded as "on a loop with the sizing group") and the four requirements whose scenario names carry the old words are removed and added again under new names. The branch for this change starts from `contract-v1` so that it builds on the committed contract.

### D10. Keeping the words out

A script, `tests/checks/vocabulary.sh`, fails when "provider" or "host" appears in the documents, the code and the specification outside the lines it allows (the capability id `provider-conformance`, this change's and the finished changes' own records under `openspec/changes/`, and the word "host" in "localhost" or in the host-name sense of an address). It runs in CI. Without it the rename would drift back.

## Risks / Trade-offs

- **Churn.** The rename touches most files. → It is mechanical, the script of D10 finds what is left, and the full set of checks runs after each group of tasks.
- **A weaker suite by accident.** Splitting checks could drop an assertion. → Every check keeps its fault; `faults.sh` fails if one passes; the table check fails if a contract scenario loses its check.
- **The core may still be too big for a real loop.** → Nothing about it has been built. The mapping documents list the adapter work of the core apart from that of each group, so the cost can be read, and the first real loop decides whether another operation should move out.
- **Overload on marker types may not work as hoped in Goose.** → Spike before committing to it (task 3.1); fall back to one driver source with a group type parameter instantiated by a macro-like repeat of the three-line entry points.
- **Leaving `provider-conformance` as an id.** → Recorded above; the cost is one directory name.

## Migration Plan

1. Archive `define-contract-v1` (verified in a scratch copy).
2. Apply this change in the order of `tasks.md`: the contract and its checks, then the in-memory loop and the wrapper, the suite by group, the libraries and tests, the vocabulary sweep with its script, the documents, CI.
3. Archive this change; the main specifications then say event loop throughout.

Rollback is reverting the branch. Nothing outside this repository depends on 0.1.

## Open Questions

1. **Rename the capability ids?** Keep `provider-conformance`, or retire it for a new `loop-conformance`. Kept for now (D1). Does not change the contract.
2. **Is any core rule still too heavy for a real loop?** The first real loop (the uSockets or tcprouter example) answers it; until then none is weakened.
3. **`draining` in the core.** It could be an inspection operation if the application, not the library, told libraries to wind down. Kept in the core because both examples need it and it costs a flag.
