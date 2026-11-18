// goose-io: the I/O contract.
//
// One contract between an event loop and the libraries and application that run on it. The event loop
// owns the thread and the sockets, delivers events and performs operations; a library handles events and
// calls operations; the application runs the loop and passes each event to its libraries.
//
// The contract is a core, which every event loop supplies, and eleven groups of extras it may add:
// half-close, sizing, abort, inspection, batching and unix (the address forms `unix:/path` and `unix:///path`), and
// relay, peek, revoke, wake and limits. A library uses what
// it needs, and fails to compile on a loop that lacks an operation; a loop without unix answers BadAddress.
//
// This file is the whole contract surface: the shared types, pure helpers over them, the version, and
// the compile-time checks (require_core and one for each group that has operations) that name every operation of a part.
// The rules (ordering, ownership, backpressure) are in docs/contract.md.
//
// Pure Goose: no C, no extern. Importing this links nothing.
namespace goose_io;
import std;

// --- version -------------------------------------------------------------------------------------

// While the major number is 0 a minor increase may change or remove behaviour.
let VERSION_MAJOR = 0;
let VERSION_MINOR = 3;

// --- handles -------------------------------------------------------------------------------------

// A connection. A slot and a generation: valid from the call or event that created it until its
// Closed event has been delivered. An operation on a Link whose generation no longer matches
// touches nothing. The default value is invalid (generations start at 1).
struct Link { slot: u32 = 0, gen: u32 = 0 }

fn is_valid(l: Link) -> bool { l.gen != 0 }
fn same(a: Link, b: Link) -> bool { a.slot == b.slot && a.gen == b.gen }

// A listening endpoint. The default value (id 0) means "none": a dialled link's Opened carries it.
// An id is never given to a second listener of the same loop, so a handle kept after
// stop_listening can never reach a newer listener.
struct Listener { id: u32 = 0 }

fn is_listener(l: Listener) -> bool { l.id != 0 }
fn same(a: Listener, b: Listener) -> bool { a.id == b.id }

// A numeric endpoint as text: "ip:port" for IPv4, "[ip]:port" for IPv6. Empty when unknown, and for a link made
// on a `unix:/path` or `unix:///path` address (a path does not fit in 56 bytes).
// 56 bytes hold the longest form ("[" + 45 + "]:" + 5).
struct Address { text: u8[..56] = [] }

fn is_empty(a: Address) -> bool { a.text.len == 0 }

// --- results -------------------------------------------------------------------------------------

// What send and send2 return. Only Sent means bytes were taken; every other value means none were.
enum SendStatus {
    Sent,       // every byte was taken; the caller may reuse its memory (not: the peer has them)
    Full,       // does not fit now; one Writable follows once it would fit, however many sends were refused
    TooLarge,   // larger than max_send: will never fit in one call; no Writable follows
    NotOpen,    // the link has not opened yet (a dial in progress)
    Closed,     // the link is closing, closed, write-shut, or the handle is stale
}

// Why a dial did not open. An event loop translates what its system reports into one of these and
// uses Other when it cannot tell; no system error number is part of the contract. The kind is
// for reporting and for choosing how to retry.
enum ConnectFailure {
    Refused,        // the address answered that nothing accepts connections there
    TimedOut,       // no answer within connect_ms
    Unreachable,    // no route to the address, its network or its machine
    Denied,         // the system does not allow this connection
    NoResources,    // the event loop or the system is out of links, descriptors, ports or memory
    BadAddress,     // the text is not an address the loop accepts: malformed, a host name, a zone identifier, a unix path without the unix group
    Other,          // any other failure, and any the event loop cannot classify
}

// Why a link ended. A portable library handles every reason and treats LoopSpecific as Error.
enum CloseReason {
    PeerClosed,         // the peer finished cleanly
    PeerReset,          // the peer aborted
    ConnectFailed { kind: ConnectFailure },     // a dial did not open; no Opened was delivered
    IdleTimeout,        // the event loop's idle limit
    HalfCloseTimeout,   // the event loop's limit on a half-closed link
    Local,              // this side called close or reset
    Shutdown,           // the loop stopped while the link was open
    Error,              // any other failure
    LoopSpecific { code: i32 },     // a reason only this event loop has; the code is for logs, not for control flow
}

fn is_connect_failed(why: CloseReason) -> bool {
    match why {
        ConnectFailed f => true,
        _ => false,
    }
}

fn is_portable(why: CloseReason) -> bool {
    match why {
        LoopSpecific p => false,
        _ => true,
    }
}

// What relay returns. Only Started means the two links are joined; every other value means nothing changed.
enum RelayStatus {
    Started,        // the loop now carries the bytes of each link to the other
    NotOpen,        // a link has not opened yet (a dial in progress)
    Closed,         // a link is closing, closed, or the handle is stale
    AlreadyRelayed, // a link is joined already
}

// A handle that wakes a loop from another thread (the wake group). Fixed size: it may be copied to any thread.
struct Waker { id: u32 = 0, gen: u32 = 0 }

// The kinds of limit a link can run too long in (the limits group).
enum Limit {
    Idle,       // no byte read from or written to the link's transport
    Silent,     // no byte read
    Stalled,    // bytes wait to be sent and the transport accepts none
    HalfOpen,   // the peer's stream has ended and the link stays open
    Age,        // since the link opened
}

// Why listen failed. None means it did not fail.
enum ListenErrorKind { None, AddressInUse, BadAddress, Denied, NoResources, Other }
struct ListenError { kind: ListenErrorKind = ListenErrorKind.None, code: i32 = 0 }

fn failed(e: ListenError) -> bool {
    match e.kind {
        None => false,
        _ => true,
    }
}

// --- events --------------------------------------------------------------------------------------

// What the application's serve block is called with. Read it with `match`.
//
// Every link event carries the link. Nothing is attached to it by the application or a library: a library finds
// its state for an event from the link (a `LinkMap` keyed by it) and recognises an accepted link by the listener
// `Opened` names. See docs/libraries.md, "How an event finds its state".
enum Event {
    // The link is open. `listener` is the listener that accepted it, or none for a dialled link.
    // Always the first event of a link that opens; a dial that fails gets Closed and no Opened.
    Opened { link: Link, listener: Listener },
    // Bytes from the peer, in order. `bytes` belongs to the event loop and is valid only until the
    // handler returns: copy what must be kept.
    Data { link: Link, bytes: const u8[:] },
    // One or more sends returned Full and now any one of them would fit (each on its own, not all
    // together). Delivered once, however many were refused; a Full after it starts again.
    Writable { link: Link },
    // The peer finished sending. Only after set_keep_open_on_eof(link, true); the link can still send.
    PeerEof { link: Link },
    // Always the last event of a link, exactly once.
    Closed { link: Link, why: CloseReason },
    // At least every 100 ms of the loop's clock, and at or after any time asked for with tick_by.
    Tick { now_ms: i64 },
    // The end of a pass that delivered at least one link event: the moment to send what was batched.
    // Always the last event of its pass.
    PassEnd {},
    // The peek group. Bytes are held for the link: `available` of them, which stay with the loop until peek or relay.
    // Delivered once for each wait_input(link, n) with n > 0, when n bytes or the peer's end have arrived, or the bound is reached.
    Input { link: Link, available: i64 },
    // The wake group. One for each wake, on the loop's thread, in the order one thread made them.
    Woken { value: i64 },
    // The limits group. The link has been in the state of `limit` for the time it was armed with; the library decides.
    Expired { link: Link, limit: Limit },
}

// True for Opened, Data, Writable, PeerEof, Closed, Input and Expired. Tick, PassEnd and Woken belong to every library.
fn is_link_event(ev: Event) -> bool {
    match ev {
        Tick t => false,
        PassEnd => false,
        Woken w => false,
        _ => true,
    }
}

// The link of a link event, an invalid Link for Tick, PassEnd and Woken.
fn link_of(ev: Event) -> Link {
    match ev {
        Opened e => e.link,
        Data e => e.link,
        Writable e => e.link,
        PeerEof e => e.link,
        Closed e => e.link,
        Input e => e.link,
        Expired e => e.link,
        _ => Link { .. },
    }
}

// --- a library's state, keyed by link --------------------------------------------------------------

// A table of a library's own values keyed by Link, so that an event finds its state from the link it carries and the
// event loop passes nothing in. It is a helper: a library may keep its state any other way, since the contract
// guarantees a link's identity and lifetime and not the table (docs/libraries.md, "Choosing a table").
//
// Flat: one entry, a generation and a value, for each slot up to the highest a library has used, in one grow-only
// array, so it is an ordinary struct with a single resizable field and a library can hold it in its own state (a
// `root struct` cannot be a field of another struct, which is why the generations and the values are not two arrays).
// Slots are dense on every event loop (the greatest slot is below the greatest number of links valid at once on that
// loop), so the memory is the event loop's peak slot count times the size of an entry, not the library's own peak. A
// lookup is one indexed load and a generation compare, and no operation allocates but `put` growing the table. The
// generation stored beside a value makes a stale or foreign link find nothing. A reference from `find` stays valid
// while later links are put (the array only grows and nothing moves); `drop` resets the entry, so a reference kept past
// `drop` reads an empty value. Use one map only with the links of one event loop: two loops can issue equal slot and
// generation pairs. bench/link_map_bench.goose measures it.
struct LinkEntry<T> { gen: u32 = 0, v: T = T { .. } }       // gen 0 means empty

struct LinkMap<T> {
    entries: LinkEntry<T>[>..] = [],
}

// Stores `v` for `link`, replacing whatever an earlier link of the same slot left. An invalid link is not stored.
fn put<T>(m: LinkMap<T>&, link: Link, v: T) {
    guard link.gen != 0 else { return; }
    while m.entries.len <= link.slot { m.entries.push(LinkEntry<T> { .. }); }
    m.entries[link.slot] = LinkEntry<T> { gen: link.gen, v: v };
}

// The value of `link`, or null for a link that is invalid, stale, never put or dropped.
fn find<T>(m: LinkMap<T>&, link: Link) -> T&? {
    guard link.gen != 0 && link.slot < m.entries.len else { return null; }
    let e .= m.entries[link.slot];
    guard e.gen == link.gen else { return null; }
    return e.v;
}

fn has<T>(m: LinkMap<T>&, link: Link) -> bool {
    return link.gen != 0 && link.slot < m.entries.len && m.entries[link.slot].gen == link.gen;
}

// Empties the entry of `link` and no other, and resets its value. Does nothing for a link that is not in the map.
fn drop<T>(m: LinkMap<T>&, link: Link) {
    guard m.has(link) else { return; }
    m.entries[link.slot] = LinkEntry<T> { .. };
}

// --- what an event loop must supply ---------------------------------------------------------------

// The contract is a core and eleven groups (docs/contract.md). Each check below names every operation of its part
// once, with the contract's argument and result types, and never runs anything. An event loop's root program calls
// require_core and the check of each group it supplies, so that a missing or mistyped operation is a compile error
// here, naming the operation, and not somewhere inside a library. The batching group has no operation, only the
// event PassEnd, and the unix group only an address form, so neither has a check: the conformance suite is what shows that a loop delivers it as the contract says.
//
// Each operation is a function whose first parameter is the event loop.
//
// The core:
//   listen(address) -> Listener, ListenError          listener_port(listener) -> u16
//   dial(address, connect_ms) -> Link                  send(link, bytes) -> SendStatus
//   max_send() -> i64                                  pause_reading(link, paused)
//   close(link)                                        now_ms() -> i64
//   tick_by(at_ms)
//   serve() { io, ev => ... }                          stop(grace_ms)   draining() -> bool
fn require_core<Io>(io: Io&) {
    if _never() {
        let listener, listen_error = io.listen("127.0.0.1:0");
        _is_listener_type(listener);
        _is_listen_error_type(listen_error);
        _is_u16(io.listener_port(listener));

        let link = io.dial("127.0.0.1:1", 0);
        _is_link_type(link);
        _is_send_status_type(io.send(link, "x"));
        _is_i64(io.max_send());
        io.pause_reading(link, false);
        io.close(link);

        _is_i64(io.now_ms());
        io.tick_by(0);

        io.stop(0);
        _is_bool(io.draining());
        io.serve() { inner, ev => _is_event_type(ev); _is_bool(inner.draining()); };
    }
}

// Half-close: set_keep_open_on_eof(link, keep), shutdown_write(link), and the event PeerEof.
fn require_half_close<Io>(io: Io&) {
    if _never() {
        let link = Link { .. };
        io.set_keep_open_on_eof(link, false);
        io.shutdown_write(link);
    }
}

// Sizing: send_room(link) -> i64, send2(link, first, second) -> SendStatus.
fn require_sizing<Io>(io: Io&) {
    if _never() {
        let link = Link { .. };
        _is_i64(io.send_room(link));
        _is_send_status_type(io.send2(link, "x", "y"));
    }
}

// Abort: reset(link).
fn require_abort<Io>(io: Io&) {
    if _never() {
        io.reset(Link { .. });
    }
}

// Inspection: peer_address(link) -> Address, stop_listening(listener).
fn require_inspection<Io>(io: Io&) {
    if _never() {
        let link = Link { .. };
        _is_address_type(io.peer_address(link));
        io.stop_listening(Listener { .. });
    }
}

// Relay: relay(a, b) -> RelayStatus, relayed_bytes(link) -> i64.
fn require_relay<Io>(io: Io&) {
    if _never() {
        let link = Link { .. };
        _is_relay_status_type(io.relay(link, link));
        _is_i64(io.relayed_bytes(link));
    }
}

// Peek: peek(link) -> const u8[:], wait_input(link, n), and the event Input.
fn require_peek<Io>(io: Io&) {
    if _never() {
        let link = Link { .. };
        io.wait_input(link, 0);
        let seen: const u8[:] = io.peek(link);
        _is_i64(seen.len);
    }
}

// Revoke: discard_unsent(link) -> i64, write_deadline(link, at_ms).
fn require_revoke<Io>(io: Io&) {
    if _never() {
        let link = Link { .. };
        _is_i64(io.discard_unsent(link));
        io.write_deadline(link, 0);
    }
}

// Wake: waker() -> Waker, wake(waker, value), and the event Woken. A Waker may be used from any thread.
fn require_wake<Io>(io: Io&) {
    if _never() {
        let w: Waker = io.waker();
        io.wake(w, 0);
    }
}

// Limits: set_limit(link, kind, ms), and the event Expired.
fn require_limits<Io>(io: Io&) {
    if _never() {
        io.set_limit(Link { .. }, Limit.Idle, 0);
    }
}

fn _never() -> bool { false }
fn _is_relay_status_type(v: RelayStatus) {}
fn _is_listener_type(v: Listener) {}
fn _is_listen_error_type(v: ListenError) {}
fn _is_link_type(v: Link) {}
fn _is_address_type(v: Address) {}
fn _is_send_status_type(v: SendStatus) {}
fn _is_event_type(v: Event) {}
fn _is_u16(v: u16) {}
fn _is_i64(v: i64) {}
fn _is_bool(v: bool) {}
