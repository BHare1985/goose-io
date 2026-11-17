// goose-io conformance suite, group 4.6: closing, half-close, close reasons.
// Requirements: Closing; Close does not lose accepted bytes; Peer end of stream and half-close; Close reasons
// are portable.
namespace goose_io_conformance;
import std;
import goose_io;
import conformance.support;

fn close_info(id: i64) -> Info {
    if id == 400 { return Info { name: "close_after_reply", req: "Closing", part: 0 }; }
    if id == 401 { return Info { name: "close_leaves_only_closed", req: "Closing", part: 0 }; }
    if id == 402 { return Info { name: "close_cancels_a_dial", req: "Closing", part: 0 }; }
    if id == 403 { return Info { name: "reset_aborts_the_peer", req: "Closing", part: 0 }; }
    if id == 404 { return Info { name: "close_with_unread_input", req: "Close does not lose accepted bytes", part: 0 }; }
    if id == 405 { return Info { name: "close_when_peer_never_reads", req: "Close does not lose accepted bytes", part: 0 }; }
    if id == 406 { return Info { name: "peer_eof_closes_by_default", req: "Peer end of stream and half-close", part: 0 }; }
    if id == 408 { return Info { name: "shutdown_write_ends_sending", req: "Peer end of stream and half-close", part: 0 }; }
    if id == 407 { return Info { name: "half_close_then_answer", req: "Peer end of stream and half-close", part: 0 }; }
    return Info { .. };
}

// --- 400: close after a reply -------------------------------------------------------------------------------

fn c_close_after_reply<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.send(k.link[1], "the whole reply");
        io.close(k.link[1]);
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.expect(k.received(0) == "the whole reply", "the peer did not receive the whole reply before the close");
        k.expect(k.closed_with(0, goose_io::CloseReason.PeerClosed), "the peer's link did not end with PeerClosed after the reply");
        k.expect(k.closed_with(1, goose_io::CloseReason.Local) && k.count(1, 'C') == 1, "the closing side did not get exactly one Closed with reason Local");
        k.finish();
    }
}

// --- 401: nothing but Closed after close ---------------------------------------------------------------------------

fn c_close_leaves_only_closed<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        // the client is refused with Full; the server then reads, which owes the client a Writable
        io.pause_reading(k.link[1], true);
        k.n = fill(io, k.link[0], 64 * 1024 * 1024);
        k.expect(k.n >= 0, "could not fill the link");
        io.send(k.link[0], pattern(io.max_send())[..]);
        io.pause_reading(k.link[1], false);
        k.step = 2;
    } else if k.step == 2 && k.first(1, 'D') >= 0 && k.first(0, 'C') < 0 && k.received(1).len >= k.n {
        // in a handler of the server's Data, once the server has read everything the client had been allowed to
        // send, so that the room the refused send needs has opened: the Writable owed for it must not be
        // delivered after close
        k.t = k.recs.len;
        io.close(k.link[0]);
        k.step = 3;
    } else if k.step == 3 && k.first(0, 'C') >= 0 {
        var after: u8[>..] = [];
        for i in k.recs.len - k.t { if k.recs[k.t + i].role == 0 { after.push(k.recs[k.t + i].kind); } }
        k.expect(after == "C", "after close the link got an event other than its one Closed");
        k.expect(k.closed_with(0, goose_io::CloseReason.Local), "the link did not end with reason Local");
        k.step = 4;
        k.finish();
    }
}

// --- 402: cancelling a dial ------------------------------------------------------------------------------------------

fn c_close_cancels_a_dial<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        if k.listen_local(io, 0) {
            let link = k.dial_local(io, 0, 0);
            io.close(link);
        }
        k.step = 1;
    } else if k.step == 1 && k.first(0, 'C') >= 0 {
        k.expect(k.kinds(0) == "C", "a dial cancelled before its Opened gave an Opened, or no single Closed");
        k.expect(k.closed_with(0, goose_io::CloseReason.Local), "a cancelled dial did not end with reason Local");
        k.t = io.now_ms();
        k.step = 2;
    } else if k.step == 2 && io.now_ms() >= k.t + 200 {
        k.finish();
    }
}

// --- 403: reset ---------------------------------------------------------------------------------------------------------

fn c_reset_aborts_the_peer<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.pause_reading(k.link[1], true);
        io.send(k.link[0], "queued, and never read");
        io.reset(k.link[0]);
        io.pause_reading(k.link[1], false);
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.expect(k.closed_with(1, goose_io::CloseReason.PeerReset), "the peer of a reset link did not end with PeerReset");
        k.expect(k.closed_with(0, goose_io::CloseReason.Local) && k.count(0, 'C') == 1, "the resetting side did not get exactly one Closed with reason Local");
        k.finish();
    }
}

// --- 404: close with unread input ----------------------------------------------------------------------------------------

fn c_close_with_unread_input<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        // bytes the server has not been given: it is not reading
        io.pause_reading(k.link[1], true);
        io.send(k.link[0], "a request the server never reads");
        k.t = io.now_ms();
        k.step = 2;
    } else if k.step == 2 && io.now_ms() >= k.t + 100 {
        io.send(k.link[1], "the reply");
        io.close(k.link[1]);
        k.step = 3;
    } else if k.step == 3 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.expect(k.received(0) == "the reply", "the peer did not receive the whole reply (the closing side had unread input)");
        k.expect(k.count(1, 'D') == 0, "the closing side got Data for input it had not read when it closed");
        k.expect(k.closed_with(1, goose_io::CloseReason.Local), "the closing side did not end with reason Local");
        k.finish();
    }
}

// --- 405: a peer that never reads -------------------------------------------------------------------------------------------

fn c_close_when_peer_never_reads<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.pause_reading(k.link[1], true);
        io.send(k.link[0], pattern(1000)[..]);
        io.close(k.link[0]);
        // an event loop may keep accepted bytes for a limit of its own: two minutes of the loop's clock
        k.within(io, 120000);
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 {
        k.expect(k.closed_with(0, goose_io::CloseReason.Local), "the link did not end with reason Local");
        k.expect(io.send(k.link[0], "x") == goose_io::SendStatus.Closed, "a send after close was not refused with Closed");
        io.pause_reading(k.link[1], false);
        k.step = 3;
        k.finish();
    }
}

// --- 406: the peer's end of stream closes the link by default ------------------------------------------------------------------------

fn c_peer_eof_closes_by_default<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.send(k.link[0], "request");
        io.shutdown_write(k.link[0]);
        k.step = 2;
    } else if k.step == 2 && k.first(1, 'D') >= 0 && !k.flag {
        // the server answers what it has been given, before it sees the end of the stream
        k.flag = true;
        io.send(k.link[1], "answer");
        k.step = 3;
    } else if k.step == 3 && k.first(1, 'C') >= 0 && k.first(0, 'C') >= 0 {
        k.expect(k.received(1) == "request", "the server did not receive the request");
        k.expect(k.closed_with(1, goose_io::CloseReason.PeerClosed), "a link that was not kept open did not end with PeerClosed on the peer's end of stream");
        k.expect(k.count(1, 'E') == 0, "PeerEof was delivered to a link that was not kept open");
        k.expect(k.received(0) == "answer", "bytes the library had sent did not reach the peer before it closed");
        k.finish();
    }
}

// --- 407: answering after the peer half-closes -------------------------------------------------------------------------------------------

fn c_half_close_then_answer<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    k.keep_open_on_accept(io, ev, 0);       // the server end, in the handler of its Opened
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.send(k.link[0], "the request");
        io.shutdown_write(k.link[0]);
        k.step = 2;
    } else if k.step == 2 && k.first(1, 'E') >= 0 {
        let e = k.first(1, 'E');
        var datas_after = 0;
        for i in k.recs.len - e { if k.recs[e + i].role == 1 && k.recs[e + i].kind == 'D' { datas_after++; } }
        k.expect(datas_after == 0, "Data was delivered after PeerEof");
        k.expect(k.received(1) == "the request", "the server did not receive the whole request before PeerEof");
        io.send(k.link[1], "the reply");
        io.shutdown_write(k.link[1]);
        k.step = 3;
    } else if k.step == 3 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.expect(k.count(1, 'E') == 1, "PeerEof was not delivered exactly once");
        k.expect(k.received(0) == "the reply", "the peer did not receive the whole reply");
        k.expect(k.closed_with(0, goose_io::CloseReason.PeerClosed) && k.closed_with(1, goose_io::CloseReason.PeerClosed), "after both sides finished the links did not close with PeerClosed");
        k.finish();
    }
}

// --- 408: shutdown_write ends sending and waits for the peer ---------------------------------------------------------

// The half-close group: after shutdown_write a send returns Closed, the bytes sent before it still arrive, and the link
// closes with PeerClosed when the peer has finished too.
fn c_shutdown_write_ends_sending<Io>(k: Case&, io: Io&, ev: goose_io::Event) {
    if k.step == 0 {
        k.connect_local(io, 0);
        k.step = 1;
    } else if k.step == 1 && k.pair_open(0) {
        io.send(k.link[0], "before");
        io.shutdown_write(k.link[0]);
        k.expect(io.send(k.link[0], "after") == goose_io::SendStatus.Closed, "send after shutdown_write did not return Closed");
        k.step = 2;
    } else if k.step == 2 && k.first(0, 'C') >= 0 && k.first(1, 'C') >= 0 {
        k.expect(k.received(1) == "before", "the bytes sent before shutdown_write did not arrive, or those after it did");
        k.expect(k.closed_with(0, goose_io::CloseReason.PeerClosed) && k.closed_with(1, goose_io::CloseReason.PeerClosed), "after shutdown_write and the peer's end of stream the links did not close with PeerClosed");
        k.finish();
    }
}

// Runs the checks of the core: true if the check is one of them.
fn close_core_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 400 { c_close_after_reply(k, io, ev); return true; }
    if k.id == 401 { c_close_leaves_only_closed(k, io, ev); return true; }
    if k.id == 402 { c_close_cancels_a_dial(k, io, ev); return true; }
    if k.id == 404 { c_close_with_unread_input(k, io, ev); return true; }
    if k.id == 405 { c_close_when_peer_never_reads(k, io, ev); return true; }
    return false;
}

// Runs the checks of the half-close group: true if the check is one of them.
fn close_half_close_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 406 { c_peer_eof_closes_by_default(k, io, ev); return true; }
    if k.id == 407 { c_half_close_then_answer(k, io, ev); return true; }
    if k.id == 408 { c_shutdown_write_ends_sending(k, io, ev); return true; }
    return false;
}

// Runs the checks of the abort group: true if the check is one of them.
fn close_abort_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 403 { c_reset_aborts_the_peer(k, io, ev); return true; }
    return false;
}
