# Benchmarks

Micro-benchmarks of goose-io, and the performance gates of the epoll event loop. They are built and run by hand: nothing here is part
of `just test` or of CI. A micro-benchmark never decides whether a change passes; a gate (below) is what the loop must hold before it is
accepted, and is run on an idle host. Each file explains what it measures and how to read it in its own header.

## Index

| Benchmark | Question it answers | Run |
|---|---|---|
| [`link_map_bench.goose`](link_map_bench.goose) | What does finding a library's state by link cost: `goose_io::LinkMap` against a table written by hand, and against a compact layout? | `goose build bench/link_map_bench.goose -o /tmp/link_map_bench && taskset -c 2 /tmp/link_map_bench` |
| [`gate_syscalls.sh`](gate_syscalls.sh) | Does the epoll loop make the same system calls per request as tcprouter's engine on the same HTTP program? | `bench/gate_syscalls.sh` |
| [`gate_http.sh`](gate_http.sh) | Does it match tcprouter's throughput, p99 latency and CPU per request (one worker, pinned CPUs, `wrk`, alternating rounds)? | `bench/gate_http.sh` |
| [`gate_memory.sh`](gate_memory.sh) | Is its memory no more than tcprouter's, and at most 512 bytes per idle link? | `bench/gate_memory.sh` |
| [`gate_forward.sh`](gate_forward.sh) | Does the loop with tcprouter's forward pump added back (goose-io-epoll-ext) hold tcprouter's forwarding numbers on 11 B, 16 KiB and 64 KiB keep-alive workloads? | `bench/gate_forward.sh` |

## The gates of the epoll event loop

The baseline is tcprouter's own engine on the same program ([`BASELINE.md`](BASELINE.md): which commit, how it was built, on which host). The
gates need `strace`, `wrk`, `python3` and a C compiler, a host with no other load, and the baseline programs in `bench/baseline/` (git-ignored:
tcprouter's repository is private). Each stores its table under `results/` with both commits and the host. The gates are:

- **system calls per request**, `strace -c -f` over a sequential client: `recvfrom`, `sendto`, `accept4`, `epoll_ctl` and `close` equal (a
  difference of 40 calls over the run is the start-up and shutdown of a process); `epoll_wait` no more than the baseline's within 3%, since how
  many events one wakeup finds depends on timing;
- **throughput, p99 latency and CPU per request**, one worker on a pinned CPU, `wrk` on others, at least seven alternating rounds, a round void
  when the server used under 90% of its core, the candidate's median within or better than the baseline's own min-to-max range;
- **memory**: idle RSS, RSS with 10,000 idle links and under load no more than the baseline's (within 3%), and at most 512 bytes for a link that
  holds no state of the program's own (goose-io-epoll's `tests/idle_server.goose` against the same program on tcprouter).

## Running a benchmark

- **Build, don't `goose run`.** `goose build` compiles at `-O2`; `goose run` at `-O1`. Only the `-O2` figure matters.
- **Pin one core and keep the machine idle** (`taskset -c 2 ...`). A benchmark that shares a core with a build or another
  benchmark reports the other process's noise.
- **Treat small gaps as ties.** Figures of a few nanoseconds move by a nanosecond or two between runs (the same code
  was seen at 1.4 ns and 3.7 ns on different runs). Run three times and use the median; a difference that is not larger
  than that spread is not a difference.
- **Say where it was measured.** Figures depend on the machine, so a result that is kept in a document (for example
  in an OpenSpec design) names the machine, the compiler version and the date.

## `link_map_bench`

A library keeps its state in a table keyed by `Link`. The benchmark measures three tables with the same functions
(`put`, `find`, `drop`):

- **by-index**: the old way, written by hand: one array of `{generation, value}` indexed by slot, a bounds check and a generation
  compare (what a library's `_conn_of(user, link)` did before the tag and the user value were removed).
- **linkmap**: `goose_io::LinkMap<T>`, the implementation the contract package ships: the same layout as by-index behind
  `put`, `find`, `has` and `drop`, so the comparison shows what the shipped functions add.
- **compact**: a layout a library can write for itself when its state is large and the event loop is large and busy: 8 bytes of
  metadata for each slot and one value for each link the library owns. It is not in the contract package.

`find` is the time to look a link up and touch its value (random order, a hit every time). `drop+put` is a connection
closing and another opening on the same slot. Memory is what the table has reserved.

### Result

Measured on the machine this was written on (an 8-core Linux x86-64 machine, goose v2026.4, `-O2`, one pinned core,
idle, median of three runs, 2026-11-17). `find` and `drop+put` are in nanoseconds. "Overhead" is `linkmap` minus
`by-index`. Memory is the table's reserved size, computed from its length and the entry size (a generation padded to 8
bytes beside the value).

| Scenario (loop slots / links the library owns) | State | by-index `find` | linkmap `find` | Overhead | `drop+put` by-index / linkmap | linkmap memory (KiB) | compact `find` / memory (KiB) |
|---|---|---|---|---|---|---|---|
| 1,024 / 16 | 32 B | 1.4 | 1.4 | +0.0 | 24 / 21 | 0 | 1.8 / 0 |
| 1,024 / 1,024 | 32 B | 4.3 | 1.6 | -2.7 | 24 / 21 | 40 | 2.1 / 40 |
| 100,000 / 16 | 32 B | 1.4 | 1.4 | +0.0 | 24 / 21 | 3,906 | 1.8 / 781 |
| 100,000 / 1,024 | 32 B | 4.8 | 2.0 | -2.8 | 24 / 21 | 3,906 | 2.6 / 813 |
| **100,000 / 100,000** | 32 B | 15.4 | 16.0 | +0.6 | 39 / 42 | 3,906 | 18.9 / 3,906 |
| 1,024 / 16 | 128 B | 1.4 | 1.4 | +0.0 | 42 / 40 | 2 | 1.9 / 2 |
| 1,024 / 1,024 | 128 B | 1.8 | 4.9 | +3.1 | 43 / 42 | 136 | 6.8 / 136 |
| 100,000 / 16 | 128 B | 4.4 | 4.3 | -0.1 | 41 / 40 | 13,281 | 1.9 / 783 |
| 100,000 / 1,024 | 128 B | 5.2 | 3.2 | -2.0 | 43 / 43 | 13,281 | 9.8 / 909 |
| **100,000 / 100,000** | 128 B | 18.6 | 18.8 | +0.2 | 181 / 180 | 13,281 | 34.5 / 13,281 |
| 1,024 / 16 | 512 B | 1.4 | 1.4 | +0.0 | 185 / 185 | 8 | 1.8 / 8 |
| 1,024 / 1,024 | 512 B | 1.9 | 4.9 | +3.0 | 188 / 188 | 520 | 4.3 / 520 |
| 100,000 / 16 | 512 B | 4.5 | 4.1 | -0.4 | 178 / 178 | 50,781 | 1.8 / 790 |
| 100,000 / 1,024 | 512 B | 5.1 | 2.1 | -3.0 | 194 / 194 | 50,781 | 6.8 / 1,294 |
| **100,000 / 100,000** | 512 B | 19.9 | 19.8 | -0.1 | 489 / 495 | 50,781 | 39.4 / 50,781 |

### What it says

- **`LinkMap` costs what the hand-written table costs, including at its largest use.** The last row of each state size is the
  maximum the contract allows for one library: every one of 100,000 slots is its own. There `LinkMap` is +0.6 ns (32 B),
  +0.2 ns (128 B) and -0.1 ns (512 B) against the hand-written table, and it is the same code behind four functions, so
  the wrapper adds nothing measurable. The other rows move between about -3 and +3 ns, the same noise: the identical code
  was seen at both 1.4 ns and 4.4 ns in different runs, in both arms (read the individual runs if in doubt).
- **Memory is identical**: the table reserves the loop's peak slot count times the size of an entry.
- **The cost that is there is the table, not `LinkMap`.** A lookup grows from about 1.4 ns with a handful of links to 16-20 ns
  when the library owns all 100,000 slots, because the table no longer fits in the cache. That is the price of any
  table indexed by slot at that size, hand-written or not, and it is one lookup for each event, where an event includes at
  least one system call (hundreds of nanoseconds or more, not measured here).
- **`drop+put` is dominated by copying the state** (11 to 24 ns for 32 to 128 bytes, about 190 ns for 512 bytes), and is
  equal in both arms.
- **No operation allocates** apart from `put` growing the table (a pointer bump on the data stack). `find`, `has` and `drop`
  only read and write entries that exist.
- **The compact layout buys memory, not speed**: 0.8 MiB instead of 49 MiB for a library that owns 16 of 100,000 slots
  with 512-byte state, at about the same lookup time, and twice as slow in the largest case (39 ns against 20 ns, because
  every lookup reads the metadata and then the value). It is not worth its extra code unless a library has that shape; the
  design records it as a layout a library can write for itself.

### History

An earlier version of `LinkMap` kept the generations and the values in two arrays (a `root struct`). It measured the same
as the hand-written table everywhere but the largest case with 512-byte state, where it was 10 ns slower (33.7 ns against 23.7 ns:
two cache lines for each lookup). It also could not be held in a library's own state, because Goose does not allow a
`root struct` to be a field of another struct. `LinkMap` is now one array of `{generation, value}` in an ordinary struct, which
removes both problems; the table above is that version.

### Changing a result

To measure a table of your own, give it `put`, `find`, `drop` and a `reserved` function with the same shapes as the arms in
the file, and add a `run<YourTable<T>, T>(...)` line to `arms`. When the contract package's `LinkMap` changes, re-run and update the table
above with the date, the machine and the compiler version.
