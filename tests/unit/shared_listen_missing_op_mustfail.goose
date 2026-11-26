// expect: listen_shared
// A loop that declares shared-listen but lacks its operation fails the check, and the error names the operation.
import std;
import goose_io from "../..";

struct Liar { n: i64 = 0 }

fn supplies_shared_listen(io: Liar&) -> goose_io::Supplied { return goose_io::Supplied {}; }

fn main() {
    var io = Liar { .. };
    goose_io::require_shared_listen(io);
}
