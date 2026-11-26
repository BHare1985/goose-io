# Limits

## What it is

`set_limit(link, kind, ms)` asks the loop to report when a link has been in a state for too long, and the event `Expired { link, limit }` is the report. The kinds are `Idle` (no byte read or written for `ms`), `Silent` (no byte read), `Stalled` (a send that has not drained), `HalfOpen` (a connection that has not opened) and `Age` (open that long, however busy). The loop reports; it never closes: the library decides. The rules are in [the contract](../contract.md#limits).

## When to use it

Use it where a loop alone can see the state. Once a relay carries the bytes the library sees none of them, so it cannot know a pair went quiet; a limit tells it. It also saves a library from keeping a timer for every connection when what it wants is the common ones: a connection that does nothing, one that never finishes opening, or one that has lived too long.

Do not use it for deadlines that mean something to the protocol (a request's timeout): those belong to the library, with `tick_by`.

## How it is commonly used

- Arm the limits when the link is ready, for example when the pair is relayed. A limit is armed once; a later call for the same kind replaces it.
- On `Expired`, say which limit ran out and close (or reset). One `Expired` is delivered for each arming.
- Combine `Idle` and `Age`: a busy link then still ends.
- A closed link gets no `Expired`.

## Examples

The reaper arms two limits on a relayed pair.

<!-- excerpt: examples/capabilities/idle_reaper.goose#arm -->
```goose
// The pair is relayed: from now on the loop watches it. Either link's limit closes the connection.
fn _arm<Io>(r: IdleReaper&, io: Io&, client: goose_io::Link, backend: goose_io::Link) {
    io.set_limit(client, goose_io::Limit.Idle, r.idle_ms);
    io.set_limit(client, goose_io::Limit.Age, r.age_ms);
}
```

When one expires it records which and closes the connection. Closing one link of a relayed pair ends both.

<!-- excerpt: examples/capabilities/idle_reaper.goose#expired -->
```goose
// A limit ran out: say which, and close. Closing one link of a relayed pair ends both.
fn _on_expired<Io>(r: IdleReaper&, io: Io&, link: goose_io::Link, limit: goose_io::Limit) {
    match limit {
        Idle => { r.idled++; },
        Age => { r.aged++; },
        _ => {},
    }
    io.close(link);
}
```

## Required or optional

A library that depends on it says `// Needs: core and limits`. Where a library can keep the same watch with its own timers (a `Deadlines` and `tick_by`), it can say `// Uses if supplied: limits` and branch on `goose_io::has_limits(io)`; for a relayed link there is no such watch, so a relay library needs it.

## Supplied by

The in-memory loop and goose-io-epoll-ext. Not goose-io-epoll, goose-io-iouring, the wrapper or the loop that supplies only the core.

## See also

[Relay](relay.md), the usual reason a library needs it; [Deadlines](../libraries.md#deadlines) for the library's own timers.
