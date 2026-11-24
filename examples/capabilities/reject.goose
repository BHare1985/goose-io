// A greeting server: a client must begin with the line `HELLO <name>`; one that begins with anything else is reset. It
// shows the abort capability (docs/capabilities/abort.md).
//
// Needs: core and abort (reset).
//
// A well-behaved client gets `welcome <name>` and the link is closed in the ordinary way, which lets the reply reach it.
// A client that sends something else, or no line at all in the first 64 bytes, is not owed a reply, and its unsent
// bytes are not worth waiting for: `reset` ends the link at once and the client sees `PeerReset`, not a clean close.
// An example, not a library to depend on.
namespace reject;
import std;
import goose_io;

let FIRST_LINE_MAX = 64;

struct Conn {
    link:   goose_io::Link = goose_io::Link { .. },
    in_use: bool           = false,
    line:   u8[..64]       = [],        // the first line so far
}

struct Ref { index: i64 = 0 }

root struct Reject {
    listener: goose_io::Listener     = goose_io::Listener { .. },
    welcomed: i64                    = 0,
    rejected: i64                    = 0,
    refs:     goose_io::LinkMap<Ref> = goose_io::LinkMap<Ref> {},
    conns:    Conn[>..]              = [],
}

fn start<Io>(r: Reject&, io: Io&, address: const u8[:]) -> bool {
    let l, err = io.listen(address);
    r.listener = l;
    return goose_io::is_listener(l) && !goose_io::failed(err);
}

fn welcomed_count(r: Reject&) -> i64 { r.welcomed }
fn rejected_count(r: Reject&) -> i64 { r.rejected }

fn _conn_of(r: Reject&, link: goose_io::Link) -> i64 {
    let ref .= r.refs.find(link);
    guard ref != null else { return -1; }
    guard ref.index < r.conns.len && r.conns[ref.index].in_use && goose_io::same(r.conns[ref.index].link, link) else { return -1; }
    return ref.index;
}

fn _newline_at(line: const u8[:]) -> i64 {
    for i in line.len { if line[i] == 10 { return i; } }
    return -1;
}

// doc:begin first_line
// Bytes of the first line arrived. A good line is answered and the link closed; a bad one, or one that is too long, is reset.
fn _on_data<Io>(r: Reject&, io: Io&, c: Conn&, bytes: const u8[:]) {
    if c.line.len + bytes.len > FIRST_LINE_MAX {
        r.rejected++;
        io.reset(c.link);
        return;
    }
    c.line.append(bytes);
    let end = _newline_at(c.line[..]);
    guard end >= 0 else { return; }             // the line is not all here yet
    let greeting = "HELLO ";
    if end > greeting.len && c.line[0..greeting.len] == greeting {
        io.send(c.link, "welcome ");
        io.send(c.link, c.line[greeting.len..end]);
        io.send(c.link, "\n");
        r.welcomed++;
        io.close(c.link);
    } else {
        r.rejected++;
        io.reset(c.link);
    }
}
// doc:end first_line

fn reject_event<Io>(r: Reject&, io: Io&, ev: goose_io::Event) -> bool {
    match ev {
        Opened o => {
            guard goose_io::is_listener(o.listener) && goose_io::same(o.listener, r.listener) else { return false; }
            r.conns.push(Conn { link: o.link, in_use: true, .. });
            r.refs.put(o.link, Ref { index: r.conns.len - 1 });
            return true;
        },
        Data d => {
            let i = r._conn_of(d.link);
            guard i >= 0 else { return false; }
            r._on_data(io, r.conns[i], d.bytes);
            return true;
        },
        Closed x => {
            let i = r._conn_of(x.link);
            guard i >= 0 else { return false; }
            r.conns[i].in_use = false;
            r.refs.drop(x.link);
            return true;
        },
        PeerEof e => { return r._conn_of(e.link) >= 0; },
        _ => { return false; },
    }
}
