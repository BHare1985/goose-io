// The layers pass the finished-loop results through (specs/io-contract of the change lifecycle-guarantees, *A finished loop
// does nothing*): after serve has returned, the wrapper and the core-only loop give the results of the loop beneath, a second
// serve returns at once, and the wrapper holds no event that it could deliver late.
import std;
import goose_io from "../..";
import goose_io.tests.support.kit;
import goose_io.tests.support.wrapper;
import goose_io.tests.support.core_only;

struct Seen { opened: i64 = 0, served: bool = false }

fn seen_event<Io>(s: Seen&, io: Io&, ev: goose_io::Event) {
    s.served = true;
    match ev {
        Opened e => { s.opened++; },
        _ => {},
    }
    kit::stop_after(io, ev, 100);
}

fn wrapper_finished() {
    var io = wrapper::Layer { .. };
    var s = Seen { .. };
    let lis, err = io.listen("127.0.0.1:8150");
    let link = io.dial("127.0.0.1:8150", 0);
    io.serve() { io, ev => seen_event(s, io, ev); };
    kit::check(s.opened == 2, "fixture: both links opened over the wrapper");
    kit::check(io.send(link, "x") == goose_io::SendStatus.Closed, "send over a finished wrapper returns Closed");
    kit::check(io.send2(link, "x", "y") == goose_io::SendStatus.Closed, "send2 over a finished wrapper returns Closed");
    kit::check(io.send_room(link) == 0, "send_room over a finished wrapper is 0");
    let l2, err2 = io.listen("127.0.0.1:8151");
    kit::check(!goose_io::is_listener(l2) && err2.kind == goose_io::ListenErrorKind.Other, "listen over a finished wrapper fails with kind Other");
    kit::check(!goose_io::is_valid(io.dial("127.0.0.1:8150", 0)), "dial over a finished wrapper returns the invalid link");
    io.close(link);
    io.reset(link);
    io.pause_reading(link, true);
    io.shutdown_write(link);
    io.set_keep_open_on_eof(link, true);
    io.tick_by(io.now_ms() + 10);
    kit::check(io.draining(), "draining is true over a finished wrapper");
    var again = Seen { .. };
    io.serve() { io, ev => seen_event(again, io, ev); };
    kit::check(!again.served, "a second serve over the wrapper never calls its handler: nothing it held is delivered late");
}

fn core_only_finished() {
    var io = core_only::Core { .. };
    var s = Seen { .. };
    let lis, err = io.listen("127.0.0.1:8152");
    let link = io.dial("127.0.0.1:8152", 0);
    io.serve() { io, ev => seen_event(s, io, ev); };
    kit::check(s.opened == 2, "fixture: both links opened over the core-only loop");
    kit::check(io.send(link, "x") == goose_io::SendStatus.Closed, "send over a finished core-only loop returns Closed");
    kit::check(!goose_io::is_valid(io.dial("127.0.0.1:8152", 0)), "dial over a finished core-only loop returns the invalid link");
    let l2, err2 = io.listen("127.0.0.1:8153");
    kit::check(!goose_io::is_listener(l2) && err2.kind == goose_io::ListenErrorKind.Other, "listen over a finished core-only loop fails with kind Other");
    io.close(link);
    io.pause_reading(link, true);
    kit::check(io.draining(), "draining is true over a finished core-only loop");
    var again = Seen { .. };
    io.serve() { io, ev => seen_event(again, io, ev); };
    kit::check(!again.served, "a second serve over the core-only loop never calls its handler");
}

fn main() {
    wrapper_finished();
    core_only_finished();
    kit::finish();
}
