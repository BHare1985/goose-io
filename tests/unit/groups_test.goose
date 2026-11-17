// The core and the groups of the contract: each has its own compile-time check (docs/contract.md). The checks never
// run anything; this test passes by compiling.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.tests.support.stub;

fn main() {
    // the in-memory loop supplies the core and every group (batching and unix have no operation, and so no check)
    var io = goose_io_memory::Loop { .. };
    goose_io::require_core(io);
    goose_io::require_half_close(io);
    goose_io::require_sizing(io);
    goose_io::require_abort(io);
    goose_io::require_inspection(io);
    kit::check(io.now_ms() == 0 && !io.draining(), "the checks call nothing");

    // a loop with only the core passes the core check
    var core = stub::Core { .. };
    goose_io::require_core(core);
    kit::check(core.max_send() >= 4096, "fixture: the stub is a loop");

    kit::check(goose_io::VERSION_MAJOR == 0 && goose_io::VERSION_MINOR == 2, "the contract version is 0.2");
    kit::finish();
}
