// The wrapper presents the loop beneath unchanged, so the address form `unix:/path` works through it: both ends open,
// and bytes cross in order, though the wrapper changes them on the way (specs/io-contract of the change add-unix-sockets).
import std;
import goose_io from "../..";
import goose_io.tests.support.kit;
import goose_io.tests.support.wrapper;

let PATH = "unix:/run/goose-io-test.sock";

fn event(p: kit::Pair&, log: kit::Log&, io: wrapper::Layer&, ev: goose_io::Event) {
    if kit::track(p, log, io, ev) {
        io.send(p.client, "ping");
        io.send(p.server, "pong");
    }
    kit::stop_after(io, ev, 300);
}

fn main() {
    var io = wrapper::Layer { .. };
    var log = kit::Log { .. };
    var p = kit::Pair { .. };
    let l, err = io.listen(PATH);
    kit::check(goose_io::is_listener(l) && !goose_io::failed(err), "listen on a path through the wrapper");
    p.client = io.dial(PATH, 0);
    io.serve() { io, ev => event(p, log, io, ev); };
    kit::check(kit::data_of(log, p.server) == "ping" && kit::data_of(log, p.client) == "pong", "bytes cross a path link through the wrapper unchanged");
    kit::finish();
}
