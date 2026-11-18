# Tasks

Ground rules for every group: work on a branch of goose-io after `epoll-event-loop` is accepted, never on `main`; do not push, tag or publish without the owner's approval; write each check before the code it checks and see it fail first (against the in-memory loop's fault, then against the loop with the code missing); a check that fails once in any repetition is a failure until explained; every scenario of the spec has a check that names it, and every check has a fault; keep the pure-Goose rule (`tests/checks/purity.sh`). This change touches only the contract, the in-memory loop, the suite and the documents; no real event loop and no tcprouter file.

## 1. Settle the open questions (spikes)

- [ ] 1.1 Spike: can a generic Goose function choose between two bodies by whether the loop type has an operation (D6 item 2)? Write the smallest program that calls an operation when the loop has it and another when not; record the result and the pattern for libraries in `design.md`; verify with a program built against the in-memory loop and against the core-only loop of `tests/support/core_only.goose`
- [ ] 1.2 Decide what the partner of a failed relayed link carries (D6 item 1): write the cases (reset, error, limit, a peer that never reads) as the scripted failures the in-memory loop will offer, record the reasons, and amend the relay requirement and scenarios of the spec to match; verify `openspec validate add-proxy-groups --strict` passes
- [ ] 1.3 Decide D6 items 3 and 4 and record them; verify `design.md` has no open item left

## 2. The contract package

- [ ] 2.1 Add the types and events to `goose_io.goose`: `RelayStatus`, `Waker`, the events `Input` and `Woken`; extend `is_link_event` and `link_of` for `Input`; raise the version to 0.3; verify `goose check goose_io.goose` passes and the example libraries still build (their matches end in a catch-all arm)
- [ ] 2.2 Add `require_relay`, `require_peek`, `require_revoke` and `require_wake`, each naming every operation of its group once with the contract's types; verify each fails to compile on the core-only loop naming its first operation (new `*_mustfail` tests) and passes on the in-memory loop once 3.x lands
- [ ] 2.3 Add the four groups, the relayed state and the combination rules (D3, D4) to `docs/contract.md`; verify `tests/checks/docs.sh` and `tests/checks/vocabulary.sh` pass

## 3. The in-memory loop and the suite, group by group

Each of 3.1 to 3.4 is the same four steps: write the checks of the group in `conformance/` and add its entry point, see them fail to build against the loop without the group, add the group to `memory.goose` with its scripted-peer support, then add one fault for each check and show each check fails against its fault (`tests/conformance/faults.sh`). Every check's name and requirement go in `tests/conformance/checks.tsv`.

- [ ] 3.1 relay: the checks of the spec's relay scenarios, the bounded-memory check with a peer that never reads, and the pair-end reasons of task 1.2; verify the suite's relay entry point passes in fifty repetitions and every fault fails its check
- [ ] 3.2 peek: the checks of its scenarios, `wait_input` on a paused link and across the peer's end of stream, and the bound; verify as 3.1
- [ ] 3.3 revoke: the checks of its scenarios, including the clock read at the write (the fault reads it at the start of the pass); verify as 3.1
- [ ] 3.4 wake: the checks of its scenarios, with a test thread, including order from one thread and a wake during draining; verify as 3.1 and that the in-memory loop's output is the same in every repetition
- [ ] 3.5 Add the checks of combinations (`write_deadline` on a relayed link, `peek` then `relay`, `wait_input` on a paused link) as tests outside the entry points; verify each fails against a loop that breaks the rule
- [ ] 3.6 Update `tests/conformance/table_check.sh`, `groups_check.sh`, `tests/conformance/run.sh` and "Which check proves which scenario" in `docs/event-loops.md` for the new groups; verify all pass

## 4. Documents and acceptance

- [ ] 4.1 Document each group in `docs/libraries.md` (which libraries need which) and `docs/event-loops.md` (what a loop must do to supply it, and the mechanisms it may use), add a row for each group to the mapping documents of the candidate loops where the mechanism is known, and update `CONTRIBUTING.md`, the layout and the README's list of groups; verify `tests/checks/docs.sh`, `layout.sh`, `vocabulary.sh` and `event_loops.sh` pass
- [ ] 4.2 Update the CI workflow (the new groups' suites in the existing jobs); verify every `run:` command exits 0 locally
- [ ] 4.3 Full acceptance run on a fresh clone of the branch: every command of `CONTRIBUTING.md` and the workflow, every new group's suite on the in-memory loop with fifty repetitions, the faults; verify all pass, then `openspec validate add-proxy-groups --strict`, and record the commit, Goose version and results in `docs/history.md`

## Workflow follow-up

- Merge, push and tag only with the owner's approval.
- Archive this change once merged.
- Later, separate work: implement the groups on `goose-io-epoll-ext`, audit tcprouter against the contract, and use the groups in tcprouter's port.
