# Peek

## What it is

Peek lets a library look at the first bytes of a connection before it chooses what to do with it. `peek(link)` returns the bytes that have arrived and not been delivered as `Data`, and consumes nothing. `wait_input(link, n)` holds `Data` back and delivers one `Input` event when `n` bytes have arrived (or the peer finished, or the loop's bound was reached); `wait_input(link, 0)` releases the held bytes as `Data`, unchanged. `discard_input(link, n)` drops the first `n` held bytes. The rules are in [the contract](../contract.md#peek).

## When to use it

Use it for a server that speaks more than one protocol on a port, a proxy that picks a backend from a TLS hello or an HTTP request line, or any library that has to decide before it reads. The bytes stay with the loop, so a library that decides without looking pays no copy, and a library that then relays loses nothing.

Do not use it when the first `Data` is enough: a library that can decide after reading has no need to hold the bytes back.

## How it is commonly used

- Call `wait_input(link, n)` in `Opened`, where `n` is the number of bytes the decision needs. Decide in `Input`.
- Decide from `peek`, then either close, `relay` (the held bytes are carried first) or call `wait_input(link, 0)` to receive them as `Data`.
- When the library has sent the held bytes on itself, `discard_input` drops them so that a relay does not carry them again.
- Allow for less than `n` bytes: `Input` arrives at the bound, or at the peer's end of stream, with `available` smaller. Treat that as "not enough to decide".

## Examples

The sniffer holds each connection until it has the bytes it needs, looks at them without taking them, and releases them to the handler it chose.

<!-- excerpt: examples/capabilities/sniff.goose#classify -->
```goose
// The first bytes are here. Look at them, answer, and let them through as Data.
fn _on_input<Io>(s: Sniff&, io: Io&, link: goose_io::Link) {
    let first = io.peek(link);
    if first.len >= LOOK && first[0..LOOK] == "GET " {
        s.http++;
        io.send(link, "http\n");
    } else {
        s.other++;
        io.send(link, "unknown\n");
    }
    io.wait_input(link, 0);
}
```

## Required or optional

A library that depends on it says `// Needs: core and peek`. One that can do without (decide after the first `Data`) can say `// Uses if supplied: peek` and branch on `goose_io::has_peek(io)`. In practice a library that chooses by peeking has no sensible second branch, so it simply needs it.

## Supplied by

The in-memory loop and goose-io-epoll-ext. Not goose-io-epoll, the wrapper or the loop that supplies only the core.

## See also

[Relay](relay.md), which carries the held bytes first; [Limits](limits.md), for a client that never sends what the decision needs.
