# Goose I/O contract and reactor development tasks.

check:
    goose check goose_io.goose

lit:
    goose-lit tests/lit

fmt:
    goose format .

fmt-check:
    goose format --check .

# Build and run the native Linux epoll/eventfd shim without the Goose compiler.
native-smoke:
    gcc -std=c11 -O2 -Wall -Wextra -Werror tests/native/epoll_smoke.c shim/epoll.c -o /tmp/goose-io-epoll-smoke
    /tmp/goose-io-epoll-smoke
