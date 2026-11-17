// The loop that supplies only the core does not supply the unix group: `unix:/path` is refused with BadAddress, for
// `listen` and for `dial` (specs/provider-conformance of the change add-unix-sockets).
import std;
import goose_io from "../..";
import goose_io.tests.support.kit;
import goose_io.tests.support.core_only;

let PATH = "unix:/run/goose-io-test.sock";

fn main() {
    var io = core_only::Core { .. };
    var log = kit::Log { .. };
    let l, err = io.listen(PATH, 1);
    kit::check(!goose_io::is_listener(l) && err.kind == goose_io::ListenErrorKind.BadAddress, "the core-only loop refuses the form: BadAddress for listen");
    let num, num_err = io.listen("127.0.0.1:8080", 1);
    kit::check(goose_io::is_listener(num), "a numeric address is untouched");
    let link = io.dial(PATH, 2, 0);
    io.serve() { io, ev => kit::note(log, io, ev); kit::stop_after(io, ev, 100); };
    kit::check(kit::kinds_of(log, link) == "C" && kit::failed_with(log, link, goose_io::ConnectFailure.BadAddress), "and for dial: one Closed of kind BadAddress");
    let url_l, url_err = io.listen("unix:///run/goose-io-test.sock", 1);
    kit::check(!goose_io::is_listener(url_l) && url_err.kind == goose_io::ListenErrorKind.BadAddress, "the core-only loop refuses the URL spelling too: BadAddress for listen");
    let url_link = io.dial("unix:///run/goose-io-test.sock", 2, 0);
    var log2 = kit::Log { .. };
    io.serve() { io, ev => kit::note(log2, io, ev); kit::stop_after(io, ev, 100); };
    kit::check(kit::failed_with(log2, url_link, goose_io::ConnectFailure.BadAddress), "and for dial");
    kit::finish();
}
