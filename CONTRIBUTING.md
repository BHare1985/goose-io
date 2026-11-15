# Contributing

The public contract is more important than any one backend. Changes to it must
include behavioral rationale and conformance tests. Backend-specific behavior
must remain behind the same public types and method semantics.

Before adding a backend:

1. Implement resource and timer generations.
2. Pass the shared deterministic contract tests.
3. Add native integration tests for EOF, errors, partial I/O, wake, cancellation,
   and descriptor reuse.
4. Add the platform to CI and document kernel/runtime prerequisites.
5. Do not mark the backend supported until those tests execute on that OS.

Do not add HTTP, TLS, SQL, Redis, pooling, routing, health-check, or proxy policy
to this repository.
