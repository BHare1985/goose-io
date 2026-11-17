# Design

## Context

See `proposal.md` for why. `scoped-library-views` gives each library a view and the application a registry. A view already sees every `dial`, `listen` and `tick_by`; the registry already sees every accepted link when it routes its `Opened`. Limits are counters kept in the registry and checked at those four points. The in-memory loop's `max_links` and `max_listeners` bound the loop as a whole; a limit here bounds one library.

## Goals / Non-Goals

**Goals:** one library cannot take what the others need; the application sets the share; refusals are visible to the application.
**Non-Goals:** limiting bytes (the loop bounds a link), limiting time in a handler, limiting a loop that has no views.

## Decisions

**D1. No default limits.** A default would be a guess that is wrong for some library, and a library that silently has no limit is the case this proposal exists to remove. The application states a limit or states `unbounded()`. Rejected: a generous default, which turns off the protection by default.

**D2. A link counts from `dial` returning, or from the accepted `Opened` being routed, until its `Closed` is handled (`done`).** This is the same window as ownership. An entry for a link that a library never closes counts until the loop closes it, which is the library's fault and the limit's point.

**D3. Refusing a dial returns the invalid link.** A view cannot make an event, so it cannot make the `Closed` that a loop makes for a failed dial. The contract already has an invalid-link result for a finished loop, and every example library checks `is_valid`. The cost is that the library does not learn why; the registry's counter does. Rejected: dialling an address that fails, which spends a real link and a connect attempt on a refusal; and a synthetic event queue in the registry, which would need the application to drain it and a handle the loop never issued.

**D4. An accepted link over the limit is closed before the library sees it.** The registry's `route` does it with `close` (or `reset` where the loop supplies it) on the real loop and returns `-1`. The library never sees an `Opened`, so it spends nothing on a connection it would have to close anyway. `route` therefore takes the loop. The `Closed` that follows is routed to nobody and dropped.

**D5. `tick_by` is clamped, not refused.** A library that asks for a wake-up still gets one, no sooner than its interval after the last. Each library's last request is a field in the registry. Other libraries' timers are not affected because the loop keeps the earliest request overall and a clamped one is later than the interval. Rejected: refusing, which would break a library that is correct and only too eager.

**D6. Counters are plain integers in the registry.** The application reads them for a log or an alarm. A counter that rises is the signal that a library is misbehaving or a limit is too low.

**D7. The contract change is small.** The finished-loop requirement already carries an exception to *Dialling never blocks*. It becomes two exceptions, and a new requirement says that a layer may refuse a dial. A library that follows the existing advice (check `is_valid`) needs no change.

## Risks / Trade-offs

- [A limit set too low fails the application's own dials with no event] → The counters show it, and the docs say that an invalid link from `dial` means refusal.
- [A library that does not check `is_valid` misuses the invalid link] → `send` on it returns `Closed`, so the library fails closed, as it does after a finished loop.
- [Accepting then closing a flood still costs the loop an accept for each] → That is the event loop's own limit; this only stops the library from paying more.
- [The clamp adds latency to a timer that is legitimately frequent] → The interval is the application's choice, per library.

## Open Questions

- Should the application be told when a library hits a limit, by a callback or a queue, instead of reading counters? Counters are enough to start.
