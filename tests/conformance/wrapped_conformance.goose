// Runs one part of the conformance suite against the wrapper of tests/support/wrapper.goose, which sits over the
// in-memory provider, changes every byte and delays Opened by one pass: `goose run tests/conformance/wrapped_conformance.goose -- 3`.
import std;
import os;
import goose_io from "../..";
import goose_io.conformance.suite;
import goose_io.tests.support.wrapper;

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
    var io = wrapper::Layer { .. };
    goose_io::require_core(io);
    goose_io::require_half_close(io);
    goose_io::require_sizing(io);
    goose_io::require_abort(io);
    goose_io::require_inspection(io);
    io.silent("10.255.0.1:81");
    io.hold("127.0.0.1:9999");
    let up = io.add_peer();
    io.peer_accept(up, "10.255.0.2:80");
    let fixture = goose_io_conformance::Fixture { silent: "10.255.0.1:81", held: "127.0.0.1:9999", refused: "10.255.0.3:9", answers: "10.255.0.2:80" };
    if group == "half-close" { exit(goose_io_conformance::conformance_half_close_part(io, fixture, part)); }
    if group == "sizing" { exit(goose_io_conformance::conformance_sizing_part(io, fixture, part)); }
    if group == "abort" { exit(goose_io_conformance::conformance_abort_part(io, fixture, part)); }
    if group == "inspection" { exit(goose_io_conformance::conformance_inspection_part(io, fixture, part)); }
    if group == "batching" { exit(goose_io_conformance::conformance_batching_part(io, fixture, part)); }
    exit(goose_io_conformance::conformance_core_part(io, fixture, part));
}
