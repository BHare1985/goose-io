# Batching

## What it is

Batching is one event, `PassEnd`, and no operation. The loop delivers it as the last event of every pass that delivered at least one link event, so a library can handle ten requests and send ten replies together. It is not delivered for a pass that brought only a `Tick` or nothing, and nothing of that pass comes after it. The rules are in [the contract](../contract.md#batching).

## When to use it

Use it when sending in one place, after the whole pass, is better than sending as each event arrives: to gather replies into fewer calls, to answer in an order the library chooses, to drop a reply for a link that closed in the same pass, or to decide once per pass something that depends on everything the pass brought.

Do not use it for work with a deadline shorter than a pass: a pass is as long as the loop makes it. A library that does nothing at the end of a pass ignores the event.

## How it is commonly used

- Queue in `Data`, send in `PassEnd`. Keep what is queued bounded: a peer that sends faster than it is answered must be held back with `pause_reading`.
- Check a link is still yours before sending: it may have closed in the same pass, and its `Closed` came before `PassEnd`.
- Treat `PassEnd` like `Tick`: it is offered to every library, and the application hands it to each once. A library with nothing queued returns at once.
- A send made while handling `PassEnd` does not cause a second `PassEnd`.

## Examples

The responder queues a reply for each request as it arrives.

<!-- excerpt: examples/capabilities/batch_reply.goose#queue -->
```goose
// A request arrived: queue its reply for the end of the pass.
fn _queue(b: BatchReply&, link: goose_io::Link, request: const u8[:]) {
    b.queued.push(link);
    b.off.push(b.bytes.len);
    b.len.push(request.len + 4);
    b.bytes.append("re: ");
    b.bytes.append(request);
}
```

At the end of the pass it sends them all.

<!-- excerpt: examples/capabilities/batch_reply.goose#flush -->
```goose
// The pass is over: send every queued reply, then forget them.
fn _flush<Io>(b: BatchReply&, io: Io&) {
    guard b.queued.len > 0 else { return; }
    for i in b.queued.len {
        io.send(b.queued[i], b.bytes[b.off[i]..b.off[i] + b.len[i]]);
    }
    b.biggest = max(b.biggest, b.queued.len);
    b.passes++;
    b.queued.clear();
    b.off.clear();
    b.len.clear();
    b.bytes.clear();
}
```

## Required or optional

A library that depends on the event says `// Needs: core and batching`, and `goose_io::require_batching(io)` checks the declaration alone, since there is no operation. A library that can work without it (send in `Data` when there is no `PassEnd`) says `// Uses if supplied: batching` and branches on `goose_io::has_batching(io)`: the result is the same, only the number of calls differs.

## Supplied by

The in-memory loop, the wrapper, and goose-io-epoll and goose-io-epoll-ext. Not the loop that supplies only the core.

## See also

[Sizing](sizing.md), for sends cut to the room a link has.
