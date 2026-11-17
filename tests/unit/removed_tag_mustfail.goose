// expect: listen
// A library that passes a tag to listen does not compile: the parameter was removed with the tag
// (specs/io-contract of the change link-keyed-state, *An operation that was removed*).
import std;
import goose_io from "../..";
import goose_io.memory;

fn main() {
    var io = goose_io_memory::Loop { .. };
    let l, err = io.listen("127.0.0.1:8080", 1);
}
