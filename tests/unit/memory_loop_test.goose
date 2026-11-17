// The in-memory loop supplies every operation of the contract, with the contract's types, so it passes the check of
// the core and the check of each group. The checks never run anything: this test passes by compiling.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;

fn main() {
    var io = goose_io_memory::Loop { .. };
    goose_io::require_core(io);
    goose_io::require_half_close(io);
    goose_io::require_sizing(io);
    goose_io::require_abort(io);
    goose_io::require_inspection(io);
    kit::check(io.now_ms() == 0 && !io.draining(), "the checks call nothing");
    kit::check(goose_io::VERSION_MAJOR == 0 && goose_io::VERSION_MINOR == 3, "the contract version the loop was written against");
    kit::finish();
}
