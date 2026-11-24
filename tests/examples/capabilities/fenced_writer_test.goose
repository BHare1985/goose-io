// examples/capabilities/fenced_writer, on the in-memory clock: a client that does not read before the fence is not written
// to after it, and the writer's link ends with reason Local; a cancel drops what the client had not read and says how many
// bytes. The client is a link of the same loop, because scripted peers hold nothing the writer could take back.
import std;
import goose_io from "../../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.examples.capabilities.fenced_writer;

fn payload_text(n: i64) -> u8[>..] {
    var b: u8[>..] = [];
    for i in n { b.push((97 + i % 26) as u8); }
    return b;
}

let PAYLOAD = 3000;
let ADDRESS = "127.0.0.1:7105";

// A writer on a loop, and a client that is a link of the same loop and does not read until `resume_ms`.
fn scenario(lease_ms: i64, cancel_at: i64, resume_ms: i64) -> i64 {
    var io = goose_io_memory::Loop { .. };
    var w = fenced_writer::FencedWriter { .. };
    var log = kit::Log { .. };
    let payload = payload_text(PAYLOAD);
    kit::check(w.start(io, ADDRESS, payload[..], lease_ms), "the writer listens");
    let client = io.dial(ADDRESS, 0);
    var cancelled = false;
    var resumed = false;
    io.serve() { io, ev => {
        kit::note(log, io, ev);
        w.writer_event(io, ev);
        match ev {
            Opened o => { if goose_io::same(o.link, client) { io.pause_reading(client, true); } },
            Tick t => {
                if cancel_at > 0 && t.now_ms >= cancel_at && !cancelled { cancelled = true; w.cancel(io); }
                if t.now_ms >= resume_ms && !resumed { resumed = true; io.pause_reading(client, false); }
                if t.now_ms >= resume_ms + 100 { io.stop(0); }
            },
            _ => {},
        }
    }; };
    let got = kit::data_of(log, client);
    if cancel_at > 0 {
        kit::check(w.dropped_bytes() == PAYLOAD, "cancel dropped the bytes the client had not read");
        kit::check(got.len == 0, "and the client never got them");
    } else {
        kit::check(got.len < PAYLOAD, "the fence stopped the writing: the client did not get the whole payload");
        let closed = kit::nth(log, kit::CLOSED, 0);
        kit::check(closed >= 0, "the writer's link ended");
    }
    return w.dropped_bytes();
}

fn main() {
    scenario(100, 0, 300);
    scenario(10000, 100, 300);
    kit::finish();
}
