// expect: supplies_peek
// A root program that passes a loop which has the peek operations but does not declare peek to the peek entry point
// of the suite does not build, and the error names the declaration: a loop cannot pass a capability's suite
// without declaring the capability.
import std;
import goose_io from "../..";
import goose_io.conformance.suite;

struct Quiet { n: i64 = 0 }

fn peek(io: Quiet&, link: goose_io::Link) -> const u8[:] { return ""; }
fn wait_input(io: Quiet&, link: goose_io::Link, byte_count: i64) {}
fn discard_input(io: Quiet&, link: goose_io::Link, byte_count: i64) -> i64 { 0 }

fn main() {
    var io = Quiet { .. };
    let fx = goose_io_conformance::Fixture { silent: "10.255.0.1:81", held: "127.0.0.1:9999", refused: "10.255.0.3:9", answers: "10.255.0.2:80", unix: "/run/goose-io-test.sock", peek_bound: 16 };
    exit(goose_io_conformance::conformance_peek_part(io, fx, 0));
}
