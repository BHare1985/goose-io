// A gateway: the line server and the line client on one loop, neither naming the other.
//
// Needs: core and half-close (the line server's need; the line client needs only the core).
//
// A front server answers each request with the reply the client fetches for it from a backend, which is a
// second line server on the same loop. Only this file names both libraries; each of them imports the contract
// and nothing else. The application's dispatch is the whole of the glue:
//
//     io.serve() { io, ev => gateway::step(front, back, client, table, io, ev); };
//
// While the loop is stopping, every library closes what it has no work on (see the Tick of each), so `serve`
// returns as soon as the last link has closed and does not wait for the grace period.
namespace gateway;
import std;
import goose_io;
import examples.lineserver.server;
import examples.lineclient.client;

// A request taken from the front server that is waiting for the backend's reply.
struct Waiting { id: u32 = 0, request: lineserver::Request = lineserver::Request { .. } }

struct Table { used: i64 = 0, items: Waiting[..64] = [] }

fn _remember(t: Table&, id: u32, r: lineserver::Request) -> bool {
    guard t.used < 64 else { return false; }
    while t.items.len < 64 { t.items.push(Waiting { .. }); }
    for i in 64 {
        if t.items[i].id == 0 { t.items[i] = Waiting { id: id, request: r }; t.used++; return true; }
    }
    return false;
}

fn _forget(t: Table&, id: u32) -> lineserver::Request {
    for i in t.items.len {
        if t.items[i].id == id {
            let r = t.items[i].request;
            t.items[i].id = 0;
            t.used--;
            return r;
        }
    }
    return lineserver::Request { .. };
}

// The backend's application: it answers a request with "backend: " and the request.
fn _backend<Io>(back: lineserver::LineServer&, io: Io&) {
    loop {
        var line: u8[>..] = [];
        let r = back.take_request(io, line);
        if !r.found { break; }
        var text: u8[>..] = [];
        format(text, "backend: ", line);
        back.reply(io, r, text[..]);
    }
}

// doc:begin step
// One event for every library, then what the application does with what they have: the backend answers, the
// front's requests go to the client, and the client's results go back to the front's connections.
fn step<Io>(front: lineserver::LineServer&, back: lineserver::LineServer&, client: lineclient::LineClient&, table: Table&, io: Io&, ev: goose_io::Event) {
    if !front.server_event(io, ev) { if !back.server_event(io, ev) { client.client_event(io, ev); } }
    // a Tick or PassEnd is every library's: give the others theirs
    if !goose_io::is_link_event(ev) { back.server_event(io, ev); client.client_event(io, ev); }
    _backend(back, io);
    loop {
        var line: u8[>..] = [];
        let r = front.take_request(io, line);
        if !r.found { break; }
        let id = client.request(io, line[..], 2000);
        if id == 0 || !_remember(table, id, r) { front.reply(io, r, "error: busy"); }
    }
    // the backend may have been answered by the work above: give the client what has arrived
    loop {
        var text: u8[>..] = [];
        let res = client.take_result(text);
        if !res.found { break; }
        let r = _forget(table, res.id);
        match res.outcome {
            Ok => { front.reply(io, r, text[..]); },
            TimedOut => { front.reply(io, r, "error: timed out"); },
            LinkLost => { front.reply(io, r, "error: backend lost"); },
            Failed => { front.reply(io, r, "error: backend unavailable"); },
        }
    }
}
// doc:end step
