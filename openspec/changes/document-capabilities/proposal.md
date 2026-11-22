## Why

`docs/contract.md` section 6 states each capability's rules for the loop author. Nothing tells a library author which capability solves their problem, when to reach for it, or what a working use looks like. That knowledge is spread over `docs/libraries.md` sections, test files and the examples, and some capabilities (revoke, limits, wake, batching) have no worked example at all. With eleven capabilities in code and more proposed, a library author has to read the normative contract to find out what relay is for. Each new capability also needs a fixed place for its documentation, so that the proposals that follow can say "add its page" and a check can hold them to it.

## What Changes

- Add `docs/capabilities/`, with one page for each of the eleven capabilities in code (half-close, sizing, abort, inspection, batching, unix, relay, peek, revoke, wake, limits) and an index, `docs/capabilities/README.md`.
- Every page has the same sections:
  - **What it is**: one paragraph, the operations and events, and a link to the normative section of `docs/contract.md`.
  - **When to use it**: the problems it solves, and when not to use it, including what to do instead without it.
  - **How it is commonly used**: the usual patterns and the mistakes to avoid.
  - **Examples**: at least one quoted from code that is built and tested.
  - **Required or optional**: how a library requires it or uses it only when supplied.
  - **Supplied by**: which in-repository loops supply it, and which known loops do.
  - **See also**.
- The index explains what a capability is, how a loop declares one and a library asks for one (from `rename-groups-to-capabilities`), and has a table with each capability's one-line purpose, its operations and events, and its page.
- Add small example programs, `examples/capabilities/<name>.goose`, each with its test, for capabilities that no existing example or test shows in common use. Every example in a page is an `excerpt:` or `source:` block that `tests/checks/docs.sh` checks.
- Extend `tests/checks/docs.sh` to read `docs/capabilities/*.md`. Add `tests/checks/capability_pages.sh`. It fails when a capability that the contract declares (a `has_<c>` query in `goose_io.goose`) has no page, when a page lacks a required section or an example, or when the index omits a page. A future capability cannot land without its page.
- Link the pages from `README.md`, `docs/libraries.md` ("What a library needs"), `docs/contract.md` section 6 (one link per capability) and `CONTRIBUTING.md` (adding a capability means adding its page).

Out of scope: changing any capability's behaviour; pages for the capabilities of `add-stream-extras` and the advanced proposals (each of those changes adds its own page, and the check holds it to that); moving normative text out of `docs/contract.md`.

## Capabilities

### New Capabilities

- `contract-documentation`: every capability of the contract has a page of a fixed shape, with checked examples, listed in an index, and a check fails when a capability lacks one.

### Modified Capabilities

None. The contract and the suite do not change.

## Impact

- **Documents:** new `docs/capabilities/README.md` and eleven pages. Links from `README.md`, `docs/libraries.md`, `docs/contract.md` and `CONTRIBUTING.md`.
- **Code:** new examples under `examples/capabilities/` with tests under `tests/examples/capabilities/`, added to `tests/run_tests.sh`. `// doc:begin`/`// doc:end` markers added to existing examples and tests that the pages quote. No change to `goose_io.goose`, the loops or the suite.
- **Checks and CI:** `tests/checks/docs.sh` reads the new directory. New `tests/checks/capability_pages.sh` is added to `.github/workflows/ci.yml`.
- **Order:** applies after `rename-groups-to-capabilities` (it uses that change's word, its declarations and its forward example). Applies before `add-stream-extras` and the advanced capability changes, which each add a page.
