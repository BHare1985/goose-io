// In-memory provider: listening, dialling, joining, peer addresses, user values.
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

    let l, err = io.listen("127.0.0.1:8080", 1);
    kit::check(goose_io::is_listener(l) && !goose_io::failed(err), "listen on a free address succeeds");
    kit::check(io.listener_port(l) == 8080, "listener_port returns the bound port");

    io.hold("127.0.0.1:9090");
    let held, held_err = io.listen("127.0.0.1:9090", 1);
    kit::check(!goose_io::is_listener(held), "listen on a held address returns no listener");
    kit::check(held_err.kind == goose_io::ListenErrorKind.AddressInUse && held_err.code != 0, "listen on a held address: AddressInUse with a code");

    let twice, twice_err = io.listen("127.0.0.1:8080", 1);
    kit::check(!goose_io::is_listener(twice) && twice_err.kind == goose_io::ListenErrorKind.AddressInUse, "listen twice on one address: AddressInUse");

    let bad, bad_err = io.listen("not an address", 1);
    kit::check(!goose_io::is_listener(bad) && bad_err.kind == goose_io::ListenErrorKind.BadAddress, "listen on malformed text: BadAddress");

    let any, any_err = io.listen("127.0.0.1:0", 1);
    kit::check(goose_io::is_listener(any) && io.listener_port(any) != 0, "port 0 gets a system-chosen port");
    kit::check(io.listener_port(goose_io::Listener { .. }) == 0, "listener_port of no listener is 0");
    kit::check(io.listener_port(goose_io::Listener { id: 999 }) == 0, "listener_port of an unknown listener is 0");

    // an IPv6 zone identifier is not part of an address
    let zoned, zoned_err = io.listen("[fe80::1%eth0]:8081", 1);
    kit::check(!goose_io::is_listener(zoned) && zoned_err.kind == goose_io::ListenErrorKind.BadAddress, "listen with a zone identifier: BadAddress");

    // a listener handle is never used again: the old one cannot reach a newer listener
    io.stop_listening(l);
    kit::check(io.listener_port(l) == 0, "listener_port of a stopped listener is 0");
    let again, again_err = io.listen("127.0.0.1:8080", 1);
    kit::check(goose_io::is_listener(again) && !goose_io::same(again, l), "listening again on the address gives a new handle");
    io.stop_listening(l);
    kit::check(io.listener_port(again) == 8080, "stop_listening with the old handle does not stop the new listener");
    io.stop_listening(again);
    let third, third_err = io.listen("127.0.0.1:8080", 1);
    kit::check(!goose_io::same(third, l) && !goose_io::same(third, again), "and no earlier handle ever comes back");

    run(io, log, 100);
    kit::check(log.entries.len == 0, "listening alone produces no events");
}

fn joined() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };

    let l, err = io.listen("127.0.0.1:0", 1);
    var target: u8[>..] = [];
    format(target, "127.0.0.1:", io.listener_port(l));
    let dialled = io.dial(target, 2, 0);
    kit::check(goose_io::is_valid(dialled), "dial returns a valid link at once");
    kit::check(log.entries.len == 0, "dial delivers nothing before serve runs");
    kit::check(goose_io::is_empty(io.peer_address(dialled)), "no peer address before Opened");

    run(io, log, 100);

    kit::check(kit::count(log, kit::OPENED) == 2, "a dial to a listener opens two links");
    let di = kit::first_for(log, kit::OPENED, dialled);
    kit::check(di >= 0, "the dialled link gets Opened");
    if di >= 0 {
        kit::check(log.entries[di].tag == 2, "the dialled link's Opened carries the dial's tag");
        kit::check(!goose_io::is_listener(log.entries[di].listener), "the dialled link's Opened carries no listener");
    }
    // the other Opened is the accepted link
    for e in log.entries {
        if e.kind == kit::OPENED && !goose_io::same(e.link, dialled) {
            kit::check(e.tag == 1, "the accepted link's Opened carries the listener's tag");
            kit::check(goose_io::same(e.listener, l), "the accepted link's Opened carries its listener");
            kit::check(e.user == 0, "the user value is 0 until set");
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
    let l, err = io.listen("127.0.0.1:7000", 1);
    a.dialled = io.dial("127.0.0.1:7000", 2, 0);
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
    let l6, err6 = io6.listen("[::1]:7001", 1);
    kit::check(goose_io::is_listener(l6), "listen on an IPv6 address");
    a6.dialled = io6.dial("[::1]:7001", 2, 0);
    io6.serve() { io, ev => addresses_event(a6, io, ev); };
    kit::check(a6.dialled_peer.text == "[::1]:7001", "an IPv6 peer address round-trips");
    kit::check(a6.accepted_peer.text.len > 6 && a6.accepted_peer.text[..6] == "[::1]:", "an accepted IPv6 link names the dialling side");
}

fn failures_of_dial() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };

    let refused = io.dial("127.0.0.1:1", 3, 0);             // nothing listens there
    let malformed = io.dial("127.0.0.1", 3, 0);            // no port
    io.set_user(malformed, 7);                            // set after the dial already failed
    let named = io.dial("db.example.com:5432", 3, 0);     // a host name is not resolved
    let empty = io.dial("", 3, 0);
    kit::check(goose_io::is_valid(refused) && goose_io::is_valid(malformed) && goose_io::is_valid(named) && goose_io::is_valid(empty), "a failing dial still returns a valid link");
    kit::check(io.send(refused, "x") == goose_io::SendStatus.NotOpen, "send before Opened returns NotOpen");
    kit::check(io.user(malformed) == 7, "user reads back before the failure is delivered");

    run(io, log, 100);

    kit::check(kit::count(log, kit::OPENED) == 0, "a failed dial never gets Opened");
    kit::check(kit::kinds_of(log, refused) == "C", "a refused dial: exactly one Closed");
    kit::check(kit::kinds_of(log, malformed) == "C", "a malformed address: exactly one Closed");
    kit::check(kit::kinds_of(log, named) == "C", "a host name: exactly one Closed");
    kit::check(kit::kinds_of(log, empty) == "C", "an empty address: exactly one Closed");
    for e in log.entries {
        if e.kind == kit::CLOSED {
            kit::check(goose_io::is_connect_failed(e.why), "a failed dial closes with ConnectFailed");
            kit::check(e.tag == 3, "the Closed of a failed dial carries its tag");
        }
    }
    kit::check(kit::failed_with(log, refused, goose_io::ConnectFailure.Refused), "nothing listening: kind Refused");
    kit::check(kit::failed_with(log, malformed, goose_io::ConnectFailure.BadAddress), "malformed text: kind BadAddress");
    kit::check(kit::failed_with(log, named, goose_io::ConnectFailure.BadAddress), "a host name is not an address: kind BadAddress");
    kit::check(kit::failed_with(log, empty, goose_io::ConnectFailure.BadAddress), "an empty address: kind BadAddress");
    kit::check(!goose_io::is_connect_failed(goose_io::CloseReason.PeerReset) && goose_io::is_portable(goose_io::CloseReason.ConnectFailed { kind: goose_io::ConnectFailure.Other }), "is_connect_failed tells the reason apart; every kind is portable");
    let mi = kit::first_for(log, kit::CLOSED, malformed);
    kit::check(mi >= 0 && log.entries[mi].user == 7, "the user value set after an immediate failure is carried by Closed");
    kit::check(io.user(malformed) == 0, "user of a stale link is 0");
}

fn timeouts() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    io.silent("10.0.0.1:80");
    let start = io.now_ms();
    let short = io.dial("10.0.0.1:80", 4, 200);
    let default = io.dial("10.0.0.1:80", 4, 0);

    run(io, log, 6000);

    let si = kit::first_for(log, kit::CLOSED, short);
    kit::check(si >= 0 && kit::kinds_of(log, short) == "C", "a dial that never answers: exactly one Closed");
    if si >= 0 {
        kit::check(kit::failed_with(log, short, goose_io::ConnectFailure.TimedOut), "a timed-out dial closes with ConnectFailed, kind TimedOut");
        kit::check(log.entries[si].at_ms >= start + 200, "not before connect_ms has passed");
        kit::check(log.entries[si].at_ms < start + 300, "and promptly after it");
    }
    let di = kit::first_for(log, kit::CLOSED, default);
    kit::check(di >= 0 && log.entries[di].at_ms >= start + io.cfg.connect_timeout_ms, "connect_ms 0 uses the provider's default");
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
    c.link = io.dial("10.0.0.2:80", 5, 0);
    io.serve() { io, ev => cancel_event(c, log, io, ev); };
    kit::check(kit::kinds_of(log, c.link) == "C", "closing a dial before it opens: one Closed, no Opened");
    let i = kit::first_for(log, kit::CLOSED, c.link);
    kit::check(i >= 0 && log.entries[i].why == goose_io::CloseReason.Local, "a cancelled dial closes with Local");

    // a dial that would have opened, closed before its Opened is delivered
    var io2 = goose_io_memory::Loop { .. };
    var log2 = kit::Log { .. };
    let l, err = io2.listen("127.0.0.1:7100", 1);
    let d = io2.dial("127.0.0.1:7100", 5, 0);
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
                s.second = io.dial("127.0.0.1:7200", 2, 0);     // must now be refused
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
    let l, err = io.listen("127.0.0.1:7200", 1);
    s.listener = l;
    s.first = io.dial("127.0.0.1:7200", 2, 0);
    io.serve() { io, ev => stopper_event(s, log, io, ev); };

    kit::check(kit::kinds_of(log, s.second) == "C", "after stop_listening a new dial is not accepted");
    kit::check(kit::data_of(log, s.accepted) == "still here", "the accepted link keeps delivering data");
    kit::check(io.listener_port(l) == 0, "a stopped listener has no port");
}

struct Limit { a: goose_io::Link = goose_io::Link { .. }, b: goose_io::Link = goose_io::Link { .. } }

fn limit_event(c: Limit&, log: kit::Log&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    kit::note(log, io, ev);
    match ev {
        Opened e => { if goose_io::same(e.link, c.a) { c.b = io.dial("127.0.0.1:7300", 2, 0); } },   // a third link: over the limit
        Tick t => { if t.now_ms >= 100 { io.stop(0); } },
        _ => {},
    }
}

fn link_limit() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.max_links = 2;
    var log = kit::Log { .. };
    var c = Limit { .. };
    let l, err = io.listen("127.0.0.1:7300", 1);
    c.a = io.dial("127.0.0.1:7300", 2, 0);        // two links: the dialled and the accepted
    io.serve() { io, ev => limit_event(c, log, io, ev); };
    kit::check(kit::first_for(log, kit::OPENED, c.a) >= 0, "a dial within the link limit opens");
    let bi = kit::first_for(log, kit::CLOSED, c.b);
    kit::check(kit::kinds_of(log, c.b) == "C" && bi >= 0 && kit::failed_with(log, c.b, goose_io::ConnectFailure.NoResources), "a dial beyond the link limit: one Closed with ConnectFailed, kind NoResources");
}

// A listener on the wildcard address takes dials to any address of its family on its port.
fn wildcard_listeners() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    let l4, e4 = io.listen("0.0.0.0:9050", 1);
    let l6, e6 = io.listen("[::]:9051", 1);
    kit::check(goose_io::is_listener(l4) && goose_io::is_listener(l6), "fixture: both wildcard listeners");
    let a = io.dial("127.0.0.1:9050", 2, 0);
    let b = io.dial("10.1.2.3:9050", 2, 0);
    let c = io.dial("[::1]:9051", 2, 0);
    let d = io.dial("[::1]:9050", 2, 0);            // the IPv4 listener's port, over IPv6
    let e = io.dial("127.0.0.1:9051", 2, 0);        // and the other way round
    let z = io.dial("[::1%lo]:9051", 2, 0);         // a zone identifier: malformed
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
    let l, err = io.listen("10.9.0.3:80", 1);       // even with a listener there
    let a = io.dial("10.9.0.1:80", 2, 0);
    let b = io.dial("10.9.0.2:80", 2, 0);
    let c = io.dial("10.9.0.3:80", 2, 0);
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
    let a, ea = io.listen("127.0.0.1:7400", 1);
    io.stop_listening(a);
    let b, eb = io.listen("127.0.0.1:7400", 1);
    io.stop_listening(b);
    kit::check(goose_io::is_listener(a) && goose_io::is_listener(b), "fixture: two listeners, both stopped");
    let c, ec = io.listen("127.0.0.1:7400", 1);
    kit::check(!goose_io::is_listener(c) && ec.kind == goose_io::ListenErrorKind.NoResources, "when its handles run out listen fails with NoResources: it never wraps round to an old handle");
}

// --- listeners that overlap ----------------------------------------------------------------------

fn in_use(e: goose_io::ListenError) -> bool { e.kind == goose_io::ListenErrorKind.AddressInUse }

fn tag_opened_for(log: kit::Log&, link: goose_io::Link) -> i64 {
    let i = kit::first_for(log, kit::OPENED, link);
    return if i < 0 { -1 } else { log.entries[i].tag };
}

// The listener's tag is on the accepted end, so the dial is joined to it and the dialled end has the dial's tag.
fn which_listener(first: const u8[:], second: const u8[:]) {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    let a, ea = io.listen(first, 1);
    let b, eb = io.listen(second, 2);
    kit::check(goose_io::is_listener(a) && !goose_io::is_listener(b) && in_use(eb), "the second of two overlapping listeners fails with AddressInUse");
    io.dial("127.0.0.1:8080", 9, 0);
    var accepted_tag = 0;
    io.serve() { io, ev =>
        match ev {
            Opened e => { if e.tag != 9 { accepted_tag = e.tag; } io.stop(0); },
            _ => {},
        }
    };
    kit::check(accepted_tag == 1, "and a dial reaches the first listener, whatever the order");
}

fn overlapping_listeners() {
    which_listener("0.0.0.0:8080", "127.0.0.1:8080");
    which_listener("127.0.0.1:8080", "0.0.0.0:8080");

    var io = goose_io_memory::Loop { .. };
    io.hold("0.0.0.0:8080");
    let h, eh = io.listen("127.0.0.1:8080", 1);
    kit::check(!goose_io::is_listener(h) && in_use(eh), "a held wildcard address blocks a listen on a specific address");

    var io2 = goose_io_memory::Loop { .. };
    let a, ea = io2.listen("0.0.0.0:8080", 1);
    let b, eb = io2.listen("127.0.0.1:8081", 1);          // another port
    let c, ec = io2.listen("[::1]:8080", 1);              // another family
    let d, ed = io2.listen("[::]:8082", 1);
    io2.stop_listening(a);
    let e, ee = io2.listen("127.0.0.1:8080", 1);          // the wildcard listener has stopped
    kit::check(goose_io::is_listener(a) && goose_io::is_listener(b) && goose_io::is_listener(c) && goose_io::is_listener(d) && goose_io::is_listener(e), "other ports, the other family and a stopped listener do not conflict");
    let f, ef = io2.listen("[::1]:8082", 1);
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

struct Churn { count: i64 = 0, last_remote: i64 = 0, chosen: i64 = -1, error: bool = false }

// Connects, and closes the dialled end, again and again; at the last connection asks for a port.
fn churn_event(c: Churn&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    match ev {
        Opened e => {
            if e.tag == 1 {
                c.last_remote = port_of(io.peer_address(e.link));
            } else {
                io.close(e.link);
            }
        },
        Closed e => {
            if e.tag == 2 {
                c.count++;
                if c.count < 16385 {
                    io.dial("127.0.0.1:7500", 2, 0);
                } else {
                    let l, err = io.listen("127.0.0.1:0", 3);
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
    let a, ea = io.listen("127.0.0.1:49152", 1);
    let b, eb = io.listen("127.0.0.1:0", 1);
    kit::check(goose_io::is_listener(b), "listen on port 0 succeeds although the next port is in use");
    kit::check(io.listener_port(b) >= 49152 && io.listener_port(b) != 49152, "and chooses another port in the range");

    // the counter stays in the range however many connections are made
    var io2 = goose_io_memory::Loop { .. };
    io2.cfg.time_limit_ms = 100000000;
    var c = Churn { .. };
    let l, el = io2.listen("127.0.0.1:7500", 1);
    io2.dial("127.0.0.1:7500", 2, 0);
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
        let h, eh = io3.listen(text, 1);
        if !goose_io::is_listener(h) { all = false; }
        p++;
    }
    kit::check(all, "fixture: every port in the range listened on");
    let z, ez = io3.listen("10.9.9.9:0", 1);
    kit::check(!goose_io::is_listener(z) && ez.kind == goose_io::ListenErrorKind.NoResources, "port 0 with no free port: NoResources");
    let y, ey = io3.listen("10.9.9.8:0", 1);
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
    let a = io.dial("10.0.0.1:80", 2, 0);
    run(io, log, 100);
    kit::check(kit::first_for(log, kit::OPENED, a) >= 0, "with max_links 1 a dial to a scripted peer opens: the peer's end is not counted");
}

fn embedded_ipv4_text() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    let l, e = io.listen("[::ffff:192.0.2.1]:80", 1);
    kit::check(!goose_io::is_listener(l) && e.kind == goose_io::ListenErrorKind.BadAddress, "listen on IPv4-embedded IPv6 text: BadAddress");
    let d = io.dial("[::ffff:192.0.2.1]:80", 2, 0);
    run(io, log, 100);
    kit::check(kit::failed_with(log, d, goose_io::ConnectFailure.BadAddress), "dial to IPv4-embedded IPv6 text: ConnectFailed, kind BadAddress");
}

fn main() {
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
    ephemeral_ports();
    scripted_end_is_not_counted();
    embedded_ipv4_text();
    kit::finish();
}
