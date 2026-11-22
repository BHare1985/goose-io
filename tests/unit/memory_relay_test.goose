// Combinations of the relay group with other groups and the end of a relayed pair, on the in-memory loop (design D6 of
// add-proxy-groups). These need the loop to break a transport or to limit a relay, which a conformance check cannot ask
// of a loop, so they are tests of this loop and not entries of the suite.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;

// Runs the tests against a fault of the loop when GOOSE_IO_FAULT names one, to show that each of them fails.
fn use_fault(io: goose_io_memory::Loop&) {
    var fault: u8[>..] = [];
    if env("GOOSE_IO_FAULT", fault) && fault.len > 0 { io.set_fault(fault[..]); }
}

struct Rig {
    l0:       goose_io::Listener   = goose_io::Listener { .. },
    l1:       goose_io::Listener   = goose_io::Listener { .. },
    client:   goose_io::Link[2]    = [goose_io::Link { .. }, goose_io::Link { .. }],
    server:   goose_io::Link[2]    = [goose_io::Link { .. }, goose_io::Link { .. }],
    open:     i64                  = 0,
    joined:   bool                 = false,
    step:     i64                  = 0,
    t:        i64                  = 0,
}

fn rig_start(io: goose_io_memory::Loop&, r: Rig&) {
    let a, ea = io.listen("127.0.0.1:7001");
    let b, eb = io.listen("127.0.0.1:7002");
    r.l0 = a;
    r.l1 = b;
    r.client[0] = io.dial("127.0.0.1:7001", 0);
    r.client[1] = io.dial("127.0.0.1:7002", 0);
}

// Notes the event; true once all four links are open. Relays the two accepted ends.
fn rig_event(io: goose_io_memory::Loop&, r: Rig&, log: kit::Log&, ev: goose_io::Event) -> bool {
    kit::note(log, io, ev);
    match ev {
        Opened e => {
            if e.listener == r.l0 { r.server[0] = e.link; }
            else if e.listener == r.l1 { r.server[1] = e.link; }
            r.open++;
            if r.open == 4 && !r.joined {
                r.joined = true;
                kit::check(io.relay(r.server[0], r.server[1]) == goose_io::RelayStatus.Started, "fixture: relay of two open links");
                return true;
            }
        },
        _ => {},
    }
    return false;
}

fn peer_reset_ends_both() {
    var io = goose_io_memory::Loop { .. };
    use_fault(io);
    var r = Rig { .. };
    var log = kit::Log { .. };
    rig_start(io, r);
    io.serve() { io, ev =>
        if rig_event(io, r, log, ev) { io.reset(r.client[0]); }
        kit::stop_after(io, ev, 1000);
    };
    kit::check(kit::closed_once(log, r.server[0], goose_io::CloseReason.PeerReset), "the relayed link whose peer reset ends with PeerReset");
    kit::check(kit::closed_once(log, r.server[1], goose_io::CloseReason.Error), "its relay partner ends with Error, never PeerReset");
}

fn transport_error_ends_both() {
    var io = goose_io_memory::Loop { .. };
    use_fault(io);
    var r = Rig { .. };
    var log = kit::Log { .. };
    rig_start(io, r);
    io.serve() { io, ev =>
        if rig_event(io, r, log, ev) { io.break_transport(r.server[0]); }
        kit::stop_after(io, ev, 1000);
    };
    kit::check(kit::closed_once(log, r.server[0], goose_io::CloseReason.Error), "the relayed link whose transport failed ends with Error");
    kit::check(kit::closed_once(log, r.server[1], goose_io::CloseReason.Error), "its relay partner ends with Error");
}

fn library_close_ends_both() {
    var io = goose_io_memory::Loop { .. };
    use_fault(io);
    var r = Rig { .. };
    var log = kit::Log { .. };
    rig_start(io, r);
    io.serve() { io, ev =>
        if rig_event(io, r, log, ev) { io.close(r.server[0]); }
        kit::stop_after(io, ev, 1000);
    };
    kit::check(kit::closed_once(log, r.server[0], goose_io::CloseReason.Local), "closing one end of a relay ends it with Local");
    kit::check(kit::closed_once(log, r.server[1], goose_io::CloseReason.Local), "its relay partner ends with Local");
}

fn main() {
    peer_reset_ends_both();
    transport_error_ends_both();
    library_close_ends_both();
    kit::finish();
}
