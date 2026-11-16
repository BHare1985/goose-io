// expect: FAIL selftest_fail [the driver]: this check fails on purpose
// The driver names a failed check and the requirement it proves, and the program's status reports it.
import std;
import goose_io from "../..";
import goose_io.conformance.suite;
import goose_io.memory;

fn main() {
    var io = goose_io_memory::Loop { .. };
    let fx = goose_io_conformance::Fixture { .. };
    exit(goose_io_conformance::conformance_core_part(io, fx, -1));
}
