# Sizing

## What it is

With the core alone a send either fits or returns `Full`, and the library finds out by trying. The sizing capability lets it ask first and send a header and a body as one. `send_room(link)` is the number of bytes a send would take now, never more than `max_send()`, and 0 for a link that is not open. `send2(link, first, second)` is one `send` of the two ranges joined, taken whole or not at all. The rules are in [the contract](../contract.md#sizing).

## When to use it

Use it when what you send has a size you can choose or a shape in two parts: a frame whose payload may be cut to fit, a protocol header in front of a body that lives elsewhere, or a library that wants to stop producing output the moment the link is full instead of building something it cannot send. `send2` saves the copy that joining the two parts into one buffer would cost.

Do not use it just to avoid `Full`. With the core, `send` and `Full` already work: join the parts into a buffer of your own, keep the bytes the loop refused, and send them on `Writable`. The echo server does that.

## How it is commonly used

- Ask `send_room` before cutting a frame, and cut it to the room. Count the header in the room: a frame needs `header + payload`.
- When the room is 0, send anyway. The refused send (`Full`) is how the library asks the loop for the one `Writable` that follows, and the next frame goes out then.
- `send2` for a fixed-size prefix and a payload that stays where it is; its size for `Full` and `TooLarge` is the sum of the two parts.
- `send_room` is a hint for this moment. Another send, or a pass later, changes it; the result of the send is what counts.

## Examples

The frame streamer cuts each frame to the room the link has, and sends the length prefix and the payload as one send.

<!-- excerpt: examples/capabilities/frames.goose#pump -->
```goose
// Sends frames while the link takes them. Each is cut to the room the link has; with no room it is sent at full size and
// refused, which arms Writable.
fn _pump<Io>(f: Frames&, io: Io&, c: Conn&) {
    while c.sent < f.body.len {
        let room = io.send_room(c.link);
        var n = min(f.body.len - c.sent, FRAME_MAX);
        if room > HEADER { n = min(n, room - HEADER); }
        let size = n;
        let header: u8[4] = [(size >> 24) as u8, (size >> 16) as u8, (size >> 8) as u8, size as u8];
        let status = io.send2(c.link, header[..], f.body[c.sent..c.sent + n]);
        if status == goose_io::SendStatus.Full { f.refused++; return; }
        if status != goose_io::SendStatus.Sent { io.close(c.link); return; }
        c.sent += n;
        f.frames++;
    }
    io.close(c.link);       // the whole body is framed; close sends what is held, then ends the link
}
```

## Required or optional

A library that calls them says `// Needs: core and sizing`, and `goose_io::require_sizing(io)` states it in code. A library that only prefers sizing can say `// Uses if supplied: sizing` and branch on `goose_io::has_sizing(io)`, with a plain `send` and a buffer of its own in the other branch, as [the libraries guide](../libraries.md#using-a-capability-when-the-loop-has-it) shows for relay. For most libraries the buffer is simple enough that the branch is not worth its cost.

## Supplied by

The in-memory loop, the wrapper, and goose-io-epoll and goose-io-epoll-ext. Not the loop that supplies only the core.

## See also

[Batching](batching.md), which gathers sends at the end of a pass; [`Full` and `Writable`](../libraries.md#full-and-writable) in the libraries guide.
