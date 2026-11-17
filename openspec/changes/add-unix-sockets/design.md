# Design

## Context

See `proposal.md` for why. What exists on main:

- The contract is a core (13 operations, 5 events) and five optional groups: half-close, sizing, abort, inspection, batching. A rule of a group binds only a loop that supplies it, and a rule of the core depends on no group. `goose_io.goose` has `require_core` and one compile-time check for each group that has operations; batching has none.
- The suite is run one group at a time. `conformance/support.goose` has a marker type and a `GROUP_*` number for each group, `conformance/suite.goose` an entry point for each (`conformance_core_part`, `conformance_batching_part`, and so on) and a `group_of` table, and `tests/conformance/checks.tsv` has a `group` column. A check of a group may call the core and its own group's operations and no other group's; `tests/conformance/groups_check.sh` enforces it.
- Every check has a recorded fault of the in-memory event loop (`memory.goose`, `set_fault`), and `faults.sh`, `table_check.sh` and `groups_check.sh` fail when a check has none.
- Addresses are numeric text. `Address` (what `peer_address` returns) is `u8[..56]`. In memory an address is `_Addr { ok, v6, ip[16], port }`, compared by four helpers; scripted peers, `hold`, `fail_dials` and `silent` all parse text through `_parse_address`.
- `tests/support/core_only.goose` is a loop that supplies the core and nothing else, over the in-memory loop; `tests/support/wrapper.goose` passes everything through.
- The text `unix:/dir/.s.PGSQL.<port>` is what the PostgreSQL pool's existing source builds for a same-machine server.

## Goals / Non-Goals

**Goals:**
- A library asks for a Unix socket with a string, and every event loop answers it as the specs say, whether it supplies the group or not.
- No operation, event or type changes, so nothing that exists breaks.
- The in-memory loop and the suite prove the group, and each new check has a recorded fault.

**Non-Goals:**
- A socket-backed loop, and anything about the file system (creating, removing, or setting the permissions of a socket file is the loop's business).
- Abstract names, relative paths, other socket types, peer credentials, descriptor passing.
- Any change to a library, or to the mapping documents of candidate loops.

## Decisions

**Unix is a sixth group, not a change to the core.** It is optional for an event loop, a library asks for it by name, and a loop without it stays conforming. The core's "TCP byte streams" is unchanged. The rules that bind only a loop supplying the group (the form, its path rules, no port, no peer text) are stated as the group's. Rejected: putting the form in the core, which would make every existing loop non-conforming for a feature most libraries do not use; and a separate contract, which would split every library's imports for one address form.

**The form is the text `unix:/path`, in the arguments `dial` and `listen` already have.** It is the text goose-http takes and the PostgreSQL pool already builds, so a library moves with no change to what it passes. Rejected: new operations (`dial_unix`, `listen_unix`), which every loop and wrapper would have to add and the compile-time checks would have to name; and a typed address argument, which would change every call in every library.

**The group has no compile-time check.** It has no operation, like batching: `require_core` and the others already cover every call it makes. What a loop that claims it must do is shown by the suite. Rejected: a `require_unix` that dials a literal, which would check nothing the types can express.

**A loop that lacks the group answers `BadAddress`; the suite does not check that.** The unix suite runs only against a loop that supplies the group, and a core check cannot dial a well-formed path and expect refusal, since a loop that supplies the group accepts it. The refusal is shown on the in-memory loop (a configuration that turns the form off) and on the core-only loop, by tests of this repository, and is what the specs say of every loop that does not supply the group. Rejected: a fixture flag that tells the suite what a loop claims, which would be a second place to say what the group's entry point already says.

**The path is absolute, at most 103 bytes, with no NUL and no leading `@`.** 103 is the smallest `sun_path` among the common systems (104 on macOS and the BSDs, less the terminator; Linux has 108), so one limit is checkable on every loop and the check for the longest path is portable. The `@` rule keeps Linux's abstract names out of the form on every system. A loop does not normalise: `unix:/a/../b` is the path as written. Rejected: Linux's 107, which would make a conforming macOS loop fail the check; relative paths, which depend on a working directory a library cannot see.

**No port, no peer text.** `listener_port` returns 0 for a path (it is a core operation, so the group's own checks can call it). `peer_address` returns the empty value, which the contract already defines as "unknown": `Address` has 56 bytes, a path up to 103, and the peer of an accepted Unix connection has no name. That rule binds a loop supplying both the unix and the inspection groups, so neither group's suite can check it without calling the other group's operation; it is shown by a unit test on the in-memory loop and is not in `checks.tsv`. Rejected: widening `Address`, which changes a type every library holds; a cross-group check, which the suite's own rule forbids.

**A path that is not listened on is `Refused`.** A real system reports a missing file (ENOENT) or a file nobody listens on (ECONNREFUSED); both mean "nothing accepts connections there". Rejected: a new kind, which changes an enum.

**In memory, a path is a name.** `_Addr` gains `unix: bool` and a `path` of up to 103 bytes. Two Unix addresses are the same endpoint, and overlap, when the paths are equal; a Unix address never overlaps a numeric one; the wildcard rule does not apply to it; `listen` skips the port search; the accepted link's remote is a Unix address that formats as the empty value. Scripted peers, `hold`, `fail_dials` and `silent` already go through `_parse_address`, so they accept the form with no further change. A configuration field turns the form off, and the core-only loop sets it. Rejected: a second table for Unix endpoints, which would duplicate the four helpers and every place that calls them.

**The fixture gains a path.** `Fixture` gets `unix: const u8[:] = ""`: an absolute path the loop may create a socket at. A loop on a real file system needs one it may write to, which only its author knows. The checks derive their other paths from it (a suffix for "nothing listens", the same directory padded to 103 and to 104 bytes for the limits). The unix entry point needs it set.

**The checks and their faults.** `unix_listen_dial` (a listener and a dial, data both ways, tags and handles; fault `UnixListenerIgnored`, a dial to a path never reaches its listener), `unix_held_path` (`UnixOverlapIgnored`), `unix_nothing_listens` (`UnixRefusedAsBadAddress`), `unix_no_port` (`UnixPortInvented`), `unix_malformed_paths` (`UnixRelativeAccepted`) and `unix_longest_path` (`UnixLongestRefused`). They live in `conformance/net.goose` beside the dial and listen checks, are in group `unix` in `checks.tsv`, and are run by their own entry point, `conformance_unix_part`.

**The version goes to 0.2.** The contract is at major 0, where a minor increase may change behaviour, and a new group is the kind of change that rule is for. The tests that state the version, `docs/contract.md`, `README.md` and the table of loops change with it.

**The goose-postgres adaptation changes as little as possible, afterwards.** Its pool is upstream's source with `http::` renamed `httpshim::`, over a shim, `httpshim.goose`, that runs the calls on this contract; it lost Unix sockets only because the contract has none. Once the group exists the text is what upstream builds, so the shim restores the branch of its `socket_address` that returns `unix:<dir>/.s.PGSQL.<port>` for a host that begins with `/`, and `connect_start` passes a `unix:` text on without adding `:port`. The pool, its signatures and its tests do not change; the one new test shows a query at a path. The last task group lists these.

## Risks / Trade-offs

- [The group is exercised only by the in-memory loop until a socket-backed loop supplies it] → The checks are written against the contract, the fixture lets a real loop choose its path, and a gap is expected to show on the first real loop, as for every check. The proposal states it.
- [`epoll-event-loop` is unapplied and says its loop supplies "every group"] → That sentence is read at the time it is applied; either the loop supplies the group (its sockets make it cheap) or the change says five. This change edits nothing there.
- [103 is shorter than Linux allows, so a long path that works on one system is `BadAddress` on a conforming loop] → That is the rule on every system, so a library finds out anywhere; `/var/run/postgresql/.s.PGSQL.5432` is 34 bytes.
- [A loop that claims the group and leaves a socket file behind] → The fixture documents that the path is the loop's to create and remove, and the suite stops its listeners before it ends.
- [The two refusals (a loop with the group off, the core-only loop) are shown by tests of this repository and not by the suite] → That is what the group's definition allows; a loop without the group is a core loop, and the core suite proves everything else about it.
- [The existing requirements for `Listening` and `Dialling` say TCP] → They are read with the unix group's requirements, which say the form has the same operations, events and rules; restating them would copy two long requirements for one clause.

## Migration Plan

Nothing to migrate: no operation or type changes. A library that wants the form passes `unix:/path`; one that does not never sees a difference. An event loop adds the group when it can, and runs the unix entry point with a fixture path. The table of loops in `README.md` gets the group for the in-memory loop and the wrapper and none for the core-only loop.

## Open Questions

- Whether a later change should widen `Address` so that `peer_address` can return a path, if a library asks.
- Whether a socket file's permissions deserve a configuration note once a real loop supplies the group.
