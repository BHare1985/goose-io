#!/usr/bin/env bash
# The system-call gate of the epoll event loop: tcprouter's http_hello (bench/baseline/, see BASELINE.md) against this
# repository's examples/loops/epoll/http_hello.goose, system calls per request under strace. Stores the table under bench/results/.
set -eu
cd "$(dirname "$0")/.."
[ -x bench/baseline/http_hello ] || { echo "bench/baseline/http_hello is missing: build it as bench/BASELINE.md says"; exit 2; }
cand="${TMPDIR:-/tmp}/epoll-candidate-http_hello"
examples/loops/epoll/build.sh examples/loops/epoll/http_hello.goose "$cand" >/dev/null
stamp="$(date +%Y%m%d-%H%M%S)"; out="bench/results/syscalls-$stamp.txt"
{ echo "# $(date -u +%FT%TZ)  host: $(uname -r), $(lscpu | sed -n 's/^Model name: *//p')"
  echo "# baseline: tcprouter $(cat bench/baseline/COMMIT 2>/dev/null || echo '?') (bench/baseline/http_hello); candidate: goose-io $(git rev-parse --short HEAD)"
  python3 bench/gate_syscalls.py bench/baseline/http_hello "$cand" "$@"; } | tee "$out"
echo "stored: $out"
