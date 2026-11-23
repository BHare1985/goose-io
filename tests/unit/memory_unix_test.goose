// In-memory event loop: the unix capability, the address form `unix:/path` (specs/io-contract of the change add-unix-sockets).
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;

let PATH = "unix:/run/goose-io-test.sock";

// Records every event and stops the loop at `until_ms`.
fn watch(io: goose_io_memory::Loop&, log: kit::Log&, ev: goose_io::Event, until_ms: i64) {
    kit::note(log, io, ev);
    kit::stop_after(io, ev, until_ms);
}

fn run(io: goose_io_memory::Loop&, log: kit::Log&, until_ms: i64) {
    io.serve() { io, ev => watch(io, log, ev, until_ms); };
}

// `unix:` and a path of `n` bytes: "/" and n - 1 letters.
fn path_of(n: i64) -> u8[>..] {
    var out: u8[>..] = [];
    out.append("unix:/");
    for i in n - 1 { out.push('x'); }
    return out;
}

fn bad_address_listen(io: goose_io_memory::Loop&, text: const u8[:], what: const u8[:]) {
    let l, err = io.listen(text);
    kit::check(!goose_io::is_listener(l) && err.kind == goose_io::ListenErrorKind.BadAddress, what);
}

// --- a listener and a dial on a path ---------------------------------------------------------------------------

fn joined_event<Io>(p: kit::Pair&, log: kit::Log&, io: Io&, ev: goose_io::Event) {
    if kit::track(p, log, io, ev) {
        kit::check(io.send(p.client, "ping") == goose_io::SendStatus.Sent, "fixture: the dialled end sends");
        kit::check(io.send(p.server, "pong") == goose_io::SendStatus.Sent, "fixture: the accepted end sends");
        kit::check(goose_io::is_empty(io.peer_address(p.client)), "the dialled end of a path link has no peer address");
        kit::check(goose_io::is_empty(io.peer_address(p.server)), "the accepted end of a path link has no peer address");
    }
    kit::stop_after(io, ev, 300);
}

fn joined() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var p = kit::Pair { .. };
    let l, err = io.listen(PATH);
    kit::check(goose_io::is_listener(l) && !goose_io::failed(err), "listen on a path succeeds");
    kit::check(io.listener_port(l) == 0, "listener_port of a path listener is 0");
    p.client = io.dial(PATH, 0);
    io.serve() { io, ev => joined_event(p, log, io, ev); };
    kit::check(kit::kinds_of(log, p.client) == "ODC" || kit::kinds_of(log, p.client) == "OD", "the dialled end opens and receives");
    kit::check(kit::data_of(log, p.server) == "ping", "bytes sent by the dialling end arrive in order");
    kit::check(kit::data_of(log, p.client) == "pong", "bytes sent by the accepting end arrive in order");
    let i = kit::first_for(log, kit::OPENED, p.server);
    kit::check(i >= 0 && goose_io::same(log.entries[i].listener, l), "the accepted link carries the listener's handle");
    let j = kit::first_for(log, kit::OPENED, p.client);
    kit::check(j >= 0 && !goose_io::is_listener(log.entries[j].listener), "the dialled link carries no listener");
}

// --- a path is held by one listener, and conflicts only with itself -------------------------------------------

fn held() {
    var io = goose_io_memory::Loop { .. };
    let a, a_err = io.listen("unix:/run/a.sock");
    kit::check(goose_io::is_listener(a), "fixture: listen on /run/a.sock");
    let again, again_err = io.listen("unix:/run/a.sock");
    kit::check(!goose_io::is_listener(again) && again_err.kind == goose_io::ListenErrorKind.AddressInUse && again_err.code != 0, "a second listen on a held path: AddressInUse with a code");
    let b, b_err = io.listen("unix:/run/b.sock");
    kit::check(goose_io::is_listener(b), "a different path does not conflict");
    let num, num_err = io.listen("0.0.0.0:8080");
    kit::check(goose_io::is_listener(num), "a numeric address does not conflict with a path");
    let num2, num2_err = io.listen("127.0.0.1:8080");
    kit::check(!goose_io::is_listener(num2) && num2_err.kind == goose_io::ListenErrorKind.AddressInUse, "fixture: numeric conflicts are as before");
    io.stop_listening(a);
    let free, free_err = io.listen("unix:/run/a.sock");
    kit::check(goose_io::is_listener(free) && !goose_io::same(free, a), "the path is free again once its listener is stopped, with a new handle");
    io.hold("unix:/run/held.sock");
    let h, h_err = io.listen("unix:/run/held.sock");
    kit::check(!goose_io::is_listener(h) && h_err.kind == goose_io::ListenErrorKind.AddressInUse, "a held path: AddressInUse");
}

// --- nothing listens ------------------------------------------------------------------------------------------

fn refused() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    let link = io.dial("unix:/run/nobody.sock", 0);
    run(io, log, 100);
    kit::check(kit::kinds_of(log, link) == "C", "a dial to a path nothing listens on gives exactly one Closed and no Opened");
    kit::check(kit::failed_with(log, link, goose_io::ConnectFailure.Refused), "and the reason is Refused");
}

// --- malformed paths ------------------------------------------------------------------------------------------

fn malformed() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var nul: u8[>..] = [];
    nul.append("unix:/a");
    nul.push(0);
    nul.append("b");
    let long = path_of(104);
    let texts: const u8[:][5] = ["unix:", "unix:run/x.sock", "unix:@name", nul[..], long[..]];
    var links: goose_io::Link[5] = [goose_io::Link { .. }; 5];
    for i in 5 { links[i] = io.dial(texts[i], 0); }
    bad_address_listen(io, "unix:", "listen on an empty path: BadAddress");
    bad_address_listen(io, "unix:run/x.sock", "listen on a relative path: BadAddress");
    bad_address_listen(io, "unix:@name", "listen on an abstract name: BadAddress");
    bad_address_listen(io, nul[..], "listen on a path with a NUL byte: BadAddress");
    bad_address_listen(io, long[..], "listen on a path of 104 bytes: BadAddress");
    run(io, log, 100);
    for i in 5 {
        kit::check(kit::kinds_of(log, links[i]) == "C" && kit::failed_with(log, links[i], goose_io::ConnectFailure.BadAddress), "a malformed path ends the dial with one Closed of kind BadAddress");
    }
}

fn longest() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    var p = kit::Pair { .. };
    let text = path_of(103);
    kit::check(text.len == 5 + 103, "fixture: the path is 103 bytes");
    let l, err = io.listen(text[..]);
    kit::check(goose_io::is_listener(l), "listen on a path of 103 bytes succeeds");
    p.client = io.dial(text[..], 0);
    io.serve() { io, ev => joined_event(p, log, io, ev); };
    kit::check(kit::count(log, kit::OPENED) == 2, "a dial to it opens both ends");
}

// --- scripted peers at a path ---------------------------------------------------------------------------------

fn peers() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    let accepting = io.add_peer();
    io.peer_accept(accepting, "unix:/run/db.sock");
    io.peer_send(accepting, 10, "hello");
    let refusing = io.add_peer();
    io.peer_refuse(refusing, "unix:/run/no.sock");
    io.fail_dials("unix:/run/denied.sock", goose_io::ConnectFailure.Denied);
    io.silent("unix:/run/silent.sock");
    let ok = io.dial("unix:/run/db.sock", 0);
    let no = io.dial("unix:/run/no.sock", 0);
    let denied = io.dial("unix:/run/denied.sock", 0);
    let quiet = io.dial("unix:/run/silent.sock", 200);
    run(io, log, 400);
    kit::check(kit::data_of(log, ok) == "hello", "a peer waiting at a path accepts the dial and sends its bytes");
    kit::check(kit::failed_with(log, no, goose_io::ConnectFailure.Refused), "a peer refusing at a path refuses the dial");
    kit::check(kit::failed_with(log, denied, goose_io::ConnectFailure.Denied), "fail_dials on a path fails the dial with that kind");
    kit::check(kit::failed_with(log, quiet, goose_io::ConnectFailure.TimedOut), "a silent path ends the dial with TimedOut when connect_ms passes");

    var io2 = goose_io_memory::Loop { .. };
    var log2 = kit::Log { .. };
    let connecting = io2.add_peer();
    let l, err = io2.listen("unix:/run/in.sock");
    io2.peer_connect(connecting, "unix:/run/in.sock", 10);
    io2.peer_send(connecting, 20, "from peer");
    run(io2, log2, 100);
    kit::check(kit::count(log2, kit::OPENED) == 1, "a scripted peer can connect to a listener on a path");
    kit::check(kit::count(log2, kit::DATA) == 1, "and its bytes arrive");
}

// --- a loop that does not supply the capability refuses the form --------------------------------------------------

fn refused_by<Io>(io: Io&, log: kit::Log&, what: const u8[:]) {
    let l, err = io.listen(PATH);
    kit::check(!goose_io::is_listener(l) && err.kind == goose_io::ListenErrorKind.BadAddress, what);
    let link = io.dial(PATH, 0);
    io.serve() { io, ev => kit::note(log, io, ev); kit::stop_after(io, ev, 100); };
    kit::check(kit::kinds_of(log, link) == "C" && kit::failed_with(log, link, goose_io::ConnectFailure.BadAddress), what);
}

fn refusing() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.unix_paths = false;
    var log = kit::Log { .. };
    refused_by(io, log, "the in-memory loop configured to refuse the form: BadAddress for listen and dial");
    // a numeric address still works
    var io2 = goose_io_memory::Loop { .. };
    io2.cfg.unix_paths = false;
    let l, err = io2.listen("127.0.0.1:8080");
    kit::check(goose_io::is_listener(l), "and a numeric address is untouched");
}

// --- the URL spelling unix:///path (task capability 6) --------------------------------------------------------------

// `unix://` and a path of `n` bytes: "/" and n - 1 letters.
fn url_of(n: i64) -> u8[>..] {
    var out: u8[>..] = [];
    out.append("unix://");
    out.push('/');
    for i in n - 1 { out.push('x'); }
    return out;
}

fn url_dials(from: const u8[:], to: const u8[:], what: const u8[:]) {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    let l, err = io.listen(from);
    kit::check(goose_io::is_listener(l) && io.listener_port(l) == 0, what);
    let link = io.dial(to, 0);
    run(io, log, 100);
    kit::check(kit::count(log, kit::OPENED) == 2, what);
}

fn url_spelling() {
    url_dials("unix:/run/u.sock", "unix:///run/u.sock", "a listener on unix:/p is reached by a dial to unix:///p");
    url_dials("unix:///run/u.sock", "unix:/run/u.sock", "a listener on unix:///p is reached by a dial to unix:/p");
    var io = goose_io_memory::Loop { .. };
    let a, a_err = io.listen("unix:/run/a.sock");
    let b, b_err = io.listen("unix:///run/a.sock");
    kit::check(!goose_io::is_listener(b) && b_err.kind == goose_io::ListenErrorKind.AddressInUse, "a path held under one spelling is held under the other");
    io.stop_listening(a);
    let c, c_err = io.listen("unix:///run/a.sock");
    kit::check(goose_io::is_listener(c), "and free again once its listener is stopped");
    let d, d_err = io.listen("unix:/run/a.sock");
    kit::check(!goose_io::is_listener(d) && d_err.kind == goose_io::ListenErrorKind.AddressInUse, "and held the other way round");
    io.hold("unix:///run/held.sock");
    let h, h_err = io.listen("unix:/run/held.sock");
    kit::check(!goose_io::is_listener(h) && h_err.kind == goose_io::ListenErrorKind.AddressInUse, "hold under one spelling holds the other");
}

fn url_malformed() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    let long = url_of(104);
    let texts: const u8[:][5] = ["unix://host/x.sock", "unix://x.sock", "unix:////x.sock", "unix://", long[..]];
    var links: goose_io::Link[5] = [goose_io::Link { .. }; 5];
    for i in 5 { links[i] = io.dial(texts[i], 0); }
    for i in 5 { bad_address_listen(io, texts[i], "listen on an authority, a doubled slash, an empty or a long URL path: BadAddress"); }
    run(io, log, 100);
    for i in 5 {
        kit::check(kit::kinds_of(log, links[i]) == "C" && kit::failed_with(log, links[i], goose_io::ConnectFailure.BadAddress), "such a dial ends with one Closed of kind BadAddress");
    }
}

fn url_literal() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    let l, err = io.listen("unix:///run/a%20b.sock");
    kit::check(goose_io::is_listener(l), "fixture: a path with % listens");
    let same = io.dial("unix:/run/a%20b.sock", 0);
    let decoded = io.dial("unix:/run/a b.sock", 0);
    let q, q_err = io.listen("unix:///run/q?x#y.sock");
    kit::check(goose_io::is_listener(q), "? and # are ordinary path bytes");
    let q2, q2_err = io.listen("unix:/run/q?x#y.sock");
    kit::check(!goose_io::is_listener(q2) && q2_err.kind == goose_io::ListenErrorKind.AddressInUse, "and the two spellings of that path are one endpoint");
    run(io, log, 100);
    kit::check(kit::first_for(log, kit::OPENED, same) >= 0, "%20 is three literal bytes, the same under both spellings");
    kit::check(kit::failed_with(log, decoded, goose_io::ConnectFailure.Refused), "and is not decoded to a space");
}

fn url_longest() {
    var io = goose_io_memory::Loop { .. };
    var log = kit::Log { .. };
    let text = url_of(103);
    let l, err = io.listen(text[..]);
    kit::check(goose_io::is_listener(l), "a URL-spelled path of 103 bytes listens");
    let link = io.dial(path_of(103)[..], 0);
    run(io, log, 100);
    kit::check(kit::count(log, kit::OPENED) == 2, "and the plain spelling of it reaches the listener");
}

fn url_refused_by() {
    var io = goose_io_memory::Loop { .. };
    io.cfg.unix_paths = false;
    var log = kit::Log { .. };
    let l, err = io.listen("unix:///run/a.sock");
    kit::check(!goose_io::is_listener(l) && err.kind == goose_io::ListenErrorKind.BadAddress, "a loop configured to refuse the form refuses the URL spelling to listen");
    let link = io.dial("unix:///run/a.sock", 0);
    run(io, log, 100);
    kit::check(kit::failed_with(log, link, goose_io::ConnectFailure.BadAddress), "and to dial");
}

fn main() {
    url_spelling();
    url_malformed();
    url_literal();
    url_longest();
    url_refused_by();
    joined();
    held();
    refused();
    malformed();
    longest();
    peers();
    refusing();
    kit::finish();
}
