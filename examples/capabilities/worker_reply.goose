// A worker pool front: a request line is handed to a worker thread, and the worker's answer is delivered back on the
// loop's thread through a waker. It shows the wake capability (docs/capabilities/wake.md).
//
// Needs: core and wake (waker, wake_with, and the event Woken).
//
// The loop belongs to the thread that serves it, so a worker cannot send on a link. It holds a `Waker`, which may be
// copied to any thread, and calls `wake_with(waker, ticket, answer)`; the loop delivers one `Woken` with that ticket and up to
// 64 bytes, in the order that thread made them, and the library sends the answer there. A `Job` crosses to the worker
// through a typed queue, so it is flat. The worker itself is the application's: it needs a loop value to call `wake_with`
// on, and a library on the contract does not name one. An example, not a library to depend on.
namespace worker_reply;
import std;
import goose_io;

// What crosses to a worker: flat, so a copy.
struct Job { waker: goose_io::Waker = goose_io::Waker { .. }, ticket: i64 = -1, request: u8[..64] = [] }

struct Conn {
    link:    goose_io::Link = goose_io::Link { .. },
    in_use:  bool           = false,
    pending: bool           = false,        // a job is out for this link
}

struct Ref { index: i64 = 0 }

root struct WorkerReply {
    listener: goose_io::Listener     = goose_io::Listener { .. },
    waker:    goose_io::Waker        = goose_io::Waker { .. },
    asked:    i64                    = 0,       // jobs handed out
    answered: i64                    = 0,       // answers sent
    refs:     goose_io::LinkMap<Ref> = goose_io::LinkMap<Ref> {},
    conns:    Conn[>..]              = [],
}

fn start<Io>(w: WorkerReply&, io: Io&, address: const u8[:]) -> bool {
    w.waker = io.waker();
    let l, err = io.listen(address);
    w.listener = l;
    return goose_io::is_listener(l) && !goose_io::failed(err);
}

fn asked_count(w: WorkerReply&) -> i64 { w.asked }
fn answered_count(w: WorkerReply&) -> i64 { w.answered }

fn _conn_of(w: WorkerReply&, link: goose_io::Link) -> i64 {
    let r .= w.refs.find(link);
    guard r != null else { return -1; }
    guard r.index < w.conns.len && w.conns[r.index].in_use && goose_io::same(w.conns[r.index].link, link) else { return -1; }
    return r.index;
}

// doc:begin hand_out
// A request arrived: give it to a worker, with the waker and the ticket the answer must carry back.
fn _hand_out(w: WorkerReply&, i: i64, request: const u8[:]) {
    var job = Job { waker: w.waker, ticket: i, .. };
    job.request.append(request);
    w.conns[i].pending = true;
    w.asked++;
    qput(job);
}
// doc:end hand_out

// doc:begin woken
// A worker's answer arrived, on the loop's thread: send it to the link its ticket names.
fn _on_woken<Io>(w: WorkerReply&, io: Io&, ticket: i64, answer: const u8[:]) -> bool {
    guard ticket >= 0 && ticket < w.conns.len && w.conns[ticket].in_use && w.conns[ticket].pending else { return false; }
    w.conns[ticket].pending = false;
    io.send(w.conns[ticket].link, answer);
    w.answered++;
    return true;
}
// doc:end woken

fn reply_event<Io>(w: WorkerReply&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Opened o => {
            guard goose_io::is_listener(o.listener) && goose_io::same(o.listener, w.listener) else { return false; }
            w.conns.push(Conn { link: o.link, in_use: true, .. });
            w.refs.put(o.link, Ref { index: w.conns.len - 1 });
            return true;
        },
        Data d => {
            let i = w._conn_of(d.link);
            guard i >= 0 else { return false; }
            w._hand_out(i, d.bytes);
            return true;
        },
        Woken k => { return w._on_woken(io, k.value, k.body[..]); },
        Closed x => {
            let i = w._conn_of(x.link);
            guard i >= 0 else { return false; }
            w.conns[i].in_use = false;
            w.refs.drop(x.link);
            return true;
        },
        PeerEof e => { return w._conn_of(e.link) >= 0; },
        _ => { return false; },
    }
}
