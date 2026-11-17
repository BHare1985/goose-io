# Tasks

Ground rules for every group: work on a branch of goose-io, never on `main`; do not modify any file under `~/dev/cnamecloud/tcprouter` or any other repository; do not push or tag without the owner's explicit approval; no attribution lines in commits; write the failing test before the code it tests and show it fail; a test that fails once in any repetition is failing until explained; no rule of the contract and no check of the suite is weakened to make the loop pass; every defect found on the way is a task in this list; use the words "event loop", "library" and "application" (`tests/checks/vocabulary.sh` runs in `tests/run_tests.sh`).

## 1. Where the loop lives

- [x] 1.1 Spike: a directory `examples/loops/epoll/` with a Goose file that calls one `extern` function from `examples/loops/epoll/sys.c` (`c_boottime_ms`), imports `goose_io` and the suite, and is built with `goose build`; record in `design.md` D1 how it is built and run (build file, flags), or that it cannot, and then the fallback (a repository of its own); verify the built program prints the clock and that `tests/checks/purity.sh` still passes with the C file there
- [ ] 1.2 Add `examples/loops/epoll/build.sh` (or the build file the spike found) and `tests/net/run.sh`, which builds a program, runs it, supports a name filter and `REPEAT=n`, and exits non-zero on any failure; verify it runs and reports 0 tests successfully
- [ ] 1.3 Record the baseline in `bench/BASELINE.md`: tcprouter commit `05995d1` (and that `main` differs only in documents), Goose version, host CPU and kernel; build tcprouter's `examples/http_hello.goose` and `tests/net/harness/forward_server.goose` optimised from a clean checkout into `bench/baseline/` (git-ignored); verify both start and answer a request

## 2. Import tcprouter's engine unmodified

- [ ] 2.1 Copy from tcprouter `05995d1` into `examples/loops/epoll/` the generic files (`engine`, `conn`, `handler`, `messages`, `policy`, `route`, `config`, `check`, `sni`, `address`, `sys` `.goose` and `src/c_sys.c`), changing only namespaces and imports; record the source commit and the file list in `examples/loops/epoll/IMPORTED.md`; verify the loop builds
- [ ] 2.2 Copy tcprouter's `tests/unit/` and `tests/net/` (drivers, harness servers, data) under `tests/imported/` with only import paths changed; verify the whole imported suite passes against the imported engine and record the pass counts in `IMPORTED.md` as the behavioural baseline
- [ ] 2.3 Commit 2.1 and 2.2 as one "import" commit whose message names the tcprouter commit; verify `git show --stat` has no file outside `examples/loops/epoll/`, `tests/imported/` and the run scripts

## 3. The core, tests first

- [ ] 3.1 Write `examples/loops/epoll/conformance.goose`, the runner of the suite with its fixture (D4: a full accept queue that drops connects, a held listener, a released port, an accepting listener for `answers`), that takes a part and a group as the in-memory runner does and calls `goose_io::require_core`; verify it fails to build because the loop lacks the core's operations, and the error names the first one
- [ ] 3.2 Add the core's missing operations one at a time, each after a check of the suite that fails for it: `listen(address)` at run time with a never-reused `Listener` table, `listener_port`, `now_ms`, `tick_by` as one earliest-wake field shared with dial deadlines, `max_send` of at least 4096, and a free list over the slot table so that a freed slot is reused before the table is extended (design D9); verify `require_core` compiles and the core parts that need them pass
- [ ] 3.3 Move to the contract's names: `Conn` to `Link`, `send` to `SendStatus` (`TooLarge`, `Full`, `NotOpen`, `Closed` mapped one to one), every event carrying the link and nothing attached to it (no `tag`, no `user`), `Opened` with the listener, close reasons to the portable set plus `LoopSpecific`; verify the imported tests still pass through a thin compatibility shim kept in `tests/imported/`
- [ ] 3.4 Make `Writable` follow the largest refused send (remember the size that was refused), keep the slot of every link, a dial that failed inside `dial` included, until every handler of its `Closed` has returned (design D9), and make `close` finish sending and drain input before the final close; verify the checks of the suite for each fail before and pass after (for the slot, `slots_dense`, `slot_kept_during_closed` and `dial_no_event_inside`)
- [ ] 3.5 Verify every part of the core passes on the loop, the new checks `owner_listener_named`, `owner_dial_found_by_link`, `slots_dense`, `slot_kept_during_closed` and `dial_no_event_inside` among them, and `run.sh`-style `--repeat 50` has no failure; verify the core runs on the loop with nothing else supplied (a build of the core entry point only); tick off the core of the mapping document's rows with the commit

## 4. The groups

- [ ] 4.1 Half-close: check `require_half_close` compiles, `set_keep_open_on_eof`, `shutdown_write` and `PeerEof` map to tcprouter's, and the half-close entry point passes; verify with fifty repetitions
- [ ] 4.2 Abort: add `reset` (`SO_LINGER` 0, then close); verify the abort entry point passes and the peer sees `PeerReset`
- [ ] 4.3 Sizing: keep `send_room` and add `send2` (both parts or neither, bounded as the sum), reading the `Full` and `TooLarge` rules of the contract; verify the sizing entry point passes
- [ ] 4.4 Inspection: add `peer_address` (`getpeername`, the contract's text, IPv6 shortened as the contract says), `stop_listening`, with `peer_address` valid inside the handler of `Closed`; verify the inspection entry point passes
- [ ] 4.5 Batching: verify `PassEnd` as tcprouter delivers it passes the batching entry point, and that a pass of only a `Tick` delivers none
- [ ] 4.6 Verify the loop's root program calls the check of the core and of each group it supplies and that removing one operation of a group fails the build naming it; verify with a scratch copy

## 5. The extension seam

- [ ] 5.1 Write `tests/net/ext_join_test.py` and `examples/loops/epoll/tests/ext_join_server.goose`: a test extension in its own namespace that takes an accepted socket, connects a second and copies both ways using only the seam's facilities; checks: bytes intact both ways, memory flat against a peer that does not read, both sockets closed when either ends, no contract event for the joined link; verify it fails to build
- [ ] 5.2 Add `serve<X, F>` with the empty default extension and the hooks and facilities of design D5; verify 5.1 passes
- [ ] 5.3 Move the proxy layer (routes, SNI inspection, forward pump, retry, policy hooks, route tags and their deadlines, fences, `forward()`) out of the loop, the tags and deadlines into the extension's own per-slot state, behind the seam into `tests/imported/proxy_ext/`, leaving the loop with no reference to routes, `Target`, `Hello`, `Pick` or tag deadlines; verify `grep -rn "Target\|match_route\|parse_hello\|_tag_allows\|Pick\." examples/loops/epoll/` prints nothing
- [ ] 5.4 Verify the whole imported suite from 2.2 passes with the proxy layer as an extension and the same pass counts; record any difference and its cause in `design.md` before continuing
- [ ] 5.5 Add `tests/net/ext_gate_test.py`: an extension whose `allows`, given a slot, turns false for the link in it; a following send transmits nothing and the link closes with a `LoopSpecific` reason; verify it passes
- [ ] 5.6 Write `docs/extending.md`: each hook, when it is called, what an extension may and may not do inside it, the named-namespace rule, and the join extension as a worked example whose code is the file built by 5.1 (checked by `tests/checks/docs.sh`); verify the check passes

## 6. Workers, limits, drain and statistics

- [ ] 6.1 Port the imported drain, signal, message and chaos tests to the contract's names, with engine-owned message kinds only (drain and statistics); verify they fail against the unported code for naming reasons only
- [ ] 6.2 Reduce the engine-owned control messages to drain and statistics (every other kind goes to the extension's `on_message`) and expose them under the contract's names; keep the order messages, then extension sweep, then events in every pass; verify 6.1 passes and the imported deadline and policy-message tests pass through the extension
- [ ] 6.3 Make `stop` and `draining` of the contract the drain of the loop and close links left at the deadline with `Shutdown`; verify the draining parts of the core pass on the loop
- [ ] 6.4 Add a multi-worker check: four workers on one port, four hundred connections, exact summed statistics; and a port held by another process fails start-up with a message naming the address; verify both pass in twenty repetitions
- [ ] 6.5 Add the descriptor-exhaustion check (accepts rest without spinning, CPU far below one core, connections served after descriptors return) and the link-limit check (`ConnectFailed` of kind `NoResources`, other links unaffected); verify both pass
- [ ] 6.6 Add the checks of idle memory (at most 512 bytes per idle link at ten thousand links), pool exhaustion (waits counted, data intact) and timeouts (idle and half-close between the limit and the limit plus 250 ms); verify they pass
- [ ] 6.7 Add the check that close with unread input does not reset the peer, and that a peer that never reads is released at the loop's limit; verify the first fails against an unchanged `close(2)` and passes now

## 7. The example libraries on real sockets

- [ ] 7.1 Write `tests/net/lineclient_test.py` running the example line client on the loop against a real line-echo service that is restarted mid-run, and `tests/net/lineserver_test.py` running the line server against real peers (split requests, pipelined requests, a peer that half-closes, a peer that never reads); verify both fail to build or run before the loop is wired in
- [ ] 7.2 Add `examples/loops/epoll/tests/` programs that build the libraries on the loop with no change to their source and check `require_core`, `require_half_close` and what each library's header names; verify 7.1 passes in twenty repetitions
- [ ] 7.3 Add `tests/net/shared_worker_test.py`: the gateway (server and client on one worker, tagged differently) over real peers; verify it passes and that the same program passes on the in-memory loop

## 8. Performance gates

- [ ] 8.1 Add `examples/http_hello.goose` on the loop, behaviourally identical to tcprouter's (same responses, keep-alive, one worker by default); verify tcprouter's `http_server_test.py` checks pass against it
- [ ] 8.2 Port `bench/syscalls.py` and write `bench/gate_syscalls.sh` that traces baseline and candidate over a fixed request count and fails unless `recv`, `send`, `epoll_wait`, `epoll_ctl`, `accept4` and `close` per request are equal; verify it passes and store the table under `bench/results/`
- [ ] 8.3 Write `bench/gate_http.sh`: one worker, pinned CPUs, at least seven alternating rounds with `wrk` at 64 and 512 connections, voiding a run where `wrk` or the backend was the limit, failing unless the candidate's median throughput, p99 and CPU per request fall within or beat the baseline's own range; verify it passes on an idle host and store the results with both commits and the host
- [ ] 8.4 Port `bench/memory.py` and compare idle RSS, RSS with 10,000 idle links and RSS under load; verify the candidate is no worse than the baseline and at most 512 bytes per idle link
- [ ] 8.5 Verify the free-seam requirement: trace one workload with no extension and with an extension whose hooks are empty; the system calls per request are equal; record it

## 9. Seam proof on the forwarding path

- [ ] 9.1 Create `bench/forward_ext/`: an extension carrying tcprouter's forward pump with a fixed target and no routing, SNI, retry or policy, and a server program; verify tcprouter's `verify.py` correctness checks pass against it
- [ ] 9.2 Run the syscall gate for the baseline `forward_server` against the extension on 11 B, 16 KiB and 64 KiB keep-alive workloads; verify equality and store the tables
- [ ] 9.3 Run the alternating-round throughput, p99 and CPU gate on the same three workloads with tcprouter's bench method (`WORKERS=1 PIN=auto`, the C backend, `wrk`); verify the candidate is within or better than the baseline's range and store the results
- [ ] 9.4 If 9.2 or 9.3 fails, change the seam (first the generic slot payload, design D5), run groups 5, 8 and 9 again and record the decision in `design.md`; if no seam reaches parity, stop for the owner's decision; verify `design.md` states the final seam and its measured numbers

## 10. Documents, CI and acceptance

- [ ] 10.1 Add the loop to `docs/event-loops.md` (how it is built and run, its runner quoted from `examples/loops/epoll/conformance.goose` and checked by `tests/checks/docs.sh`, its fixture) and to the README's table of conforming loops with the core, the groups, the contract version and the commit; mark the rows of `docs/event-loops/tcprouter-engine.md` done with the commit; verify `docs.sh`, `layout.sh` and `vocabulary.sh` pass
- [ ] 10.2 Write `docs/tcprouter-adoption.md` for the follow-on project: which tcprouter files map to which files and hooks here, the proxy extension from 5.3 as the starting point, the gates that project must hold, and the fallback; verify each file and hook it names exists
- [ ] 10.3 Add a Linux-only job to `.github/workflows/ci.yml` that builds the loop, runs every part of the core and of each group on it with `--repeat 3`, and runs the network tests; keep the matrix, the `macos-26` label and the one-run-per-commit triggers; verify every `run:` command exits 0 locally and update `CONTRIBUTING.md`
- [ ] 10.4 Full acceptance run on a fresh clone of the branch: every command of `CONTRIBUTING.md` and the workflow, the suite on the loop with fifty repetitions, the network tests with twenty, the imported suite through the proxy extension and every gate of groups 8 and 9; verify all pass, then `openspec validate epoll-event-loop --strict`, and record the commit, Goose version and results in `docs/history.md`

## Workflow follow-up

- Review `bench/forward_ext/` and `tests/imported/proxy_ext/` with the owner before any push: they hold tcprouter's proxy code.
- Merge, push and tag only with the owner's approval, after `link-keyed-state` (archived) and `lifecycle-guarantees` have merged.
- Archive this change once merged.
- Next change: an io_uring loop from c_proxy, admitted by the same suite. Separate project: refactor tcprouter onto goose-io following `docs/tcprouter-adoption.md`.
