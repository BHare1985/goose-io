// examples/capabilities/worker_reply: requests are answered by a worker thread through wake_with, every client gets its own
// answer, and the test joins the worker before it ends.
import std;
import goose_io from "../../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.examples.capabilities.worker_reply;

let CLIENTS = 6;

// The application's worker: it answers each job in upper case. It needs a loop value only to call wake_with, which uses
// the process's queue and nothing of the loop's state.
// An idle loop that expects wakes waits for them instead of moving its clock, so the scripted peers act at once.
thread_fn worker() {
    var io = goose_io_memory::Loop { .. };
    loop {
        let job = qget<worker_reply::Job>();
        guard job.ticket >= 0 else { break; }
        var answer: u8[..64] = [];
        for b in job.request[..] { answer.push(if b >= 97 && b <= 122 { b - 32 } else { b }); }
        io.wake_with(job.waker, job.ticket, answer[..]);
    }
}

fn main() {
    var io = goose_io_memory::Loop { .. };
    var w = worker_reply::WorkerReply { .. };
    kit::check(w.start(io, "127.0.0.1:7107"), "the server listens");
    var peers: goose_io_memory::Peer[>..] = [];
    for i in CLIENTS {
        let p = io.add_peer();
        peers.push(p);
        io.peer_connect(p, "127.0.0.1:7107", 0);
    }
    io.peer_send(peers[0], 0, "alpha");
    io.peer_send(peers[1], 0, "bravo");
    io.peer_send(peers[2], 0, "charlie");
    io.peer_send(peers[3], 0, "delta");
    io.peer_send(peers[4], 0, "echo");
    io.peer_send(peers[5], 0, "foxtrot");
    io.expect_wakes(CLIENTS);
    let id = thread_spawn(worker);
    io.serve() { io, ev => { w.reply_event(io, ev); kit::stop_after(io, ev, 300); }; };
    qput(worker_reply::Job { ticket: -1, .. });
    thread_wait(id);
    kit::check(io.peer_received(peers[0]) == "ALPHA", "the first client got its own answer");
    kit::check(io.peer_received(peers[3]) == "DELTA", "the fourth client got its own answer");
    kit::check(io.peer_received(peers[5]) == "FOXTROT", "the last client got its own answer");
    kit::check(w.asked_count() == CLIENTS && w.answered_count() == CLIENTS, "every request was handed out and answered");
    kit::finish();
}
