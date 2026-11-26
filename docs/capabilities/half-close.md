# Half-close

## What it is

A link normally ends when the peer finishes sending: the loop closes it with reason `PeerClosed` and the library never learns that bytes were still owed to the peer. The half-close capability changes that on request. `set_keep_open_on_eof(link, keep)` asks the loop to keep the link open for sending after the peer's end of stream and to deliver the event `PeerEof` once, after all `Data`. `shutdown_write(link)` ends this side's sending while still receiving. The rules are in [the contract](../contract.md#half-close).

## When to use it

Use it when the answer to a request is sent after the peer has said it has no more to say: a line server that replies to everything a client wrote and then finishes, a protocol where one side's end of stream means "now answer", or a client that sends a body, calls `shutdown_write` and reads until the server is done. Without it a library can only `close`, which ends receiving too, so it must send its answer before the peer's end of stream arrives or lose it.

Do not use it for a protocol whose messages say where they end (a length, a terminator): the peer finishing is then the end of the connection, and the default does what is wanted.

## How it is commonly used

- Call `set_keep_open_on_eof(link, true)` in the handler of `Opened` (or right after `dial` for a dialled link). A call made after that handler returns has no effect, whether or not the peer has finished.
- On `PeerEof`, answer what has been read, then end with `shutdown_write` (the peer sees end of stream after the answer, and the link closes when both sides are done) or `close`.
- On a client, `shutdown_write` after the last request tells the server that no more come, and the server's own end of stream is the end of the reply.
- Remember that after `shutdown_write` a `send` returns `Closed`: send everything first.

## Examples

The line server asks for keep-open when a connection opens, so that a client that sends its requests and finishes still gets its answers.

<!-- excerpt: examples/lineserver/server.goose#keep_open -->
```goose
// Called from the handler of Opened: the peer finishing is then PeerEof, not Closed.
fn _keep_open<Io>(s: LineServer&, io: Io&, link: goose_io::Link) {
    io.set_keep_open_on_eof(link, true);
}
```

The same server is the fuller example of how `PeerEof` is used: see the entry point in [the libraries guide](../libraries.md#the-shape-of-a-library).

## Required or optional

A library that calls these operations says `// Needs: core and half-close` in its header, and `goose_io::require_half_close(io)` states the same in code: it fails to build on a loop without the declaration. Using half-close only when the loop has it is rarely worth it, because what the library does on `PeerEof` is a different protocol behaviour, not an optimisation; a library whose protocol needs it needs it.

## Supplied by

The in-memory loop, the wrapper, and [goose-io-epoll](https://github.com/BHare1985/goose-io-epoll) [goose-io-epoll-ext](https://github.com/BHare1985/goose-io-epoll-ext) and [goose-io-iouring](https://github.com/BHare1985/goose-io-iouring) supply it. The loop that supplies only the core does not, and the line server fails to build on it. The mapping documents in [`docs/event-loops/`](../event-loops/) say how each other candidate loop would.

## See also

[Abort](abort.md) and the table that compares `shutdown_write`, `close` and `reset`; [Keep-open and the end of a send](../libraries.md#keep-open-and-the-end-of-a-send) in the libraries guide.
