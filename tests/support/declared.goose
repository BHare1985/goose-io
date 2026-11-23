// A loop in a namespace of its own that declares two capabilities and has no operations at all. It is for tests of the
// declarations only: the declaration of a loop is found in the loop's own namespace, whichever that is.
namespace declared;
import std;
import goose_io;

struct Loop { n: i64 = 0 }

fn supplies_relay(io: Loop&) -> goose_io::Supplied { return goose_io::Supplied {}; }
fn supplies_wake(io: Loop&) -> goose_io::Supplied { return goose_io::Supplied {}; }
