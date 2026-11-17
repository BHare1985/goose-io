# Design

## Context

See `proposal.md`. After `scoped-library-views`, a view stands between a library and the loop on every call. The address is a string already in the form the contract defines (`host:port`, `[v6]:port`, `unix:///path`, `unix://@name`), so the check needs no resolver.

## Goals / Non-Goals

**Goals:** a library reaches only addresses the application allowed; a refusal is visible and cheap.
**Non-Goals:** name resolution (the contract takes addresses), a firewall, a check on peers.

## Decisions

**D1. Allow-list, not deny-list.** A deny-list names what the author thought of; an attacker uses the next address. An unlisted address is refused. Rejected: a deny-list of private ranges, which fails open.

**D2. No default.** As for limits, a default is a guess. `allow_all()` is the explicit choice for a trusted library.

**D3. Rules by kind.** `TcpRule { net, prefix_bits, port_lo, port_hi, dial, listen }` for IPv4 and IPv6, and `UnixRule { prefix, dial, listen }`. A rule applies to the operations it names. The policy is a struct holding two arrays (TCP, unix); because Goose allows one resizable field in an ordinary struct, the two sit in two structs behind a small wrapper, decided in the first task.

**D4. Parsing is the check's own.** The view parses the address once with a small parser (IPv4 dotted quad, bracketed IPv6, port, `unix://` forms). An address it cannot parse is refused; the loop would have failed it anyway, and a view must not pass what it cannot read.

**D5. Unix paths match on whole components after `..` is refused.** `/run/app` allows `/run/app` and `/run/app/x`, not `/run/application`. Abstract names (`unix://@name`) have their own prefix rules and are matched the same way on the name. A symbolic link under an allowed prefix is resolved by the operating system after the check; the view cannot see it, and the document says so. Rejected: calling `realpath`, which is a blocking system call in a layer that is pure Goose, and which races with the call.

**D6. `Denied` is a new `ListenErrorKind`.** A refused `listen` is not `Other` and not `NoResources`; the application and the library can tell a policy from a failure. Event loops never produce it, so none changes its behavior; one that maps kinds exhaustively adds a case.

**D7. A refused dial returns the invalid link.** The same decision as in the limits proposal (D3 there), and the same contract text (*A layer may refuse a dial*). If both proposals are applied the requirement is defined once, in whichever is applied first, and the other refers to it.

**D8. Helpers are values.** `allow_all()` (every address), `loopback_only()` (127.0.0.0/8 and ::1, all ports, both operations), `deny_unix()` (TCP only). An application combines rules by building a policy.

## Risks / Trade-offs

- [Policy strings are parsed on every call] → A rule match is a few integer compares; the parse is bounded by the address length. Measured in the bench with the cost of a view.
- [IPv4-mapped IPv6 addresses (`::ffff:127.0.0.1`) bypass an IPv4 rule] → The parser maps them to IPv4 before matching; there is a test.
- [A path rule gives a false sense of safety] → The document states the symbolic-link case and that this is not a sandbox (see `security-model`).
- [The invalid link gives no reason] → The application can add a counter of refusals per library, as the limits proposal does; shared, not repeated here.

## Open Questions

- Should the policy be changeable while the loop runs? Not now: it is fixed when the library is added.
