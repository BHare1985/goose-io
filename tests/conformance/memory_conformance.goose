// Runs one part of the conformance suite against the in-memory event loop: `goose run tests/conformance/memory_conformance.goose -- 3 core`.
// The part is the first argument (default 0) and the capability the second (core, half-close, sizing, abort, inspection, batching, unix, relay, peek, revoke, wake, limits, name-resolution or shared-listen; default core).
// The environment variable GOOSE_IO_FAULT, when set, switches the in-memory event loop to one of its named faults
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
    var capability: u8[>..] = [];
    if arg_count() > 2 { arg(2, capability); }
    var io = goose_io_memory::Loop { .. };
    io.cfg.peek_bound = 16;
    var fault: u8[>..] = [];
    if env("GOOSE_IO_FAULT", fault) && fault.len > 0 { io.set_fault(fault[..]); }
    io.silent("10.255.0.1:81");
    io.hold("127.0.0.1:9999");
    let up = io.add_peer();
    io.peer_accept(up, "10.255.0.2:80");
    io.script_name("found.test", 0, "127.0.0.1");
    io.script_name("missing.test", 0, "");
    io.script_name("slow.test", 5000, "127.0.0.1");
    io.script_name("db.test", 0, "10.0.0.1,10.0.0.2");
    let fixture = goose_io_conformance::Fixture { found: "found.test", missing: "missing.test", slow: "slow.test", pair: "db.test", pair_first: "10.0.0.1:80", pair_second: "10.0.0.2:80", silent: "10.255.0.1:81", held: "127.0.0.1:9999", refused: "10.255.0.3:9", answers: "10.255.0.2:80", unix: "/run/goose-io-test.sock", peek_bound: 16 };
    if capability == "half-close" { exit(goose_io_conformance::conformance_half_close_part(io, fixture, part)); }
    if capability == "sizing" { exit(goose_io_conformance::conformance_sizing_part(io, fixture, part)); }
    if capability == "abort" { exit(goose_io_conformance::conformance_abort_part(io, fixture, part)); }
    if capability == "inspection" { exit(goose_io_conformance::conformance_inspection_part(io, fixture, part)); }
    if capability == "batching" { exit(goose_io_conformance::conformance_batching_part(io, fixture, part)); }
    if capability == "unix" { exit(goose_io_conformance::conformance_unix_part(io, fixture, part)); }
    if capability == "relay" { exit(goose_io_conformance::conformance_relay_part(io, fixture, part)); }
    if capability == "peek" { exit(goose_io_conformance::conformance_peek_part(io, fixture, part)); }
    if capability == "revoke" { exit(goose_io_conformance::conformance_revoke_part(io, fixture, part)); }
    if capability == "wake" { exit(goose_io_conformance::conformance_wake_part(io, fixture, part)); }
    if capability == "shared-listen" { exit(goose_io_conformance::conformance_shared_listen_part(io, fixture, part)); }
    if capability == "name-resolution" { exit(goose_io_conformance::conformance_name_resolution_part(io, fixture, part)); }
    if capability == "limits" { exit(goose_io_conformance::conformance_limits_part(io, fixture, part)); }
    exit(goose_io_conformance::conformance_core_part(io, fixture, part));
}
