# Declaring the capabilities a loop supplies

A loop supplies the core of the contract and, if it chooses, any of the optional capabilities: half_close, sizing, abort,
inspection, batching, unix, relay, peek, revoke, wake and limits. A loop says which ones it supplies by declaring them, one
line each, in its own namespace. Libraries and the conformance suite read those declarations; nothing else tells them.

## Declaring one

Next to the operations of a capability, add a function named `supplies_<capability>` that returns `goose_io::Supplied`:

```goose
namespace my_loop;

struct Loop { /* ... */ }

fn relay(io: Loop&, a: goose_io::Link, b: goose_io::Link) -> goose_io::RelayStatus { /* ... */ }
fn relayed_bytes(io: Loop&, link: goose_io::Link) -> i64 { /* ... */ }

fn supplies_relay(io: Loop&) -> goose_io::Supplied { return goose_io::Supplied {}; }
```

A capability the loop does not declare answers `goose_io::Absent`. The core needs no declaration. Batching and unix have no
operations of their own, so for them the declaration is all a loop does.

Declare exactly the capabilities the loop supplies:

- A capability declared without its operations fails to compile, with the name of the missing operation.
- A capability whose operations exist but which is not declared is treated as absent: libraries do not use it, and the
  conformance suite for it does not compile against the loop.

## A loop that wraps another

A wrapper supplies what the loop under it supplies, so it forwards each answer instead of repeating it:

```goose
fn supplies_relay(w: Layer&) { return goose_io::has_relay(inner); }
```

`tests/support/wrapper.goose` does this for the capabilities it forwards.

## What a library sees

A library asks with `goose_io::has_<capability>(io)`, passes the answer down, and branches on its type at compile time:

```goose
fn pair<Io, S>(io: Io&, has: S, a: goose_io::Link, b: goose_io::Link) {
    const if same<S, goose_io::Supplied> {
        io.relay(a, b);
    } else {
        // copy the bytes with send, pause_reading and Writable
    }
}

// the caller:  pair(io, goose_io::has_relay(io), a, b);
```

The copy-or-relay choice is written out in `examples/forward/forward.goose`, and `docs/libraries.md` explains it.

## Examples

The loops listed in `examples/README.md` are examples of declaring: one supplies the core and five capabilities, and the other
adds five more. Read their declarations next to the operations they describe.
