// goose-io conformance suite: the driver and the entry points.
//
// The suite is written only against the contract. Both ends of every link are on the event loop under test:
// a check listens and dials on the same loop and makes the peer's behaviour with contract calls (`reset`,
// `shutdown_write`, `pause_reading`, not sending). What calls cannot produce (an address that never answers,
// one that is held, one that nothing listens on) the runner supplies in a Fixture.
//
// The suite is run one group at a time (design D5 of the change simplify-contract): there is an entry point for the
// core and one for each group of extras, and each compiles only the checks of its group, so an event loop that
// supplies the core can run the core suite and nothing that needs more. An event loop's root program is about
// ten lines (docs/event-loops.md):
//
//     import goose_io from "../..";
//     import goose_io.conformance.suite;
//     import goose_io.memory;
//     fn main() {
//         var io = goose_io_memory::Loop { .. };
//         io.silent("10.255.0.1:81");
//         io.hold("127.0.0.1:9999");
//         let fixture = goose_io_conformance::Fixture { silent: "10.255.0.1:81", held: "127.0.0.1:9999", refused: "10.255.0.3:9" };
//         exit(goose_io_conformance::conformance_core_part(io, fixture, 0));
//     }
//
// Only one `stop` can be observed in one `serve`, so the core suite is divided into parts and each part is run by
// its own process: part 0 is every check that does not need `stop` and ends with "stop with nothing open"; parts 1
// to 5 are one scenario of `stop` each. The other groups have part 0 only.
namespace goose_io_conformance;
import std;
import goose_io;
import conformance.support;
import conformance.selftest;
import conformance.handles;
import conformance.net;
import conformance.data;
import conformance.close;
import conformance.time;
import conformance.states;
import conformance.relay;
import conformance.peek;
import conformance.revoke;
import conformance.wake;
import conformance.limits;

// Part -1 holds two checks that exist to test the driver: one passes and one fails on purpose.
let SELFTEST = -1;

fn info(id: i64) -> Info {
    var i = selftest_info(id);
    if i.name.len == 0 { i = handles_info(id); }
    if i.name.len == 0 { i = net_info(id); }
    if i.name.len == 0 { i = data_info(id); }
    if i.name.len == 0 { i = close_info(id); }
    if i.name.len == 0 { i = time_info(id); }
    if i.name.len == 0 { i = states_info(id); }
    if i.name.len == 0 { i = relay_info(id); }
    if i.name.len == 0 { i = peek_info(id); }
    if i.name.len == 0 { i = revoke_info(id); }
    if i.name.len == 0 { i = wake_info(id); }
    if i.name.len == 0 { i = limits_info(id); }
    i.group = group_of(i.name);
    return i;
}

// The group a check belongs to: the group whose operation or event is its subject.
fn group_of(name: const u8[:]) -> i64 {
    if name == "selftest_pass" || name == "selftest_fail" { return GROUP_CORE; }
    if name == "close_after_reply" || name == "close_cancels_a_dial" || name == "close_with_unread_input" || name == "close_when_peer_never_reads" || name == "data_arrives_as_slices" || name == "send_copies_at_once" || name == "send_is_bounded" || name == "writable_once_for_many_refusals" || name == "writable_next_episode" || name == "pause_and_resume_reading" || name == "order_accepted_link" || name == "owner_listener_named" || name == "owner_dial_found_by_link" || name == "states_send" || name == "states_closed_is_final" || name == "states_close" || name == "states_pause" || name == "states_completion" || name == "states_closed_wakes_nothing" || name == "grace_keeps_local" || name == "finished_loop" || name == "setup_before_serve" || name == "handles_pair_unique" || name == "handles_slot_held" || name == "slots_dense" || name == "slot_kept_during_closed" || name == "dial_no_event_inside" || name == "listen_accepts" || name == "listen_held_address" || name == "dial_succeeds" || name == "dial_times_out" || name == "dial_bad_address" || name == "ticks_are_regular" || name == "tick_by_is_prompt" || name == "tick_by_two_deadlines" || name == "stop_with_nothing_open" || name == "stop_link_stays_open" || name == "stop_libraries_finish" || name == "listen_while_draining" || name == "dial_while_draining" || name == "stop_called_twice" || name == "close_leaves_only_closed" || name == "data_slice_stable_in_handler" || name == "send_before_open" || name == "send_after_close" || name == "send_too_large" || name == "writable_after_full" || name == "writable_means_it_fits" || name == "order_failed_dial" || name == "listen_port_zero" || name == "dial_refused" || name == "ipv6_loopback" || name == "handles_stale_reuse" || name == "handles_unset" || name == "events_not_reentrant" { return GROUP_CORE; }
    if name == "states_half_close" || name == "states_keep_open" || name == "peer_eof_closes_by_default" || name == "half_close_then_answer" || name == "full_not_writable_after_shutdown_write" || name == "full_resolved_when_peer_closes" || name == "shutdown_write_ends_sending" || name == "handles_unset_shutdown_write" { return GROUP_HALF_CLOSE; }
    if name == "finished_loop_sizing" || name == "states_sizing" || name == "send2_joins_parts" || name == "send2_all_or_nothing" || name == "send2_refusals" || name == "send_room_is_zero_when_closed" || name == "handles_stale_send_room" || name == "handles_unset_sizing" { return GROUP_SIZING; }
    if name == "states_reset" || name == "reset_aborts_the_peer" || name == "handles_stale_reset" || name == "handles_unset_reset" || name == "events_not_reentrant_after_reset" { return GROUP_ABORT; }
    if name == "finished_loop_inspection" || name == "states_inspection" || name == "listen_stop_keeps_links" || name == "listener_handle_never_reused" || name == "peer_address_names_peer" || name == "peer_address_ipv6" || name == "handles_valid_in_closed" || name == "handles_stale_peer_address" || name == "handles_unset_inspection" { return GROUP_INSPECTION; }
    if name == "pass_end_follows_link_events" || name == "pass_end_not_on_idle_pass" { return GROUP_BATCHING; }
    if name == "unix_listen_dial" || name == "unix_held_path" || name == "unix_nothing_listens" || name == "unix_no_port" || name == "unix_malformed_paths" || name == "unix_longest_path" || name == "unix_url_spelling" || name == "unix_alias_held" { return GROUP_UNIX; }
    if name == "relay_carries_bytes" || name == "relay_refusals" || name == "relay_holds_back_unread" || name == "relay_send_refused_and_close_ends_both" || name == "relayed_bytes_in_closed" { return GROUP_RELAY; }
    if name == "wait_input_gathers" || name == "wait_input_peer_ends" || name == "peek_bound" || name == "discard_input_drops" { return GROUP_PEEK; }
    if name == "discard_unsent_drops" || name == "write_deadline_stops" || name == "write_deadline_moved" { return GROUP_REVOKE; }
    if name == "wake_in_order" { return GROUP_WAKE; }
    if name == "wake_carries_body" { return GROUP_WAKE; }
    if name.len > 6 && starts_with(name, "limit_") { return GROUP_LIMITS; }
    return GROUP_NONE;
}

// What a check of each group is run by: the functions `step` runs the check whose id the case holds, and `takes` says
// whether a check belongs to the suite being run.
fn step<Io>(g: CoreGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if selftest_step(k, fx, io, ev) { return; }
    if handles_core_step(k, fx, io, ev) { return; }
    if net_core_step(k, fx, io, ev) { return; }
    if data_core_step(k, fx, io, ev) { return; }
    if close_core_step(k, fx, io, ev) { return; }
    if time_core_step(k, fx, io, ev) { return; }
    if states_core_step(k, fx, io, ev) { return; }
    k.fail("the check is not known to the driver");
}

fn step<Io>(g: BatchingGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if time_batching_step(k, fx, io, ev) { return; }
    k.fail("the check is not known to the driver");
}

fn step<Io>(g: UnixGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if net_unix_step(k, fx, io, ev) { return; }
    k.fail("the check is not known to the driver");
}

fn step<Io>(g: SizingGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if handles_sizing_step(k, fx, io, ev) { return; }
    if data_sizing_step(k, fx, io, ev) { return; }
    if states_sizing_step(k, fx, io, ev) { return; }
    k.fail("the check is not known to the driver");
}

fn step<Io>(g: HalfCloseGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if handles_half_close_step(k, fx, io, ev) { return; }
    if data_half_close_step(k, fx, io, ev) { return; }
    if close_half_close_step(k, fx, io, ev) { return; }
    if states_half_close_step(k, fx, io, ev) { return; }
    k.fail("the check is not known to the driver");
}

fn step<Io>(g: AbortGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if handles_abort_step(k, fx, io, ev) { return; }
    if close_abort_step(k, fx, io, ev) { return; }
    if states_abort_step(k, fx, io, ev) { return; }
    k.fail("the check is not known to the driver");
}

fn step<Io>(g: InspectionGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if handles_inspection_step(k, fx, io, ev) { return; }
    if net_inspection_step(k, fx, io, ev) { return; }
    if states_inspection_step(k, fx, io, ev) { return; }
    k.fail("the check is not known to the driver");
}

// What the entry point does to the loop before `serve` is called (*A loop is set up, serving, draining or finished*): the
// core listens and dials, and its check `setup_before_serve` requires that the events of those calls arrive from `serve`.
fn setup<Io>(g: CoreGroup&, k: Case&, io: Io&) { setup_before_serve_hook(k, io); }
fn setup<Io>(g: BatchingGroup&, k: Case&, io: Io&) {}
fn setup<Io>(g: UnixGroup&, k: Case&, io: Io&) {}
fn setup<Io>(g: SizingGroup&, k: Case&, io: Io&) {}
fn setup<Io>(g: HalfCloseGroup&, k: Case&, io: Io&) {}
fn setup<Io>(g: AbortGroup&, k: Case&, io: Io&) {}
fn setup<Io>(g: InspectionGroup&, k: Case&, io: Io&) {}

// The checks that run after serve has returned (see AFTER_ID): one function for each group.
fn after<Io>(g: CoreGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) { if !states_core_after(k, io, ev) { k.fail("the check is not known to the driver"); } }
fn after<Io>(g: SizingGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) { if !states_sizing_after(k, io, ev) { k.fail("the check is not known to the driver"); } }
fn after<Io>(g: InspectionGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) { if !states_inspection_after(k, io, ev) { k.fail("the check is not known to the driver"); } }
fn after<Io>(g: BatchingGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) { k.fail("the check is not known to the driver"); }
fn after<Io>(g: UnixGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) { k.fail("the check is not known to the driver"); }
fn after<Io>(g: HalfCloseGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) { k.fail("the check is not known to the driver"); }
fn after<Io>(g: AbortGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) { k.fail("the check is not known to the driver"); }

fn takes(g: CoreGroup&, i: Info) -> bool { i.group == GROUP_CORE }
fn takes(g: BatchingGroup&, i: Info) -> bool { i.group == GROUP_BATCHING }
fn takes(g: SizingGroup&, i: Info) -> bool { i.group == GROUP_SIZING }
fn takes(g: HalfCloseGroup&, i: Info) -> bool { i.group == GROUP_HALF_CLOSE }
fn takes(g: InspectionGroup&, i: Info) -> bool { i.group == GROUP_INSPECTION }
fn takes(g: AbortGroup&, i: Info) -> bool { i.group == GROUP_ABORT }
fn takes(g: UnixGroup&, i: Info) -> bool { i.group == GROUP_UNIX }

fn step<Io>(g: RelayGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if relay_group_step(k, fx, io, ev) { return; }
    k.fail("the check is not known to the driver");
}
fn setup<Io>(g: RelayGroup&, k: Case&, io: Io&) {}
fn after<Io>(g: RelayGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) { k.fail("the check is not known to the driver"); }
fn takes(g: RelayGroup&, i: Info) -> bool { i.group == GROUP_RELAY }
fn conformance_relay_part<Io>(io: Io&, fx: Fixture, part: i64) -> i32 {
    var g = RelayGroup { .. };
    return _run_part(g, io, fx, part);
}

fn step<Io>(g: PeekGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if peek_group_step(k, fx, io, ev) { return; }
    k.fail("the check is not known to the driver");
}
fn setup<Io>(g: PeekGroup&, k: Case&, io: Io&) {}
fn after<Io>(g: PeekGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) { k.fail("the check is not known to the driver"); }
fn takes(g: PeekGroup&, i: Info) -> bool { i.group == GROUP_PEEK }
fn conformance_peek_part<Io>(io: Io&, fx: Fixture, part: i64) -> i32 {
    var g = PeekGroup { .. };
    return _run_part(g, io, fx, part);
}

fn step<Io>(g: RevokeGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if revoke_group_step(k, fx, io, ev) { return; }
    k.fail("the check is not known to the driver");
}
fn setup<Io>(g: RevokeGroup&, k: Case&, io: Io&) {}
fn after<Io>(g: RevokeGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) { k.fail("the check is not known to the driver"); }
fn takes(g: RevokeGroup&, i: Info) -> bool { i.group == GROUP_REVOKE }
fn conformance_revoke_part<Io>(io: Io&, fx: Fixture, part: i64) -> i32 {
    var g = RevokeGroup { .. };
    return _run_part(g, io, fx, part);
}

fn step<Io>(g: WakeGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if wake_group_step(k, fx, io, ev) { return; }
    k.fail("the check is not known to the driver");
}
fn setup<Io>(g: WakeGroup&, k: Case&, io: Io&) {}
fn after<Io>(g: WakeGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) { k.fail("the check is not known to the driver"); }
fn takes(g: WakeGroup&, i: Info) -> bool { i.group == GROUP_WAKE }
fn conformance_wake_part<Io>(io: Io&, fx: Fixture, part: i64) -> i32 {
    var g = WakeGroup { .. };
    return _run_part(g, io, fx, part);
}

fn step<Io>(g: LimitsGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    if limits_group_step(k, fx, io, ev) { return; }
    k.fail("the check is not known to the driver");
}
fn setup<Io>(g: LimitsGroup&, k: Case&, io: Io&) {}
fn after<Io>(g: LimitsGroup&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) { k.fail("the check is not known to the driver"); }
fn takes(g: LimitsGroup&, i: Info) -> bool { i.group == GROUP_LIMITS }
fn conformance_limits_part<Io>(io: Io&, fx: Fixture, part: i64) -> i32 {
    var g = LimitsGroup { .. };
    return _run_part(g, io, fx, part);
}

struct Driver {
    part:     i64      = 0,
    pos:      i64      = 0,
    running:  bool     = false,
    depth:    i64      = 0,
    failures: i64      = 0,
    ran:      i64      = 0,
    stopped:  bool     = false,
    ids:      i64[>..] = [],     // resizable fields come last
}

fn _report(d: Driver&, k: Case&) {
    let i = info(k.id);
    d.ran++;
    if k.verdict == FAILED {
        d.failures++;
        print("FAIL ", i.name, " [", i.req, "]: ", k.why);
    } else {
        print("ok   ", i.name);
    }
}

fn _begin<Io, G>(g: G&, d: Driver&, k: Case&, fx: Fixture, io: Io&) {
    k.reset(d.ids[d.pos]);
    d.running = true;
    k.within(io, 10000);
    let start: goose_io::Event = goose_io::Event.Tick { now_ms: io.now_ms() };
    g.step(k, fx, io, start);
}

fn _drive<Io, G>(g: G&, d: Driver&, k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) {
    d.depth++;
    if d.depth > 1 && d.running { k.fail("an event was delivered from inside the handler of another event"); }
    if d.pos >= d.ids.len {
        if !d.stopped { d.stopped = true; io.stop(0); }
        d.depth--;
        return;
    }
    if !d.running { g._begin(d, k, fx, io); }
    k.sight(ev);
    k.track(io, ev);
    g.step(k, fx, io, ev);
    if k.verdict == RUNNING && io.now_ms() >= k.deadline {
        k.fail("not finished in time on the loop's clock");
    }
    // a check ends when it has failed, or when it is finished and every link it made has closed
    if k.verdict == FAILED || (k.done && k.live <= 0) {
        if k.verdict == RUNNING { k.verdict = PASSED; }
        d._report(k);
        d.pos++;
        d.running = false;
        if d.pos < d.ids.len { g._begin(d, k, fx, io); }
    }
    d.depth--;
}

// Runs one part of the suite for one group on `io`. Returns the number of checks that failed and prints one line for
// each check, naming a failed check and the requirement it proves.
fn _run_part<Io, G>(g: G&, io: Io&, fx: Fixture, part: i64) -> i32 {
    var d = Driver { part: part, .. };
    var k = Case { .. };
    for id in 1000 {
        let i = info(id);
        if i.name.len > 0 && i.part == part && g.takes(i) && id < AFTER_ID { d.ids.push(id); }
    }
    if d.ids.len == 0 { print("FAIL no checks in part ", part); return 1; }
    if part == 0 { g.setup(k, io); }
    io.serve() { io, ev => _drive(g, d, k, fx, io, ev); };
    // serve has returned: a check that waited for `stop` to take effect gives its verdict now
    if d.running {
        k.after = true;
        let end: goose_io::Event = goose_io::Event.Tick { now_ms: io.now_ms() };
        g.step(k, fx, io, end);
        if k.verdict == RUNNING {
            if k.done { k.verdict = PASSED; } else { k.fail("serve returned before the check finished"); }
        }
        d._report(k);
        d.pos++;
    }
    if d.pos < d.ids.len {
        for i in d.ids.len - d.pos {
            print("FAIL ", info(d.ids[d.pos + i]).name, " [", info(d.ids[d.pos + i]).req, "]: serve returned before the check ran");
            d.failures++;
        }
    }
    // the checks of the finished loop: serve has returned, and each is given one step
    for id in 100 {
        let i = info(AFTER_ID + id);
        if i.name.len > 0 && i.part == part && g.takes(i) {
            k.reset(AFTER_ID + id);
            k.after = true;
            let end: goose_io::Event = goose_io::Event.Tick { now_ms: io.now_ms() };
            g.after(k, fx, io, end);
            if k.verdict == RUNNING { if k.done { k.verdict = PASSED; } else { k.fail("the check did not finish on the finished loop"); } }
            d._report(k);
        }
    }
    print(d.ran, " checks run in part ", part, ", ", d.failures, " failed");
    return d.failures as i32;
}

// The checks of the core: what every event loop supplies, and nothing that needs a group.
fn conformance_core_part<Io>(io: Io&, fx: Fixture, part: i64) -> i32 {
    var g = CoreGroup { .. };
    return _run_part(g, io, fx, part);
}

// The checks of the batching group (`PassEnd`).
fn conformance_batching_part<Io>(io: Io&, fx: Fixture, part: i64) -> i32 {
    var g = BatchingGroup { .. };
    return _run_part(g, io, fx, part);
}

// The checks of the half-close group: `shutdown_write`, `set_keep_open_on_eof` and `PeerEof`.
fn conformance_half_close_part<Io>(io: Io&, fx: Fixture, part: i64) -> i32 {
    var g = HalfCloseGroup { .. };
    return _run_part(g, io, fx, part);
}

// The checks of the sizing group: `send_room` and `send2`.
fn conformance_sizing_part<Io>(io: Io&, fx: Fixture, part: i64) -> i32 {
    var g = SizingGroup { .. };
    return _run_part(g, io, fx, part);
}

// The checks of the abort group: `reset`.
fn conformance_abort_part<Io>(io: Io&, fx: Fixture, part: i64) -> i32 {
    var g = AbortGroup { .. };
    return _run_part(g, io, fx, part);
}

// The checks of the inspection group: `peer_address`, and `stop_listening`.
fn conformance_inspection_part<Io>(io: Io&, fx: Fixture, part: i64) -> i32 {
    var g = InspectionGroup { .. };
    return _run_part(g, io, fx, part);
}

// The checks of the unix group: the address form `unix:/path`. The fixture's `unix` is a path the loop may use.
fn conformance_unix_part<Io>(io: Io&, fx: Fixture, part: i64) -> i32 {
    var g = UnixGroup { .. };
    return _run_part(g, io, fx, part);
}
