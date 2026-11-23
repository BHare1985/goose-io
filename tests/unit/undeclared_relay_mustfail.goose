// expect: supplies_relay
// A loop that has every relay operation but does not declare relay fails the relay check, and the error names the
// declaration: having the operations is not supplying the capability.
import std;
import goose_io from "../..";

struct Quiet { n: i64 = 0 }

fn relay(io: Quiet&, first: goose_io::Link, second: goose_io::Link) -> goose_io::RelayStatus { goose_io::RelayStatus.Closed }
fn relayed_bytes(io: Quiet&, link: goose_io::Link) -> i64 { 0 }

fn main() {
    var io = Quiet { .. };
    goose_io::require_relay(io);
}
