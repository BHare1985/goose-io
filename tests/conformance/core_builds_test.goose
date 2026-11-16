// The core suite builds for an event loop that supplies only the core: this test passes by compiling. The suite is
// not run (the stub loop does nothing), only built, so a check of the core that called an operation outside the core
// would fail here, naming the operation.
import std;
import goose_io from "../..";
import goose_io.conformance.suite;
import goose_io.tests.support.stub;
import goose_io.tests.support.kit;

fn never() -> bool { false }

fn main() {
    var io = stub::Core { .. };
    let fx = goose_io_conformance::Fixture { .. };
    if never() { goose_io_conformance::conformance_core_part(io, fx, 0); }
    kit::check(!never(), "the core entry point was built for a loop with only the core");
    kit::finish();
}
