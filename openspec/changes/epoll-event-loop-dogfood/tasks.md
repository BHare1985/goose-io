# Tasks

Work happens in `.implementations/tcprouter-goose-io` on a new branch; commits follow that repo's CLAUDE.md. Gap records go to the end of this file.

## 1. Setup and the first checks

- [ ] 1.1 Branch tcprouter-goose-io from HEAD 8cd67fe, record the baseline (46 test files, 0 failed, the bench numbers of `bench/RESULTS.md` re-measured on this host, bytes per idle connection) in `docs/port-baseline.md`; verify by running `tests/run_tests.sh` once in the background and `bench/run_m6.sh` through `run-locked.sh`
- [ ] 1.2 Check the retry question against the contract: write a conformance-style probe on goose-io-epoll-ext showing whether peeked ClientHello bytes can be sent to server A, A ends without a byte, and the same bytes are sent to server B before the client's bytes are consumed (RT-21, `gates/early_close_peek`); verify by the probe passing or a gap record
- [ ] 1.3 Make the library generic over `Io`: `Worker` wraps a loop of a type given at compile time, with the required groups listed once and checked at start (`require_*`); verify by a unit test that starting on a loop without a required group fails before any listener opens and names the group
- [ ] 1.4 Import goose-io-epoll-ext and goose-io as local paths for the work; verify by `goose check tcprouter.goose` and a build of `tests/net/harness/forward_server.goose` on the new Worker

## 2. Stage 1: forward by port

- [ ] 2.1 Listeners and accept on the loop: `start` listens on the configured addresses, `Opened` creates the connection's record, `max_conns_per_worker` and `stop_listening` on drain; verify by `listen_test`, `scale_test`, `generation_test`
- [ ] 2.2 Forward action by `dial` plus `relay`, with `connect_ms` and target rotation, and `Closed` mapped to tcprouter's `CloseReason` (including `PeerEof` and half-close); verify by `forward_test`, `halfclose_test`, `connect_ms_test`, `server_rst_test`, `backpressure_test`
- [ ] 2.3 Idle, half-close timeouts and drain on the limits group and `stop`; verify by `timeout_test`, `drain_test`, `drain_stall_test`
- [ ] 2.4 Measure the forward path now against the baseline (11 B, 16 KiB, 1 MiB, new connection per request) before more code depends on it; verify by a results file under `bench/results/`; a shortfall is a finding about the relay group

## 3. Stage 2: inspection, SNI routing, retry

- [ ] 3.1 Listeners with `inspect: Sni`: `wait_input` and `peek` give the hello to `match_route`, `inspect_timeout_ms` on the Silent limit; verify by `sni_forward_test`, `http_split_test`, the `sni` unit tests
- [ ] 3.2 Retry before any client byte is consumed, and the early-close retry (RT-21): the hello stays unconsumed until a server answers; verify by `retry_test`, `early_close_test`, `gates/early_close_peek`
- [ ] 3.3 TLS support rows (fences and SNI with real TLS clients); verify by `tls_support_test`

## 4. Stage 3: handler mode

- [ ] 4.1 `serve` with a block, `send`, `close`, `reset`, `set_user`, `pause_reading`, `send_room`, `shutdown_write`, `set_keep_open_on_eof`; verify by `handler_test`, `handler_edges_test`, `queues_test`, `http_server_test`
- [ ] 4.2 `dial` from a handler with a tag, `PassEnd` and the batching window; verify by `dial_test`, `passend_test`, `batch_test`, `fairness_test`

## 5. Stage 4: tags, deadlines, fences, messages, policy, stats

- [ ] 5.1 Tag table, serve-until deadlines (`tick_by` plus a heap), `CloseTagged`, fences via `write_deadline` and `discard_unsent`; verify by `deadline_test`, `handler_deadline_test`, `replace_deadline_test`, `tag_overflow_test`
- [ ] 5.2 Messages through the wake group (Drain, Stats, CloseTagged, ReplaceDeadline, Policy, SetAddr) and the policy hook; verify by `message_test`, `policy_message_test`, `serve_policy_test`, `set_addr_test`, `signal_test`
- [ ] 5.3 Stats; verify by the stats rows in `batch_test` and `policy_message_test`
- [ ] 5.4 Examples and README build and pass; verify by `examples_test`, `readme_test`, `comments_test`

## 6. Acceptance

- [ ] 6.1 Remove the old engine and C sidecar from the tree; verify by a search of the library files and `src/` for socket, epoll, accept, recv, send and connect calls (none)
- [ ] 6.2 Full suite once on a quiet host, in the background: 46 files, 0 failed, none edited; every test that failed once is rerun with `REPEAT=20` and explained
- [ ] 6.3 Speed and memory gates against the baseline (spec: no loss of speed); verify by a results file naming each workload's ratio; a miss is reported with its cause
- [ ] 6.4 Pin the imports by full commit hash and prove a fresh clone builds and passes `tests/run_tests.sh` (needs the user to push goose-io-epoll and goose-io-epoll-ext; ask first)
- [ ] 6.5 goose-io documentation names tcprouter-goose-io as the worked example of the contract and links it; verify by `openspec validate` on both changes and the docs checks
- [ ] 6.6 Report: what passed, what failed, what was not run, every gap found and its change, and any row without a test

## Gap records

<!-- one entry per gap: what the router needs, the nearest contract operation, why it cannot be built on it, the change that fixes it -->

### Found while reading, before coding (2026-11-22)

- G1 (predicted, confirm in 3.2): retry replays the ClientHello to a second server, then relays. `peek` consumes nothing and `relay` carries the
  held bytes first, so the hello would reach the server twice. Needs a way to consume held input (for example `discard_input(link, n)` in the peek group),
  or the router must route the hello through `wait_input(link, 0)` and `Data`, which is the workaround the design forbids. Fix: a small `add-peek-consume` change.
- G2 (tests that look inside the engine; decision needed): `tests/net/harness/edges_server.goose` and `tests/unit/generation_test.goose` feed forged events to
  the engine's own dispatch and read `stale_events`, `bad_events` (RT-2b, RT-2c); `buffers_in_use`, `buffers_total`, `buffer_waits`, `ready_len`,
  `waiting_len` (RT-5g, RT-2a in `flat_memory_test`, `scale_test`, `queues_test`, `memory_test`) read the engine's own buffer pool. On the contract those belong to the
  loop (link generations are checked by conformance; buffers are the loop's). The 46 files cannot all pass unedited unless the router keeps those counters
  as fixed or derived values, which would pass without proving anything. To be decided with the user (and Charlie for tcprouter's rules).
