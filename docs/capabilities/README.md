# Capabilities

The contract is a core and eleven optional capabilities ([the contract, section 2](../contract.md#2-a-core-and-optional-capabilities)). The core is enough for a client and for a server that answers as bytes arrive. A capability adds a few operations or events, with rules that bind only a loop that supplies it. There is one page for each, written for the author of a library: what it is, when to use it and when not to, how it is commonly used, a checked example, whether a library needs it or can use it if present, and which loops supply it.

## Declaring and asking

A loop declares each capability it supplies with one line in its own namespace, next to the operations:

```goose
fn supplies_relay(io: Loop&) -> goose_io::Supplied { return goose_io::Supplied {}; }
```

A library that cannot work without a capability calls `goose_io::require_<name>(io)` in its test and says `// Needs: core and <name>` in its header. A library that can use it when present asks at compile time and keeps the other branch for a loop without it:

```goose
const if same<type_of(goose_io::has_relay(io)), goose_io::Supplied> { /* relay */ } else { /* copy */ }
```

[Using a capability when the loop has it](../libraries.md#using-a-capability-when-the-loop-has-it) shows it whole, and [Declaring the capabilities a loop supplies](../event-loops/declarations.md) covers the loop's side.

## The pages

| Capability | What it adds | Example |
|---|---|---|
| [Half-close](half-close.md) | `PeerEof`; end sending without ending receiving | `examples/lineserver` |
| [Sizing](sizing.md) | `send_room` and `send2`: ask the room, send in two parts | `examples/capabilities/frames.goose` |
| [Abort](abort.md) | `reset`: end a link so the peer sees an abort | `examples/capabilities/reject.goose` |
| [Inspection](inspection.md) | `peer_address`, `stop_listening` | `examples/capabilities/access_log.goose` |
| [Batching](batching.md) | `PassEnd`: the end of a pass | `examples/capabilities/batch_reply.goose` |
| [Unix](unix.md) | the address form `unix:/path` | `tests/examples/unix_dial_test.goose` |
| [Relay](relay.md) | the loop carries bytes between two links | `examples/forward` |
| [Peek](peek.md) | look at the first bytes, then choose | `examples/capabilities/sniff.goose` |
| [Revoke](revoke.md) | `discard_unsent`, `write_deadline`: take back unsent bytes | `examples/capabilities/fenced_writer.goose` |
| [Wake](wake.md) | another thread tells the loop something | `examples/capabilities/worker_reply.goose` |
| [Limits](limits.md) | the loop reports a link idle, silent, stalled or old | `examples/capabilities/idle_reaper.goose` |

The examples marked `examples/capabilities` are small programs for reading and copying from, not libraries to depend on.
