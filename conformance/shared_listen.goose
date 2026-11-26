// goose-io conformance suite, shared-listen capability: `listen_shared`.
// Requirements: Shared listeners hold one address together | Shared and plain listeners conflict |
// A stopped shared listener says what it does with waiting connections.
// The suite gets one loop, so the checks hold two shared listeners in it: what the contract says of "two loops of one process"
// holds for two listeners of one loop too, and a real loop that spreads connections by SO_REUSEPORT does it the same way.
namespace goose_io_conformance;
import std;
import goose_io;
import conformance.support;

fn shared_listen_info(id: i64) -> Info {
    if id == 700 { return Info { name: "shared_two_listeners", req: "Shared listeners hold one address together", part: 0 }; }
    if id == 701 { return Info { name: "shared_each_once", req: "Shared listeners hold one address together", part: 0 }; }
    if id == 702 { return Info { name: "shared_plain_after_shared", req: "Shared and plain listeners conflict", part: 0 }; }
    if id == 703 { return Info { name: "shared_shared_after_plain", req: "Shared and plain listeners conflict", part: 0 }; }
    if id == 704 { return Info { name: "shared_unix_refused", req: "Shared and plain listeners conflict", part: 0 }; }
    if id == 705 { return Info { name: "shared_stop_one", req: "A stopped shared listener says what it does with waiting connections", part: 0 }; }
    return Info { .. };
}

// A second shared listener on the first one's address.
fn _second_shared<Io>(k: Case&, io: Io&) -> bool {
    let l, err = io.listen_shared("127.0.0.1:0");
    k.expect(goose_io::is_listener(l) && !goose_io::failed(err), "listen_shared on a free port failed");
    guard goose_io::is_listener(l) else { return false; }
    k.l = l;
    k.port = io.listener_port(l) as i64;
    let text = local_text(k.port);
    let l2, err2 = io.listen_shared(text[..]);
    k.expect(goose_io::is_listener(l2) && !goose_io::failed(err2), "a second listen_shared on an address shared listeners hold failed");
    k.l2 = l2;
    return goose_io::is_listener(l2);
}

fn c_shared_two_listeners<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        if k._second_shared(io) {
            k.expect(!goose_io::same(k.l, k.l2), "two shared listeners got the same handle");
            k.expect(io.listener_port(k.l2) as i64 == k.port, "the second shared listener does not report the shared port");
        }
        k.finish();
    }
}

// Every connection is accepted by one shared listener, never two and never none.
fn c_shared_each_once<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    let dials = 6;
    if k.step == 0 {
        guard k._second_shared(io) else { k.finish(); return; }
        let text = local_text(k.port);
        for _ in dials { io.dial(text[..], 0); }
        k.within(io, 2000);
        k.step = 1;
    } else if k.step == 1 {
        match ev {
            Opened e => {
                if goose_io::is_listener(e.listener) {
                    k.expect(goose_io::same(e.listener, k.l) || goose_io::same(e.listener, k.l2), "a connection was accepted by a listener that is not one of the shared ones");
                    k.n++;
                    io.close(e.link);
                }
            },
            _ => {},
        }
        if k.n >= dials { k.t = io.now_ms(); k.step = 2; k.within(io, 300); }
    } else if k.step == 2 {
        k.expect(k.n == dials, "a connection was accepted more than once");
        if io.now_ms() >= k.started + 200 { k.live = 0; k.finish(); }
    }
}

fn c_shared_plain_after_shared<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        let l, err = io.listen_shared("127.0.0.1:0");
        k.expect(goose_io::is_listener(l) && !goose_io::failed(err), "listen_shared on a free port failed");
        k.l = l;
        let text = local_text(io.listener_port(l) as i64);
        let p, perr = io.listen(text[..]);
        k.expect(!goose_io::is_listener(p), "a plain listen succeeded on an address a shared listener holds");
        k.expect(perr.kind == goose_io::ListenErrorKind.AddressInUse, "a plain listen on a shared address did not fail with AddressInUse");
        k.finish();
    }
}

fn c_shared_shared_after_plain<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        guard k.listen_local(io, 0) else { k.finish(); return; }
        let text = local_text(k.port);
        let s, serr = io.listen_shared(text[..]);
        k.expect(!goose_io::is_listener(s), "listen_shared succeeded on an address a plain listener holds");
        k.expect(serr.kind == goose_io::ListenErrorKind.AddressInUse, "listen_shared on a plain listener's address did not fail with AddressInUse");
        k.finish();
    }
}

fn c_shared_unix_refused<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        // a loop without the unix capability has no unix fixture: any path will do, since it is refused either way
        var path: u8[>..] = [];
        path.append("unix:");
        if fx.unix.len > 0 { path.append(fx.unix); } else { path.append("/tmp/goose-io-shared-listen.sock"); }
        let l, err = io.listen_shared(path[..]);
        k.expect(!goose_io::is_listener(l), "listen_shared on a unix path succeeded");
        k.expect(err.kind == goose_io::ListenErrorKind.BadAddress, "listen_shared on a unix path did not fail with BadAddress");
        k.finish();
    }
}

// One of two shared listeners stops: the other goes on accepting.
fn c_shared_stop_one<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    let dials = 4;
    if k.step == 0 {
        guard k._second_shared(io) else { k.finish(); return; }
        io.stop_listening(k.l);
        let text = local_text(k.port);
        for _ in dials { io.dial(text[..], 0); }
        k.within(io, 2000);
        k.step = 1;
    } else if k.step == 1 {
        match ev {
            Opened e => {
                if goose_io::is_listener(e.listener) {
                    k.expect(goose_io::same(e.listener, k.l2), "a connection went to the stopped shared listener or to none of them");
                    k.n++;
                    io.close(e.link);
                }
            },
            _ => {},
        }
        if k.n >= dials { k.live = 0; k.finish(); }
    }
}

fn shared_listen_capability_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 700 { c_shared_two_listeners(k, io, ev); return true; }
    if k.id == 701 { c_shared_each_once(k, io, ev); return true; }
    if k.id == 702 { c_shared_plain_after_shared(k, io, ev); return true; }
    if k.id == 703 { c_shared_shared_after_plain(k, io, ev); return true; }
    if k.id == 704 { c_shared_unix_refused(k, fx, io, ev); return true; }
    if k.id == 705 { c_shared_stop_one(k, io, ev); return true; }
    return false;
}
