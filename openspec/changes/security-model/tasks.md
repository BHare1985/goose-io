# Tasks

Apply first: the other proposals refer to this document.

## 1. The document

- [ ] 1.1 Write `tests/checks/security.sh` first: it fails when `docs/security.md` is missing, when an operation of `docs/contract.md` has no row in the class table, when a threat row has no answer, or when `README.md` or `docs/libraries.md` lacks the link; run it and verify it fails
- [ ] 1.2 Write `docs/security.md`: the model and what it is not, the class table (every operation, checked against the contract), the threat table (D3), and what is out of scope; verify 1.1 passes except for the links
- [ ] 1.3 Mark each threat row "proposed" with its change name until that change is applied; verify the check accepts the marking

## 2. Links and rules

- [ ] 2.1 Link the document from `README.md` and `docs/libraries.md`; verify 1.1 passes
- [ ] 2.2 Add the classification rule to `CONTRIBUTING.md` and `tests/checks/security.sh` to its check list and layout section; verify `layout.sh` passes

## 3. Everything together

- [ ] 3.1 Read the document for any claim of protection that the mechanisms do not give, and correct it; verify it says first that this is not a sandbox
- [ ] 3.2 Run every command of `CONTRIBUTING.md`; verify they pass
- [ ] 3.3 Run `openspec validate security-model --strict`; verify it is valid and every scenario is named by the check
