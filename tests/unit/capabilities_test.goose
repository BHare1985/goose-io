// The core and the capabilities of the contract: each has its own compile-time check, and each has a declaration
// that a loop makes in its own namespace and that the contract answers `Absent` for when it is not made
// (docs/contract.md). The checks never run anything; the declarations are asked by type.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;
import goose_io.tests.support.stub;
import goose_io.tests.support.core_only;
import goose_io.tests.support.declared;
import goose_io.tests.support.wrapper;

fn is_supplied<S>(s: S) -> bool {
    const if same<S, goose_io::Supplied> { return true; } else { return false; }
}

fn main() {
    // the in-memory loop supplies the core and every capability (batching and unix have no operation, and so no check)
    var io = goose_io_memory::Loop { .. };
    goose_io::require_core(io);
    goose_io::require_half_close(io);
    goose_io::require_sizing(io);
    goose_io::require_abort(io);
    goose_io::require_inspection(io);
    kit::check(io.now_ms() == 0 && !io.draining(), "the checks call nothing");

    // a loop with only the core passes the core check
    var stubbed = stub::Core { .. };
    goose_io::require_core(stubbed);
    kit::check(stubbed.max_send() >= 4096, "fixture: the stub is a loop");

    // the in-memory loop declares every capability
    kit::check(is_supplied(goose_io::has_half_close(io)), "memory: half_close");
    kit::check(is_supplied(goose_io::has_sizing(io)), "memory: sizing");
    kit::check(is_supplied(goose_io::has_abort(io)), "memory: abort");
    kit::check(is_supplied(goose_io::has_inspection(io)), "memory: inspection");
    kit::check(is_supplied(goose_io::has_batching(io)), "memory: batching");
    kit::check(is_supplied(goose_io::has_unix(io)), "memory: unix");
    kit::check(is_supplied(goose_io::has_relay(io)), "memory: relay");
    kit::check(is_supplied(goose_io::has_peek(io)), "memory: peek");
    kit::check(is_supplied(goose_io::has_revoke(io)), "memory: revoke");
    kit::check(is_supplied(goose_io::has_wake(io)), "memory: wake");
    kit::check(is_supplied(goose_io::has_limits(io)), "memory: limits");

    // the core-only loop and the stub declare none
    var core = core_only::Core { .. };
    kit::check(!is_supplied(goose_io::has_half_close(core)), "core-only: half_close");
    kit::check(!is_supplied(goose_io::has_sizing(core)), "core-only: sizing");
    kit::check(!is_supplied(goose_io::has_abort(core)), "core-only: abort");
    kit::check(!is_supplied(goose_io::has_inspection(core)), "core-only: inspection");
    kit::check(!is_supplied(goose_io::has_batching(core)), "core-only: batching");
    kit::check(!is_supplied(goose_io::has_unix(core)), "core-only: unix");
    kit::check(!is_supplied(goose_io::has_relay(core)), "core-only: relay");
    kit::check(!is_supplied(goose_io::has_peek(core)), "core-only: peek");
    kit::check(!is_supplied(goose_io::has_revoke(core)), "core-only: revoke");
    kit::check(!is_supplied(goose_io::has_wake(core)), "core-only: wake");
    kit::check(!is_supplied(goose_io::has_limits(core)), "core-only: limits");
    kit::check(!is_supplied(goose_io::has_relay(stubbed)), "stub: relay");

    // a loop in a third namespace that declares relay and wake: exactly those two are supplied
    var third = declared::Loop { .. };
    kit::check(is_supplied(goose_io::has_relay(third)), "declared: relay");
    kit::check(is_supplied(goose_io::has_wake(third)), "declared: wake");
    kit::check(!is_supplied(goose_io::has_peek(third)), "declared: peek is not");
    kit::check(!is_supplied(goose_io::has_limits(third)), "declared: limits is not");

    // the wrapper answers for what it passes through
    var layer = wrapper::Layer { .. };
    kit::check(is_supplied(goose_io::has_half_close(layer)), "wrapper: half_close");
    kit::check(is_supplied(goose_io::has_unix(layer)), "wrapper: unix");
    kit::check(!is_supplied(goose_io::has_relay(layer)), "wrapper: relay is not");

    kit::check(goose_io::VERSION_MAJOR == 0 && goose_io::VERSION_MINOR == 4, "the contract version is 0.4");
    kit::finish();
}
