// goose-io conformance suite, group 4.4: listening, dialling, peer addresses, IPv6.
// Requirements: Listening; Listener handles are never reused; A link reports its peer's address;
// Dialling never blocks and always ends in one event; A failed dial says why; Scope of the base contract.
namespace goose_io_conformance;
import std;
import goose_io;
import conformance.support;

fn net_info(id: i64) -> Info {
    if id == 200 { return Info { name: "listen_accepts", req: "Listening", part: 0 }; }
    if id == 201 { return Info { name: "listen_held_address", req: "Listening", part: 0 }; }
    if id == 202 { return Info { name: "listen_port_zero", req: "Listening", part: 0 }; }
    if id == 203 { return Info { name: "listen_stop_keeps_links", req: "Listening", part: 0 }; }
    if id == 204 { return Info { name: "listener_handle_never_reused", req: "Listener handles are never reused", part: 0 }; }
    if id == 205 { return Info { name: "peer_address_names_peer", req: "A link reports its peer's address", part: 0 }; }
    if id == 206 { return Info { name: "dial_succeeds", req: "Dialling never blocks and always ends in one event", part: 0 }; }
    if id == 207 { return Info { name: "dial_refused", req: "A failed dial says why", part: 0 }; }
    if id == 208 { return Info { name: "dial_times_out", req: "A failed dial says why", part: 0 }; }
    if id == 209 { return Info { name: "dial_bad_address", req: "A failed dial says why", part: 0 }; }
    if id == 210 { return Info { name: "ipv6_loopback", req: "Scope of the base contract", part: 0 }; }
    if id == 211 { return Info { name: "peer_address_ipv6", req: "A link reports its peer's address", part: 0 }; }
    return Info { .. };
}

// --- 200: a connection is accepted -----------------------------------------------------------------

fn c_listen_accepts<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        let o = k.recs[k.first(1, 'O')];
        k.expect(goose_io::same(o.listener, k.l), "Opened of an accepted link did not carry the listener's handle");
        k.expect(o.tag == k.tag(0), "Opened of an accepted link did not carry the listener's tag");
        let d = k.recs[k.first(0, 'O')];
        k.expect(!goose_io::is_listener(d.listener), "Opened of a dialled link carried a listener");
        io.close(k.link[0]);
        k.step = 2;
        k.finish();
    }
}

// --- 201: the address is taken ---------------------------------------------------------------------

fn c_listen_held_address<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.expect(fx.held.len > 0, "the fixture supplied no held address");
        let l, err = io.listen(fx.held, k.tag(0));
        k.expect(!goose_io::is_listener(l), "listen on a held address returned a listener");
        k.expect(err.kind == goose_io::ListenErrorKind.AddressInUse, "listen on a held address did not return AddressInUse");
        k.expect(goose_io::failed(err), "failed() was false for an error");
        k.within(io, 600);
        k.step = 1;
    } else if k.step == 1 && io.now_ms() >= k.started + 250 {
        // nothing happens afterwards
        k.expect(k.recs.len == 0, "events followed a failed listen");
        k.finish();
    }
}

// --- 202: a system-chosen port can be discovered ---------------------------------------------------

fn c_listen_port_zero<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        if k.listen_local(io, 0) {
            k.n = k.port;
            if k.listen_local(io, 1) { k.expect(k.port != k.n, "two listeners on port 0 got the same port"); }
            k.port = k.n;
            k.dial_local(io, 0, 0);
        }
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        k.expect(io.listener_port(k.l) as i64 == k.port, "listener_port changed between calls");
        io.close(k.link[0]);
        k.step = 2;
        k.finish();
    }
}

// --- 203: stopping a listener keeps its links ------------------------------------------------------

fn c_listen_stop_keeps_links<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.stop_listening(k.l);
        k.dial_to(io, local_text(k.port), 1, 0);          // pair 1's dialled end: must be refused
        io.send(k.link[0], "still open");
        k.step = 2;
    } else if k.step == 2 && k.received(1).len >= 10 && k.first(2, 'C') >= 0 {
        k.expect(k.received(1) == "still open", "an accepted link stopped carrying data when its listener stopped");
        k.expect(k.kinds(2) == "C", "a dial after stop_listening was accepted");
        k.expect(k.is_open(0) && k.is_open(1), "stop_listening closed an accepted link");
        io.close(k.link[0]);
        k.step = 3;
        k.finish();
    }
}

// --- 204: a stale listener handle cannot reach a newer listener ----------------------------------------

fn c_listener_handle_never_reused<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        if k.listen_local(io, 0) {
            k.n = k.port;
            let first = k.l;
            io.stop_listening(first);
            k.expect(io.listener_port(first) == 0, "listener_port of a stopped listener was not 0");
            // listen again on the very address the first one had
            let again, err = io.listen(local_text(k.n), k.tag(2));
            k.expect(goose_io::is_listener(again) && !goose_io::failed(err), "could not listen again on the address of a stopped listener");
            k.expect(!goose_io::same(again, first), "a stopped listener's handle was given to a new listener");
            k.l2 = again;
            io.stop_listening(first);            // the old handle: it must not stop the new listener
            k.expect(io.listener_port(again) as i64 == k.n, "an old listener handle stopped a newer listener");
            k.dial_local(io, 1, 0);
        }
        k.step = 1;
    } else if k.step == 1 && k.first(2, 'O') >= 0 && k.first(3, 'O') >= 0 {
        io.close(k.link[2]);
        k.step = 2;
        k.finish();
    }
}

// --- 205: peer addresses ---------------------------------------------------------------------------

fn c_peer_address_names_peer<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        let target = addr_text(io.peer_address(k.link[0]));
        k.expect(target == local_text(k.port), "the dialled link's peer address was not the target");
        let from = addr_text(io.peer_address(k.link[1]));
        k.expect(starts_with(from, "127.0.0.1:") && from.len > 10, "the accepted link's peer address was not the dialling side's address");
        k.step = 2;
        io.close(k.link[0]);
    } else if k.step == 2 && k.first(0, 'C') >= 0 {
        // the handler of that Closed has to return before the handle is stale
        k.step = 3;
    } else if k.step == 3 {
        k.expect(goose_io::is_empty(io.peer_address(k.link[0])), "a closed link still had a peer address");
        k.finish();
    }
}

// --- 206: a successful dial ------------------------------------------------------------------------

fn c_dial_succeeds<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        if k.listen_local(io, 0) {
            let link = k.dial_local(io, 0, 0);
            k.expect(goose_io::is_valid(link), "dial did not return a valid link");
            k.expect(k.recs.len == 0, "an event was delivered before dial returned");
            k.expect(io.send(link, "x") == goose_io::SendStatus.NotOpen, "send before Opened did not return NotOpen");
        }
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        k.expect(k.kinds(0) == "O", "the dialled link saw something before its Opened");
        io.close(k.link[0]);
        k.step = 2;
        k.finish();
    }
}

// --- 207: a refused dial -----------------------------------------------------------------------------

fn c_dial_refused<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.expect(fx.refused.len > 0, "the fixture supplied no address that nothing listens on");
        k.dial_to(io, fx.refused, 0, 0);
        k.step = 1;
    } else if k.step == 1 && k.first(0, 'C') >= 0 {
        k.expect(k.kinds(0) == "C", "a refused dial did not give exactly one Closed and no Opened");
        k.expect(k.failed_with(0, goose_io::ConnectFailure.Refused) || k.failed_with(0, goose_io::ConnectFailure.Other), "a refused dial did not close with ConnectFailed of kind Refused (or Other)");
        k.finish();
    }
}

// --- 208: a dial that times out ----------------------------------------------------------------------

fn c_dial_times_out<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.expect(fx.silent.len > 0, "the fixture supplied no address that never answers");
        k.t = io.now_ms();
        k.dial_to(io, fx.silent, 0, 200);
        k.within(io, 5000);
        k.step = 1;
    } else if k.step == 1 && k.first(0, 'C') >= 0 {
        let at = k.recs[k.first(0, 'C')].at;
        k.expect(k.kinds(0) == "C", "a dial that timed out did not give exactly one Closed and no Opened");
        k.expect(at >= k.t + 200, "the dial timed out before connect_ms had passed");
        k.expect(k.failed_with(0, goose_io::ConnectFailure.TimedOut), "a dial that timed out did not close with ConnectFailed of kind TimedOut");
        k.finish();
    }
}

// --- 209: malformed text, host names, zone identifiers -----------------------------------------------

fn c_dial_bad_address<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.dial_to(io, "not an address", 0, 0);
        k.dial_to(io, "db.example.com:5432", 1, 0);
        k.step = 1;
        let l, err = io.listen("[fe80::1%eth0]:8080", k.tag(0));
        k.expect(!goose_io::is_listener(l) && err.kind == goose_io::ListenErrorKind.BadAddress, "listen with a zone identifier did not return BadAddress");
        let h, herr = io.listen("db.example.com:80", k.tag(0));
        k.expect(!goose_io::is_listener(h) && herr.kind == goose_io::ListenErrorKind.BadAddress, "listen on a host name did not return BadAddress");
        k.link[1] = io.dial("[fe80::1%eth0]:80", k.tag(0), 0);
        k.live++;
    } else if k.step == 1 && k.first(0, 'C') >= 0 && k.first(2, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.expect(k.kinds(0) == "C" && k.kinds(2) == "C" && k.kinds(1) == "C", "a dial to a bad address did not give exactly one Closed and no Opened");
        k.expect(k.failed_with(0, goose_io::ConnectFailure.BadAddress), "a malformed address did not give BadAddress");
        k.expect(k.failed_with(2, goose_io::ConnectFailure.BadAddress), "a host name did not give BadAddress");
        k.expect(k.failed_with(1, goose_io::ConnectFailure.BadAddress), "a zone identifier did not give BadAddress");
        k.finish();
    }
}

// --- 210: IPv6 ---------------------------------------------------------------------------------------

fn c_ipv6_loopback<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        let l, err = io.listen("[::1]:0", k.tag(0));
        k.expect(goose_io::is_listener(l) && !goose_io::failed(err), "could not listen on [::1]");
        k.l = l;
        k.port = io.listener_port(l) as i64;
        var text: u8[>..] = [];
        format(text, "[::1]:", k.port);
        k.dial_to(io, text, 0, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.send(k.link[0], "over v6");
        k.step = 2;
    } else if k.step == 2 && k.received(1).len >= 7 {
        k.expect(k.received(1) == "over v6", "an IPv6 link did not carry data");
        io.close(k.link[0]);
        k.step = 3;
        k.finish();
    }
}

// --- 211: the peer address of an IPv6 link -------------------------------------------------------------------

fn c_peer_address_ipv6<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        let l, err = io.listen("[::1]:0", k.tag(0));
        k.expect(goose_io::is_listener(l) && !goose_io::failed(err), "could not listen on [::1]");
        k.l = l;
        k.port = io.listener_port(l) as i64;
        var text: u8[>..] = [];
        format(text, "[::1]:", k.port);
        k.dial_to(io, text, 0, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        var text: u8[>..] = [];
        format(text, "[::1]:", k.port);
        k.expect(addr_text(io.peer_address(k.link[0])) == text, "the peer address of an IPv6 link was not [::1]:port in lower case");
        io.close(k.link[0]);
        k.step = 2;
        k.finish();
    }
}

// Runs the checks of the core: true if the check is one of them.
fn net_core_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 200 { c_listen_accepts(k, io, ev); return true; }
    if k.id == 201 { c_listen_held_address(k, fx, io, ev); return true; }
    if k.id == 202 { c_listen_port_zero(k, io, ev); return true; }
    if k.id == 206 { c_dial_succeeds(k, io, ev); return true; }
    if k.id == 207 { c_dial_refused(k, fx, io, ev); return true; }
    if k.id == 208 { c_dial_times_out(k, fx, io, ev); return true; }
    if k.id == 209 { c_dial_bad_address(k, io, ev); return true; }
    if k.id == 210 { c_ipv6_loopback(k, io, ev); return true; }
    return false;
}

// Runs the checks of the inspection group: true if the check is one of them.
fn net_inspection_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 203 { c_listen_stop_keeps_links(k, io, ev); return true; }
    if k.id == 204 { c_listener_handle_never_reused(k, io, ev); return true; }
    if k.id == 205 { c_peer_address_names_peer(k, io, ev); return true; }
    if k.id == 211 { c_peer_address_ipv6(k, io, ev); return true; }
    return false;
}
