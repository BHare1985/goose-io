# Relay

## What it is

`relay(a, b)` joins two open links: the loop carries the bytes of each to the other and the library sees none of them. It returns a `RelayStatus` (`Started`, `NotOpen`, `Closed` or `AlreadyRelayed`); only `Started` joins the links. `relayed_bytes(link)` is the number of bytes carried from that link to its partner, and still answers while the link's `Closed` is handled. The loop is free to use buffers, a pump or `splice`: the contract states the intent, not the mechanism. The rules, including what each operation does on a relayed link, are in [the contract](../contract.md#relay).

## When to use it

Use it for a proxy or a forwarder, where the library decides what to connect to and then has nothing to say about the bytes. It removes a copy through the library, and on a loop with a pump it moves the bytes without the library running at all. It also makes the pair one unit: closing one link ends both.

Do not use it when the library must see or change the bytes: it gets no `Data` for a relayed link, and it cannot take the relay back.

## How it is commonly used

- Hold the client back with `pause_reading` until the backend is open, then `relay`. Bytes the client sent meanwhile stay with the loop and are the first carried.
- Check the status. Anything but `Started` means the library still owns the links and must close them.
- Read `relayed_bytes` in the handler of `Closed`, for accounting.
- Combine it with [peek](peek.md) (look at the first bytes, then relay) and [limits](limits.md) (the loop sees the quiet, the library closes).
- `send`, `pause_reading`, `shutdown_write` and `set_keep_open_on_eof` do nothing on a relayed link.

## Examples

The forwarder relays where the loop can, and copies where it cannot. This is the whole branch.

<!-- excerpt: examples/forward/forward.goose#branch -->
```goose
// The backend is open: hand the pair to the loop when it has relay, otherwise copy through this library.
fn _pair<Io, S>(f: Forward&, io: Io&, has: S, client: Side&, backend: Side&) {
    const if same<S, goose_io::Supplied> {
        if io.relay(client.link, backend.link) == goose_io::RelayStatus.Started {
            f.relayed++;
        } else {
            io.close(client.link);
            io.close(backend.link);
        }
    } else {
        f.copied++;
        f._send_held(io, backend);
        if backend.held.len == 0 { io.pause_reading(client.link, false); }
    }
}
```

## Required or optional

A library that cannot work without it says `// Needs: core and relay`. A forwarder like the one above is better as optional: its header says `// Needs: core only.` and `// Uses if supplied: relay`, and it branches on `goose_io::has_relay(io)`, so it runs on every loop and is faster where the loop can relay. The cost is the second branch, which must be tested on a loop without the capability.

## Supplied by

The in-memory loop, and goose-io-epoll-ext. Not goose-io-epoll, the wrapper (which forwards only the capabilities of the loop under it that it knows) or the loop that supplies only the core.

## See also

[Peek](peek.md), [Limits](limits.md), [Revoke](revoke.md); [Using a capability when the loop has it](../libraries.md#using-a-capability-when-the-loop-has-it).
