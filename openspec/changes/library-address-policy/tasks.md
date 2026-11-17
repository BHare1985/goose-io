# Tasks

Ground rules as in `scoped-library-views`. Apply after it.

## 1. Address parsing and rules

- [ ] 1.1 Write `tests/unit/address_policy_test.goose` first: parsing IPv4, bracketed IPv6, IPv4-mapped IPv6, `unix:///path` and `unix://@name`; an unparseable address is refused; CIDR and port range matching; unix prefix matching on whole components; `..` refused; verify it fails
- [ ] 1.2 Add the parser, `TcpRule`, `UnixRule`, `Policy` and the match to `scope.goose` (the layout of the policy is decided here, one resizable field per struct); verify 1.1 passes

## 2. Enforcing the policy

- [ ] 2.1 Add `Denied` to `ListenErrorKind` in `goose_io.goose`, and to the mapping in each event loop and each place that matches on the kind; verify `tests/run_tests.sh` passes
- [ ] 2.2 Write the tests first, in `tests/unit/view_policy_test.goose`: a dial and a listen that match are passed to the loop, those that do not are refused (the loop is not called, `dial` returns the invalid link, `listen` fails with `Denied`), and a policy is required to add a library (a `*_mustfail` test); verify they fail
- [ ] 2.3 Enforce the policy in the view's `dial` and `listen`; add `allow_all()`, `loopback_only()` and `deny_unix()`; verify 2.2 passes

## 3. Example and documents

- [ ] 3.1 Add to `examples/scoped.goose` a library that dials `127.0.0.1:2375` and a unix socket outside its prefix, and show that both are refused while its allowed dial works; verify it passes
- [ ] 3.2 In `docs/contract.md` add `Denied`; in `docs/libraries.md`, "Isolating libraries", add policies, the helpers, the symbolic-link limit and that this is not a firewall; verify `docs.sh` passes

## 4. Everything together

- [ ] 4.1 Add the parse and match to the bench of the view, and record the cost beside the existing figures; verify the bench README names the machine and date
- [ ] 4.2 Run every command of `CONTRIBUTING.md`; verify they pass
- [ ] 4.3 Run `openspec validate library-address-policy --strict`; verify it is valid and every scenario is named by a test
