# Wake

## What it is

A loop belongs to the thread that serves it, and wake is the one exception. `waker()` returns a `Waker`, a fixed-size handle that can be copied to any thread. `wake(waker, value)` and `wake_with(waker, value, body)` may be called from another thread and deliver one `Woken { value, body }` event to the loop's thread, in the order one calling thread made them. `body` is up to 64 bytes. The rules are in [the contract](../contract.md#wake).

## When to use it

Use it when work happens on another thread and its result must come back into the loop: a worker pool, a blocking call, a timer thread, a signal handler's thread, or an application that tells the loop to change something (an address, a deadline). Without it the other thread can only share state with the loop, which a library on this contract should not do.

Do not call any other operation from another thread. Only `wake` is allowed.

## How it is commonly used

- Get the waker on the loop's thread (`waker()`), and give copies to the workers. The handle is plain data.
- Put a ticket in `value`, so that `Woken` finds the request it answers, and the answer in `body` when it is short.
- `Woken` goes to every library like `Tick`; the application decides who handles it, so check the value before acting.
- Keep a count of what is outstanding. An idle loop does not know that a worker will still call it.

## Examples

The worker front hands a request to a thread with its ticket and the waker.

<!-- excerpt: examples/capabilities/worker_reply.goose#hand_out -->
```goose
// A request arrived: give it to a worker, with the waker and the ticket the answer must carry back.
fn _hand_out(w: WorkerReply&, i: i64, request: const u8[:]) {
    var job = Job { waker: w.waker, ticket: i, .. };
    job.request.append(request);
    w.conns[i].pending = true;
    w.asked++;
    qput(job);
}
```

The answer returns as `Woken`, on the loop's thread, and goes to the client that asked.

<!-- excerpt: examples/capabilities/worker_reply.goose#woken -->
```goose
// A worker's answer arrived, on the loop's thread: send it to the link its ticket names.
fn _on_woken<Io>(w: WorkerReply&, io: Io&, ticket: i64, answer: const u8[:]) -> bool {
    guard ticket >= 0 && ticket < w.conns.len && w.conns[ticket].in_use && w.conns[ticket].pending else { return false; }
    w.conns[ticket].pending = false;
    io.send(w.conns[ticket].link, answer);
    w.answered++;
    return true;
}
```

## Required or optional

A library that uses threads says `// Needs: core and wake`, since without it the answer has no way back. A library that offers threads as an optimisation (compute inline when the loop cannot wake) can say `// Uses if supplied: wake` and branch on `goose_io::has_wake(io)`.

## Supplied by

The in-memory loop and goose-io-epoll-ext. Not goose-io-epoll, goose-io-iouring, the wrapper or the loop that supplies only the core.

## See also

[Limits](limits.md) and [batching](batching.md), the other ways a library learns of something that is not a link event; [The end of the loop](../libraries.md#the-end-of-the-loop).
