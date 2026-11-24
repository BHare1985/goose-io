## Context

The contract has eleven capabilities in code (after `rename-groups-to-capabilities`): half-close, sizing, abort, inspection, batching, unix, relay, peek, revoke, wake, limits. Their rules are in `docs/contract.md` section 6, written for the event loop's author and the suite. A library author's guidance is scattered:

- `docs/libraries.md` covers keep-open, `Full`/`Writable`, deadlines, a path as an address, and limits.
- Examples exist for half-close (`examples/lineserver/server.goose`), unix (`tests/examples/unix_dial_test.goose`) and, after the rename, relay (`examples/forward/forward.goose`).
- Sizing, abort, inspection, batching, peek, revoke, wake and limits are shown only in conformance checks, which exercise rules and not uses.

`tests/checks/docs.sh` already proves that quoted code matches the repository (`<!-- source: -->`, `<!-- excerpt: path#name -->`), but only in `README.md` and `docs/*.md`. More capabilities are coming: four in `add-stream-extras` and twelve proposed beside this change. Each must arrive with its page.

## Goals / Non-Goals

**Goals:**

- One page per capability, the same shape on every page, answering what it is, when to use it, how it is commonly used, and examples.
- Every example is real code that builds and runs in CI.
- A check that makes a missing page, section or example a CI failure, so future capability changes cannot skip it.
- The pages become the way into a capability. The normative contract stays where it is and is linked.

**Non-Goals:**

- Rewriting `docs/contract.md`. Pages link to it and never restate a rule differently. Where a page summarises a rule, it quotes the contract's own wording or links to it.
- Pages for capabilities not yet in code.
- Generated documentation from source comments.

## Decisions

### D1. One directory, one page per capability, one index

`docs/capabilities/<name>.md`, with `<name>` exactly the capability's name in the contract (`half-close.md`, `relay.md`). `docs/capabilities/README.md` is the index. A page per capability, rather than sections of `docs/libraries.md`, gives each capability a stable link. Proposals and the check can then name a file, and `docs/libraries.md` stays about the shape of a library.

*Alternative:* sections in `docs/libraries.md`. Rejected: it is already 700 lines and would double, and a check of "a section per capability" is more fragile than a file per capability.

### D2. The fixed sections

```
# <Name>
## What it is            one paragraph; operations and events; link to docs/contract.md#<section>
## When to use it        problems it solves; when not to; what a library does without it
## How it is commonly used   patterns, in order of how often they are needed; mistakes to avoid
## Examples              at least one checked block, with a sentence before each saying what it shows
## Required or optional  require_<name> and the Needs: line; has_<name> and the branch, or why not
## Supplied by           in-memory, core-only, wrapper, epoll; outside loops; mapping documents
## See also              related capabilities and docs/libraries.md sections
```

"When not to use it" belongs on the page because most capabilities have a core alternative (`send` instead of `send2`, `close` instead of `reset`, copying instead of relay), and the question a library author asks is usually "do I need this?"

### D3. Examples: reuse what is built, write small programs for the rest

| Capability | Example quoted | Status |
|---|---|---|
| half-close | `examples/lineserver/server.goose` (keep open, answer after `PeerEof`, then `shutdown_write`) | exists; add `doc:` markers |
| sizing | `examples/capabilities/frames.goose`: length-prefixed frames sent with `send2`, `send_room` to stop before `Full` | new |
| abort | `examples/capabilities/reject.goose`: a server that resets a client which sends a malformed first line | new |
| inspection | `examples/capabilities/access_log.goose`: logs `peer_address` at `Opened`, `stop_listening` when draining | new |
| batching | `examples/capabilities/batch_reply.goose`: queues replies during a pass and sends them on `PassEnd` | new |
| unix | `tests/examples/unix_dial_test.goose` and the line server on `unix:/path` | exists; add markers |
| relay | `examples/forward/forward.goose` (from `rename-groups-to-capabilities`) | exists after the rename |
| peek | `examples/capabilities/sniff.goose`: `wait_input` for the first bytes, then serve or relay | new |
| revoke | `examples/capabilities/fenced_writer.goose`: `write_deadline` at a fence, `discard_unsent` when it is cancelled | new |
| wake | `examples/capabilities/worker_reply.goose`: a worker thread computes a reply and sends it back with `wake_with` | new |
| limits | `examples/capabilities/idle_reaper.goose`: `Idle` and `Age` limits on a relayed pair, closing on `Expired` | new |

Each new example is a library of the repository's usual shape (state, a `step` for events, a `// Needs:` header) and is at most about 150 lines, so it can be read whole. Each has a test in `tests/examples/capabilities/` on the in-memory loop. The pages quote parts through `// doc:begin`/`// doc:end`. They are examples, not reusable libraries, and `examples/README.md` says so.

*Alternative:* quote conformance checks. Rejected: a check tests a rule at its edge, which is the opposite of common use.

### D4. The page check reads the contract, not a list

`tests/checks/capability_pages.sh` takes the capabilities from `goose_io.goose` (each `fn has_<name><`, added by the rename) and the operations of each from its `require_<name>` (the `io.<op>(` calls). It needs no list of its own to keep in step. It fails when:

- a capability has no page, or a page has no capability;
- a page lacks a section of D2, or has them out of order;
- "What it is" does not name every operation and event of the capability (events are taken from the `// <Name>:` comment above each `require_`, which already lists them);
- "Examples" has no `source:` or `excerpt:` block;
- the index has no row linking the page.

`tests/checks/docs.sh` is extended to `docs/capabilities/*.md`, so every quoted block is compared to its file. `tests/run_tests.sh` already builds and runs `examples/` and `tests/examples/`, and the new directory is added to it.

Batching and unix have no `require_` check. Their operations and events come from the comment above their `has_` query (`// Batching: event PassEnd`, `// Unix: the address form unix:/path`), which the rename's task 1.1 writes.

### D5. Pages link, they do not restate

Each "What it is" links to `docs/contract.md#<section>` and gives a summary in a library author's terms. When a page needs a rule exactly, for example the state table of relay, it links to it rather than copying it. A copied rule would drift, and the contract is the one place a rule is stated. `docs/contract.md` section 6 gets one line per capability linking to its page.

## Risks / Trade-offs

- [Eight new example programs are code to maintain] → each is small, uses one capability, and is tested. A contract change that breaks one breaks its test, which is the point.
- [The page check's text parsing of `goose_io.goose` is brittle] → it reads only the `fn has_` and `fn require_` lines and the comment above them, a format `goose format` keeps stable. The check has its own must-fail fixtures (a page with a missing section, a capability with no page).
- [The wake example needs a thread and the in-memory loop] → the in-memory loop supplies wake and its tests already wake from a thread. The example uses the same pattern, and its test joins the thread before it ends.
- [Pages drift from the contract in prose] → only examples are checked mechanically, so pages keep rules to links (D5). Review covers the prose.

## Migration Plan

Additive. Pages, examples and checks land together. The page check runs in CI from the same commit, so it is never red on `main`.

## Open Questions

- Should "Supplied by" be generated from the loops' declarations (an aggregate query, as in the rename's open question) instead of written by hand? Written by hand for now, since the epoll loop lives in another repository.
