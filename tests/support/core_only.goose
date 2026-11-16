// An event loop that supplies the core of the contract and nothing more: the loop a library with small needs may be
// run on. It sits over the in-memory loop and passes the 13 operations of the core through, and it has no other
// operation of the contract (no half-close, sizing, abort or inspection) and delivers none of the events of the
// groups: PeerEof can only follow set_keep_open_on_eof, which it does not have, and the PassEnd of the in-memory
// loop is not given on.
//
// What the fixture of a test needs from a loop (`silent`, `hold`, `add_peer`, `peer_accept` and the scripted peers)
// is the in-memory loop's own, passed through, and is not part of the contract.
//
// The inner loop is a global of this module, so one process holds one core-only loop.
namespace core_only;
import std;
import goose_io;
import memory;

var inner: goose_io_memory::Loop = goose_io_memory::Loop { .. };

struct Core { n: i64 = 0 }

fn listen(io: Core&, address: const u8[:], tag: u16) -> goose_io::Listener, goose_io::ListenError { return inner.listen(address, tag); }
fn listener_port(io: Core&, l: goose_io::Listener) -> u16 { inner.listener_port(l) }
fn dial(io: Core&, address: const u8[:], tag: u16, connect_ms: i64) -> goose_io::Link { inner.dial(address, tag, connect_ms) }
fn send(io: Core&, link: goose_io::Link, bytes: const u8[:]) -> goose_io::SendStatus { inner.send(link, bytes) }
fn max_send(io: Core&) -> i64 { inner.max_send() }
fn pause_reading(io: Core&, link: goose_io::Link, paused: bool) { inner.pause_reading(link, paused); }
fn close(io: Core&, link: goose_io::Link) { inner.close(link); }
fn set_user(io: Core&, link: goose_io::Link, user: u32) { inner.set_user(link, user); }
fn now_ms(io: Core&) -> i64 { inner.now_ms() }
fn tick_by(io: Core&, at_ms: i64) { inner.tick_by(at_ms); }
fn stop(io: Core&, grace_ms: i64) { inner.stop(grace_ms); }
fn draining(io: Core&) -> bool { inner.draining() }

fn serve<F>(io: Core&) {
    inner.serve() { _, ev =>
        match ev {
            PassEnd => {},
            PeerEof e => {},
            _ => { F(io, ev); },
        }
    };
}

// Not part of the contract: what a test fixture needs from the in-memory loop underneath.
fn silent(io: Core&, address: const u8[:]) { inner.silent(address); }
fn hold(io: Core&, address: const u8[:]) { inner.hold(address); }
fn add_peer(io: Core&) -> goose_io_memory::Peer { inner.add_peer() }
fn peer_accept(io: Core&, peer: goose_io_memory::Peer, address: const u8[:]) { inner.peer_accept(peer, address); }

// Never called: makes the compiler check this loop against the core's own check whenever it is built.
fn _supplied(io: Core&) {
    goose_io::require_core(io);
}
