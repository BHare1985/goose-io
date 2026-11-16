// A loop that supplies exactly the core of the contract and does nothing with it, for tests of the compile-time checks:
// a library or a check that asks for more than the core fails to build, and the error names what is missing.
namespace stub;
import std;
import goose_io;

struct Core { n: i64 = 0 }

fn listen(io: Core&, address: const u8[:], tag: u16) -> goose_io::Listener, goose_io::ListenError { return goose_io::Listener { .. }, goose_io::ListenError { .. }; }
fn listener_port(io: Core&, l: goose_io::Listener) -> u16 { 0 }
fn dial(io: Core&, address: const u8[:], tag: u16, connect_ms: i64) -> goose_io::Link { goose_io::Link { .. } }
fn send(io: Core&, link: goose_io::Link, bytes: const u8[:]) -> goose_io::SendStatus { goose_io::SendStatus.Closed }
fn max_send(io: Core&) -> i64 { 4096 }
fn pause_reading(io: Core&, link: goose_io::Link, paused: bool) {}
fn close(io: Core&, link: goose_io::Link) {}
fn set_user(io: Core&, link: goose_io::Link, user: u32) {}
fn now_ms(io: Core&) -> i64 { 0 }
fn tick_by(io: Core&, at_ms: i64) {}
fn stop(io: Core&, grace_ms: i64) {}
fn draining(io: Core&) -> bool { true }
fn serve<F>(io: Core&) {
    let e: goose_io::Event = goose_io::Event.Tick { now_ms: 0 };
    F(io, e);
}
