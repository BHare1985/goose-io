// Runs one part of the conformance suite against the in-memory provider: `goose run tests/conformance/memory_conformance.goose -- 3 core`.
// The part is the first argument (default 0) and the group the second (core or batching; default all of them).
// The environment variable GOOSE_IO_FAULT, when set, switches the in-memory provider to one of its named faults
// (see tests/conformance/faults.sh).
import std;
import os;
import goose_io from "../..";
import goose_io.conformance.suite;
import goose_io.memory;

fn main() {
    var part = 0;
    if arg_count() > 1 {
        var text: u8[>..] = [];
        arg(1, text);
        part = 0;
        for c in text { if c >= '0' && c <= '9' { part = part * 10 + (c - '0'); } }
    }
    var group: u8[>..] = [];
    if arg_count() > 2 { arg(2, group); }
    var io = goose_io_memory::Loop { .. };
    var fault: u8[>..] = [];
    if env("GOOSE_IO_FAULT", fault) && fault.len > 0 { io.set_fault(fault[..]); }
    io.silent("10.255.0.1:81");
    io.hold("127.0.0.1:9999");
    let up = io.add_peer();
    io.peer_accept(up, "10.255.0.2:80");
    let fixture = goose_io_conformance::Fixture { silent: "10.255.0.1:81", held: "127.0.0.1:9999", answers: "10.255.0.2:80" };
    if group == "core" { exit(goose_io_conformance::conformance_core_part(io, fixture, part)); }
    if group == "batching" { exit(goose_io_conformance::conformance_batching_part(io, fixture, part)); }
    exit(goose_io_conformance::conformance_part(io, fixture, part));
}
