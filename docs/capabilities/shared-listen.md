# Shared listen

## What it is

`listen` gives an address to one listener. Shared listen lets several listeners hold the same address, and the system gives each new connection to exactly one of them. `listen_shared(address)` returns a `Listener` and a `ListenError`, as `listen` does. A program that runs one loop per thread gives each loop a shared listener on the same address, and each loop accepts its own share with nothing handed from loop to loop. Linux and the BSDs do it with `SO_REUSEPORT`.

## When to use it

Share listening when each loop on its own thread can serve any connection: a web server, an echo server, a proxy whose loops are alike. Do not use it when one loop must see every connection first (to choose by the first bytes which loop owns it): accept on one loop and hand the link off instead. A program with one loop gains nothing.

A plain `listen` and a shared `listen_shared` cannot hold one address together: the later of the two fails with `AddressInUse`. A `listen_shared` on a unix path fails with `BadAddress`.

## How it is commonly used

- Every worker calls `listen_shared` with the same address, one worker per loop. The first may use port 0 and the others take the port it got (`listener_port`).
- Stopping one worker with `stop_listening` leaves the others accepting. Connections that were waiting on it may be reset: a loop says whether it moves them or resets them, so a server that restarts one worker at a time retries those clients.
- On a loop that does not supply the capability a library keeps `listen`, and runs one loop.

## Examples

A worker chooses how to listen when it is built. A loop without the capability never compiles the call to `listen_shared`.

<!-- excerpt: examples/capabilities/loop_per_core.goose#listen -->
```goose
// The choice is made when the library is built: a loop without the capability never compiles the call to `listen_shared`.
fn _listen<Io, S>(w: Worker&, io: Io&, has: S, address: const u8[:]) -> bool {
    const if same<S, goose_io::Supplied> {
        let l, err = io.listen_shared(address);
        w.listener = l;
        w.shared = true;
        return goose_io::is_listener(l) && !goose_io::failed(err);
    } else {
        let l, err = io.listen(address);
        w.listener = l;
        return goose_io::is_listener(l) && !goose_io::failed(err);
    }
}
```

Its test starts two workers on one address of the in-memory loop, which hands out connections in turn, and checks each is accepted once and echoed; and on the core-only loop it checks that the second worker cannot take the address.

## Required or optional

A server that must run a loop per core says `// Needs: core and shared-listen`. A library that can also run on one loop says `// Uses if supplied: shared-listen` and branches on `goose_io::has_shared_listen(io)`, as the example does.

## Supplied by

The in-memory loop and the wrapper when its inner loop does. goose-io-epoll, goose-io-epoll-ext and goose-io-iouring (with `SO_REUSEPORT`); not the wrapper unless its inner loop does. Not the loop that supplies only the core.

## See also

[Inspection](inspection.md), which has `stop_listening`; [Name resolution](name-resolution.md), another capability a server meets; [The contract](../contract.md#shared-listening).
