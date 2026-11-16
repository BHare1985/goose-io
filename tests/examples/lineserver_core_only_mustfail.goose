// expect: set_keep_open_on_eof
// The line server needs half-close (its header says so): on the loop that supplies only the core it fails to build,
// and the error names the operation it lacks.
import std;
import goose_io from "../..";
import goose_io.tests.support.core_only;
import goose_io.examples.lineserver.server;

fn never() -> bool { false }

fn main() {
    var io = core_only::Core { .. };
    var s = lineserver::LineServer { .. };
    if never() { s.server_event(io, goose_io::Event.Tick { now_ms: 0 }); }
}
