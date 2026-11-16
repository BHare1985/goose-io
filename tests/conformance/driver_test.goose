// The conformance driver: a passing check and a failing one give the return value the entry point promises.
import std;
import goose_io from "../..";
import goose_io.conformance.suite;
import goose_io.memory;
import goose_io.tests.support.kit;

fn main() {
    var io = goose_io_memory::Loop { .. };
    let fx = goose_io_conformance::Fixture { .. };
    let failed = goose_io_conformance::conformance_core_part(io, fx, -1);
    kit::check(failed == 1, "one check passes and one fails on purpose: the entry point returns 1");
    kit::finish();
}
