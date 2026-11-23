// A batching responder: it answers whatever a client sends with `re: <what was sent>`, but sends no reply while the
// loop is delivering events. It queues each reply and sends them all at the end of the pass. It shows the batching
// capability (docs/capabilities/batching.md).
//
// Needs: core and batching (the event PassEnd).
//
// `PassEnd` comes once at the end of a pass that delivered link events, however many it delivered. A library that answers
// a hundred links in one pass can do its sending in one place, after it has seen everything the pass brought, and can
// drop replies for links that closed in the same pass. An example, not a library to depend on.
namespace batch_reply;
import std;
import goose_io;

struct Mine { yes: bool = true }

root struct BatchReply {
    listener: goose_io::Listener      = goose_io::Listener { .. },
    mine:     goose_io::LinkMap<Mine> = goose_io::LinkMap<Mine> {},
    queued:   goose_io::Link[>..]     = [],      // the links to answer at the end of the pass
    off:      i64[>..]                = [],      // where each reply starts in `bytes`
    len:      i64[>..]                = [],
    bytes:    u8[>..]                 = [],
    biggest:  i64                     = 0,       // the most replies sent at the end of one pass
    passes:   i64                     = 0,       // passes that ended with something to send
}

fn start<Io>(b: BatchReply&, io: Io&, address: const u8[:]) -> bool {
    let l, err = io.listen(address);
    b.listener = l;
    return goose_io::is_listener(l) && !goose_io::failed(err);
}

fn biggest_batch(b: BatchReply&) -> i64 { b.biggest }
fn batches(b: BatchReply&) -> i64 { b.passes }

// doc:begin queue
// A request arrived: queue its reply for the end of the pass.
fn _queue(b: BatchReply&, link: goose_io::Link, request: const u8[:]) {
    b.queued.push(link);
    b.off.push(b.bytes.len);
    b.len.push(request.len + 4);
    b.bytes.append("re: ");
    b.bytes.append(request);
}
// doc:end queue

// doc:begin flush
// The pass is over: send every queued reply, then forget them.
fn _flush<Io>(b: BatchReply&, io: Io&) {
    guard b.queued.len > 0 else { return; }
    for i in b.queued.len {
        io.send(b.queued[i], b.bytes[b.off[i]..b.off[i] + b.len[i]]);
    }
    b.biggest = max(b.biggest, b.queued.len);
    b.passes++;
    b.queued.clear();
    b.off.clear();
    b.len.clear();
    b.bytes.clear();
}
// doc:end flush

fn batch_event<Io>(b: BatchReply&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Opened o => {
            guard goose_io::is_listener(o.listener) && goose_io::same(o.listener, b.listener) else { return false; }
            b.mine.put(o.link, Mine { .. });
            return true;
        },
        Data d => {
            guard b.mine.find(d.link) != null else { return false; }
            b._queue(d.link, d.bytes);
            return true;
        },
        PassEnd => { b._flush(io); return false; },
        Closed x => {
            guard b.mine.find(x.link) != null else { return false; }
            b.mine.drop(x.link);
            return true;
        },
        PeerEof e => { return b.mine.find(e.link) != null; },
        _ => { return false; },
    }
}
