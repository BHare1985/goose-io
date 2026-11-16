// The in-memory provider supplies every operation of the contract, with the contract's types.
// require_provider never runs anything: this test passes by compiling.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;

fn main() {
    var io = goose_io_memory::Loop { .. };
    goose_io::require_provider(io);
    kit::check(io.now_ms() == 0 && !io.draining(), "require_provider calls nothing");
    kit::check(goose_io::VERSION_MAJOR == 0 && goose_io::VERSION_MINOR == 1, "the contract version the provider was written against");
    kit::finish();
}
