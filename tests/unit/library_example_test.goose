// A library tested with no network. This file is the example in docs/libraries.md,
// "Testing a library", and runs as a test.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;

// --- the library ---------------------------------------------------------------------------------
// Sends back what it receives in upper case, and closes the link at the first '.'.

struct Link { open: bool = false }

struct Shout {
    listener: goose_io::Listener      = goose_io::Listener { .. },
    links:    i64                     = 0,
    bytes:    i64                     = 0,
    conns:    goose_io::LinkMap<Link> = goose_io::LinkMap<Link> {},        // the library's state, found by the event's link
}

// Returns false for an event that belongs to another library: an accepted link is ours when `Opened` names our
// listener, and every later event is ours when we have state for its link.
fn shout_event<Io>(lib: Shout&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Opened e => {
            guard goose_io::is_listener(e.listener) && goose_io::same(e.listener, lib.listener) else { return false; }
            lib.conns.put(e.link, Link { open: true });
            lib.links++;
        },
        Data d => {
            guard lib.conns.has(d.link) else { return false; }
            var out: u8[>..] = [];
            var done = false;
            for c in d.bytes {
                if c == '.' { done = true; break; }
                out.push(if c >= 'a' && c <= 'z' { c - 32 } else { c });
            }
            lib.bytes += out.len;
            io.send(d.link, out);
            if done { io.close(d.link); }
        },
        Closed e => {
            guard lib.conns.has(e.link) else { return false; }
            lib.links--;
            lib.conns.drop(e.link);
        },
        _ => { return false; },
    }
    return true;
}

// --- the test ------------------------------------------------------------------------------------

fn main() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.read_chunk = 4;                      // deliver in small pieces: the library must not care
    var lib = Shout { .. };
    let listener, err = io.listen("127.0.0.1:7000");
    kit::check(!goose_io::failed(err), "listen");
    lib.listener = listener;

    // The client is a scripted peer: connect at once, send 10 ms later, send again 40 ms after that.
    let peer = io.add_peer();
    io.peer_connect(peer, "127.0.0.1:7000", 0);
    io.peer_send(peer, 10, "hello ");
    io.peer_send(peer, 40, "world.this is never answered");

    var closed_at = -1;
    io.serve() { io, ev => {
        shout_event(lib, io, ev);
        match ev {
            Closed c => { closed_at = io.now_ms(); },
            _ => {},
        }
        kit::stop_after(io, ev, 200);           // stop at the first Tick at or after 200 ms
    } };

    kit::check(io.peer_received(peer) == "HELLO WORLD", "the peer got the answer, and nothing after the '.'");
    kit::check(closed_at == 50, "the library closed the link when the '.' arrived, 50 ms in");
    kit::check(io.peer_saw_eof(peer), "the peer saw the end of the stream");
    kit::check(lib.links == 0 && lib.bytes == 11, "the library's own counts are right");
    kit::check(io.now_ms() == 200, "200 ms of the loop's clock passed, and no real time to speak of");
    kit::finish();
}
