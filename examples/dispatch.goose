// An application that sends each event to the library that owns its link, in one lookup, instead of offering it to every
// library in turn: an echo server and a line client on one loop.
//
// Needs: core only (the echo server and the line client need nothing more).
//
// A library is written to be offered any event and to handle only those of its own links, so the simplest application
// offers each event to the libraries in turn until one claims it (examples/gateway.goose does this). That costs a failed
// ownership check in every library before the owner. This application keeps the one fact that makes it unnecessary, which
// library owns each link, in a `LinkMap`:
//
//     io.serve() { io, ev => dispatch::step(router, echo, client, io, ev); };
//
// Known links are one lookup. A link seen for the first time is offered to the libraries in turn and whichever claims it
// owns it from then on, so the application needs no help from a library that dials for itself (the line client's links are
// made inside the library, and the application never sees the handle `dial` returned).
namespace dispatch;
import std;
import goose_io;
import examples.echo.echo;
import examples.lineclient.client;

// doc:begin router
// The library that owns a link, as a number the application chooses.
struct Owner { library: i64 = 0 }

root struct Router {
    owners:  goose_io::LinkMap<Owner> = goose_io::LinkMap<Owner> {},
    offered: i64                      = 0,        // events offered in turn: the first event of each link
}

// Offers the event to one library; true if the event was for one of its links.
fn _offer<Io>(echo: echo::Echo&, client: lineclient::LineClient&, library: i64, io: Io&, ev: goose_io::Event) -> bool {
    return if library == 0 { echo.echo_event(io, ev) } else { client.client_event(io, ev) };
}

fn step<Io>(r: Router&, echo: echo::Echo&, client: lineclient::LineClient&, io: Io&, ev: goose_io::Event) {
    if !goose_io::is_link_event(ev) {
        // a Tick is about no link: every library has its own
        echo.echo_event(io, ev);
        client.client_event(io, ev);
        return;
    }
    let link = goose_io::link_of(ev);
    let known .= r.owners.find(link);
    if known != null {
        _offer(echo, client, known.library, io, ev);                    // one lookup
    } else {
        for library in 2 {                                              // the first event of a link: ask each library once
            r.offered++;
            if _offer(echo, client, library, io, ev) {
                r.owners.put(link, Owner { library: library });
                break;
            }
        }
    }
    match ev {
        Closed e => { r.owners.drop(e.link); },                         // the handle is valid until this handler returns
        _ => {},
    }
}
// doc:end router
