## Context

Section 11 of `docs/contract.md`: "TLS: a wrapping event loop (*Event loops can be layered*; `tests/support/wrapper.goose` shows the layering)". `add-stream-extras` adds files, and relay is in code. Neither can be supplied by a user-space TLS wrapper, because the bytes pass below it. Linux kTLS requires the receive key to be installed at a record boundary of the stream with no protected byte read into user space, and delivers non-application records through a control message. OpenSSL reads record by record during the handshake for this reason. The research attached to this proposal listed kTLS and NIC offload under "KernelCrypto".

## Goals / Non-Goals

**Goals:**

- Let a TLS library or wrapping loop keep the kernel's relay and file paths and stop copying through user space.
- Make the boundary rule (no protected byte read before install) something a library can meet with the contract's operations.
- Test the record rules in memory without real cryptography.

**Non-Goals:**

- A TLS implementation in goose-io.
- Rekeying after install, renegotiation, DTLS, QUIC.
- Promising that a loop uses the NIC rather than the kernel.

## Decisions

### D1. The library handshakes, the loop does records

The handshake needs certificates, policy and a TLS library, which the contract cannot carry. The record layer is the part the kernel offers. The split is the kernel's own (`SOL_TLS` after a user-space handshake).

### D2. Reading by records, so the boundary rule can be met

A loop that reads in large chunks may read past the handshake into the first protected record, after which receive keys cannot be installed. `read_records` makes every `Data` end at a record boundary while the handshake runs. *Alternative:* `install_tls_receive` takes the bytes already read and the loop decrypts them. Rejected: the kernel cannot be given them back, so a loop would need a user-space record layer as well.

### D3. Each direction on its own

TLS 1.3 servers often install send keys before they see the client's Finished. Two operations let a library install each when it is ready.

### D4. Non-application records as an event

Alerts and post-handshake messages must reach the library, and silently dropping them would break session resumption. `TlsRecord` mirrors `Data`: bytes lent until the handler returns.

### D5. A test cipher in memory

The in-memory loop cannot bring a cryptographic library into the tests. `TestOnly` is a reversible transform with a sequence number, enough to check framing, order and the boundary rule. Every real loop refuses it, and the suite checks that a real cipher on the in-memory loop is `Unsupported`.

### D6. Declaration, optional use and the fallback

The capability is declared as every capability is (`rename-groups-to-capabilities`, design D2): a default `fn supplies_kernel_tls<Io>(io: Io&) -> Absent` and a query `fn has_kernel_tls<Io>(io: Io&)` in `goose_io.goose`, and in a loop that supplies it `fn supplies_kernel_tls(io: Loop&) -> goose_io::Supplied`. `require_kernel_tls` names `read_records`, `install_tls_send`, `install_tls_receive` and `send_tls_record` and requires the declaration. A wrapping loop forwards the declaration through `goose_io::has_kernel_tls(w.inner)`.

A TLS wrapping loop uses it optionally over its inner loop: after the handshake, the `Supplied` branch installs both directions and from then on passes `send`, relay and files straight to the inner loop, so the wrapper can declare relay and files itself. The other branch encrypts in user space, as today, and the wrapper declares neither. The example shows both.

### D7. Documentation: the capability's page

The change adds `docs/capabilities/kernel-tls.md` with the fixed sections of `document-capabilities` (D2), so a library author can understand the capability and know when to reach for it without reading the normative contract:

- **What it is:** the four operations, `TlsRecord`, the key types, the boundary rule and the statuses; links to the normative section.
- **When to use it:** a TLS server or proxy that relays, sends files, or moves enough bytes that a copy shows. When not: a loop without kernel-tls, an unsupported cipher, a library that already terminates TLS in a wrapping loop and needs neither relay nor files.
- **How it is commonly used:** read by records from `Opened`, handshake through `Data` and `send`, install send then receive keys, handle `TlsRecord` for tickets and alerts, send `close_notify` before `shutdown_write`; mistakes: installing receive keys while bytes are held, expecting a key update to work after install.
- **Examples:** quoted, through `// doc:begin`/`// doc:end`, from `examples/capabilities/tls_offload.goose`, a small library (a scripted handshake with the `TestOnly` cipher, keys installed for both directions, a file or relay carried as plaintext, and `close_notify` sent at the end), and its test `tests/examples/capabilities/tls_offload_test.goose`, which runs on the in-memory loop, and on the core-only loop, where it encrypts with `TestOnly` itself.
- **Required or optional:** the `// Needs:` and `// Uses if supplied:` headers and the branch on `goose_io::has_kernel_tls`.
- **Supplied by:** the in-memory loop; not the core-only loop; the wrapper when its inner loop does; the mechanism each candidate loop would use (`setsockopt(SOL_TLS, TLS_TX/TLS_RX)` on Linux, KTLS on FreeBSD, NIC TLS offload; no loop without a kernel record layer), linked to the mapping documents.

The page, its index row, the example and its test land in the same change as the operations, and the capability page check (`tests/checks/capability_pages.sh`) fails until they do. `docs/contract.md` gains a section for the capability that holds the normative rules and links to the page.

## Risks / Trade-offs

- [A key update after install cannot be followed] → for now a received key update is delivered as `TlsRecord` and the page says to close the link; an open question tracks rekeying.
- [A test cipher shipped by mistake] → only the in-memory loop knows it, and the suite checks that real loops refuse it.
- [Reading by records costs system calls during the handshake] → only until keys are installed, a few records per link.
- [A capability no program uses yet] → it is specified, tested in memory and documented, and implemented on a real loop only when a program needs it. Its page says which loops supply it, so a library author is not misled.

## Migration Plan

Additive. A loop that does not supply the capability is unchanged: the default declaration answers `Absent`. A TLS wrapping loop that wants the kernel path adds the branch of D6. Others change nothing. The change lands on a branch after `rename-groups-to-capabilities` and `document-capabilities`. Nothing is pushed or tagged without the owner's approval. Reverting is a revert of the merge.

## Open Questions

- Rekeying (TLS 1.3 key update): allow `install_tls_receive` again at a record boundary after a key update `TlsRecord`, as recent Linux kernels do?
- Should the capability report whether the NIC or the kernel does the work? Left to the loop's statistics.
