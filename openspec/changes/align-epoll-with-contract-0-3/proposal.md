## Why

The open change `epoll-event-loop` (46 unchecked tasks, nothing applied) was written against contract 0.1/0.2. Contract 0.3 (`link-keyed-state`) removed the tag and the user value from every event and operation, and added two obligations on an event loop: slots are dense, and a slot is freed only after every handler of its `Closed` has returned. Applied as written, the epoll change would build a loop for a contract that no longer exists: `listen(address, tag)`, events with `tag` and `user`, `set_user` and `user`, and a tag-based extension hook. It must be brought up to date before anyone applies it, and by its own proposal, not by a quiet edit: `link-keyed-state` left it untouched on purpose and said its owner would revise it.

## What Changes

This change is planning only. It edits no code and no file of `epoll-event-loop` itself; its tasks revise that change's planning artifacts (through `openspec-update-change`, one artifact at a time, each confirmed by the owner) so that `epoll-event-loop` matches contract 0.3. What must change there:

- **No tag, no user value.** The loop's operations and events are the contract's: `listen(address)`, `dial(address, connect_ms)`, events that carry the link (and, for `Opened`, the listener), a core of twelve operations. `set_user` and `user` rows and tasks go; the inspection group is `peer_address` and `stop_listening`. Where tcprouter's engine carries a tag, the tag is the extension's own (a route's lease or deadline): it lives in the extension's per-slot state, indexed by slot, and the loop carries none.
- **The extension seam identifies a link by its slot.** The hook `allows(w, tag)` becomes `allows(w, slot)`; `wait_limit`, `on_message` and the tag deadlines stay the extension's, and nothing about them reaches the contract.
- **Dense slots, freed after `Closed`.** The loop keeps its slot table dense (a freed slot is reused before a new one is issued, from a free list) and frees a slot only after every handler of its `Closed` has returned. This is also the repair for the known defect in the mapping document (the slot of a dial that failed inside `dial` is freed before its `Closed` is delivered). The conformance expectations are the suite's new checks (`slots_dense`, `slot_kept_during_closed`, `owner_listener_named`, `owner_dial_found_by_link`, `dial_no_event_inside`).
- **Version and counts.** "Contract 0.1", "13 operations" and "five groups" become 0.3, twelve and six groups; the sentence that the loop "supplies every group" is made exact (see the design's open question about the unix group).
- **Ordering.** The epoll change's "merge after `contract-v1` and `simplify-contract`" becomes "after `link-keyed-state` and `lifecycle-guarantees`".

Out of scope: applying any task of `epoll-event-loop`, deciding whether the loop supplies the unix group (recorded as an open question for the owner), any change to the contract, the conformance suite or the in-memory loop, and any edit of tcprouter.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `epoll-event-loop`: this capability has no main spec yet (its change is unarchived), so the delta here is written as ADDED requirements that the revised spec of `epoll-event-loop` must contain (no tag or user value attached, slots dense and held until `Closed`). The tasks move them into that change's own spec, and this change is archived with `--skip-specs`, so the requirements are not created twice.

## Impact

- **`openspec/changes/epoll-event-loop/`:** `proposal.md`, `design.md`, `tasks.md` and `specs/epoll-event-loop/spec.md` are revised, in the places the design lists. No task there is ticked.
- **Code, tests, docs of goose-io:** none.
- **Order:** this change is applied (its tasks run) before `epoll-event-loop` is applied, and it needs `link-keyed-state` archived, which it is.
- **Risk:** the extension seam's identity change (`allows` by slot) is a design change to an unbuilt hook, not to the contract; the seam proof (D8 of the epoll design) is where it is validated.
