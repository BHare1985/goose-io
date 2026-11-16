// expect: ms of its own clock without serve returning
// A test that never calls stop. It must end with a failure that names the limit, not hang.
// (A *_mustfail.goose file passes when it exits non-zero and prints the text after "expect:".)
import std;
import goose_io from "../..";
import goose_io.memory;

fn main() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.time_limit_ms = 2000;
    var n = 0;
    io.serve() { io, ev => { n++; } };
    print("serve returned");
}
