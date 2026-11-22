## Context

- `add-proxy-groups` adds the five capabilities tcprouter needs (relay, peek, revoke, wake, limits). This change adds the four that other stream programs need, in the same style, so that the contract's list of capabilities is complete before the loops and tcprouter use any of them. It applies after that change.
- The gaps: an HTTP or file server cannot send a file without reading it into memory; a program that has a header, a body and more cannot send them as one without joining them (`send2` takes two); a program that wants to send without a copy cannot lend a buffer to the loop; a transparent proxy or an access log cannot ask for the loop's own address or the address the peer connected to before a redirect.
- Since this change was first written, `rename-groups-to-capabilities` renamed groups to capabilities, gave each capability a compile-time declaration (`supplies_<c>`, `has_<c>`) and let a library use a capability optionally. `document-capabilities` gave each capability a page in `docs/capabilities/`. This change follows both, and its delta specs are written against the specs as they stand after those two are archived.
- This change is the contract, the in-memory loop and the suite only. Implementing a capability on a real loop is later work, and a capability with no user may stay unimplemented there.

## Goals / Non-Goals

**Goals:**

- Four capabilities stated by behaviour, each with an operation or two, so a loop may use `sendfile`, `writev`, `MSG_ZEROCOPY` or `getsockname` and a library says which it needs.

**Non-Goals:**

- Naming a kernel mechanism, implementing on a real loop, a file system API (the capability opens a file for sending and nothing more), memory-mapped input, and everything out of scope in `add-proxy-groups`.

## Decisions

### D1. Mechanisms behind the intents

| Capability | Intent | Mechanisms a loop may use |
|---|---|---|
| files | send a file's bytes | `sendfile`, io_uring splice from a file, a read and send |
| loans | send from a lent buffer without a copy | `MSG_ZEROCOPY`, `IORING_OP_SEND_ZC`, a copy |
| parts | send several ranges as one | `writev`, `sendmsg`, a join |
| addresses | the local end, and the destination before redirection | `getsockname`, `SO_ORIGINAL_DST`, `IP_TRANSPARENT` |

A loop that implements an operation by a plain copy conforms.

### D2. files and loans add a handle type each

`File` and `Loan` are fixed-size handles checked for staleness the way `Link` is: a slot and a generation, the invalid value reserved, a stale handle touching nothing. A `File` is opened by the library and closed by it; a send that has been accepted keeps its bytes readable after `close_file`. A `Loan` is owned by the loop from `Sent` on. The in-memory loop's file is a byte range the test registers by name, so a path in the in-memory loop is a name of that registry.

### D3. loans are bounded and a copy conforms

A loop that lends buffers must bound them, so a library that never releases cannot make memory grow; the bound is the loop's and `loan` returns an invalid handle at it. A loop with no way to send without a copy implements `send_loan` as a copy and conforms: the point of the operation is that it permits better.

### D4. parts generalises send2

`send_parts` takes a list of ranges and behaves as one `send` of their join. Its size for `Full` and `TooLarge` is the sum, so the rules of `Writable` and `send_room` are those of `send`. A loop bounds the list's length and answers `TooLarge` over it.

### D5. addresses

`local_address` names the loop's own end; `original_destination` the address the peer asked for before a system redirect, and the same text as `local_address` when there was none. Both use the contract's address text and are empty for a link that is not open, a stale link, or a `unix:` link, and valid in the handler of `Closed` like `peer_address`.

### D6. Each of the four is declared, and three are worth using optionally

`goose_io.goose` gains `supplies_files`, `supplies_loans`, `supplies_parts` and `supplies_addresses` with the `Absent` default, and `has_files` … `has_addresses`, as the rename does for the first eleven. `require_files` and the others also check the declaration. The in-memory loop declares all four, and the core-only loop and the test wrapper declare none, apart from what the wrapper forwards.

files, loans and parts each make an existing core behaviour cheaper, so a library should use them optionally rather than require them:

| Capability | Branch when supplied | Other path (core only) |
|---|---|---|
| files | `open_file` once, `send_file` ranges | read the file in the library and `send` it in pieces under `max_send` |
| loans | `loan`, fill `loan_bytes`, `send_loan` | fill a buffer of the library's own, `send` it |
| parts | `send_parts(link, parts)` | join into one buffer, `send`, or `send2` when the loop declares sizing |
| addresses | `local_address`, `original_destination` | none: a transparent proxy cannot work without the original destination, so it requires addresses |

A new example, `examples/capabilities/static_files.goose`, serves files from a registry and takes both paths: `send_file` and `send_parts` (header and body) when supplied, and read-and-`send` otherwise. Its tests run on the in-memory loop and on the core-only loop, as the forward example's do.

### D7. Each of the four gets its page

Following `document-capabilities`, the change adds `docs/capabilities/files.md`, `loans.md`, `parts.md` and `addresses.md`, each with the fixed sections and an index row:

- **files**: when serving a static file or a large blob, so the bytes never pass through the library. Not for small or generated responses, where the open/close cost more than a `send`. The example is `static_files.goose`.
- **loans**: when a library builds large messages and sends many of them (a broadcaster, a replication stream), so the loop may send without a copy. Not for small replies. The page says that a copy conforms, so a loan is a permission, not a promise.
- **parts**: header, body and trailer, or a frame prefix and scattered payload, without joining them. It replaces `send2` for more than two parts. The page shows the fallback join.
- **addresses**: access logs that need the local port on a multi-address server, and transparent proxies (`original_destination`). The example is a small transparent forwarder over the in-memory loop's scripted redirection.

`tests/checks/capability_pages.sh` fails until all four pages exist, because it reads the capabilities from `goose_io.goose`.

## Risks / Trade-offs

- **Speculative capabilities** → specified, tested in memory, and implemented on a real loop only when a program needs one; the documentation lists a loop's capabilities, so a capability no loop supplies is honest about it.
- **`File` opens a hole in "no operating-system primitives"** → the handle is opaque and the path is text; no descriptor appears. The in-memory loop shows the contract needs none.
- **The version goes up one minor step** from the version this change lands on (the rename raises it once before) → a minor increase while the major is zero.

## Migration Plan

- Applies after `rename-groups-to-capabilities` and `document-capabilities` are applied and accepted, on a branch; nothing is pushed or tagged without the owner's approval. Additive; reverting is a revert of the merge.

## Open Questions

- Whether `loan_bytes` needs a guard against use after `send_loan` on a loop that does not copy (a stale-checked view): settled with the first check.
