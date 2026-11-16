// goose-io conformance suite: two checks that exist only to test the driver. One passes, one fails on
// purpose. They are in part -1, which a provider's runner never runs.
namespace goose_io_conformance;
import std;
import goose_io;
import conformance.support;

fn selftest_info(id: i64) -> Info {
    if id == 0 { return Info { name: "selftest_pass", req: "the driver", part: -1 }; }
    if id == 1 { return Info { name: "selftest_fail", req: "the driver", part: -1 }; }
    return Info { .. };
}

fn selftest_step<Io>(k: Case&, fx: Fixture, io: Io&, ev: goose_io::Event) -> bool {
    if k.id == 0 { if k.step == 0 { k.step = 1; k.finish(); } return true; }
    if k.id == 1 { if k.step == 0 { k.step = 1; k.fail("this check fails on purpose"); } return true; }
    return false;
}
