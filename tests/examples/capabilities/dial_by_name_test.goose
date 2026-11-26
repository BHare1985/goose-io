// examples/capabilities/dial_by_name: a host name is resolved and each address is tried in turn until one opens, on the
// in-memory loop that resolves; on the core-only loop, which does not, the same library dials an address it is given. A name that
// does not exist, and a lookup that times out, end the client Failed.
import std;
import goose_io from "../../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.tests.support.core_only;
import goose_io.examples.capabilities.dial_by_name;

fn run_named(name: const u8[:], expect_open: bool, expect_dials: i64, timeout_ms: i64) {
    var io = goose_io_memory::Loop { .. };
    io.script_name("db.test", 0, "10.0.0.1,10.0.0.2");
    io.script_name("slow.test", 5000, "10.0.0.2");
    io.script_name("gone.test", 0, "");
    let first = io.add_peer();
    io.peer_refuse(first, "10.0.0.1:80");
    let second = io.add_peer();
    io.peer_accept(second, "10.0.0.2:80");
    var d = dial_by_name::DialByName { .. };
    kit::check(d.start(io, name, 80, timeout_ms, 1000), "the client starts");
    io.serve() { io, ev => { d.dial_event(io, ev); kit::stop_after(io, ev, 3000); }; };
    kit::check(d.is_open() == expect_open, "the client ends open or failed as expected");
    kit::check(d.failed() == !expect_open, "failed is the opposite of open");
    kit::check(d.dial_count() == expect_dials, "the number of dials");
}

fn run_core_only() {
    var io = core_only::Core { .. };
    let peer = io.add_peer();
    io.peer_accept(peer, "10.0.0.2:80");
    var d = dial_by_name::DialByName { .. };
    kit::check(d.start(io, "10.0.0.2:80", 80, 1000, 1000), "the client starts on a loop without name resolution");
    io.serve() { io, ev => { d.dial_event(io, ev); kit::stop_after(io, ev, 500); }; };
    kit::check(d.is_open(), "the address was dialled directly");
    kit::check(d.dial_count() == 1, "one dial");
}

fn main() {
    let which = kit::scenario();
    if which == -1 || which == 0 { run_named("db.test", true, 2, 1000); }
    if which == -1 || which == 1 { run_named("gone.test", false, 0, 1000); }
    if which == -1 || which == 2 { run_named("slow.test", false, 0, 1000); }
    if which == -1 || which == 3 { run_core_only(); }
    kit::finish();
}
