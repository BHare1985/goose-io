# Name resolution

## What it is

`dial` takes an address, never a host name. Name resolution turns a host name into addresses on the loop, bounded in time. `resolve(host, port, timeout_ms)` returns a `Query` and the loop delivers exactly one `Resolved { query, status, count }` for it, unless the lookup is cancelled with `cancel_resolve(query)`. `status` is a `ResolveStatus`: `Found`, `NotFound`, `TimedOut`, `Failed` or `Cancelled`; `count` is above 0 only for `Found`. While the `Resolved` is handled, `resolved_address(query, i)` for `i` from 0 to `count - 1` returns an address `dial` accepts, with the port given to `resolve`, in the order the system advises (RFC 6724, as `getaddrinfo` gives them). Afterwards it returns an empty address. A timeout of 0 means the loop's default. The rules are in [the contract](../contract.md#name-resolution).

## When to use it

Use it in any client that is given a host name. Do not use it when the addresses are known in advance (dial them), or when the library must control DNS itself (its own resolver over descriptor readiness, a particular server, record types other than addresses): this capability answers addresses and nothing else.

Do not pass a host name to `dial`. It ends with `Closed`, `ConnectFailed`, `BadAddress`, whether or not the loop supplies this capability.

## How it is commonly used

- Resolve, then dial the first address in the `Resolved` handler. On `ConnectFailed` dial the next. A client may race a second address after 250 ms; that is the client's choice and not the loop's.
- Copy the addresses out of the handler. They are lent until it returns, like the bytes of `Data`. A library that keeps `Query` and calls `resolved_address` later gets an empty address.
- Give each lookup a timeout, and treat `TimedOut` and `NotFound` differently: the first may work later.
- On a loop that does not supply the capability a library with `wake` can run `getaddrinfo` on a thread and send each address back with `wake_with` (an `Address` fits in its 64 bytes). A library with neither accepts only addresses.

## Examples

A client that resolves a host name and tries each address in turn chooses its path when it is built. A loop without the capability never compiles the call to `resolve`.

<!-- excerpt: examples/capabilities/dial_by_name.goose#branch -->
```goose
// The choice is made when the library is built: a loop without the capability never compiles the call to `resolve`.
fn _begin<Io, S>(d: DialByName&, io: Io&, has: S, resolve_ms: i64) -> bool {
    const if same<S, goose_io::Supplied> {
        d.query = io.resolve(d.host.text[..], d.port, resolve_ms);
        guard goose_io::is_valid(d.query) else { d.phase = Phase.Failed; return false; }
        d.phase = Phase.Resolving;
        return true;
    } else {
        d.addresses.push(d.host);
        d._dial_next(io);
        return true;
    }
}
```

The answer arrives as `Resolved`, on the loop's thread. The client copies the addresses and dials the first.

<!-- excerpt: examples/capabilities/dial_by_name.goose#resolved -->
```goose
// The answer of the lookup. Only a loop that supplies the capability delivers `Resolved`, so only it compiles `resolved_address`.
fn _on_resolved<Io, S>(d: DialByName&, io: Io&, has: S, status: goose_io::ResolveStatus, count: i64, query: goose_io::Query) {
    const if same<S, goose_io::Supplied> {
        if status == goose_io::ResolveStatus.Found {
            // the addresses are lent until this handler returns: copy them
            for i in min(count, TRIES_MAX) { d.addresses.push(io.resolved_address(query, i)); }
            d._dial_next(io);
        } else {
            d.phase = Phase.Failed;
        }
    }
}
```

Its test runs the library on the in-memory loop, where a name has two addresses and the first is refused, and a name that does not exist and one that is too slow end it failed; and on the core-only loop, where it dials the address it was given.

## Required or optional

A library that must dial names says `// Needs: core and name-resolution`. A library that can also take an address says `// Uses if supplied: name-resolution` and branches on `goose_io::has_name_resolution(io)`, as the example does.

## Supplied by

The in-memory loop (the lookups are scripted, with delays, on its clock), the wrapper when its inner loop does, and the layer `Resolving<Io>` of [goose-io-dns](https://github.com/BHare1985/goose-io-dns), which adds it to any loop (core only; a thread asks the system resolver and the layer polls with `tick_by`). It is the only real implementation so far. Not the loop that supplies only the core. A real loop must never call `getaddrinfo` on its own thread: libuv uses its thread pool (`uv_getaddrinfo`), libevent uses evdns, an io_uring or epoll loop uses a resolver thread that wakes the loop, or c-ares on its descriptors. The mapping documents in [event-loops](../event-loops/) say which fits.

## See also

[Wake](wake.md), the fallback when the loop does not resolve; [Limits](limits.md), the other bounded wait the loop reports; [The contract](../contract.md#name-resolution).
