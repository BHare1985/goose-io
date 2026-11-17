// goose-io conformance suite, group 4.5: received bytes, sending, backpressure, pausing.
// Requirements: Received bytes are lent for the duration of the event; Sending is all or nothing; Two parts
// can be sent as one; Send backpressure is explicit and bounded; Writable follows Full once; Reading can be
// paused; A refused send is always resolved.
namespace goose_io_conformance;
import std;
import goose_io;
import conformance.support;

fn data_info(id: i64) -> Info {
    if id == 300 { return Info { name: "data_arrives_as_slices", req: "Received bytes are lent for the duration of the event", part: 0 }; }
    if id == 301 { return Info { name: "data_slice_stable_in_handler", req: "Received bytes are lent for the duration of the event", part: 0 }; }
    if id == 302 { return Info { name: "send_copies_at_once", req: "Sending is all or nothing", part: 0 }; }
    if id == 303 { return Info { name: "send_before_open", req: "Sending is all or nothing", part: 0 }; }
    if id == 304 { return Info { name: "send_after_close", req: "Sending is all or nothing", part: 0 }; }
    if id == 305 { return Info { name: "send2_joins_parts", req: "Two parts can be sent as one", part: 0 }; }
    if id == 306 { return Info { name: "send2_all_or_nothing", req: "Two parts can be sent as one", part: 0 }; }
    if id == 307 { return Info { name: "send_too_large", req: "Send backpressure is explicit and bounded", part: 0 }; }
    if id == 308 { return Info { name: "send_is_bounded", req: "Send backpressure is explicit and bounded", part: 0 }; }
    if id == 309 { return Info { name: "send_room_is_zero_when_closed", req: "Send backpressure is explicit and bounded", part: 0 }; }
    if id == 310 { return Info { name: "writable_after_full", req: "Writable follows Full once", part: 0 }; }
    if id == 311 { return Info { name: "writable_once_for_many_refusals", req: "Writable follows Full once", part: 0 }; }
    if id == 312 { return Info { name: "writable_means_it_fits", req: "Writable follows Full once", part: 0 }; }
    if id == 313 { return Info { name: "writable_next_episode", req: "Writable follows Full once", part: 0 }; }
    if id == 314 { return Info { name: "pause_and_resume_reading", req: "Reading can be paused", part: 0 }; }
    if id == 315 { return Info { name: "full_not_writable_after_shutdown_write", req: "A refused send is always resolved", part: 0 }; }
    if id == 316 { return Info { name: "full_resolved_when_peer_closes", req: "A refused send is always resolved", part: 0 }; }
    if id == 317 { return Info { name: "send2_refusals", req: "Two parts can be sent as one", part: 0 }; }
    return Info { .. };
}

// Sends max_send-sized pieces until one is refused. Returns the bytes accepted, or -1 if nothing was
// refused within `limit` bytes, or -2 if a send returned something other than Sent or Full.
fn fill<Io>(io: Io&, link: goose_io::Link, limit: i64) -> i64 { return fill_with(io, link, io.max_send(), limit); }

// The same with pieces of `size` bytes: the room left when one is refused is then less than `size`.
fn fill_with<Io>(io: Io&, link: goose_io::Link, size: i64, limit: i64) -> i64 {
    let chunk = pattern(size);
    var total = 0;
    while total < limit {
        let r = io.send(link, chunk[..]);
        if r == goose_io::SendStatus.Full { return total; }
        if r != goose_io::SendStatus.Sent { return -2; }
        total += chunk.len;
    }
    return -1;
}

// --- 300: bytes arrive as slices --------------------------------------------------------------------

fn c_data_arrives_as_slices<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.send(k.link[0], pattern(100)[..]);
        k.step = 2;
    } else if k.step == 2 && k.received(1).len >= 100 {
        k.expect(k.received(1) == pattern(100), "the slices of the Data events were not the 100 bytes sent, in order");
        k.expect(k.received(1).len == 100, "more bytes arrived than were sent");
        io.close(k.link[0]);
        k.step = 3;
        k.finish();
    }
}

// --- 301: the slice of a Data event does not change while its handler runs ---------------------------

fn c_data_slice_stable_in_handler<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.send(k.link[0], pattern(3000)[..]);
        k.step = 2;
    } else if k.step == 2 {
        match ev {
            Data d => {
                if goose_io::same(d.link, k.link[1]) && k.flag == false {
                    // while this handler runs, make the event loop busy with the same link and others
                    var copy: u8[>..] = [];
                    copy.append(d.bytes);
                    io.send(k.link[1], "reply while handling");
                    io.send(k.link[0], pattern(500)[..]);
                    var same = d.bytes.len == copy.len;
                    if same { for i in copy.len { if d.bytes[i] != copy[i] { same = false; } } }
                    k.expect(same, "the bytes of a Data event changed while its handler was running");
                    k.flag = true;
                    k.step = 3;
                }
            },
            _ => {},
        }
    } else if k.step == 3 && k.received(0).len >= 20 {
        k.expect(k.received(1).len >= 3000 || k.count(1, 'D') >= 1, "no data arrived");
        io.close(k.link[0]);
        k.step = 4;
        k.finish();
    }
}

// --- 302: the caller reuses its memory at once, and a small send is accepted ---------------------------

fn c_send_copies_at_once<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        var buffer: u8[64] = [0; 64];
        for i in 64 { buffer[i] = ('a' + i % 26) as u8; }
        k.expect(io.send(k.link[0], buffer[..]) == goose_io::SendStatus.Sent, "a send of 64 bytes on an idle link did not return Sent");
        for i in 64 { buffer[i] = 'Z'; }
        k.step = 2;
    } else if k.step == 2 && k.received(1).len >= 64 {
        k.expect(k.received(1) == pattern(64), "the peer did not receive the bytes as they were when send was called");
        io.close(k.link[0]);
        k.step = 3;
        k.finish();
    }
}

// --- 303: a send before the link opens -----------------------------------------------------------------

fn c_send_before_open<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        if k.listen_local(io, 0) {
            let link = k.dial_local(io, 0, 0);
            k.expect(io.send(link, "too early") == goose_io::SendStatus.NotOpen, "send before Opened did not return NotOpen");
        }
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.send(k.link[0], "on time");
        io.close(k.link[0]);
        k.step = 2;
    } else if k.step == 2 && k.first(1, 'C') >= 0 {
        k.expect(k.received(1) == "on time", "a send refused with NotOpen was queued anyway");
        k.step = 3;
        k.finish();
    }
}

// --- 304: a send after close -----------------------------------------------------------------------------

fn c_send_after_close<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.send(k.link[0], "before");
        io.close(k.link[0]);
        k.expect(io.send(k.link[0], "after") == goose_io::SendStatus.Closed, "send after close did not return Closed");
        k.step = 2;
    } else if k.step == 2 && k.first(1, 'C') >= 0 {
        k.expect(k.received(1) == "before", "bytes sent after close were queued, or bytes before it were lost");
        k.step = 3;
        k.finish();
    }
}

// --- 305: a header and a body ----------------------------------------------------------------------------

fn c_send2_joins_parts<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        let header = pattern(20);
        var body: u8[>..] = [];
        for i in 100 { body.push(('A' + i % 26) as u8); }
        k.expect(io.send2(k.link[0], header[..], body[..]) == goose_io::SendStatus.Sent, "send2 of a header and a body on an idle link did not return Sent");
        k.step = 2;
    } else if k.step == 2 && k.received(1).len >= 120 {
        var want: u8[>..] = pattern(20);
        for i in 100 { want.push(('A' + i % 26) as u8); }
        k.expect(k.received(1) == want, "the peer did not receive the 120 bytes of header and body in order");
        io.close(k.link[0]);
        k.step = 3;
        k.finish();
    }
}

// Sends until the room left is between `low` and `high` bytes (the pieces are never larger than the
// room, so no send is refused on the way). Returns false if it could not get there.
fn fill_to_room<Io>(io: Io&, link: goose_io::Link, low: i64, high: i64, sent: i64&) -> bool {
    var rounds = 0;
    while rounds < 100000 {
        let room = io.send_room(link);
        if room >= low && room <= high { return true; }
        if room < low { return false; }
        let piece = if room - (low + high) / 2 > io.max_send() { io.max_send() } else { room - (low + high) / 2 };
        if io.send(link, pattern(piece)[..]) != goose_io::SendStatus.Sent { return false; }
        sent += piece;
        rounds++;
    }
    return false;
}

// --- 306: neither part is taken when both do not fit ---------------------------------------------------------

fn c_send2_all_or_nothing<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.pause_reading(k.link[1], true);
        var sent = 0;
        let ok = fill_to_room(io, k.link[0], 101, 1099, sent);
        k.m = sent;
        k.expect(ok, "could not fill the link to a room between the two parts");
        if ok {
            k.n = io.send_room(k.link[0]);
            let r = io.send2(k.link[0], pattern(100)[..], pattern(1000)[..]);
            k.expect(r == goose_io::SendStatus.Full, "send2 whose parts do not fit together did not return Full");
            k.t = k.received(1).len;
            io.pause_reading(k.link[1], false);
            k.step = 2;
        }
    } else if k.step == 2 && k.count(0, 'W') >= 1 {
        let r = io.send2(k.link[0], pattern(100)[..], pattern(1000)[..]);
        k.expect(r == goose_io::SendStatus.Sent, "send2 after Writable did not return Sent");
        io.close(k.link[0]);
        k.step = 3;
    } else if k.step == 3 && k.first(1, 'C') >= 0 {
        // everything the peer got: the fill, then exactly one copy of the two parts
        let got = k.received(1);
        k.expect(got.len >= 1100, "the peer received less than the two parts");
        if got.len >= 1100 {
            var tail: u8[>..] = [];
            tail.append(got[got.len - 1100..]);
            var want: u8[>..] = pattern(100);
            want.append(pattern(1000)[..]);
            k.expect(tail == want, "the peer did not receive the two parts joined");
            k.expect(got.len == k.m + 1100, "the peer received a part of a refused send2");
        }
        k.finish();
    }
}

// --- 307: an oversized send never fits -----------------------------------------------------------------------

fn c_send_too_large<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        let most = io.max_send();
        k.expect(most >= 4096, "max_send was less than 4096");
        k.expect(io.send(k.link[0], pattern(most + 1)[..]) == goose_io::SendStatus.TooLarge, "a send larger than max_send did not return TooLarge");
        k.expect(io.send(k.link[0], pattern(most)[..]) == goose_io::SendStatus.Sent, "a send of exactly max_send on an idle link did not return Sent");
        k.t = io.now_ms();
        k.step = 2;
    } else if k.step == 2 && io.now_ms() >= k.t + 400 {
        k.expect(k.count(0, 'W') == 0, "TooLarge led to a Writable");
        io.close(k.link[0]);
        k.step = 3;
        k.finish();
    }
}

// --- 308: a reader that never reads does not make the event loop hold more and more ----------------------------

fn c_send_is_bounded<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.pause_reading(k.link[1], true);
        let n = fill(io, k.link[0], 64 * 1024 * 1024);
        k.expect(n != -1, "a link whose peer never reads accepted 64 MiB without a Full");
        k.expect(n != -2, "a send returned something other than Sent or Full while filling a link");
        k.expect(n > 0, "a link accepted nothing before its first Full");
        io.pause_reading(k.link[1], false);
        io.close(k.link[0]);
        k.step = 2;
        k.finish();
    }
}

// --- 309: no room on a link that cannot send ---------------------------------------------------------------

fn c_send_room_is_zero_when_closed<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        if k.listen_local(io, 0) {
            let link = k.dial_local(io, 0, 0);
            k.expect(io.send_room(link) == 0, "send_room before Opened was not 0");
        }
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        let room = io.send_room(k.link[0]);
        k.expect(room > 0 && room <= io.max_send(), "send_room of an idle open link was not between 1 and max_send");
        k.expect(io.send_room(k.link[1]) > 0, "the other link had no room");
        io.close(k.link[0]);
        k.expect(io.send_room(k.link[0]) == 0, "send_room after close was not 0");
        k.step = 2;
        k.finish();
    }
}

// --- 310: a full queue is reported and later reopened -----------------------------------------------------------

fn c_writable_after_full<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.pause_reading(k.link[1], true);
        k.expect(fill(io, k.link[0], 64 * 1024 * 1024) >= 0, "could not fill the link");
        k.expect(io.send(k.link[0], pattern(io.max_send())[..]) == goose_io::SendStatus.Full, "a send on a full link did not return Full");
        k.expect(k.count(0, 'W') == 0, "a Writable arrived while the peer was not reading");
        io.pause_reading(k.link[1], false);
        k.step = 2;
    } else if k.step == 2 && k.count(0, 'W') >= 1 {
        k.expect(io.send(k.link[0], pattern(100)[..]) == goose_io::SendStatus.Sent, "a small send after Writable did not return Sent");
        k.t = io.now_ms();
        k.step = 3;
    } else if k.step == 3 && io.now_ms() >= k.t + 300 {
        k.expect(k.count(0, 'W') == 1, "more than one Writable was delivered for one refusal");
        io.close(k.link[0]);
        k.step = 4;
        k.finish();
    }
}

// --- 311: several refusals share one Writable -------------------------------------------------------------------

fn c_writable_once_for_many_refusals<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.pause_reading(k.link[1], true);
        k.expect(fill(io, k.link[0], 64 * 1024 * 1024) >= 0, "could not fill the link");
        for i in 3 {
            k.expect(io.send(k.link[0], pattern(io.max_send())[..]) == goose_io::SendStatus.Full, "a send on a full link did not return Full");
        }
        io.pause_reading(k.link[1], false);
        k.step = 2;
    } else if k.step == 2 && k.count(0, 'W') >= 1 {
        k.t = io.now_ms();
        k.step = 3;
    } else if k.step == 3 && io.now_ms() >= k.t + 300 {
        k.expect(k.count(0, 'W') == 1, "three refusals gave more than one Writable");
        io.close(k.link[0]);
        k.step = 4;
        k.finish();
    }
}

// --- 312: Writable means the refused send fits -------------------------------------------------------------------

fn c_writable_means_it_fits<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.pause_reading(k.link[1], true);
        let most = io.max_send();
        // pieces of a quarter: when one is refused, less than a quarter of room is left, so each of the three
        // sends below is refused
        k.expect(fill_with(io, k.link[0], most / 4, 64 * 1024 * 1024) >= 0, "could not fill the link");
        k.n = most;
        k.expect(io.send(k.link[0], pattern(most)[..]) == goose_io::SendStatus.Full, "the largest send was not refused");
        k.expect(io.send(k.link[0], pattern(most * 3 / 4)[..]) == goose_io::SendStatus.Full, "a send of three quarters was not refused");
        k.expect(io.send(k.link[0], pattern(most / 2)[..]) == goose_io::SendStatus.Full, "a send of half was not refused");
        io.pause_reading(k.link[1], false);
        k.step = 2;
    } else if k.step == 2 && k.count(0, 'W') >= 1 {
        k.expect(io.send(k.link[0], pattern(k.n)[..]) == goose_io::SendStatus.Sent, "the largest refused send did not return Sent after Writable");
        io.close(k.link[0]);
        k.step = 3;
        k.finish();
    }
}

// --- 313: a later refusal gets its own Writable --------------------------------------------------------------------

fn c_writable_next_episode<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.pause_reading(k.link[1], true);
        k.expect(fill(io, k.link[0], 64 * 1024 * 1024) >= 0, "could not fill the link");
        io.pause_reading(k.link[1], false);
        k.step = 2;
    } else if k.step == 2 && k.count(0, 'W') >= 1 {
        io.pause_reading(k.link[1], true);
        k.expect(fill(io, k.link[0], 64 * 1024 * 1024) >= 0, "could not fill the link a second time");
        io.pause_reading(k.link[1], false);
        k.step = 3;
    } else if k.step == 3 && k.count(0, 'W') >= 2 {
        io.close(k.link[0]);
        k.step = 4;
        k.finish();
    }
}

// --- 314: pause and resume --------------------------------------------------------------------------------------------

fn c_pause_and_resume_reading<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.pause_reading(k.link[1], true);
        io.send(k.link[0], "held back");
        k.t = io.now_ms();
        k.step = 2;
    } else if k.step == 2 && io.now_ms() >= k.t + 300 {
        k.expect(k.received(1).len == 0, "Data was delivered while reading was paused");
        io.pause_reading(k.link[1], false);
        k.step = 3;
    } else if k.step == 3 && k.received(1).len >= 9 {
        k.expect(k.received(1) == "held back", "the bytes were not delivered after the resume");
        io.close(k.link[0]);
        k.step = 4;
        k.finish();
    }
}

// --- 315: a refusal is not followed by a Writable once the write side is shut ---------------------------------------

fn c_full_not_writable_after_shutdown_write<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.pause_reading(k.link[1], true);
        k.expect(fill(io, k.link[0], 64 * 1024 * 1024) >= 0, "could not fill the link");
        k.expect(io.send(k.link[0], pattern(io.max_send())[..]) == goose_io::SendStatus.Full, "a send on a full link did not return Full");
        io.shutdown_write(k.link[0]);
        io.pause_reading(k.link[1], false);
        k.t = io.now_ms();
        k.step = 2;
    } else if k.step == 2 && io.now_ms() >= k.t + 400 {
        k.expect(k.count(0, 'W') == 0, "a Writable was delivered after shutdown_write");
        io.close(k.link[0]);
        k.step = 3;
        k.finish();
    }
}

// --- 316: a refusal is resolved when the peer goes away ---------------------------------------------------------------

fn c_full_resolved_when_peer_closes<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        io.set_keep_open_on_eof(k.link[0], true);       // while it is dialling
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.pause_reading(k.link[1], true);
        k.expect(fill(io, k.link[0], 64 * 1024 * 1024) >= 0, "could not fill the link");
        k.expect(io.send(k.link[0], pattern(io.max_send())[..]) == goose_io::SendStatus.Full, "a send on a full link did not return Full");
        io.close(k.link[1]);
        k.within(io, 3000);
        k.step = 2;
    } else if k.step == 2 && (k.count(0, 'W') >= 1 || k.first(0, 'C') >= 0) {
        k.expect(k.count(0, 'W') <= 1, "more than one Writable was delivered");
        if k.count(0, 'W') >= 1 && k.first(0, 'C') < 0 {
            let r = io.send(k.link[0], "z");
            k.expect(r != goose_io::SendStatus.Full, "the send after the Writable was refused again");
            io.close(k.link[0]);
        }
        k.step = 3;
        k.finish();
    }
}

// --- 317: send2 is refused as send is --------------------------------------------------------------------------

fn c_send2_refusals<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        if k.listen_local(io, 0) {
            let link = k.dial_local(io, 0, 0);
            k.expect(io.send2(link, "too", " early") == goose_io::SendStatus.NotOpen, "send2 before Opened did not return NotOpen");
        }
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        let most = io.max_send();
        k.expect(io.send2(k.link[0], pattern(most)[..], "x") == goose_io::SendStatus.TooLarge, "a send2 larger than max_send in all did not return TooLarge");
        io.close(k.link[0]);
        k.expect(io.send2(k.link[0], "af", "ter") == goose_io::SendStatus.Closed, "send2 after close did not return Closed");
        k.step = 2;
        k.finish();
    }
}

// Runs the checks of the core: true if the check is one of them.
fn data_core_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 300 { c_data_arrives_as_slices(k, io, ev); return true; }
    if k.id == 301 { c_data_slice_stable_in_handler(k, io, ev); return true; }
    if k.id == 302 { c_send_copies_at_once(k, io, ev); return true; }
    if k.id == 303 { c_send_before_open(k, io, ev); return true; }
    if k.id == 304 { c_send_after_close(k, io, ev); return true; }
    if k.id == 307 { c_send_too_large(k, io, ev); return true; }
    if k.id == 308 { c_send_is_bounded(k, io, ev); return true; }
    if k.id == 310 { c_writable_after_full(k, io, ev); return true; }
    if k.id == 311 { c_writable_once_for_many_refusals(k, io, ev); return true; }
    if k.id == 312 { c_writable_means_it_fits(k, io, ev); return true; }
    if k.id == 313 { c_writable_next_episode(k, io, ev); return true; }
    if k.id == 314 { c_pause_and_resume_reading(k, io, ev); return true; }
    return false;
}

// Runs the checks of the sizing group: true if the check is one of them.
fn data_sizing_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 305 { c_send2_joins_parts(k, io, ev); return true; }
    if k.id == 306 { c_send2_all_or_nothing(k, io, ev); return true; }
    if k.id == 309 { c_send_room_is_zero_when_closed(k, io, ev); return true; }
    if k.id == 317 { c_send2_refusals(k, io, ev); return true; }
    return false;
}

// Runs the checks of the half-close group: true if the check is one of them.
fn data_half_close_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 315 { c_full_not_writable_after_shutdown_write(k, io, ev); return true; }
    if k.id == 316 { c_full_resolved_when_peer_closes(k, io, ev); return true; }
    return false;
}
