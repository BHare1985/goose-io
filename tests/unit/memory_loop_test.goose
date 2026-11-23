// The in-memory loop supplies every operation of the contract, with the contract's types, so it passes the check of
// the core and the check of each capability. The checks never run anything: this test passes by compiling.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;

// --- the life of a loop (specs/io-contract of the change lifecycle-guarantees) ----------------------------------------------

struct Life { link: goose_io::Link = goose_io::Link { .. }, events_before: i64 = 0, served: bool = false, opened: i64 = 0, second_calls: i64 = 0 }

fn life_event(l: Life&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    l.served = true;
    match ev {
        Opened e => { l.opened++; },
        _ => {},
    }
    kit::stop_after(io, ev, 100);
}

// A listen and a dial made before serve deliver Opened from serve, and nothing before it.
fn setup_before_serve() {
    var io = goose_io_memory::Loop { .. };
    var l = Life { .. };
    let lis, err = io.listen("127.0.0.1:8140");
    kit::check(goose_io::is_listener(lis) && !goose_io::failed(err), "listen before serve works");
    l.link = io.dial("127.0.0.1:8140", 0);
    kit::check(goose_io::is_valid(l.link), "dial before serve returns a link");
    kit::check(!l.served, "no event is delivered before serve is called");
    io.serve() { io, ev => life_event(l, io, ev); };
    kit::check(l.opened == 2, "serve delivers Opened for both links made before it");
}

// What every operation does once serve has returned.
fn finished_loop() {
    var io = goose_io_memory::Loop { .. };
    var l = Life { .. };
    let lis, err = io.listen("127.0.0.1:8141");
    l.link = io.dial("127.0.0.1:8141", 0);
    io.serve() { io, ev => life_event(l, io, ev); };
    kit::check(l.opened == 2, "fixture: the links opened and serve returned");

    let before = io.now_ms();
    kit::check(io.send(l.link, "x") == goose_io::SendStatus.Closed, "send on a finished loop returns Closed");
    kit::check(io.send2(l.link, "x", "y") == goose_io::SendStatus.Closed, "send2 on a finished loop returns Closed");
    kit::check(io.send_room(l.link) == 0, "send_room on a finished loop is 0");
    let l2, err2 = io.listen("127.0.0.1:8142");
    kit::check(!goose_io::is_listener(l2) && err2.kind == goose_io::ListenErrorKind.Other, "listen on a finished loop fails with kind Other");
    let d = io.dial("127.0.0.1:8141", 0);
    kit::check(!goose_io::is_valid(d), "dial on a finished loop returns the invalid link");
    io.close(l.link);
    io.reset(l.link);
    io.pause_reading(l.link, true);
    io.shutdown_write(l.link);
    io.set_keep_open_on_eof(l.link, true);
    io.tick_by(before + 10);
    io.stop_listening(lis);
    kit::check(io.draining(), "draining is true on a finished loop");
    kit::check(io.now_ms() >= before, "now_ms does not go backwards");
    kit::check(goose_io::is_empty(io.peer_address(l.link)), "peer_address on a finished loop is empty");

    // a second serve returns at once and never calls its handler
    var again = Life { .. };
    io.serve() { io, ev => life_event(again, io, ev); };
    kit::check(!again.served, "a second serve never calls its handler");
}

fn main() {
    setup_before_serve();
    finished_loop();
    var io = goose_io_memory::Loop { .. };
    goose_io::require_core(io);
    goose_io::require_half_close(io);
    goose_io::require_sizing(io);
    goose_io::require_abort(io);
    goose_io::require_inspection(io);
    kit::check(io.now_ms() == 0 && !io.draining(), "the checks call nothing");
    kit::check(goose_io::VERSION_MAJOR == 0 && goose_io::VERSION_MINOR == 4, "the contract version the loop was written against");
    kit::finish();
}
