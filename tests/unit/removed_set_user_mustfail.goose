// expect: set_user
// A library that calls set_user does not compile: the operation was removed with the user value
// (specs/io-contract of the change link-keyed-state, *An operation that was removed*).
import std;
import goose_io from "../..";
import goose_io.memory;

fn main() {
    var io = goose_io_memory::Loop { .. };
    let link = io.dial("127.0.0.1:1", 0);
    io.set_user(link, 1);
}
