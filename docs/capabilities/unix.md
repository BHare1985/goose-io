# Unix

## What it is

The unix capability is an address form, `unix:/path` (or `unix:///path`, the same path), accepted by `listen` and `dial` wherever a numeric address is. It adds no operation, event or type: the calls, results and rules are those of the core, and a library changes only the string it passes. A loop without it answers `BadAddress`, as for any text it does not accept. The rules are in [the contract](../contract.md#unix).

## When to use it

Use it to talk to a local service through a socket file: a database on its Unix socket, a daemon that a proxy sits in front of, a process on the same machine where a port would only add exposure. A library gets it for free if it takes the address as configuration and does not build it from a host and a port.

Do not use it for anything that needs a port or a peer address: `listener_port` is 0 for a path, and `peer_address` is empty for a link made on one.

## How it is commonly used

- Take the address as a string from configuration and pass it through unchanged. `unix:/run/app.sock` and `127.0.0.1:5432` then work with the same code.
- Handle `ConnectFailed` with kind `Refused` for a path nothing listens on, and `AddressInUse` for a path another listener holds.
- Do not parse or normalise the path: the loop uses it as written.
- A library that logs a peer address must accept an empty one.

## Examples

The same dial as for a numeric address, with a path. A scripted peer waits at the path.

<!-- excerpt: tests/examples/unix_dial_test.goose#unix_peer -->
```goose
fn dials_a_path<Io>(io: Io&) {
    var log = kit::Log { .. };
    let db = io.add_peer();
    io.peer_accept(db, "unix:/var/run/postgresql/.s.PGSQL.5432");
    io.peer_send(db, 5, "ready");
    let link = io.dial("unix:/var/run/postgresql/.s.PGSQL.5432", 0);
    io.serve() { io, ev => on_event(log, io, ev); };
    kit::check(kit::data_of(log, link) == "ready", "the peer at the path answers");
    kit::check(io.peer_received(db) == "hello", "and reads what the library sent");
}
```

## Required or optional

There is no operation to check, so `goose_io::require_unix(io)` checks the declaration alone, and `// Needs: core and unix` is for a library that cannot work without a path. A library that takes any address is simply core: on a loop without the capability a path in its configuration fails with `BadAddress`, which it already handles, so it needs no branch and no `has_unix`.

## Supplied by

The in-memory loop (turn it off with `io.cfg.unix_paths = false` to see a library meet a loop without it) and the wrapper. Neither goose-io-epoll nor goose-io-epoll-ext supplies it.

## See also

[Inspection](inspection.md), where a path has no peer address; [A path as an address](../libraries.md#a-path-as-an-address) in the libraries guide.
