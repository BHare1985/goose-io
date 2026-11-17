## Context

See `proposal.md` for why. What exists:

- `epoll-event-loop` is a complete planning change (proposal, design D1 to D8, 46 tasks, a spec of 12 requirements) and nothing in it is applied. Its design and tasks name the tag and the user value in these places: the proposal's list of added operations (`user` readable inside `Closed`, the user value of a dial that failed inside `dial`) and "supplies the core and every group"; design context (13 operations and five groups), D2 step 3 (events with `tag` and `user`), D3's table (`listen(address, tag)`, the user value of a dial, inspection's `user`), D5's hook `allows(w, tag)` and the paragraph on a tag's meaning; tasks 3.2, 3.3, 3.4, 4.4, 5.3 and 5.5; its spec's scenario *An extension refuses a send* and the requirement that the loop supplies "every group"; and its last ground rule (merge after `contract-v1` and `simplify-contract`).
- Contract 0.3 (`link-keyed-state`, archived) removed the tag and the user value and added *Slot numbers are dense* and *A slot is freed when its Closed has been handled*. `lifecycle-guarantees` (open) adds that a slot whose generations are used up is retired and a slot is not reissued before its `Closed` is delivered.
- In tcprouter's engine a "tag" is not the contract's tag: it is a route's identity with a lease and a deadline, which the proxy layer uses (`_tag_allows`, `CloseTagged`, `Deadline`). The mapping document (`docs/event-loops/tcprouter-engine.md`) already records, since `link-keyed-state`, that the engine frees a slot when it queues `Closed`, before the event is delivered.

## Goals / Non-Goals

**Goals:**
- After this change's tasks, `epoll-event-loop` describes a loop for contract 0.3, with no mention of a contract tag or user value, and with the dense-slot and slot-held obligations in its design, tasks and spec.
- Keep tcprouter's route tags working as an extension's own state, so the seam proof (D8) still carries tcprouter's forwarding.

**Non-Goals:**
- Applying any task of `epoll-event-loop`, or changing its scope, its performance gates or its tcprouter-read-only rule.
- Deciding whether the loop supplies the unix group.
- Any change to the contract, the suite or the in-memory loop.

## Decisions

**D1. The loop carries no tag. A tag is the extension's.** In tcprouter the tag rides on every event and on `listen` and `dial`, and the proxy layer reads it back. In 0.3 the contract has neither; the epoll loop therefore has no field for it on a slot's contract side. The proxy layer, which moves behind the seam (D2 step 2 of the epoll design), keeps what it needs (the route's tag, its lease and deadline) in per-slot state of its own, indexed by the loop's slot index, as D5 already says per-slot extension state lives in the extension. The loop's `Opened` names the listener handle that accepted the link (a never-reused `Listener` table, as D3 has it), and a dialled link needs nothing. Rejected: keeping a loop-side tag "for the extension only", which would put back the field 0.3 removed and make every slot larger for an extension most programs do not use.

**D2. The hook that decided by tag decides by slot.** `allows(w, tag) -> bool` becomes `allows(w, slot) -> bool`, called before a dial opens, a send and a flush, as before. The extension looks the slot up in its own state (and checks the generation it keeps there). `wait_limit(w, now)`, the tag deadlines it computes, `on_message` (`Deadline`, `CloseTagged`, `SetAddr`, `Policy`) and `on_sweep` are unchanged: they are the extension's own, and nothing about them reaches the contract. With no extension `allows` is still constant true and disappears. The seam proof's forwarding extension needs no tag at all (fixed target, no routing).

**D3. Dense slots and slot-held-until-`Closed` are the loop's slot discipline, and they repair a known defect.** The loop keeps its slot table dense with a free list: a new link takes a freed slot before the table is extended, and a slot goes back on the free list only after every handler of its `Closed` has returned, in the same place the loop today bumps the generation. The mapping document's open item ("the slot is freed when `Closed` is queued, so `user` and `peer_address` inside the handler answer empty and a link made in that handler can take the slot") is the same fix, so the task that settles "the user value of a dial that failed inside `dial`" is reworded to keep the slot until its `Closed` is delivered, with no value to settle. The conformance expectations are the suite's checks `slots_dense`, `slot_kept_during_closed`, `owner_listener_named`, `owner_dial_found_by_link` and `dial_no_event_inside`, and the unit scenario *a slot is not reused inside the handler of its Closed* for a dial that failed inside `dial`. A slot retired by `lifecycle-guarantees` is simply not put back; that change owns the rule.

**D4. The delta spec is written once, in `epoll-event-loop`.** The capability `epoll-event-loop` has no main spec, so a delta here would create it from three requirements if archived first. The delta in this change exists so the requirements are reviewed and validated; its tasks add the same text to `epoll-event-loop`'s own spec, and this change is archived with `openspec archive align-epoll-with-contract-0-3 --skip-specs`. Rejected: leaving the requirements only in this change (they would be lost on archive); and merging the two changes into one (it would reopen `epoll-event-loop`, which has an owner and 46 tasks).

**D5. Counts, version and order are plain edits.** "13 operations" becomes twelve, "five groups" six, "contract 0.1" 0.3, and the closing ground rule names `link-keyed-state` and `lifecycle-guarantees`. The phrase "supplies the core and every group" is replaced by the explicit list the loop supplies, with the unix group left as the owner's decision (open question).

## Risks / Trade-offs

- [Reading `allows` by slot instead of by tag changes an unbuilt hook, and the seam proof has not run] → The proof (D8 of the epoll design) is the validation; if the extension's slot-indexed state costs more than the tag lookup it replaces, the epoll design already names the fallback (a generic slot payload).
- [A new reader of `epoll-event-loop` sees a change that was edited after its first review] → The edits are listed in this change's tasks, each confirmed by the owner, and the commit message of each revision names them.
- [The mapping document and the epoll design disagree about when a slot is freed until both are revised] → Task group 2 revises the design in the same order as the mapping document's wording.

## Open Questions

- Does the epoll loop supply the unix group (`unix:/path`, a `sockaddr_un` and the path rules)? Its sockets make it cheap, and `add-unix-sockets` left the decision to the owner "at the time `epoll-event-loop` is applied". This change does not decide it: the revised text lists the groups the loop was written for and says the unix group is decided when the loop is applied. If the owner decides now, one more task group belongs in `epoll-event-loop`, in a proposal of its own.
