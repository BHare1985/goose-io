# Tasks

Ground rules for every group: work on a branch of goose-io after `epoll-event-loop` is accepted, never on `main`; do not modify any file under `~/dev/cnamecloud/tcprouter` (the clone in `.implementations/tcprouter-goose-io` is the place for tcprouter work, and it has no remote); do not push, tag or publish without the owner's approval; write each check before the code it checks and see it fail first (against the in-memory loop's fault, then against the loop with the code missing); a check that fails once in any repetition is a failure until explained; every scenario of the spec has a check that names it, and every check has a fault; keep the pure-Goose rule (`tests/checks/purity.sh`).

## 1. Settle the open questions (spikes, no contract change yet)

- [ ] 1.1 Spike: can a generic Goose function choose between two bodies by whether the loop type has an operation (D8 item 2)? Write the smallest program that calls `relay` when the loop has it and `send` otherwise; record the result and the pattern for libraries in `design.md`; verify with a program built against the in-memory loop and against the core-only loop of `tests/support/core_only.goose`
- [ ] 1.2 Spike on `goose-io-epoll-ext`: what a pair ends with when one side fails (D8 item 1): read tcprouter's `RT-20` and `RT-19` rows in `~/dev/cnamecloud/tcprouter/design/05-requirements.md`, run its pump against a peer that resets, a peer that sends garbage and a peer that never reads, and record the reason each link would carry; amend the relay requirement of the spec to match; verify the amended scenarios read the same as the recorded outcomes
- [ ] 1.3 Spike: the memory of a link waiting for a hello with `peek` held in the loop (D8 item 3); build the waiting state on `goose-io-epoll-ext` for 10,000 links and compare with tcprouter's inspecting link; record the bound and the number in `design.md`; verify the number is no worse than tcprouter's
- [ ] 1.4 Decide D8 item 4 (`Input` carries no bytes) and record it; verify `design.md` has no open item left

## 2. The audit of tcprouter against the contract

- [ ] 2.1 Write `openspec/changes/add-stream-groups/audit.md`: every `RT-n` row of tcprouter's `design/05-requirements.md` with the operation or group that carries it (core, a group of this change, tcprouter's own code, or none) and what the loop must do; verify every row is present and that none is marked "none" without a named proposal
- [ ] 2.2 For each row marked "none", amend a group of this change (or add one) and its spec scenarios, or record why the feature stays loop-specific with the owner's agreement; verify the audit has no unresolved row
- [ ] 2.3 Review the audit with the owner before any group's code is written; verify the owner's decision is recorded in `audit.md`

## 3. The contract package

- [ ] 3.1 Add the types and events to `goose_io.goose`: `RelayStatus`, `Waker`, `File`, `Loan`, the events `Input` and `Woken`, and raise the version to 0.3; verify `goose check goose_io.goose` passes and the example libraries still build (their matches end in a catch-all arm)
- [ ] 3.2 Add `require_relay`, `require_peek`, `require_revoke`, `require_wake`, `require_files`, `require_loans`, `require_parts` and `require_addresses`, each naming every operation of its group once with the contract's types, and extend `is_link_event` and `link_of` for `Input`; verify each check fails to compile on the core-only loop naming its first operation (new `*_mustfail` tests) and passes on the in-memory loop
- [ ] 3.3 Add the group lists and the relayed state to `docs/contract.md` (sections 2, 4 and 6) and the combinations rules of D3 and D4; verify `tests/checks/docs.sh` and `tests/checks/vocabulary.sh` pass

## 4. The in-memory loop and the suite, group by group

Each of 4.1 to 4.8 is the same four steps: write the checks of the group in `conformance/` and add its entry point, see them fail to build against the loop without the group, add the group to `memory.goose` with its scripted-peer support, then add one fault for each check and show each check fails against its fault (`tests/conformance/faults.sh`). Every check's name and requirement go in `tests/conformance/checks.tsv`.

- [ ] 4.1 relay: the checks of the spec's relay scenarios, the bounded-memory check with a peer that never reads, and the pair-end reasons of task 1.2; verify the suite's relay entry point passes in fifty repetitions and every fault fails its check
- [ ] 4.2 peek: the checks of its scenarios, `wait_input` on a paused link and across the peer's end of stream; verify as 4.1
- [ ] 4.3 revoke: the checks of its scenarios, including the clock read at the write (the fault reads it at the start of the pass); verify as 4.1
- [ ] 4.4 wake: the checks of its scenarios, with a test thread, including order from one thread and a wake during draining; verify as 4.1 and that the in-memory loop's output is still the same in every repetition
- [ ] 4.5 parts: `send_parts` with zero, one and three parts, all-or-nothing, the `Full` and `TooLarge` sums; verify as 4.1
- [ ] 4.6 addresses: `local_address` and `original_destination` for IPv4 and IPv6 and a stale link, and the in-memory loop's way of scripting a redirection; verify as 4.1
- [ ] 4.7 loans: take, fill, send, refused and kept, the bound; verify as 4.1
- [ ] 4.8 files: `open_file` on an in-memory file registered by the test, `send_file`, a range past the end, a missing file; verify as 4.1
- [ ] 4.9 Add the checks of combinations (`write_deadline` on a relayed link, `peek` then `relay`, `wait_input` on a paused link, `send_parts` on a relayed link) as tests outside the entry points; verify each fails against a loop that breaks the rule
- [ ] 4.10 Update `tests/conformance/table_check.sh`, `groups_check.sh` and `docs/event-loops.md` ("Which check proves which scenario") for the new groups; verify all pass

## 5. The groups on `goose-io-epoll-ext`

Work in `.implementations/goose-io-epoll-ext`. After each group run its entry point (the repository's `conformance.sh --group G --repeat 50`) and the plain-path gates.

- [ ] 5.1 relay: turn `forward.goose`'s pump into `relay` on two contract links (a relayed link keeps its slot and its `Closed`), keeping the edge-triggered flags, the 64 KiB budget and the half-close rules; verify the relay suite passes in fifty repetitions and the system calls of a relayed 11 B, 16 KiB and 64 KiB keep-alive workload equal tcprouter's `forward_server` (the gate of `bench/gate_forward.sh` on a forwarder written on `relay`)
- [ ] 5.2 peek: `MSG_PEEK` with `SO_RCVLOWAT` held in the loop, `Input`, release into `Data`, and relay after peek; verify the peek suite passes and the waiting link's memory is no more than task 1.3 recorded
- [ ] 5.3 revoke: `discard_unsent` over the loop's send queue and `write_deadline` with the clock read at each write and in the relay's writes; verify the revoke suite passes and the combination checks of 4.9
- [ ] 5.4 wake: an `eventfd` registered with epoll, a `Waker` that carries its descriptor, `Woken` in order; verify the wake suite passes with a test thread and that `serve` returns while wakes are being made
- [ ] 5.5 parts, addresses: `writev` for parts, `getsockname` and `SO_ORIGINAL_DST` for addresses; verify their suites pass
- [ ] 5.6 loans, files: loans as the loop's own buffers (a copy is conforming), `sendfile` for files; verify their suites pass and `send_file` of a 100 MiB file keeps the loop's memory flat
- [ ] 5.7 Run the gates of `bench/` on the loop with every group present and unused (`gate_syscalls.sh`, `gate_http.sh`, `gate_memory.sh`), and `gate_forward.sh` with a forwarder written on `relay`; verify each passes against tcprouter's engine and store the results under `bench/results/`

## 6. Documents and acceptance

- [ ] 6.1 Document each group in `docs/contract.md`, `docs/libraries.md` (which libraries need which) and `docs/event-loops.md`, list `goose-io-epoll-ext` and the groups it passed in `examples/README.md` and the README's table of conforming loops, and add a row for each group to `docs/event-loops/io-uring.md` and `libuv.md`, `libevent.md` and `usockets.md` where the mapping is known; verify `tests/checks/docs.sh`, `layout.sh`, `vocabulary.sh` and `event_loops.sh` pass
- [ ] 6.2 Update `CONTRIBUTING.md`, the CI workflow (the in-memory suite for every new group in the existing jobs, and the Linux-only epoll ext job) and `tests/conformance/run.sh`; verify every `run:` command exits 0 locally
- [ ] 6.3 Full acceptance run on a fresh clone of the branch: every command of `CONTRIBUTING.md` and the workflow, every group's suite on the in-memory loop with fifty repetitions and on `goose-io-epoll-ext` with fifty, the faults, the gates; verify all pass, then `openspec validate add-stream-groups --strict`, and record the commit, Goose version and results in `docs/history.md`

## Workflow follow-up

- Merge, push and tag only with the owner's approval, after `epoll-event-loop` is accepted.
- Archive this change once merged.
- Next: port tcprouter onto `goose-io-epoll-ext` in the clone (`.implementations/tcprouter-goose-io`), row by row from `audit.md`, with its own tests as the judge; a separate change.
