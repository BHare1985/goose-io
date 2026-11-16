// expect: send_room
// A loop with only the core fails the sizing check, and the error names the first operation of the group it lacks.
import std;
import goose_io from "../..";
import goose_io.tests.support.stub;

fn main() {
    var io = stub::Core { .. };
    goose_io::require_sizing(io);
}
