// expect: cancel_resolve
// A loop that declares name resolution but lacks one of its operations fails the check, and the error names the operation.
import std;
import goose_io from "../..";

struct Liar { n: i64 = 0 }

fn supplies_name_resolution(io: Liar&) -> goose_io::Supplied { return goose_io::Supplied {}; }
fn resolve(io: Liar&, host: const u8[:], port: i64, timeout_ms: i64) -> goose_io::Query { goose_io::Query { .. } }
fn resolved_address(io: Liar&, query: goose_io::Query, i: i64) -> goose_io::Address { goose_io::Address { .. } }

fn main() {
    var io = Liar { .. };
    goose_io::require_name_resolution(io);
}
