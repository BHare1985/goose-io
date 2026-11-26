// expect: supplies_name_resolution
// A loop that has every name-resolution operation but does not declare the capability fails the check, and the error names
// the declaration: having the operations is not supplying the capability.
import std;
import goose_io from "../..";

struct Quiet { n: i64 = 0 }

fn resolve(io: Quiet&, host: const u8[:], port: i64, timeout_ms: i64) -> goose_io::Query { goose_io::Query { .. } }
fn resolved_address(io: Quiet&, query: goose_io::Query, i: i64) -> goose_io::Address { goose_io::Address { .. } }
fn cancel_resolve(io: Quiet&, query: goose_io::Query) {}

fn main() {
    var io = Quiet { .. };
    goose_io::require_name_resolution(io);
}
