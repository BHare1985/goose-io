// expect: send2
// A loop that has send_room but not send2 passes the core check and fails the sizing check, naming send2.
import std;
import goose_io from "../..";
import goose_io.tests.support.stub;

fn send_room(io: stub::Core&, link: goose_io::Link) -> i64 { 0 }

fn main() {
    var io = stub::Core { .. };
    goose_io::require_core(io);
    goose_io::require_sizing(io);
}
