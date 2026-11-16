// goose-io: the I/O contract.
//
// One contract between an event loop (a provider) and the libraries and application (the host)
// that run on it. A provider delivers events and performs operations; a library handles events
// and calls operations; the host runs the loop and passes each event to its libraries.
//
// This file is the whole contract surface: the shared types, pure helpers over them, the
// version, and require_provider, which names every operation a provider must supply.
// The rules (ordering, ownership, backpressure) are in docs/contract.md.
//
// Pure Goose: no C, no extern. Importing this links nothing.
namespace goose_io;
import std;

// --- version -------------------------------------------------------------------------------------

// While the major number is 0 a minor increase may change or remove behaviour.
let VERSION_MAJOR = 0;
let VERSION_MINOR = 1;

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

// A numeric endpoint as text: "ip:port" for IPv4, "[ip]:port" for IPv6. Empty when unknown.
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

// Why a dial did not open. A provider translates what its system reports into one of these and
// uses Other when it cannot tell; no system error number is part of the contract. The kind is
// for reporting and for choosing how to retry.
enum ConnectFailure {
    Refused,        // the address answered that nothing accepts connections there
    TimedOut,       // no answer within connect_ms
    Unreachable,    // no route to the network or the host
    Denied,         // the system does not allow this connection
    NoResources,    // the provider or the system is out of links, descriptors, ports or memory
    BadAddress,     // the text is not a numeric address: malformed, a host name, a zone identifier
    Other,          // any other failure, and any the provider cannot classify
}

// Why a link ended. A portable library handles every reason and treats Provider as Error.
enum CloseReason {
    PeerClosed,         // the peer finished cleanly
    PeerReset,          // the peer aborted
    ConnectFailed { kind: ConnectFailure },     // a dial did not open; no Opened was delivered
    IdleTimeout,        // the provider's idle limit
    HalfCloseTimeout,   // the provider's limit on a half-closed link
    Local,              // this side called close or reset
    Shutdown,           // the loop stopped while the link was open
    Error,              // any other failure
    Provider { code: i32 },     // a reason only this provider has; the code is for logs, not for control flow
}

fn is_connect_failed(why: CloseReason) -> bool {
    match why {
        ConnectFailed f => true,
        _ => false,
    }
}

fn is_portable(why: CloseReason) -> bool {
    match why {
        Provider p => false,
        _ => true,
    }
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

// What the host's serve block is called with. Read it with `match`.
//
// Every link event carries the link, the tag given to dial or listen (which library owns it) and
// the user value last set with set_user (which of that library's connections it is; 0 until set).
enum Event {
    // The link is open. `listener` is the listener that accepted it, or none for a dialled link.
    // Always the first event of a link that opens; a dial that fails gets Closed and no Opened.
    Opened { link: Link, tag: u16, user: u32, listener: Listener },
    // Bytes from the peer, in order. `bytes` belongs to the provider and is valid only until the
    // handler returns: copy what must be kept.
    Data { link: Link, tag: u16, user: u32, bytes: const u8[:] },
    // One or more sends returned Full and now any one of them would fit (each on its own, not all
    // together). Delivered once, however many were refused; a Full after it starts again.
    Writable { link: Link, tag: u16, user: u32 },
    // The peer finished sending. Only after set_keep_open_on_eof(link, true); the link can still send.
    PeerEof { link: Link, tag: u16, user: u32 },
    // Always the last event of a link, exactly once.
    Closed { link: Link, tag: u16, user: u32, why: CloseReason },
    // At least every 100 ms of the loop's clock, and at or after any time asked for with tick_by.
    Tick { now_ms: i64 },
    // The end of a pass that delivered at least one link event: the moment to send what was batched.
    // Always the last event of its pass.
    PassEnd {},
}

// True for Opened, Data, Writable, PeerEof and Closed. Tick and PassEnd belong to every library.
fn is_link_event(ev: Event) -> bool {
    match ev {
        Tick t => false,
        PassEnd => false,
        _ => true,
    }
}

// The tag of a link event, 0 for Tick and PassEnd.
fn tag_of(ev: Event) -> u16 {
    match ev {
        Opened e => e.tag,
        Data e => e.tag,
        Writable e => e.tag,
        PeerEof e => e.tag,
        Closed e => e.tag,
        _ => 0,
    }
}

// The user value of a link event, 0 for Tick and PassEnd.
fn user_of(ev: Event) -> u32 {
    match ev {
        Opened e => e.user,
        Data e => e.user,
        Writable e => e.user,
        PeerEof e => e.user,
        Closed e => e.user,
        _ => 0,
    }
}

// The link of a link event, an invalid Link for Tick and PassEnd.
fn link_of(ev: Event) -> Link {
    match ev {
        Opened e => e.link,
        Data e => e.link,
        Writable e => e.link,
        PeerEof e => e.link,
        Closed e => e.link,
        _ => Link { .. },
    }
}

// --- what a provider must supply -----------------------------------------------------------------

// Names every operation of the contract once, with the contract's argument and result types.
// Never runs anything. A provider's root program calls it once, so that a missing or mistyped
// operation is a compile error here and not somewhere inside a library.
//
// The operations, each a function whose first parameter is the provider:
//
//   listen(address, tag) -> Listener, ListenError      listener_port(listener) -> u16
//   stop_listening(listener)
//   dial(address, tag, connect_ms) -> Link             peer_address(link) -> Address
//   send(link, bytes) -> SendStatus                    send2(link, first, second) -> SendStatus
//   send_room(link) -> i64                             max_send() -> i64
//   pause_reading(link, paused)                        set_keep_open_on_eof(link, keep)
//   shutdown_write(link)                               close(link)   reset(link)
//   set_user(link, user)                               user(link) -> u32
//   now_ms() -> i64                                    tick_by(at_ms)
//   serve() { io, ev => ... }                          stop(grace_ms)   draining() -> bool
fn require_provider<Io>(io: Io&) {
    if _never() {
        let listener, listen_error = io.listen("127.0.0.1:0", 1);
        _is_listener_type(listener);
        _is_listen_error_type(listen_error);
        _is_u16(io.listener_port(listener));
        io.stop_listening(listener);

        let link = io.dial("127.0.0.1:1", 1, 0);
        _is_link_type(link);
        _is_address_type(io.peer_address(link));
        _is_send_status_type(io.send(link, "x"));
        _is_send_status_type(io.send2(link, "x", "y"));
        _is_i64(io.send_room(link));
        _is_i64(io.max_send());
        io.pause_reading(link, false);
        io.set_keep_open_on_eof(link, false);
        io.shutdown_write(link);
        io.close(link);
        io.reset(link);
        io.set_user(link, 1);
        _is_u32(io.user(link));

        _is_i64(io.now_ms());
        io.tick_by(0);

        io.stop(0);
        _is_bool(io.draining());
        io.serve() { inner, ev => _is_event_type(ev); _is_bool(inner.draining()); };
    }
}

fn _never() -> bool { false }
fn _is_listener_type(v: Listener) {}
fn _is_listen_error_type(v: ListenError) {}
fn _is_link_type(v: Link) {}
fn _is_address_type(v: Address) {}
fn _is_send_status_type(v: SendStatus) {}
fn _is_event_type(v: Event) {}
fn _is_u16(v: u16) {}
fn _is_u32(v: u32) {}
fn _is_i64(v: i64) {}
fn _is_bool(v: bool) {}
