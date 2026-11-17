// expect: unknown function or member: listener_port
// A loop that lacks one operation of the core does not compile, and the error names the operation.
// (A *_mustfail.goose file passes when it exits non-zero and prints the text after "expect:".)
import std;
import goose_io from "../..";

// Every operation of the contract except listener_port.
struct Almost { n: i64 = 0 }

fn listen(io: Almost&, address: const u8[:]) -> goose_io::Listener, goose_io::ListenError { return goose_io::Listener { .. }, goose_io::ListenError { .. }; }
fn stop_listening(io: Almost&, l: goose_io::Listener) {}
fn dial(io: Almost&, address: const u8[:], connect_ms: i64) -> goose_io::Link { goose_io::Link { .. } }
fn peer_address(io: Almost&, link: goose_io::Link) -> goose_io::Address { goose_io::Address { .. } }
fn send(io: Almost&, link: goose_io::Link, bytes: const u8[:]) -> goose_io::SendStatus { goose_io::SendStatus.Closed }
fn send_room(io: Almost&, link: goose_io::Link) -> i64 { 0 }
fn max_send(io: Almost&) -> i64 { 4096 }
fn pause_reading(io: Almost&, link: goose_io::Link, paused: bool) {}
fn set_keep_open_on_eof(io: Almost&, link: goose_io::Link, keep: bool) {}
fn shutdown_write(io: Almost&, link: goose_io::Link) {}
fn close(io: Almost&, link: goose_io::Link) {}
fn reset(io: Almost&, link: goose_io::Link) {}
fn now_ms(io: Almost&) -> i64 { 0 }
fn tick_by(io: Almost&, at_ms: i64) {}
fn stop(io: Almost&, grace_ms: i64) {}
fn draining(io: Almost&) -> bool { true }
fn serve<F>(io: Almost&) {
    let e: goose_io::Event = goose_io::Event.Tick { now_ms: 0 };
    F(io, e);
}

fn main() {
    var io = Almost { .. };
    goose_io::require_core(io);
}
