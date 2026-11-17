# Tasks

Ground rules for every task: work on a branch, not `main`. Write the test before the code it tests. Do not push or tag without the owner's approval. A test that fails once in any repetition is a failure until its cause is explained. No operation, event or handle type changes; nothing here adds C, an `extern` or a build sidecar. Use the contract's words ("event loop", "library", "application"): `tests/checks/vocabulary.sh` fails on the old ones. Groups 1 to 4 are in this repository; group 5 is in the goose-postgres adaptation and starts only when 1 to 4 are applied.

## 1. The in-memory event loop supplies the unix group

- [x] 1.1 Write `tests/unit/memory_unix_test.goose` first for: listen on a path and dial it (both ends `Opened`, bytes in both directions, the accepted link carrying the listener's tag and handle); a second listen on the same path gives `AddressInUse`, and the path is free again after `stop_listening`; two different paths, and a path and a numeric address, never conflict; a dial to a path nothing listens on gives one `Closed` with `Refused`; `listener_port` is 0; `peer_address` is empty on both ends of a path link; every malformed form (`unix:`, `unix:rel`, `unix:@a`, a NUL byte, 104 bytes) gives `BadAddress` for `dial` and `listen`, and a 103-byte path works; a scripted peer accepting, refusing and connecting at a path, and `hold`, `fail_dials` and `silent` on a path; verify the test fails against the current loop
- [x] 1.2 Give `_Addr` in `memory.goose` a `unix` flag and a path of up to 103 bytes, teach `_parse_address` the form (`unix:` then an absolute path with no NUL and no leading `@`), and make `_same_endpoint`, `_overlaps` and `_listener_takes` compare paths for Unix addresses and never match across the two families; verify the malformed, held and conflict cases of 1.1 pass
- [x] 1.3 Make `listen` skip the port search for a Unix address, `listener_port` return 0 for it, and the accepted link's remote a Unix address that formats as the empty value; verify the rest of 1.1 passes and `tests/run_tests.sh` still passes in full, so numeric behaviour is untouched
- [x] 1.4 Add `unix_paths: bool = true` to the loop's `Config`, so that with it off `dial` and `listen` on any `unix:` text give `BadAddress`, and set it off in `tests/support/core_only.goose` (its `_prepare`); verify with a case in `tests/unit/memory_unix_test.goose` and one that dials a path on the core-only loop, and that the wrapper (`tests/support/wrapper.goose`) passes a path through to the loop beneath unchanged

## 2. The unix group of the conformance suite, with a fault for each check

- [x] 2.1 Add `GROUP_UNIX = 6` and an `UnixGroup` marker to `conformance/support.goose`, `unix: const u8[:] = ""` to `Fixture` (documented as an absolute path the loop may create a socket at), a `step` and `takes` for the group and a `conformance_unix_part` entry point in `conformance/suite.goose`; verify `goose check conformance/suite.goose` is clean and the existing groups' parts still pass
- [x] 2.2 Add to `conformance/net.goose` the checks `unix_listen_dial` (212), `unix_held_path` (213), `unix_nothing_listens` (214), `unix_no_port` (215), `unix_malformed_paths` (216) and `unix_longest_path` (217) (211 is taken by `peer_address_ipv6`), with `group_of` naming each as `GROUP_UNIX`; each calls the core only (no `peer_address`) and derives its other paths from `fx.unix` (a suffix, and the same directory padded to 103 and 104 bytes); verify each passes against the in-memory loop through `conformance_unix_part`
- [x] 2.3 Add the faults to `memory.goose` and its fault list and one row per check to `tests/conformance/checks.tsv` with group `unix`: `UnixListenerIgnored` (a dial to a path never reaches its listener) for 212, `UnixOverlapIgnored` for 213, `UnixRefusedAsBadAddress` for 214, `UnixPortInvented` for 215, `UnixRelativeAccepted` for 216 and `UnixLongestRefused` for 217; verify `tests/conformance/faults.sh` reports each check failing with its fault and `tests/conformance/groups_check.sh` reports no check calling an operation outside the core and its group
- [x] 2.4 Make `tests/conformance/memory_conformance.goose` and `tests/conformance/wrapped_conformance.goose` set `fixture.unix` to a path of the form `/run/goose-io-test.sock` and dispatch the group name `unix`; verify `tests/conformance/run.sh`, `tests/conformance/run.sh --wrapped` and `tests/conformance/run.sh --group unix --repeat 5` pass with identical output on every repetition, and that `tests/conformance/run.sh --core-only` runs no unix part
- [x] 2.5 Name each new check in `docs/event-loops.md` (the document part `tests/conformance/table_check.sh` reads) with the requirement and scenarios it proves, add `conformance_unix_part` and the group name to its list of entry points and runner example, and add the unix group to its group table and the `tests/conformance/memory_conformance.goose` excerpt; verify `tests/conformance/table_check.sh` and `tests/checks/docs.sh` pass

## 3. The contract's documents and version

- [x] 3.1 Raise `VERSION_MINOR` in `goose_io.goose` to 2 and change its header comment to six groups with the address forms, and update `tests/unit/types_test.goose` and `tests/unit/groups_test.goose` to expect 0.2 (the groups test also notes that unix has no compile-time check); verify `goose check goose_io.goose` is clean and both tests pass
- [x] 3.2 In `docs/contract.md`: six groups in section 2 and its table, the form and its path rules in the addresses paragraph, a "Unix" entry in section 6 (the groups) saying what binds a loop that supplies it, the empty `peer_address` and the 0 port, and the `BadAddress` rows of the dialling and failure sections; remove the "Unix sockets" row from the "does not cover" table and set the version to 0.2; verify every requirement of this change's `specs/io-contract/spec.md` is named in it, and `tests/checks/docs.sh` and `tests/checks/vocabulary.sh` pass
- [x] 3.3 In `README.md`: "six groups", Unix sockets removed from "Not covered" and from the limits sentence, version 0.2, and the loops table rows at 0.2 with the in-memory loop and the wrapper supplying unix and the core-only loop not; verify `tests/checks/docs.sh`, `tests/checks/layout.sh` and `tests/checks/vocabulary.sh` pass
- [x] 3.4 Add to `docs/libraries.md`, under "Testing a library", a short example of a library dialling `unix:/path` against a scripted peer on the in-memory loop, as an excerpt of a test under `tests/examples/` marked for `tests/checks/docs.sh`; verify the test passes and the excerpt check passes

## 4. Everything together

- [x] 4.1 Run `just test` (every step of the `Justfile`) from a clean checkout of the branch; verify it exits zero
- [x] 4.2 Run `openspec validate add-unix-sockets --strict`; verify it reports the change valid, and that each scenario of both spec files is named by a check, a unit test or a document step (list the mapping in the pull request description)

## 5. The goose-postgres adaptation, with the least change

These are in the goose-postgres adaptation, whose pool is upstream's source with `http::` renamed to `httpshim::` and whose shim is `httpshim.goose`; nothing in the pool, its signatures or its tests changes. Start after 1 to 4 are applied and goose-io is at 0.2.

- [x] 5.1 In `httpshim.goose`, make `socket_address` return `unix:<dir>/.s.PGSQL.<port>` for a host that begins with `/` (the text upstream's `socket.goose` builds) and `connect_start` pass a text that begins with `unix:` to `dial` as it is, without appending `:port`; verify with a test in `test/io/` that a scripted peer at `unix:/var/run/postgresql/.s.PGSQL.5432` answers a query through `pg::query` exactly as the TCP test does, with no other source file changed
- [x] 5.2 Remove the sentences that say a Unix socket fails the dial from the shim's header and the adaptation's documents (`docs/architecture.md`, the decision entry), and rerun its whole test suite; verify the diff of this group touches only `httpshim.goose`, the new test and those lines, and that `pool.goose` is unchanged

## Workflow follow-up

- Archive the change after review with `openspec archive add-unix-sockets`, so the five modified requirements replace their current text in `openspec/specs/io-contract/`.
- Decide, when `epoll-event-loop` is applied, whether its loop supplies the unix group.
