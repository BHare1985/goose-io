// A library that dials a Unix socket (the unix capability, `unix:/path`), run on the in-memory event loop against a
// scripted peer waiting at the path: the same calls as for a numeric address, only the string differs. The excerpt
// is in docs/libraries.md, "Scripted peers".
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.tests.support.wrapper;

fn on_event<Io>(log: kit::Log&, io: Io&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    match ev {
        Opened e => { io.send(e.link, "hello"); },
        _ => {},
    }
    kit::stop_after(io, ev, 200);
}

// doc:begin unix_peer
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
// doc:end unix_peer

let SCENARIOS = 1;

// With no argument it runs on the in-memory event loop; with a scenario number, on the wrapper
// (tests/examples/over_wrapper.sh runs them all).
fn main() {
    if kit::scenario() >= 0 {
        var w = wrapper::Layer { .. };
        dials_a_path(w);
    } else {
        var io = goose_io_memory::Loop { .. };
        dials_a_path(io);
    }
    kit::finish();
}
