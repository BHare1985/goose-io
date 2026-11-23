// expect: set_limit
// The loop that supplies only the core cannot pass the compile-time check of the limits capability: the build fails and the
// error names the first operation of the capability that the loop lacks.
import std;
import goose_io from "../..";
import goose_io.tests.support.core_only;

fn never() -> bool { false }

fn main() {
    var io = core_only::Core { .. };
    if never() { goose_io::require_limits(io); }
}
