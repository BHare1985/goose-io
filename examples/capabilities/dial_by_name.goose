// A client that dials a host name: it resolves the name, then tries each address in turn until one opens. It shows
// the name-resolution capability (docs/capabilities/name-resolution.md).
//
// Needs: core only.
// Uses if supplied: name-resolution (the loop looks the name up; without it the client dials the text it was given, which
// must be an address).
//
// `dial` takes only addresses, so a host name has to be resolved first. On a loop that supplies name resolution the
// client calls `resolve`, copies the addresses out of the `Resolved` handler (they are lent only until it returns) and
// dials the first. A refused dial moves it to the next. On a loop that does not, a client that has `wake` can run the
// lookup on a thread and send each address back with `wake_with`; this one does not, and takes an address. An example,
// not a library to depend on.
namespace dial_by_name;
import std;
import goose_io;

let TRIES_MAX = 8;

enum Phase { Idle, Resolving, Dialling, Open, Failed }

root struct DialByName {
    host:       goose_io::Address      = goose_io::Address { .. },
    port:       i64                    = 0,
    connect_ms: i64                    = 1000,
    phase:      Phase                  = Phase.Idle,
    query:      goose_io::Query        = goose_io::Query { .. },
    link:       goose_io::Link         = goose_io::Link { .. },
    addresses:  goose_io::Address[..8] = [],
    next:       i64                    = 0,
    dials:      i64                    = 0,
}

// Starts: resolves `host` (or, on a loop without the capability, dials it as an address).
fn start<Io>(d: DialByName&, io: Io&, host: const u8[:], port: i64, resolve_ms: i64, connect_ms: i64) -> bool {
    guard host.len > 0 && host.len <= 56 else { return false; }
    d.host.text.append(host);
    d.port = port;
    d.connect_ms = connect_ms;
    return d._begin(io, goose_io::has_name_resolution(io), resolve_ms);
}

// doc:begin branch
// The choice is made when the library is built: a loop without the capability never compiles the call to `resolve`.
fn _begin<Io, S>(d: DialByName&, io: Io&, has: S, resolve_ms: i64) -> bool {
    const if same<S, goose_io::Supplied> {
        d.query = io.resolve(d.host.text[..], d.port, resolve_ms);
        guard goose_io::is_valid(d.query) else { d.phase = Phase.Failed; return false; }
        d.phase = Phase.Resolving;
        return true;
    } else {
        d.addresses.push(d.host);
        d._dial_next(io);
        return true;
    }
}
// doc:end branch

fn _dial_next<Io>(d: DialByName&, io: Io&) {
    if d.next >= d.addresses.len { d.phase = Phase.Failed; return; }
    d.link = io.dial(d.addresses[d.next].text[..], d.connect_ms);
    d.next++;
    d.dials++;
    d.phase = Phase.Dialling;
}

fn is_open(d: DialByName&) -> bool { d.phase == Phase.Open }
fn failed(d: DialByName&) -> bool { d.phase == Phase.Failed }
fn link_of(d: DialByName&) -> goose_io::Link { d.link }
fn dial_count(d: DialByName&) -> i64 { d.dials }

// doc:begin resolved
// The answer of the lookup. Only a loop that supplies the capability delivers `Resolved`, so only it compiles `resolved_address`.
fn _on_resolved<Io, S>(d: DialByName&, io: Io&, has: S, status: goose_io::ResolveStatus, count: i64, query: goose_io::Query) {
    const if same<S, goose_io::Supplied> {
        if status == goose_io::ResolveStatus.Found {
            // the addresses are lent until this handler returns: copy them
            for i in min(count, TRIES_MAX) { d.addresses.push(io.resolved_address(query, i)); }
            d._dial_next(io);
        } else {
            d.phase = Phase.Failed;
        }
    }
}
// doc:end resolved

// The library's entry point: true if the event was for this client.
fn dial_event<Io>(d: DialByName&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Resolved r => {
            guard d.phase == Phase.Resolving && goose_io::same(r.query, d.query) else { return false; }
            d._on_resolved(io, goose_io::has_name_resolution(io), r.status, r.count, r.query);
            return true;
        },
        Opened e => {
            guard !goose_io::is_listener(e.listener) && d.phase == Phase.Dialling && goose_io::same(e.link, d.link) else { return false; }
            d.phase = Phase.Open;
            return true;
        },
        Closed e => {
            guard d.phase == Phase.Dialling && goose_io::same(e.link, d.link) else { return false; }
            d._dial_next(io);
            return true;
        },
        _ => { return false; },
    }
}
