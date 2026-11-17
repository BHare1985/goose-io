# Design

## Context

See `proposal.md` for why. What exists on main:

- `Link` is `{ slot: u32, gen: u32 }`: a slot the loop assigns and a generation that makes a stale handle harmless (*Links are generation-checked handles*). `Listener` is `{ id: u32 }`, never reused. `Opened` already carries `listener` (none for a dialled link).
- Every link event also carries `tag: u16` and `user: u32`. `listen` and `dial` take the tag; `set_user` (core) and `user` (inspection) set and read the value. `tag_of` and `user_of` are five-arm matches.
- Both examples keep their connections in a table, set the user value to the table index, and call `_conn_of(user, link)`, which bounds-checks the index and compares `same(table[user].link, link)`.
- The in-memory loop picks the first free slot (`memory.goose`, around line 411), so its slots are already dense. The contract does not say so.
- Goose has generics, grow-only arrays (`T[>..]`, whose elements never move so references stay valid), optional references (`T&?`), and `root struct` for a type with several resizable fields. The table below was built and measured with `goose v2026.4` (a generic `root struct` with grow-only arrays and a `find` returning `T&?`): `bench/link_map_bench.goose` holds it, and a reference from `find` stayed valid across 5,000 later `put`s.
- `lifecycle-guarantees` (open) is written against the contract as this change leaves it, and owns the rules that a generation is not issued twice and that a slot is not reissued before its `Closed` is delivered.

## Goals / Non-Goals

**Goals:**
- A library finds its state for an event from the event, with no value attached by anyone.
- The event loop passes nothing to the library and the application assigns nothing to it.
- A stale handle, a foreign handle and a forgotten removal each find nothing instead of the wrong state.
- Less contract: fewer operations, fewer event fields, no special case for a dial that fails at once.

**Non-Goals:**
- A socket-backed loop, or any change to `epoll-event-loop` beyond the new slot obligation.
- Letting two libraries share one table, or the loop own library state.
- Keeping `tag` or `user` as deprecated aliases (the contract is at 0.x, where a minor increase may remove behaviour).

## Decisions

**The link is the key; the event loop does not pass an index.** The loop already assigns `link.slot` when it creates a link; that is all it contributes, and it contributes it today. What a loop owes is one new promise: slots are dense, so a table indexed by slot is no bigger than the **loop's** peak of links (every library's links together). It is not bounded by one library's own peak: slots are handed out for the whole loop, so a library with two links can hold one whose slot is 100,000 while another library holds the rest, and its table then has 100,001 entries. The library, not the loop, owns the table. Answer to "does the event-loop author pass the loop's index": no, nothing is passed, there is only the guarantee on how slots are chosen. Rejected: `listen` and `dial` returning a loop-chosen small id that is not the slot (a second number for the same thing); and a loop-owned table of library state, which makes the loop generic over every library's record type and ties their lifetimes together.

**`LinkMap<T>` is the library's side of that, in the contract package.** A generic `root struct` with a grow-only array of generations and one of values, indexed by slot:

```goose
root struct LinkMap<T> {
    gens: u32[>..] = [],      // gens[slot] is the generation of the link the value belongs to; 0 means empty
    vals: T[>..]   = [],
}
fn put<T>(m: LinkMap<T>&, link: Link, v: T)        // grows to link.slot + 1; overwrites a stale entry
fn find<T>(m: LinkMap<T>&, link: Link) -> T&?      // null for an invalid, stale, foreign or removed link
fn has<T>(m: LinkMap<T>&, link: Link) -> bool
fn drop<T>(m: LinkMap<T>&, link: Link)             // empties the entry; the value's slot is kept for reuse
```

What the language gives: grow-only arrays mean a reference returned by `find` stays valid while the handler pushes more entries (no rehash, no invalidated pointer), a `root struct` lets two arrays grow independently, and `T&?` makes "not mine" a value the compiler makes the caller handle, where the old `_conn_of` returned `-1` and trusted the caller to look. The generation is stored inside the map, so the check the examples did by hand (`same(table[i].link, link)`) cannot be forgotten. The cost is 4 bytes per slot beside the value, and `T { .. }` filler for slots the library never used, so the table holds the loop's peak slot count times the size of the library's state. It does no allocation in `find`, `has` or `drop`, and `put` only pushes (a pointer bump) when the table grows.

*Measured* (`bench/link_map_bench.goose`, goose v2026.4, `-O2`, one pinned core; the small timings vary by a nanosecond or two from run to run, so treat a close gap as a tie and re-run on the target machine):

| state | loop peak / library's own links | flat: find, memory | compact: find, memory |
|---|---|---|---|
| 32 B | 1,024 / 16 | 1.5 ns, 0 KiB | 1.8 ns, 0 KiB |
| 32 B | 100,000 / 16 | 1.5 ns, 3.4 MiB | 1.8 ns, 0.8 MiB |
| 128 B | 100,000 / 1,024 | 4.8 ns, 12.6 MiB | 9.9 ns, 0.9 MiB |
| 512 B | 100,000 / 16 | 1.7 ns, 49 MiB | 5.5 ns, 0.8 MiB |
| 512 B | 100,000 / 1,024 | 2.4 ns, 49 MiB | 10.3 ns, 1.3 MiB |
| 32 B | 100,000 / 100,000 | 13.5 ns, 3.4 MiB | 29.4 ns, 3.8 MiB |

The *compact* layout keeps 8 bytes of metadata for each slot (generation and a cell index in one `u64`) and one value cell for each link the library owns, with a free list of cells. It saves memory only when the loop's slot count is large and the library's own links are few and its state is large; it costs a second dependent load for each lookup (2 to 10 ns here, twice as slow when the library owns every slot), a free list and a reserved cell, and it hands a dropped cell to a different connection, so a reference kept past `drop` is more dangerous than with the flat layout. A drop plus a put costs the same in both (it is dominated by copying the state). With 1,024 slots even 512-byte state reserves about 0.5 MiB flat, so **the flat layout is the one the contract package provides**. A library that needs the compact one (or any other layout) writes its own table with the same four functions: the contract guarantees the identity and the lifetime of a `Link`, which is all such a table relies on, and `LinkMap` is a helper and not a requirement. `bench/link_map_bench.goose` holds a compact table that can be copied, and takes any type with `put`, `find` and `drop`, so a table written elsewhere can be measured the same way. Rejected: shipping both layouts in the contract package (two things to keep identical, with a cost that is only worth paying for a library that has not been written); and a build-time or runtime switch (Goose has no per-library build flag, and one global setting cannot suit a library with large state next to one with small).

Rejected: a dictionary keyed by `Link`, which hashes and probes where an array indexes, and cannot hand out a stable reference; and a `slot_pool<T>` the library allocates from, which gives the library a second index to carry in the event, which is the user value again.

**Ownership of a new link comes from what already names it.** A dialled link was returned by `dial` and the library put it in its map before the next event, so its `Opened`, `Data`, and a `Closed` after a failed dial all find it. An accepted link has no entry yet, so `Opened` names its listener and the library compares it with the listener it started, which is what `which == frontend` is in the czmq example. Anything else is `find(...) == null`. The tag's job was the third case plus the first `Opened`; both are covered. Rejected: keeping a tag only for `Opened` (the listener already is that).

**A library claims an event only when it owns the link.** Every arm of a library's entry point returns "handled" only for a link it owns, and "not handled" for any other, so the application's chain (`if !front.server_event(..) { if !back.server_event(..) { client.client_event(..) } }`) hands the event on. Today's examples return "handled" for `Data`, `Writable`, `PeerEof` and `Closed` after a tag matches even when the lookup finds nothing; with no tag that would let the first library in the chain swallow the events of the others, so the examples change to claim only on a successful lookup. An accepted link is put in the map when its `Opened` is claimed; a dialled link was put when `dial` returned, so its `Opened` must not put it again (that would overwrite the state the library already set up).

```goose
Opened e => {
    if goose_io::is_listener(e.listener) {                       // an accepted link
        guard goose_io::same(e.listener, s.listener) else { return false; }     // another library's listener
        s.conns.put(e.link, Conn { .. });
    } else {                                                    // a dialled link: put when dial returned
        guard s.conns.has(e.link) else { return false; }        // a dial of another library
    }
    s._on_opened(io, e.link);
    return true;
}
Data e => {
    let c .= s.conns.find(e.link);
    guard c != null else { return false; }                      // not mine
    s._on_data(io, c, e.bytes);
    return true;
}
Writable e => { guard s.conns.has(e.link) else { return false; } s._on_writable(io, e.link); return true; }
PeerEof e  => { guard s.conns.has(e.link) else { return false; } s._on_eof(io, e.link); return true; }
Closed e => {
    guard s.conns.has(e.link) else { return false; }            // not mine: do not run this library's close handling
    s._on_closed(e.link);
    s.conns.drop(e.link);
    return true;
}
```

A library that has several listeners compares `e.listener` with each (a short list of the listeners it started); a library that both accepts and dials uses the one map for both kinds of link.

**Dense slots are a contract rule with a check.** "A loop SHALL give a new link a slot freed earlier before it gives a slot never used, so a slot number is below the greatest number of links valid at once." Without it a loop could issue ever-higher slots and every library's table would grow without bound. A freed slot is one whose `Closed` has been delivered, and "delivered" means the handlers for it have returned, not that the loop queued or generated the event: the handle is valid until the `Closed` handler returns (*Links are generation-checked handles*), so an old link cannot lose its identity while a library is still handling its `Closed`. (A slot whose generations are used up is retired and not reused; that rule belongs to `lifecycle-guarantees`, and the dense-slot rule is stated so that it allows it.) The rule is a requirement this change adds so that a table indexed by slot stays bounded; it is not something an event loop has by nature, and a loop author is told why it is there. The check opens `n` links, closes them, opens `n` again, and requires every slot to be below `n`; its fault makes the in-memory loop take a fresh slot each time. Rejected: a `max_links()` operation the library sizes against, which is the loop passing an index after all and fails for a loop whose limit is not fixed.

**Removal is the library's job and forgetting is safe.** The handle is valid until the `Closed` handler returns, and `LinkMap.drop` belongs in that handler. If a library forgets, a new link on the slot has a different generation, so `find` is null for it, and `put` overwrites the stale value. Nothing reads another link's state. `drop` resets the entry's value, so a reference a library kept past `drop` sees an empty value and, once another link is put on that slot, that link's value: a library does not keep a reference past the `Closed` that ends its link.

**A library cannot be handed another library's state.** Every link comes into being one of two ways: a dial returns it to exactly one caller, or an accept names exactly one listener that exactly one library started. A library holds state only for links it dialled, links its own listener accepted, and so for nothing else, so at most one library holds state for a given link, and *a library claims an event only when it owns the link* turns that into "the first claimant is the only claimant". That holds under five conditions, each stated in the contract or in a change this one builds on:

1. Listener handles are never reused (*Listener handles are never reused*, with a check), so a stale `Opened` cannot name a later library's listener.
2. A slot and generation pair is not issued twice and a generation is never 0 (the invalid link). The in-memory loop already skips 0 when a generation wraps (`memory.goose:963`), but wraps back onto earlier values after 2^32 reuses of a slot; `lifecycle-guarantees` retires such a slot instead, and until it is applied a library that forgets to `drop` could in principle see a stale entry match a new link after 2^32 reuses of one slot. This is stated in the design and not repaired here, because the repair is that change's.
3. A `Link` is used only on the loop that created it. A map is therefore tied to one loop: a library that is given links from two loops keeps one map for each, since two loops can issue equal slot and generation pairs.
4. Every event of a link is delivered after the handler that called `dial` has returned (*Dialling never blocks and always ends in one event*, with a check), so a dialled link's `Opened` finds the entry the library put.
5. A library claims an event only when it owns the link (above), shown by tests of the example libraries with two instances and with two different libraries on one loop.

What the old design allowed and this one does not: two libraries given the same tag (the application invented tags, and the documents and tests use `1` freely) each claimed the other's events, and the user index had to be checked against the link anyway.

**`set_user`, `user` and the tag go.** The contract has one fewer operation and one fewer event field per event. `tag_of` and `user_of` go. The in-memory loop's `Closed` for a failed dial no longer needs "read the value at delivery"; the library already holds the link. The note in `docs/event-loops/tcprouter-engine.md` that records the defect becomes moot and is edited. Rejected: leaving `user` as an optional extra in the inspection group, since a library that wants a number can keep it in its own value.

**One minor version, 0.3, and no compatibility shim.** At major 0 a minor increase may remove behaviour (*The contract states its version*). The break is a compile error naming the operation, and the migration is mechanical (below). Rejected: a release with both forms, which would keep every check and fault for the old form for a version nobody wants.

## Migration

A library or loop moves in these steps; each is a compile error until done.

1. Loop: stop taking `tag` in `listen` and `dial`, drop `tag`/`user` from the five events, drop `set_user` and `user`; take slots from a freelist before extending.
2. Library: replace its table-by-index with a `LinkMap<Conn>`; delete the `tag` field and every `if e.tag != s.tag` line; in `Opened` decide ownership by `e.listener` or by `has(e.link)`; in `Closed`, call `drop`.
3. Application: stop assigning tags; compare listeners if it runs several in one library.

## Risks / Trade-offs

- A loop that cannot keep slots dense cannot conform. An epoll loop with a freelist and an io_uring loop with a fixed-file table keep it for free; a loop that hands out file-descriptor numbers as slots would not, and must map them.
- Two libraries on one loop each hold a map as large as the highest slot they used, and the entries between are filler, so each map holds the **loop's** peak slot count times the size of its library's state: bounded by the loop and paid by every library, not by that library's own links. That is small for the usual cases (about 0.5 MiB at 1,024 slots of 512-byte state) and large for a very busy shared loop with large state (49 MiB at 100,000 slots of 512-byte state); such a library writes a table of its own with another layout. The numbers are in *Decisions*.
- A `find` that returns a reference stays valid for the life of the map, which is what grow-only arrays give (a prototype held a reference across 5,000 further puts, one at slot 100,000). A library that stores the reference past the `Closed` has stored a dead entry: the compiler's lifetime rules stop it outliving the map but not outliving the connection, and `drop` resets the value.
- `epoll-event-loop` has an open task list that names tags; it will need an edit when this is applied.
- The library's `Opened` for a dialled link must find the map entry the library put after `dial` returned. That holds because every event is delivered from `serve`, after the handler that called `dial` has returned; a loop that delivers an event inside `dial` would break it, and *Dialling never blocks and always ends in one event* already forbids that.
- A generation that wraps onto an earlier value could match a stale entry (condition 2 above). It takes 2^32 reuses of one slot and a library that never drops; `lifecycle-guarantees` removes it by retiring the slot.
- An event no library claims (a link the application dialled itself and passed to the chain) is dropped. With tags the application's own number could collide with a library's and the event would be claimed wrongly; now it is simply unclaimed.

## Open Questions

- Should `LinkMap.put` for an accepted link be in the contract package's helpers for `Opened` (`adopt(e.link, ...)`), or is the example's two-line check enough? The design leaves it out until a second library wants it.
- `PassEnd` and `Tick` still go to every library. No change is proposed.
- Should the contract package also provide a compact table (`CompactLinkMap<T>`) if a library on a busy loop needs one? It would be a new type with the same four functions, so adding it later breaks nothing; the design waits for a library that has the problem, and meanwhile `bench/link_map_bench.goose` holds a working one to copy.
