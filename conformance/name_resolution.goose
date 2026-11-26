// goose-io conformance suite, name-resolution capability: `resolve`, `resolved_address`, `cancel_resolve` and `Resolved`.
// Requirements: A lookup ends in one Resolved | Resolved addresses are valid while the event is handled |
// A lookup is bounded and can be cancelled | Dial still takes only addresses.
// The names come from the Fixture: a call cannot make a name, so the runner provides them (see Fixture.found).
namespace goose_io_conformance;
import std;
import goose_io;
import conformance.support;

fn name_resolution_info(id: i64) -> Info {
    if id == 680 { return Info { name: "resolve_found", req: "A lookup ends in one Resolved", part: 0 }; }
    if id == 681 { return Info { name: "resolve_not_found", req: "A lookup ends in one Resolved", part: 0 }; }
    if id == 682 { return Info { name: "resolve_invalid", req: "A lookup ends in one Resolved", part: 0 }; }
    if id == 683 { return Info { name: "resolve_dial_result", req: "Resolved addresses are valid while the event is handled", part: 0 }; }
    if id == 684 { return Info { name: "resolve_address_order", req: "Resolved addresses are valid while the event is handled", part: 0 }; }
    if id == 685 { return Info { name: "resolve_address_after", req: "Resolved addresses are valid while the event is handled", part: 0 }; }
    if id == 686 { return Info { name: "resolve_timeout", req: "A lookup is bounded and can be cancelled", part: 0 }; }
    if id == 687 { return Info { name: "resolve_cancel", req: "A lookup is bounded and can be cancelled", part: 0 }; }
    if id == 688 { return Info { name: "resolve_dial_name", req: "Dial still takes only addresses", part: 0 }; }
    if id == 689 { return Info { name: "resolve_cancelled_at_finish", req: "A lookup is bounded and can be cancelled", part: 1 }; }
    return Info { .. };
}

// True when `ev` is the Resolved of the query whose id the check kept in k.p.
fn _is_mine_resolved(k: Case&, ev: goose_io::Event) -> bool {
    match ev {
        Resolved r => { return k.p != 0 && r.query.id == k.p; },
        _ => { return false; },
    }
}

fn _resolved_count(k: Case&) -> i64 {
    var n = 0;
    for e in k.recs { if e.kind == 'R' && e.query == k.p { n++; } }
    return n;
}

fn c_resolve_found<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.expect(fx.found.len > 0, "the fixture supplied no name that resolves");
        let q = io.resolve(fx.found, 80, 0);
        k.expect(goose_io::is_valid(q), "resolve returned an invalid query");
        k.p = q.id as i64;
        k.step = 1;
    } else if k.step == 1 {
        match ev {
            Resolved r => {
                if r.query.id == k.p {
                    k.expect(r.status == goose_io::ResolveStatus.Found, "a name the system knows did not end Found");
                    k.expect(r.count >= 1, "a Found result had a count below 1");
                    k.step = 2;
                    k.within(io, 2000);
                }
            },
            _ => {},
        }
    } else if k.step == 2 {
        k.expect(k._resolved_count() == 1, "the lookup was not delivered exactly once");
        if io.now_ms() >= k.started + 250 { k.finish(); }
    }
}

fn c_resolve_not_found<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.expect(fx.missing.len > 0, "the fixture supplied no name without addresses");
        let q = io.resolve(fx.missing, 80, 0);
        k.expect(goose_io::is_valid(q), "resolve returned an invalid query");
        k.p = q.id as i64;
        k.step = 1;
    } else if k.step == 1 {
        match ev {
            Resolved r => {
                if r.query.id == k.p {
                    k.expect(r.status == goose_io::ResolveStatus.NotFound, "a name with no addresses did not end NotFound");
                    k.expect(r.count == 0, "a result that is not Found had a count above 0");
                    k.finish();
                }
            },
            _ => {},
        }
    }
}

// An empty host and a port outside 0 to 65535 give an invalid query and no event.
fn c_resolve_invalid<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        let empty = io.resolve("", 80, 0);
        let low = io.resolve(fx.found, -1, 0);
        let high = io.resolve(fx.found, 65536, 0);
        k.expect(!goose_io::is_valid(empty), "an empty host gave a valid query");
        k.expect(!goose_io::is_valid(low), "a port below 0 gave a valid query");
        k.expect(!goose_io::is_valid(high), "a port above 65535 gave a valid query");
        k.within(io, 2000);
        k.step = 1;
    } else if k.step == 1 {
        match ev {
            Resolved r => { k.fail("an invalid query was delivered a Resolved"); },
            Tick t => { if t.now_ms >= k.started + 250 { k.finish(); } },
            _ => {},
        }
    }
}

fn c_resolve_dial_result<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        if k.listen_local(io, 0) {
            let q = io.resolve(fx.found, k.port, 0);
            k.p = q.id as i64;
            k.step = 1;
        }
    } else if k.step == 1 {
        match ev {
            Resolved r => {
                if r.query.id == k.p {
                    k.expect(r.status == goose_io::ResolveStatus.Found, "a name the system knows did not end Found");
                    let a = io.resolved_address(r.query, 0);
                    k.expect(!goose_io::is_empty(a), "resolved_address(query, 0) was empty in the Resolved handler");
                    k.dial_to(io, a.text[..], 0, 0);
                    k.step = 2;
                }
            },
            _ => {},
        }
    } else if k.step == 2 && k.pair_open(0) {
        k.expect(k.kinds(0) == "O", "the dial to the first resolved address did not open");
        io.close(k.link[0]);
        k.step = 3;
        k.finish();
    }
}

// The pair name has two addresses (fx.pair_first, fx.pair_second, with port 80), in that order.
fn c_resolve_address_order<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.expect(fx.pair.len > 0, "the fixture supplied no name with two addresses");
        let q = io.resolve(fx.pair, 80, 0);
        k.p = q.id as i64;
        k.step = 1;
    } else if k.step == 1 {
        match ev {
            Resolved r => {
                if r.query.id == k.p {
                    k.expect(r.status == goose_io::ResolveStatus.Found && r.count == 2, "the name with two addresses did not end Found with count 2");
                    k.expect(io.resolved_address(r.query, 0).text[..] == fx.pair_first, "address 0 is not the first address, with the port given to resolve");
                    k.expect(io.resolved_address(r.query, 1).text[..] == fx.pair_second, "address 1 is not the second address, with the port given to resolve");
                    k.expect(goose_io::is_empty(io.resolved_address(r.query, 2)), "an index at or above count gave an address");
                    k.expect(goose_io::is_empty(io.resolved_address(r.query, -1)), "a negative index gave an address");
                    k.finish();
                }
            },
            _ => {},
        }
    }
}

// Outside the handler of the Resolved, the address is empty.
fn c_resolve_address_after<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        let q = io.resolve(fx.found, 80, 0);
        k.p = q.id as i64;
        k.within(io, 2000);
        k.step = 1;
    } else if k.step == 1 {
        match ev {
            Resolved r => {
                if r.query.id == k.p {
                    k.expect(!goose_io::is_empty(io.resolved_address(r.query, 0)), "resolved_address was empty in the Resolved handler");
                    k.step = 2;
                }
            },
            _ => {},
        }
    } else if k.step == 2 {
        match ev {
            Tick t => {
                let later = goose_io::Query { id: k.p as u32 };
                k.expect(goose_io::is_empty(io.resolved_address(later, 0)), "resolved_address gave an address after the Resolved handler returned");
                k.finish();
            },
            _ => {},
        }
    }
}

// A name that answers after 5000 ms, looked up with a timeout of 1000 ms, ends TimedOut at 1000 ms.
fn c_resolve_timeout<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        if fx.slow.len == 0 { k.finish(); return; }
        k.t = io.now_ms();
        let q = io.resolve(fx.slow, 80, 1000);
        k.p = q.id as i64;
        k.step = 1;
    } else if k.step == 1 {
        match ev {
            Resolved r => {
                if r.query.id == k.p {
                    let at = io.now_ms() - k.t;
                    k.expect(r.status == goose_io::ResolveStatus.TimedOut, "a lookup with no result at its timeout did not end TimedOut");
                    k.expect(r.count == 0, "a TimedOut result had a count above 0");
                    k.expect(at >= 1000 && at < 1500, "TimedOut did not come at the timeout on the loop's clock");
                    k.finish();
                }
            },
            _ => {},
        }
    }
}

// A cancelled lookup delivers nothing.
fn c_resolve_cancel<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        let q = io.resolve(fx.found, 80, 0);
        k.p = q.id as i64;
        io.cancel_resolve(q);
        io.cancel_resolve(q);       // again: nothing
        k.within(io, 500);
        k.step = 1;
    } else if k.step == 1 {
        match ev {
            Resolved r => { if r.query.id == k.p { k.fail("a cancelled lookup was delivered a Resolved"); } },
            Tick t => { if t.now_ms >= k.started + 400 { k.finish(); } },
            _ => {},
        }
    }
}

// A host name given to dial is not resolved: the link closes with ConnectFailed, BadAddress.
fn c_resolve_dial_name<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        var target: u8[>..] = [];
        target.append(fx.found);
        target.append(":80");
        k.dial_to(io, target[..], 0, 0);
        k.step = 1;
    } else if k.step == 1 && k.first(0, 'C') >= 0 {
        k.expect(k.kinds(0) == "C", "a dial to a host name did not give exactly one Closed and no Opened");
        k.expect(k.failed_with(0, goose_io::ConnectFailure.BadAddress), "a dial to a host name did not close with ConnectFailed, BadAddress");
        k.finish();
    }
}

// A lookup still running when the loop finishes ends Cancelled, delivered before serve returns.
fn c_resolve_cancelled_at_finish<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if k.after {
        if fx.slow.len > 0 { k.expect(k.flag, "a lookup still running when the loop finished did not end Cancelled before serve returned"); }
        k.finish();
        return;
    }
    if k.step == 0 {
        if fx.slow.len == 0 { k.finish(); return; }
        let q = io.resolve(fx.slow, 80, 20000);
        k.p = q.id as i64;
        io.stop(0);
        k.step = 1;
    } else if k.step == 1 {
        match ev {
            Resolved r => {
                if r.query.id == k.p {
                    k.expect(r.status == goose_io::ResolveStatus.Cancelled, "a lookup still running at the end ended with another status than Cancelled");
                    k.flag = true;
                }
            },
            _ => {},
        }
    }
}

fn name_resolution_capability_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 680 { c_resolve_found(k, fx, io, ev); return true; }
    if k.id == 681 { c_resolve_not_found(k, fx, io, ev); return true; }
    if k.id == 682 { c_resolve_invalid(k, fx, io, ev); return true; }
    if k.id == 683 { c_resolve_dial_result(k, fx, io, ev); return true; }
    if k.id == 684 { c_resolve_address_order(k, fx, io, ev); return true; }
    if k.id == 685 { c_resolve_address_after(k, fx, io, ev); return true; }
    if k.id == 686 { c_resolve_timeout(k, fx, io, ev); return true; }
    if k.id == 687 { c_resolve_cancel(k, fx, io, ev); return true; }
    if k.id == 688 { c_resolve_dial_name(k, fx, io, ev); return true; }
    if k.id == 689 { c_resolve_cancelled_at_finish(k, fx, io, ev); return true; }
    return false;
}
