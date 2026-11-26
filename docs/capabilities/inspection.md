# Inspection

## What it is

Inspection lets a library look at a link and at a listener. `peer_address(link)` is the address of the link's peer as text, at most 56 bytes, empty once the link is closed or for a link made on a Unix path. `stop_listening(listener)` accepts no new connections on that listener, and leaves the links already accepted open. The rules are in [the contract](../contract.md#inspection).

## When to use it

Use `peer_address` to log who connected, to apply a policy by address, or to tell the peer of a connection what it looks like from outside. Use `stop_listening` when a server is being drained: it stops taking new work and finishes what it has, which `close`-ing the links does not do.

Do not store the address and use it as the identity of a link: it is text for reporting, and two links may have the same one. The link handle is the identity.

## How it is commonly used

- Ask `peer_address` in the handler of `Opened`, while the link is open. After `Closed` it is empty, so a library that logs on close must have copied it earlier.
- Check `goose_io::is_empty` on the result: a Unix path and a stale handle give an empty address.
- Stop listening on `draining()`, checked on `Tick`, and close the idle links; the busy ones finish and the loop ends once none is left.
- A stopped listener's handle is never reused, so keeping it is harmless.

## Examples

The access log writes a line for each accepted connection with the time and the address the loop reports, and answers with the address.

<!-- excerpt: examples/capabilities/access_log.goose#opened -->
```goose
// A connection was accepted: write its line, and answer with the address the loop reports.
fn _on_opened<Io>(a: AccessLog&, io: Io&, link: goose_io::Link) {
    let peer = io.peer_address(link);
    a.log.append(str(io.now_ms()));
    a.log.append(" ");
    a.log.append(peer.text[..]);
    a.log.append("\n");
    io.send(link, peer.text[..]);
}
```

When the loop is stopping it takes no new connections.

<!-- excerpt: examples/capabilities/access_log.goose#draining -->
```goose
// A loop that is stopping takes no new connections; the ones it has finish.
fn _on_tick<Io>(a: AccessLog&, io: Io&) {
    if io.draining() && !a.stopped {
        io.stop_listening(a.listener);
        a.stopped = true;
    }
}
```

## Required or optional

A library that calls them says `// Needs: core and inspection`, and `goose_io::require_inspection(io)` states it in code. A library that only logs an address can use it if supplied (`// Uses if supplied: inspection`) and log without one otherwise.

## Supplied by

The in-memory loop, the wrapper, and goose-io-epoll, goose-io-epoll-ext and goose-io-iouring. Not the loop that supplies only the core.

## See also

[Unix](unix.md), where a path has no peer address; [While the loop is stopping](../libraries.md#while-the-loop-is-stopping) in the libraries guide.
