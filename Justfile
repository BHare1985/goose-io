# goose-io: the I/O contract package. Pure Goose; nothing here builds C.

check:
    goose check goose_io.goose

test:
    tests/run_tests.sh
    tests/checks/docs.sh
    tests/checks/layout.sh
    tests/conformance/run.sh
    tests/conformance/run.sh --wrapped
    tests/examples/over_wrapper.sh
    tests/examples/imports_test.sh
    tests/conformance/faults.sh
    tests/conformance/table_check.sh

fmt:
    goose format .

fmt-check:
    goose format --check .
