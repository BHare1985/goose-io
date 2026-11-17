// In-memory event loop: listening, dialling, joining, peer addresses, slots.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;

// Records every event and stops the loop at `until_ms`.
fn watch(io: goose_io_memory::Loop&, log: kit::Log&, ev: goose_io::Event, until_ms: i64) {
    kit::note(log, io, ev);
    match ev {
        Tick t => { if t.now_ms >= until_ms { io.stop(0); } },
        _ => {},
    }
}

fn run(io: goose_io_memory::Loop&, log: kit::Log&, until_ms: i64) {
    io.serve() { io, ev => watch(io, log, ev, until_ms); };
}

fn listening() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };

    let l, err = io.listen("127.0.0.1:8080");
    kit::check(goose_io::is_listener(l) && !goose_io::failed(err), "listen on a free address succeeds");
    kit::check(io.listener_port(l) == 8080, "listener_port returns the bound port");

    io.hold("127.0.0.1:9090");
    let held, held_err = io.listen("127.0.0.1:9090");
    kit::check(!goose_io::is_listener(held), "listen on a held address returns no listener");
    kit::check(held_err.kind == goose_io::ListenErrorKind.AddressInUse && held_err.code != 0, "listen on a held address: AddressInUse with a code");

    let twice, twice_err = io.listen("127.0.0.1:8080");
    kit::check(!goose_io::is_listener(twice) && twice_err.kind == goose_io::ListenErrorKind.AddressInUse, "listen twice on one address: AddressInUse");

    let bad, bad_err = io.listen("not an address");
    kit::check(!goose_io::is_listener(bad) && bad_err.kind == goose_io::ListenErrorKind.BadAddress, "listen on malformed text: BadAddress");

    let any, any_err = io.listen("127.0.0.1:0");
    kit::check(goose_io::is_listener(any) && io.listener_port(any) != 0, "port 0 gets a system-chosen port");
    kit::check(io.listener_port(goose_io::Listener { .. }) == 0, "listener_port of no listener is 0");
    kit::check(io.listener_port(goose_io::Listener { id: 999 }) == 0, "listener_port of an unknown listener is 0");

    // an IPv6 zone identifier is not part of an address
    let zoned, zoned_err = io.listen("[fe80::1%eth0]:8081");
    kit::check(!goose_io::is_listener(zoned) && zoned_err.kind == goose_io::ListenErrorKind.BadAddress, "listen with a zone identifier: BadAddress");

    // a listener handle is never used again: the old one cannot reach a newer listener
    io.stop_listening(l);
    kit::check(io.listener_port(l) == 0, "listener_port of a stopped listener is 0");
    let again, again_err = io.listen("127.0.0.1:8080");
    kit::check(goose_io::is_listener(again) && !goose_io::same(again, l), "listening again on the address gives a new handle");
    io.stop_listening(l);
    kit::check(io.listener_port(again) == 8080, "stop_listening with the old handle does not stop the new listener");
    io.stop_listening(again);
    let third, third_err = io.listen("127.0.0.1:8080");
    kit::check(!goose_io::same(third, l) && !goose_io::same(third, again), "and no earlier handle ever comes back");

    run(io, log, 100);
    kit::check(log.entries.len == 0, "listening alone produces no events");
}

fn joined() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };

    let l, err = io.listen("127.0.0.1:0");
    var target: u8[>..] = [];
    format(target, "127.0.0.1:", io.listener_port(l));
    let dialled = io.dial(target, 0);
    kit::check(goose_io::is_valid(dialled), "dial returns a valid link at once");
    kit::check(log.entries.len == 0, "dial delivers nothing before serve runs");
    kit::check(goose_io::is_empty(io.peer_address(dialled)), "no peer address before Opened");

    run(io, log, 100);

    kit::check(kit::count(log, kit::OPENED) == 2, "a dial to a listener opens two links");
    let di = kit::first_for(log, kit::OPENED, dialled);
    kit::check(di >= 0, "the dialled link gets Opened");
    if di >= 0 {
        kit::check(!goose_io::is_listener(log.entries[di].listener), "the dialled link's Opened carries no listener");
    }
    // the other Opened is the accepted link
    for e in log.entries {
        if e.kind == kit::OPENED && !goose_io::same(e.link, dialled) {
            kit::check(goose_io::same(e.listener, l), "the accepted link's Opened carries its listener");
        }
    }
}

struct Addresses { dialled: goose_io::Link = goose_io::Link { .. }, accepted: goose_io::Link = goose_io::Link { .. },
                   dialled_peer: goose_io::Address = goose_io::Address { .. }, accepted_peer: goose_io::Address = goose_io::Address { .. } }

fn addresses_event(a: Addresses&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    match ev {
        Opened e => {
            if goose_io::is_listener(e.listener) { a.accepted = e.link; a.accepted_peer = io.peer_address(e.link); }
            else { a.dialled_peer = io.peer_address(e.link); }
        },
        Tick t => { if t.now_ms >= 100 { io.stop(0); } },
        _ => {},
    }
}

fn peer_addresses() {
    var io = goose_io_memory::Loop { .. };
    var a = Addresses { .. };
    let l, err = io.listen("127.0.0.1:7000");
    a.dialled = io.dial("127.0.0.1:7000", 0);
    io.serve() { io, ev => addresses_event(a, io, ev); };

    kit::check(a.dialled_peer.text == "127.0.0.1:7000", "a dialled link's peer address is its target");
    kit::check(a.accepted_peer.text.len > 10 && a.accepted_peer.text[..10] == "127.0.0.1:", "an accepted link's peer address names the dialling side");
    kit::check(a.accepted_peer.text != "127.0.0.1:7000", "the dialling side has its own port");
    kit::check(goose_io::is_empty(io.peer_address(a.dialled)), "no peer address after Closed (dialled)");
    kit::check(goose_io::is_empty(io.peer_address(a.accepted)), "no peer address after Closed (accepted)");
    kit::check(goose_io::is_empty(io.peer_address(goose_io::Link { .. })), "no peer address for an invalid link");

    // IPv6
    var io6 = goose_io_memory::Loop { .. };
    var a6 = Addresses { .. };
    let l6, err6 = io6.listen("[::1]:7001");
    kit::check(goose_io::is_listener(l6), "listen on an IPv6 address");
    a6.dialled = io6.dial("[::1]:7001", 0);
    io6.serve() { io, ev => addresses_event(a6, io, ev); };
    kit::check(a6.dialled_peer.text == "[::1]:7001", "an IPv6 peer address round-trips");
    kit::check(a6.accepted_peer.text.len > 6 && a6.accepted_peer.text[..6] == "[::1]:", "an accepted IPv6 link names the dialling side");
}

fn failures_of_dial() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };

    let refused = io.dial("127.0.0.1:1", 0);             // nothing listens there
    let malformed = io.dial("127.0.0.1", 0);            // no port
    let named = io.dial("db.example.com:5432", 0);     // a host name is not resolved
    let empty = io.dial("", 0);
    kit::check(goose_io::is_valid(refused) && goose_io::is_valid(malformed) && goose_io::is_valid(named) && goose_io::is_valid(empty), "a failing dial still returns a valid link");
    kit::check(io.send(refused, "x") == goose_io::SendStatus.NotOpen, "send before Opened returns NotOpen");

    run(io, log, 100);

    kit::check(kit::count(log, kit::OPENED) == 0, "a failed dial never gets Opened");
    kit::check(kit::kinds_of(log, refused) == "C", "a refused dial: exactly one Closed");
    kit::check(kit::kinds_of(log, malformed) == "C", "a malformed address: exactly one Closed");
    kit::check(kit::kinds_of(log, named) == "C", "a host name: exactly one Closed");
    kit::check(kit::kinds_of(log, empty) == "C", "an empty address: exactly one Closed");
    for e in log.entries {
        if e.kind == kit::CLOSED {
            kit::check(goose_io::is_connect_failed(e.why), "a failed dial closes with ConnectFailed");
            kit::check(goose_io::is_valid(e.link), "the Closed of a failed dial carries a link");
        }
    }
    kit::check(kit::failed_with(log, refused, goose_io::ConnectFailure.Refused), "nothing listening: kind Refused");
    kit::check(kit::failed_with(log, malformed, goose_io::ConnectFailure.BadAddress), "malformed text: kind BadAddress");
    kit::check(kit::failed_with(log, named, goose_io::ConnectFailure.BadAddress), "a host name is not an address: kind BadAddress");
    kit::check(kit::failed_with(log, empty, goose_io::ConnectFailure.BadAddress), "an empty address: kind BadAddress");
    kit::check(!goose_io::is_connect_failed(goose_io::CloseReason.PeerReset) && goose_io::is_portable(goose_io::CloseReason.ConnectFailed { kind: goose_io::ConnectFailure.Other }), "is_connect_failed tells the reason apart; every kind is portable");
    let mi = kit::first_for(log, kit::CLOSED, malformed);
    kit::check(mi >= 0, "the Closed of a failed dial carries the link dial returned");
}

fn timeouts() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    io.silent("10.0.0.1:80");
    let start = io.now_ms();
    let short = io.dial("10.0.0.1:80", 200);
    let default = io.dial("10.0.0.1:80", 0);

    run(io, log, 6000);

    let si = kit::first_for(log, kit::CLOSED, short);
    kit::check(si >= 0 && kit::kinds_of(log, short) == "C", "a dial that never answers: exactly one Closed");
    if si >= 0 {
        kit::check(kit::failed_with(log, short, goose_io::ConnectFailure.TimedOut), "a timed-out dial closes with ConnectFailed, kind TimedOut");
        kit::check(log.entries[si].at_ms >= start + 200, "not before connect_ms has passed");
        kit::check(log.entries[si].at_ms < start + 300, "and promptly after it");
    }
    let di = kit::first_for(log, kit::CLOSED, default);
    kit::check(di >= 0 && log.entries[di].at_ms >= start + io.cfg.connect_timeout_ms, "connect_ms 0 uses the event loop's default");
}

struct Cancel { link: goose_io::Link = goose_io::Link { .. }, done: bool = false }

fn cancel_event(c: Cancel&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    match ev {
        Tick t => {
            if !c.done { c.done = true; io.close(c.link); }
            if t.now_ms >= 400 { io.stop(0); }
        },
        _ => {},
    }
}

fn cancelling() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var c = Cancel { .. };
    io.silent("10.0.0.2:80");
    c.link = io.dial("10.0.0.2:80", 0);
    io.serve() { io, ev => cancel_event(c, log, io, ev); };
    kit::check(kit::kinds_of(log, c.link) == "C", "closing a dial before it opens: one Closed, no Opened");
    let i = kit::first_for(log, kit::CLOSED, c.link);
    kit::check(i >= 0 && log.entries[i].why == goose_io::CloseReason.Local, "a cancelled dial closes with Local");

    // a dial that would have opened, closed before its Opened is delivered
    var io2 = goose_io_memory::Loop { .. };
    var log2 = kit::Log { .. };
    let l, err = io2.listen("127.0.0.1:7100");
    let d = io2.dial("127.0.0.1:7100", 0);
    io2.close(d);
    run(io2, log2, 100);
    kit::check(kit::kinds_of(log2, d) == "C", "a dial closed at once never gets Opened");
}

struct Stopper { listener: goose_io::Listener = goose_io::Listener { .. }, first: goose_io::Link = goose_io::Link { .. },
                 accepted: goose_io::Link = goose_io::Link { .. }, second: goose_io::Link = goose_io::Link { .. }, sent: bool = false }

fn stopper_event(s: Stopper&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    match ev {
        Opened e => {
            if goose_io::is_listener(e.listener) {
                s.accepted = e.link;
                io.stop_listening(s.listener);
                io.stop_listening(s.listener);                 // twice: no effect
                s.second = io.dial("127.0.0.1:7200", 0);     // must now be refused
            }
        },
        Tick t => {
            if t.now_ms >= 200 && !s.sent { s.sent = true; kit::check(io.send(s.first, "still here") == goose_io::SendStatus.Sent, "an accepted link still sends after stop_listening"); }
            if t.now_ms >= 400 { io.stop(0); }
        },
        _ => {},
    }
}

fn stop_listening_keeps_links() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var s = Stopper { .. };
    let l, err = io.listen("127.0.0.1:7200");
    s.listener = l;
    s.first = io.dial("127.0.0.1:7200", 0);
    io.serve() { io, ev => stopper_event(s, log, io, ev); };

    kit::check(kit::kinds_of(log, s.second) == "C", "after stop_listening a new dial is not accepted");
    kit::check(kit::data_of(log, s.accepted) == "still here", "the accepted link keeps delivering data");
    kit::check(io.listener_port(l) == 0, "a stopped listener has no port");
}

struct Limit { a: goose_io::Link = goose_io::Link { .. }, b: goose_io::Link = goose_io::Link { .. } }

fn limit_event(c: Limit&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    match ev {
        Opened e => { if goose_io::same(e.link, c.a) { c.b = io.dial("127.0.0.1:7300", 0); } },   // a third link: over the limit
        Tick t => { if t.now_ms >= 100 { io.stop(0); } },
        _ => {},
    }
}

fn link_limit() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.max_links = 2;
    var log = kit::Log { .. };
    var c = Limit { .. };
    let l, err = io.listen("127.0.0.1:7300");
    c.a = io.dial("127.0.0.1:7300", 0);        // two links: the dialled and the accepted
    io.serve() { io, ev => limit_event(c, log, io, ev); };
    kit::check(kit::first_for(log, kit::OPENED, c.a) >= 0, "a dial within the link limit opens");
    let bi = kit::first_for(log, kit::CLOSED, c.b);
    kit::check(kit::kinds_of(log, c.b) == "C" && bi >= 0 && kit::failed_with(log, c.b, goose_io::ConnectFailure.NoResources), "a dial beyond the link limit: one Closed with ConnectFailed, kind NoResources");
}

// A listener on the wildcard address takes dials to any address of its family on its port.
fn wildcard_listeners() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    let l4, e4 = io.listen("0.0.0.0:9050");
    let l6, e6 = io.listen("[::]:9051");
    kit::check(goose_io::is_listener(l4) && goose_io::is_listener(l6), "fixture: both wildcard listeners");
    let a = io.dial("127.0.0.1:9050", 0);
    let b = io.dial("10.1.2.3:9050", 0);
    let c = io.dial("[::1]:9051", 0);
    let d = io.dial("[::1]:9050", 0);            // the IPv4 listener's port, over IPv6
    let e = io.dial("127.0.0.1:9051", 0);        // and the other way round
    let z = io.dial("[::1%lo]:9051", 0);         // a zone identifier: malformed
    run(io, log, 100);
    kit::check(kit::failed_with(log, z, goose_io::ConnectFailure.BadAddress) && kit::first_for(log, kit::OPENED, z) < 0, "a dial with a zone identifier fails with ConnectFailed, kind BadAddress");
    kit::check(kit::first_for(log, kit::OPENED, a) >= 0 && kit::first_for(log, kit::OPENED, b) >= 0, "a listener on 0.0.0.0 takes a dial to any IPv4 address on its port");
    kit::check(kit::first_for(log, kit::OPENED, c) >= 0, "a listener on [::] takes a dial to any IPv6 address on its port");
    kit::check(kit::failed_with(log, d, goose_io::ConnectFailure.Refused) && kit::failed_with(log, e, goose_io::ConnectFailure.Refused), "but not a dial of the other family");
}

// Every kind of connect failure can be scripted, so a library can be tested against each.
fn failure_kinds() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    io.fail_dials("10.9.0.1:80", goose_io::ConnectFailure.Unreachable);
    io.fail_dials("10.9.0.2:80", goose_io::ConnectFailure.Denied);
    io.fail_dials("10.9.0.3:80", goose_io::ConnectFailure.Other);
    let l, err = io.listen("10.9.0.3:80");       // even with a listener there
    let a = io.dial("10.9.0.1:80", 0);
    let b = io.dial("10.9.0.2:80", 0);
    let c = io.dial("10.9.0.3:80", 0);
    run(io, log, 100);
    kit::check(kit::failed_with(log, a, goose_io::ConnectFailure.Unreachable), "a dial scripted to be unreachable: kind Unreachable");
    kit::check(kit::failed_with(log, b, goose_io::ConnectFailure.Denied), "scripted to be denied: kind Denied");
    kit::check(kit::failed_with(log, c, goose_io::ConnectFailure.Other), "scripted to fail some other way: kind Other");
    kit::check(kit::count(log, kit::OPENED) == 0, "and none of them opens");
}

// Listener handles are never used again, so a loop can only ever issue so many.
fn listener_exhaustion() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.max_listeners = 2;
    let a, ea = io.listen("127.0.0.1:7400");
    io.stop_listening(a);
    let b, eb = io.listen("127.0.0.1:7400");
    io.stop_listening(b);
    kit::check(goose_io::is_listener(a) && goose_io::is_listener(b), "fixture: two listeners, both stopped");
    let c, ec = io.listen("127.0.0.1:7400");
    kit::check(!goose_io::is_listener(c) && ec.kind == goose_io::ListenErrorKind.NoResources, "when its handles run out listen fails with NoResources: it never wraps round to an old handle");
}

// --- listeners that overlap ----------------------------------------------------------------------

fn in_use(e: goose_io::ListenError) -> bool { e.kind == goose_io::ListenErrorKind.AddressInUse }

// The accepted end names its listener, so the dial is joined to the first of two overlapping listeners.
fn which_listener(first: const u8[:], second: const u8[:]) {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    let a, ea = io.listen(first);
    let b, eb = io.listen(second);
    kit::check(goose_io::is_listener(a) && !goose_io::is_listener(b) && in_use(eb), "the second of two overlapping listeners fails with AddressInUse");
    io.dial("127.0.0.1:8080", 0);
    var accepted_by = goose_io::Listener { .. };
    io.serve() { io, ev =>
        match ev {
            Opened e => { if goose_io::is_listener(e.listener) { accepted_by = e.listener; } io.stop(0); },
            _ => {},
        }
    };
    kit::check(goose_io::same(accepted_by, a), "and a dial reaches the first listener, whatever the order");
}

// --- the accepted link names its own listener (specs/io-contract: *An accepted link names its listener*) ---------------

struct Named { first: goose_io::Listener = goose_io::Listener { .. }, second: goose_io::Listener = goose_io::Listener { .. }, named: goose_io::Listener[..4] = [] }

fn named_event(n: Named&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    match ev {
        Opened e => { if goose_io::is_listener(e.listener) { n.named.push(e.listener); if n.named.len == 2 { io.stop(0); } } },
        _ => {},
    }
}

fn opened_names_its_listener() {
    var io = goose_io_memory::Loop { .. };
    var n = Named { .. };
    let a, ea = io.listen("127.0.0.1:8601");
    let b, eb = io.listen("127.0.0.1:8602");
    n.first = a;
    n.second = b;
    io.dial("127.0.0.1:8602", 0);
    io.dial("127.0.0.1:8601", 0);
    io.serve() { io, ev => named_event(n, io, ev); };
    kit::check(n.named.len == 2, "fixture: two links accepted");
    kit::check(n.named.len == 2 && goose_io::same(n.named[0], b) && goose_io::same(n.named[1], a), "each accepted link's Opened names the listener that took it, not the other one");
    kit::check(!goose_io::same(a, b), "the two listeners have different handles");
}

fn overlapping_listeners() {
    which_listener("0.0.0.0:8080", "127.0.0.1:8080");
    which_listener("127.0.0.1:8080", "0.0.0.0:8080");

    var io = goose_io_memory::Loop { .. };
    io.hold("0.0.0.0:8080");
    let h, eh = io.listen("127.0.0.1:8080");
    kit::check(!goose_io::is_listener(h) && in_use(eh), "a held wildcard address blocks a listen on a specific address");

    var io2 = goose_io_memory::Loop { .. };
    let a, ea = io2.listen("0.0.0.0:8080");
    let b, eb = io2.listen("127.0.0.1:8081");          // another port
    let c, ec = io2.listen("[::1]:8080");              // another family
    let d, ed = io2.listen("[::]:8082");
    io2.stop_listening(a);
    let e, ee = io2.listen("127.0.0.1:8080");          // the wildcard listener has stopped
    kit::check(goose_io::is_listener(a) && goose_io::is_listener(b) && goose_io::is_listener(c) && goose_io::is_listener(d) && goose_io::is_listener(e), "other ports, the other family and a stopped listener do not conflict");
    let f, ef = io2.listen("[::1]:8082");
    kit::check(!goose_io::is_listener(f) && in_use(ef), "an IPv6 wildcard overlaps an IPv6 address on its port");
}

// --- system-chosen ports -------------------------------------------------------------------------

fn port_of(a: goose_io::Address) -> i64 {
    var colon = -1;
    for c, i in a.text { if c == ':' { colon = i; } }
    var v = 0;
    var i = colon + 1;
    while colon >= 0 && i < a.text.len { v = v * 10 + (a.text[i] - '0'); i++; }
    return v;
}

struct Churn { count: i64 = 0, last_remote: i64 = 0, chosen: i64 = -1, error: bool = false, dialled: goose_io::Link = goose_io::Link { .. } }

// Connects, and closes the dialled end, again and again; at the last connection asks for a port.
fn churn_event(c: Churn&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    match ev {
        Opened e => {
            if goose_io::is_listener(e.listener) {
                c.last_remote = port_of(io.peer_address(e.link));
            } else {
                c.dialled = e.link;
                io.close(e.link);
            }
        },
        Closed e => {
            if goose_io::same(e.link, c.dialled) {
                c.count++;
                if c.count < 16385 {
                    io.dial("127.0.0.1:7500", 0);
                } else {
                    let l, err = io.listen("127.0.0.1:0");
                    c.error = !goose_io::is_listener(l);
                    c.chosen = io.listener_port(l);
                    io.stop(0);
                }
            }
        },
        _ => {},
    }
}

fn ephemeral_ports() {
    // the next port is taken
    var io = goose_io_memory::Loop { .. };
    let a, ea = io.listen("127.0.0.1:49152");
    let b, eb = io.listen("127.0.0.1:0");
    kit::check(goose_io::is_listener(b), "listen on port 0 succeeds although the next port is in use");
    kit::check(io.listener_port(b) >= 49152 && io.listener_port(b) != 49152, "and chooses another port in the range");

    // the counter stays in the range however many connections are made
    var io2 = goose_io_memory::Loop { .. };
    io2.cfg.time_limit_ms = 100000000;
    var c = Churn { .. };
    let l, el = io2.listen("127.0.0.1:7500");
    io2.dial("127.0.0.1:7500", 0);
    io2.serve() { io, ev => churn_event(c, io, ev); };
    kit::check(c.count == 16385, "fixture: more connections than there are ports in the range");
    kit::check(!c.error && c.chosen >= 49152 && c.chosen <= 65535, "port 0 still gives a port in the range");
    kit::check(c.last_remote >= 49152 && c.last_remote <= 65535, "and the remote port of an accepted link is in the range");

    // every port of the range is in use
    var io3 = goose_io_memory::Loop { .. };
    io3.cfg.max_listeners = 20000;
    var p = 49152;
    var all = true;
    while p <= 65535 {
        var text: u8[>..] = [];
        format(text, "10.9.9.9:", p);
        let h, eh = io3.listen(text);
        if !goose_io::is_listener(h) { all = false; }
        p++;
    }
    kit::check(all, "fixture: every port in the range listened on");
    let z, ez = io3.listen("10.9.9.9:0");
    kit::check(!goose_io::is_listener(z) && ez.kind == goose_io::ListenErrorKind.NoResources, "port 0 with no free port: NoResources");
    let y, ey = io3.listen("10.9.9.8:0");
    kit::check(goose_io::is_listener(y), "another address still has free ports");
}

// --- stated limits -------------------------------------------------------------------------------

struct Ends { opened: i64 = 0, third: goose_io::Link = goose_io::Link { .. } }

fn scripted_end_is_not_counted() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.max_links = 1;
    var log = kit::Log { .. };
    let p = io.add_peer();
    io.peer_accept(p, "10.0.0.1:80");
    let a = io.dial("10.0.0.1:80", 0);
    run(io, log, 100);
    kit::check(kit::first_for(log, kit::OPENED, a) >= 0, "with max_links 1 a dial to a scripted peer opens: the peer's end is not counted");
}

fn embedded_ipv4_text() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    let l, e = io.listen("[::ffff:192.0.2.1]:80");
    kit::check(!goose_io::is_listener(l) && e.kind == goose_io::ListenErrorKind.BadAddress, "listen on IPv4-embedded IPv6 text: BadAddress");
    let d = io.dial("[::ffff:192.0.2.1]:80", 0);
    run(io, log, 100);
    kit::check(kit::failed_with(log, d, goose_io::ConnectFailure.BadAddress), "dial to IPv4-embedded IPv6 text: ConnectFailed, kind BadAddress");
}

// --- slots are dense (specs/io-contract of the change link-keyed-state: *Slot numbers are dense*) ------------------

struct Dense {
    stage:  i64                  = 0,   // 0: opening the first four pairs, 1: closing them, 2: the second four pairs
    first:  goose_io::Link[..16] = [],
    second: goose_io::Link[..16] = [],
    closed: i64                  = 0,
}

fn dense_event(d: Dense&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    match ev {
        Opened e => {
            if d.stage == 0 {
                d.first.push(e.link);
                if d.first.len == 8 { for l in d.first { io.close(l); } d.stage = 1; }
            } else if d.stage == 2 {
                d.second.push(e.link);
                if d.second.len == 8 { io.stop(0); }
            }
        },
        Closed e => { if d.stage == 1 { d.closed++; } },
        Tick t => {
            // after every handler of every Closed has returned, so every slot is free
            if d.stage == 1 && d.closed == 8 {
                d.stage = 2;
                for i in 4 { io.dial("127.0.0.1:7100", 0); }
            }
        },
        _ => {},
    }
}

fn dense_slots_run(fault: const u8[:]) -> Dense {
    var io = goose_io_memory::Loop { .. };
    if fault.len > 0 { io.set_fault(fault); }
    var d = Dense { .. };
    let l, err = io.listen("127.0.0.1:7100");
    for i in 4 { io.dial("127.0.0.1:7100", 0); }
    io.serve() { io, ev => dense_event(d, io, ev); };
    return d;
}

fn dense_slots() {
    let d = dense_slots_run("");
    kit::check(d.first.len == 8 && d.second.len == 8, "fixture: eight links open twice");
    var max_slot = 0;
    for l in d.second { if l.slot > max_slot { max_slot = l.slot; } }
    kit::check(max_slot < 8, "after eight links closed, eight more take slots below eight");
    var generations_differ = true;
    for l in d.second {
        for old in d.first { if l.slot == old.slot && l.gen == old.gen { generations_differ = false; } }
    }
    kit::check(generations_differ, "a reused slot has a new generation");

    let bad = dense_slots_run("SlotsNeverReused");
    var bad_max = 0;
    for l in bad.second { if l.slot > bad_max { bad_max = l.slot; } }
    kit::check(bad.second.len == 8 && bad_max >= 8, "with fault SlotsNeverReused the second eight take new slots");
}

struct Kept { old_slot: i64 = -1, new_slot: i64 = -1, link: goose_io::Link = goose_io::Link { .. }, closed: bool = false }

fn kept_event(k: Kept&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    match ev {
        Opened e => { if !goose_io::is_listener(e.listener) && !k.closed { k.link = e.link; io.close(e.link); } },
        Closed e => {
            if goose_io::same(e.link, k.link) && !k.closed {
                k.closed = true;
                k.old_slot = e.link.slot;
                let fresh = io.dial("127.0.0.1:7101", 0);     // inside the handler of the Closed
                k.new_slot = fresh.slot;
            }
        },
        Tick t => { if k.closed && t.now_ms > 300 { io.stop(0); } },
        _ => {},
    }
}

fn kept_run(fault: const u8[:]) -> Kept {
    var io = goose_io_memory::Loop { .. };
    if fault.len > 0 { io.set_fault(fault); }
    var k = Kept { .. };
    let l, err = io.listen("127.0.0.1:7101");
    io.dial("127.0.0.1:7101", 0);
    io.serve() { io, ev => kept_event(k, io, ev); };
    return k;
}

fn slot_kept_during_closed() {
    let k = kept_run("");
    kit::check(k.old_slot >= 0 && k.new_slot >= 0, "fixture: a link opened inside a Closed handler");
    kit::check(k.new_slot != k.old_slot, "a link opened inside a Closed handler does not take that link's slot");
    let bad = kept_run("ClosedHandleStaleEarly");
    kit::check(bad.new_slot == bad.old_slot, "with fault ClosedHandleStaleEarly it does");
}

fn main() {
    dense_slots();
    slot_kept_during_closed();
    failure_kinds();
    listener_exhaustion();
    listening();
    joined();
    wildcard_listeners();
    peer_addresses();
    failures_of_dial();
    timeouts();
    cancelling();
    stop_listening_keeps_links();
    link_limit();
    overlapping_listeners();
    opened_names_its_listener();
    ephemeral_ports();
    scripted_end_is_not_counted();
    embedded_ipv4_text();
    kit::finish();
}
