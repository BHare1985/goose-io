// A worker that listens on an address other workers listen on too, so that each worker accepts its own share of the
// connections. It shows the shared-listen capability (docs/capabilities/shared-listen.md).
//
// Needs: core only.
// Uses if supplied: shared-listen (the worker holds the address together with the others; without it the worker takes
// the address alone, and a second worker on it gets AddressInUse).
//
// A server that runs one loop per core starts one worker per loop, each with its own event loop on its own thread, all on
// the same address. With the capability the system spreads the connections among the listeners and nothing is handed
// from loop to loop. Here the workers answer by echoing: the serving is as small as it can be, and what this file adds is the choice of how to listen.
// An example, not a library to depend on.
namespace loop_per_core;
import std;
import goose_io;

struct Mine { n: i64 = 0 }

root struct Worker {
    listener: goose_io::Listener      = goose_io::Listener { .. },
    links:    goose_io::LinkMap<Mine> = goose_io::LinkMap<Mine> {},   // the links this worker accepted
    accepted: i64                     = 0,     // connections this worker accepted
    shared:   bool                    = false, // the loop let it share the address
}

// doc:begin listen
// The choice is made when the library is built: a loop without the capability never compiles the call to `listen_shared`.
fn _listen<Io, S>(w: Worker&, io: Io&, has: S, address: const u8[:]) -> bool {
    const if same<S, goose_io::Supplied> {
        let l, err = io.listen_shared(address);
        w.listener = l;
        w.shared = true;
        return goose_io::is_listener(l) && !goose_io::failed(err);
    } else {
        let l, err = io.listen(address);
        w.listener = l;
        return goose_io::is_listener(l) && !goose_io::failed(err);
    }
}
// doc:end listen

// Listens on `address`, shared when the loop can. False if the listen failed.
fn start<Io>(w: Worker&, io: Io&, address: const u8[:]) -> bool {
    return w._listen(io, goose_io::has_shared_listen(io), address);
}

// The port the worker listens on.
fn port<Io>(w: Worker&, io: Io&) -> u16 { return io.listener_port(w.listener); }

fn accepted_count(w: Worker&) -> i64 { return w.accepted; }
fn is_shared(w: Worker&) -> bool { return w.shared; }

// The worker's one entry point: true if the event was for one of its links. It answers every byte with the same byte.
fn worker_event<Io>(w: Worker&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Opened o => {
            guard goose_io::is_listener(o.listener) && goose_io::same(o.listener, w.listener) else { return false; }
            w.accepted++;
            w.links.put(o.link, Mine { .. });
            return true;
        },
        Data d => {
            guard w.links.find(d.link) != null else { return false; }
            if io.send(d.link, d.bytes) != goose_io::SendStatus.Sent { io.close(d.link); }
            return true;
        },
        Closed x => {
            guard w.links.find(x.link) != null else { return false; }
            w.links.drop(x.link);
            return true;
        },
        _ => { return false; },
    }
}
