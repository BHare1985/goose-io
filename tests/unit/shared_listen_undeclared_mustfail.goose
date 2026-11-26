// expect: supplies_shared_listen
// A loop that has every shared-listen operation but does not declare the capability fails the check, and the error names
// the declaration: having the operations is not supplying the capability.
import std;
import goose_io from "../..";

struct Quiet { n: i64 = 0 }

fn listen_shared(io: Quiet&, address: const u8[:]) -> goose_io::Listener, goose_io::ListenError { return goose_io::Listener { .. }, goose_io::ListenError { .. }; }

fn main() {
    var io = Quiet { .. };
    goose_io::require_shared_listen(io);
}
