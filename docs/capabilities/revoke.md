# Revoke

## What it is

Revoke takes back what a library has sent but the loop has not yet written. `discard_unsent(link)` drops every byte the loop accepted on the link and has not handed to the transport, returns how many, and counts a `Writable` owed to the link as if those bytes had been sent. `write_deadline(link, at_ms)` sets a time after which the loop writes no further byte on the link: `send` then answers `Closed` and the link ends with reason `Local`. Bytes already handed to the transport are not recalled. The rules are in [the contract](../contract.md#revoke).

## When to use it

Use it when a library's promise is "nothing after this moment": a message that is only valid until a time, a cancelled request whose answer is still queued, a fence that must not be crossed by a late write. The loop reads the clock at each write, so a process that was stopped between the start of a pass and a write does not write late.

Do not use it as a way to cancel what has gone out: it cannot, and a library that needs that must close the link.

## How it is commonly used

- Set `write_deadline` to the fence when a message is accepted. Make a later call replace it, and 0 remove it.
- On cancel, call `discard_unsent`. Its result says how many bytes were still held: if it is not all of them, some are on the wire.
- After a deadline passes, handle the `Closed` with reason `Local` as the end of the link.
- On a relayed link the deadline binds the relay's writes in both directions.

## Examples

The fenced writer gives each message a deadline.

<!-- excerpt: examples/capabilities/fenced_writer.goose#fence -->
```goose
// A client connected: fence the link, then send the payload.
fn _on_opened<Io>(w: FencedWriter&, io: Io&, link: goose_io::Link) {
    io.write_deadline(link, io.now_ms() + w.lease_ms);
    io.send(link, w.payload[..]);
}
```

When a request is cancelled it drops what has not been written.

<!-- excerpt: examples/capabilities/fenced_writer.goose#cancel -->
```goose
// The stream is cancelled: what the loop has not written is dropped, and the links end.
fn cancel<Io>(w: FencedWriter&, io: Io&) {
    for c in w.conns {
        if !c.in_use { continue; }
        w.dropped += io.discard_unsent(c.link);
        io.close(c.link);
    }
}
```

## Required or optional

A library whose guarantee depends on it says `// Needs: core and revoke`. There is no honest fallback, since without the capability the guarantee cannot be kept, so a library that offers the guarantee needs it, and a library that does not offer it does not use it.

## Supplied by

The in-memory loop and goose-io-epoll-ext. Not goose-io-epoll, goose-io-iouring, the wrapper or the loop that supplies only the core.

## See also

[Abort](abort.md), which ends the link and discards in one call; [Deadlines](../libraries.md#deadlines) in the libraries guide, for the library's own timers.
