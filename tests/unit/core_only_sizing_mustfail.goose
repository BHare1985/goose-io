// expect: send_room
// The loop that supplies only the core cannot be given to the sizing entry point of the suite: the build fails and
// the error names the first operation of the capability that the loop lacks.
import std;
import goose_io from "../..";
import goose_io.conformance.suite;
import goose_io.tests.support.core_only;

fn never() -> bool { false }

fn main() {
    var io = core_only::Core { .. };
    let fx = goose_io_conformance::Fixture { .. };
    if never() { goose_io_conformance::conformance_sizing_part(io, fx, 0); }
}
