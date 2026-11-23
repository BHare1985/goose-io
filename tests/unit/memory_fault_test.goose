// set_fault switches the in-memory loop to the fault of that name (str() of a Fault variant). A name that is no variant
// matches no fault, so the loop behaves as it does with none.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;

fn main() {
    var io = goose_io_memory::Loop { .. };
    kit::check(!io._fault_is(goose_io_memory::Fault.NoPassEnd), "a new loop has no fault");
    io.set_fault("NoPassEnd");
    kit::check(io._fault_is(goose_io_memory::Fault.NoPassEnd), "a known name sets a fault");
    kit::check(!io._fault_is(goose_io_memory::Fault.TickEvery250), "another fault is not set");
    io.set_fault("TickEvery250");
    kit::check(io._fault_is(goose_io_memory::Fault.TickEvery250) && !io._fault_is(goose_io_memory::Fault.NoPassEnd), "another known name replaces it");
    io.set_fault("NoSuchFault");
    kit::check(!io._fault_is(goose_io_memory::Fault.TickEvery250), "an unknown name matches no fault");
    kit::finish();
}
