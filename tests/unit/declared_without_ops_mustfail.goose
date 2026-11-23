// expect: relayed_bytes
// A loop that declares relay but lacks one relay operation fails the relay check, and the error names the operation.
import std;
import goose_io from "../..";

struct Liar { n: i64 = 0 }

fn supplies_relay(io: Liar&) -> goose_io::Supplied { return goose_io::Supplied {}; }
fn relay(io: Liar&, first: goose_io::Link, second: goose_io::Link) -> goose_io::RelayStatus { goose_io::RelayStatus.Closed }

fn main() {
    var io = Liar { .. };
    goose_io::require_relay(io);
}
