// Contract types and helpers (specs/io-contract: "Links are generation-checked handles",
// "Every link event names its owner", "The contract states its version").
import std;
import goose_io from "../..";

var failures: i64 = 0;
fn check(ok: bool, what: const u8[:]) {
    if !ok { print("FAIL: ", what); failures++; }
}

// The compiler has no size query for a type holding a slice, so the size of the largest
// Event variant (Data) is measured on a mirror with the slice replaced by two 64-bit words.
struct DataShape { link: goose_io::Link, tag: u16, user: u32, ptr: u64, len: u64 }

fn main() {
    // Link
    let none = goose_io::Link { .. };
    check(!goose_io::is_valid(none), "a default Link is invalid");
    let a = goose_io::Link { slot: 3, gen: 1 };
    let b = goose_io::Link { slot: 3, gen: 2 };
    let c = goose_io::Link { slot: 3, gen: 1 };
    check(goose_io::is_valid(a), "a Link with a generation is valid");
    check(goose_io::same(a, c), "same: equal slot and generation");
    check(!goose_io::same(a, b), "same: generation differs");
    check(!goose_io::same(a, goose_io::Link { slot: 4, gen: 1 }), "same: slot differs");

    // Listener
    let no_listener = goose_io::Listener { .. };
    check(!goose_io::is_listener(no_listener), "a default Listener is none");
    check(goose_io::is_listener(goose_io::Listener { id: 1 }), "a Listener with an id is one");

    // Address
    let empty = goose_io::Address { .. };
    check(goose_io::is_empty(empty), "a default Address is empty");
    check(empty.text.len == 0, "an empty Address has no text");
    check(empty.text.cap >= 53, "an Address holds a bracketed IPv6 address and a port");
    var full = goose_io::Address { .. };
    full.text.append("127.0.0.1:80");
    check(!goose_io::is_empty(full), "an Address with text is not empty");

    // tag_of / is_link_event / user_of / link_of for every variant
    let l = goose_io::Link { slot: 1, gen: 1 };
    let opened:   goose_io::Event = goose_io::Event.Opened { link: l, tag: 11, user: 21, listener: goose_io::Listener { id: 1 } };
    let data:     goose_io::Event = goose_io::Event.Data { link: l, tag: 12, user: 22, bytes: "abc" };
    let writable: goose_io::Event = goose_io::Event.Writable { link: l, tag: 13, user: 23 };
    let eof:      goose_io::Event = goose_io::Event.PeerEof { link: l, tag: 14, user: 24 };
    let closed:   goose_io::Event = goose_io::Event.Closed { link: l, tag: 15, user: 25, why: goose_io::CloseReason.Local };
    let tick:     goose_io::Event = goose_io::Event.Tick { now_ms: 5 };
    let pass_end: goose_io::Event = goose_io::Event.PassEnd {};

    check(goose_io::is_link_event(opened) && goose_io::tag_of(opened) == 11 && goose_io::user_of(opened) == 21, "Opened");
    check(goose_io::is_link_event(data) && goose_io::tag_of(data) == 12 && goose_io::user_of(data) == 22, "Data");
    check(goose_io::is_link_event(writable) && goose_io::tag_of(writable) == 13 && goose_io::user_of(writable) == 23, "Writable");
    check(goose_io::is_link_event(eof) && goose_io::tag_of(eof) == 14 && goose_io::user_of(eof) == 24, "PeerEof");
    check(goose_io::is_link_event(closed) && goose_io::tag_of(closed) == 15 && goose_io::user_of(closed) == 25, "Closed");
    check(!goose_io::is_link_event(tick) && goose_io::tag_of(tick) == 0, "Tick carries no tag");
    check(!goose_io::is_link_event(pass_end) && goose_io::tag_of(pass_end) == 0, "PassEnd carries no tag");
    check(goose_io::same(goose_io::link_of(data), l), "link_of a link event");
    check(!goose_io::is_valid(goose_io::link_of(tick)), "link_of Tick is invalid");

    // Close reasons: a provider-specific reason carries a code and is not portable.
    let why: goose_io::CloseReason = goose_io::CloseReason.Provider { code: 42 };
    check(!goose_io::is_portable(why), "a provider-specific reason is not portable");
    check(goose_io::is_portable(goose_io::CloseReason.PeerReset), "PeerReset is portable");

    // Size: tag byte + the largest payload.
    var shapes: DataShape[>..] = [];
    shapes.push(DataShape { link: l, tag: 0, user: 0, ptr: 0, len: 0 });
    check(bytes_of(shapes).len + 1 <= 32, "Event is at most 32 bytes");

    // Version
    check(goose_io::VERSION_MAJOR == 0 && goose_io::VERSION_MINOR == 1, "contract version is 0.1");

    if failures > 0 { print(failures, " failed"); exit(1); }
}
