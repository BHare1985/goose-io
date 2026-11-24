// examples/capabilities/frames: a body arrives as length-prefixed frames, in order and whole, on a link with room for
// only a few frames at a time: the streamer is held back, never refused for a frame that would fit, and finishes when the
// peer reads again.
import std;
import goose_io from "../../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.examples.capabilities.frames;

fn body_text(n: i64) -> u8[>..] {
    var b: u8[>..] = [];
    for i in n { b.push((65 + i % 26) as u8); }
    return b;
}

// The frames in `got` joined back into a body; false if a header and its payload do not match up.
fn unframe(got: const u8[:], out: u8[>..]&) -> bool {
    var at = 0;
    while at < got.len {
        guard at + frames::HEADER <= got.len else { return false; }
        let n = ((got[at] as i64) << 24) | ((got[at + 1] as i64) << 16) | ((got[at + 2] as i64) << 8) | got[at + 3];
        guard n > 0 && at + frames::HEADER + n <= got.len else { return false; }
        out.append(got[at + frames::HEADER..at + frames::HEADER + n]);
        at += frames::HEADER + n;
    }
    return true;
}

fn run<Io>(io: Io&, roomy: bool) {
    if !roomy { io.cfg.link_buffer = 4096; io.cfg.max_send = 4096; }
    var f = frames::Frames { .. };
    let body = body_text(20000);
    kit::check(f.start(io, "127.0.0.1:7100", body[..]), "the streamer listens");
    let p = io.add_peer();
    io.peer_connect(p, "127.0.0.1:7100", 0);
    if !roomy {
        io.peer_stop_reading(p, 1);
        io.peer_resume_reading(p, 150);
    }
    var log = kit::Log { .. };
    io.serve() { io, ev => { kit::note(log, io, ev); f.frames_event(io, ev); kit::stop_after(io, ev, 400); }; };
    var back: u8[>..] = [];
    kit::check(unframe(io.peer_received(p)[..], back), "every frame has its header and its whole payload");
    kit::check(back[..] == body[..], "the frames carry the body, in order");
    kit::check(f.frame_count() > 1, "the body went in several frames");
    kit::check(io.peer_closed(p) || io.peer_saw_eof(p), "the link ends after the last frame");
    if roomy {
        kit::check(f.refused_count() == 0, "on a link with room no send is refused");
    } else {
        kit::check(f.refused_count() > 0, "the peer that stopped reading held the streamer back");
        kit::check(f.refused_count() < f.frame_count(), "a refusal is the exception: frames are cut to the room and sent");
    }
}

fn main() {
    var a = goose_io_memory::Loop { .. };
    run(a, true);
    var b = goose_io_memory::Loop { .. };
    run(b, false);
    kit::finish();
}
