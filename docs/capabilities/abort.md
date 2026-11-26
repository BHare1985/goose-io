# Abort

## What it is

`reset(link)` closes a link at once and discards what was accepted but not yet sent, so the peer sees an abort (`PeerReset`) and not a clean end of stream. After it `send` returns `Closed`, and the link's only further event is its one `Closed` with reason `Local`. It does not wait for the peer. The rules are in [the contract](../contract.md#abort).

## When to use it

Use it to end a link that must not be treated as having ended well: a client that spoke the wrong protocol, a connection that must be dropped now whatever it still holds, a refused request where the peer should see an error and not a half answer. It is also the right end for a connection you are abandoning because the data held for it is useless.

Do not use it where the peer is owed what you accepted: `close` sends the accepted bytes first. A reset is rude by design, and a client that sees `PeerReset` will usually retry or report an error.

## How it is commonly used

- `close` is the normal end, `reset` the exception. Choose by what the peer is owed.
- Reset once. After `reset` the handle is finished for sending, and the `Closed` that follows has reason `Local`.
- Reset from `Data` for a protocol violation, from `Tick` for a connection that missed a deadline, from `Expired` for one that ran out of a limit.

| | `shutdown_write` (half-close) | `close` (core) | `reset` (abort) |
|---|---|---|---|
| Bytes already accepted | sent | sent | discarded |
| What the peer sees | end of stream after those bytes | end of stream after those bytes | an abort (`PeerReset`) |
| Receiving afterwards | goes on | stops | stops |
| Waits for the peer | yes | no | no |

## Examples

The greeting server resets a client whose first line is not a greeting, and closes one that greeted, so the welcome reaches it.

<!-- excerpt: examples/capabilities/reject.goose#first_line -->
```goose
// Bytes of the first line arrived. A good line is answered and the link closed; a bad one, or one that is too long, is reset.
fn _on_data<Io>(r: Reject&, io: Io&, c: Conn&, bytes: const u8[:]) {
    if c.line.len + bytes.len > FIRST_LINE_MAX {
        r.rejected++;
        io.reset(c.link);
        return;
    }
    c.line.append(bytes);
    let end = _newline_at(c.line[..]);
    guard end >= 0 else { return; }             // the line is not all here yet
    let greeting = "HELLO ";
    if end > greeting.len && c.line[0..greeting.len] == greeting {
        io.send(c.link, "welcome ");
        io.send(c.link, c.line[greeting.len..end]);
        io.send(c.link, "\n");
        r.welcomed++;
        io.close(c.link);
    } else {
        r.rejected++;
        io.reset(c.link);
    }
}
```

## Required or optional

A library that calls `reset` says `// Needs: core and abort`, and `goose_io::require_abort(io)` states it in code. A library for which a reset is only a nicety can use `close` instead, and says `// Uses if supplied: abort` with a branch on `goose_io::has_abort(io)`: the outcome for the peer differs (it sees a clean end), but the library's own state is the same.

## Supplied by

The in-memory loop, the wrapper, and goose-io-epoll, goose-io-epoll-ext and goose-io-iouring. Not the loop that supplies only the core.

## See also

[Half-close](half-close.md) and the comparison of the three ways to end a link, linked from [the contract](../contract.md#abort); [Revoke](revoke.md), which drops unsent bytes without ending the link.
