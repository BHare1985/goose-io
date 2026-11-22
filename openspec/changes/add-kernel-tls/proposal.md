## Why

`docs/contract.md` section 11 places TLS in a wrapping event loop: the wrapper encrypts in user space and passes ciphertext to the loop below. That works on every loop, but it costs two things on a loop that could do better. First, every byte is copied through user space twice, once to encrypt it and once to send it. Second, the wrapper cannot supply relay or files: `splice` and `sendfile` move bytes the wrapper never sees, so a TLS proxy or a TLS static file server loses the kernel paths the plain one has. Linux kernel TLS (`SOL_TLS`, `TLS_TX`/`TLS_RX`), FreeBSD's KTLS and NIC TLS offload take the record layer after a user-space handshake: the library does the handshake, gives the session keys to the socket, and from then on sends and receives plaintext while the kernel or the NIC encrypts. The research behind this proposal called it "KernelCrypto".

## What Changes

- Add the kernel-tls capability. The handshake stays the library's (or a TLS wrapping loop's): it reads and writes handshake records with the core's `send` and `Data`.
- `read_records(link, on)` makes the loop read the link one TLS record at a time, so every `Data` ends at a record boundary and the library can install keys with no byte of the protected stream already read.
- `install_tls_send(link, keys)` and `install_tls_receive(link, keys)` hand the session's keys for one direction to the loop. After them, `send`, `send2`, relay and files carry plaintext and the loop sends records; `Data` carries plaintext of application records.
- `TlsRecord` delivers a received record that is not application data (an alert, a post-handshake message such as a session ticket or key update). `send_tls_record` sends one, for an alert or `close_notify`.
- Add a cipher `TestOnly` that only the in-memory loop supplies and every real loop refuses, so the suite can test the record rules without a cryptographic library.
- Declare the capability as every capability is declared (`supplies_kernel_tls` and `goose_io::has_kernel_tls`, from `rename-groups-to-capabilities`), with a compile-time check `require_kernel_tls` naming every operation. Raise the contract's minor version by one.
- Add a conformance entry point for the capability, a check for every scenario, an implementation in the in-memory loop (the `TestOnly` cipher only), and a named fault for every check.
- Add `docs/capabilities/kernel-tls.md`, the page that explains what the capability is, when a library would use it and when not, and how it is commonly used, with a checked example (`examples/capabilities/tls_offload.goose`). Add its row to the index, as `document-capabilities` requires of every new capability.

Out of scope: the handshake itself, certificate handling, key updates after install (refused for now: an open question), renegotiation, DTLS and QUIC, and choosing between kernel and NIC offload (the loop's configuration).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `io-contract`: adds the kernel TLS capability: the operations `read_records`, `install_tls_send`, `install_tls_receive` and `send_tls_record`, the event `TlsRecord`, and the types `TlsKeys`, `TlsCipher` and `TlsStatus`, and the rules that bind a loop that supplies it.
- `provider-conformance`: adds the kernel TLS suite, its in-memory implementation and faults, and the rule for listing a real loop as supplying it.
- `contract-documentation`: adds the requirement that `docs/capabilities/kernel-tls.md` exists and covers the split between the library's handshake and the loop's record layer, reading by records before install, what relay and files gain, and when a user-space TLS wrapper is the better choice.

## Impact

- **goose-io code:** `goose_io.goose` (the types `TlsKeys`, `TlsCipher`, `TlsStatus`, the event `TlsRecord` and the four operations, the declaration and query, `require_kernel_tls`, minor version), `memory.goose`, `conformance/`, `tests/conformance/`, `tests/unit/`, the new example and its test. Pure Goose.
- **Libraries:** none changes. A TLS wrapping loop or a TLS library may install keys when the loop below supplies kernel-tls and encrypt in user space otherwise.
- **Event loops:** unchanged unless they choose to supply the capability; a loop that does not supply it gets the default declaration, `Absent`, and needs no change. The mapping documents of the candidate loops gain a row (`setsockopt(SOL_TLS, TLS_TX/TLS_RX)` on Linux, KTLS on FreeBSD, NIC TLS offload; no loop without a kernel record layer).
- **Documents:** `docs/capabilities/kernel-tls.md`, its index row, a section in `docs/contract.md`, `docs/history.md`.
- **Order:** applies after `rename-groups-to-capabilities` and `document-capabilities` are accepted. It is independent of `add-stream-extras` and of the other capability proposals: it modifies no requirement another one modifies, so they apply in any order, and whichever lands later rebases only the version number.
- **Toolchain:** none new.
