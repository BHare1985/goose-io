// set_fault switches the in-memory loop to a named fault, and a name it does not know does nothing: it does not
// clear a fault that is already set.
import std;
import goose_io from "../..";
import goose_io.memory;
import goose_io.tests.support.kit;

fn main() {
    var io = goose_io_memory::Loop { .. };
    kit::check(io._fault == goose_io_memory::Fault.None, "a new loop has no fault");
    io.set_fault("NoPassEnd");
    let set = io._fault;
    kit::check(set != goose_io_memory::Fault.None, "a known name sets a fault");
    io.set_fault("NoSuchFault");
    kit::check(io._fault == set, "an unknown name leaves the fault as it was");
    io.set_fault("TickEvery250");
    kit::check(io._fault != set && io._fault != goose_io_memory::Fault.None, "another known name replaces it");
    kit::finish();
}
