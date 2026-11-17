// examples/dispatch: an application that sends each event to the library that owns its link in one lookup. An echo server and a
// line client run on one loop: the client's request travels to the server and comes back, each library handled only its own
// links, and only the first event of each link was offered to the libraries in turn.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.examples.echo.echo;
import goose_io.examples.lineclient.client;
import goose_io.examples.dispatch;

struct Seen { asked: bool = false, events: i64 = 0, ok: bool = false, reply: u8[>..] = [] }

fn app_event(s: Seen&, r: dispatch::Router&, e: echo::Echo&, c: lineclient::LineClient&, io: goose_io_memory::Loop&, ev: goose_io::Event) {
    dispatch::step(r, e, c, io, ev);
    if goose_io::is_link_event(ev) { s.events++; }
    match ev {
        Tick t => { if !s.asked { s.asked = true; c.request(io, "ping", 1000); } },
        _ => {},
    }
    loop {
        var text: u8[>..] = [];
        let res = c.take_result(text);
        if !res.found { break; }
        match res.outcome {
            Ok => { s.ok = true; s.reply.append(text[..]); },
            _ => {},
        }
    }
    kit::stop_after(io, ev, 300);
}

fn main() {
    var io = goose_io_memory::Loop { .. };
    var r = dispatch::Router { .. };
    var e = echo::Echo { .. };
    var c = lineclient::LineClient { .. };
    var s = Seen { .. };
    kit::check(e.start(io, "127.0.0.1:7200"), "the echo server listens");
    kit::check(c.start(io, "127.0.0.1:7200", 1, 100), "the line client starts");
    io.serve() { io, ev => app_event(s, r, e, c, io, ev); };
    kit::check(s.ok && s.reply == "ping", "the client's request came back from the echo server through the application");
    // two links (the accepted end and the dialled end): at most two libraries asked once for each, however many events followed
    kit::check(r.offered <= 4, "only the first event of each link was offered to the libraries in turn");
    kit::check(s.events > r.offered, "the events that followed were dispatched by lookup, not offered in turn");
    kit::finish();
}
