## Why

`peek` consumes nothing and `relay` carries held bytes first. A router that replays a client's hello to a second server (retry) sends the held bytes itself and then relays, so the server sees the hello twice. The library needs a way to drop held bytes. Found by the tcprouter port (epoll-event-loop-dogfood, gap G1).

## What Changes

- Add `discard_input(link, n) -> i64` to the peek group: drops up to `n` held bytes (at most what `peek` shows) of an open, unrelayed link; returns the count. No `Input`, no `Data`.
- `require_peek` names it. Memory loop, conformance check `discard_input_drops`, fault `DiscardInputKeeps`.

## Impact

Additive; contract stays 0.3 (not yet released). Loops that claim the peek group must implement it.
