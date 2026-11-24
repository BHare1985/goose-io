## ADDED Requirements

### Requirement: The kernel TLS capability is named by its parts
The contract SHALL have an optional capability named kernel-tls, made of the operations `read_records`, `install_tls_send`, `install_tls_receive` and `send_tls_record`, the event `TlsRecord`, and the types `TlsKeys`, `TlsCipher` and `TlsStatus`. It SHALL have the declaration `supplies_kernel_tls`, the query `has_kernel_tls` and the compile-time check `require_kernel_tls`, which names every operation of the capability and requires the declaration.

#### Scenario: A loop without the capability
- **WHEN** a library that calls `install_tls_send` without a compile-time branch is built against an event loop that does not declare kernel-tls
- **THEN** the build fails and the error names `supplies_kernel_tls` or `install_tls_send`

#### Scenario: A library that uses it optionally
- **WHEN** a library that calls `install_tls_send` only in the branch taken when `goose_io::has_kernel_tls` is `Supplied` is built against the core-only loop
- **THEN** it builds, and the library keeps encrypting in user space, as a TLS wrapping loop does

### Requirement: Reading by records ends every Data at a record boundary
After `read_records(link, true)`, the loop SHALL deliver the link's bytes so that every `Data` holds whole TLS records only, reading no byte of a record it does not deliver whole. `read_records(link, false)` SHALL return to ordinary delivery. It SHALL have no effect after `install_tls_receive`.

#### Scenario: A handshake read by records
- **WHEN** a client sends its Finished record and its first application record together, on a link reading by records
- **THEN** the server sees the Finished record in one `Data` and can install receive keys before the next record is read

### Requirement: Installing keys hands one direction to the loop
`install_tls_send(link, keys)` SHALL make the loop send every later byte of `send`, `send2`, relay and, when supplied, files as TLS application records under `keys`, numbered from `keys`' sequence number. `install_tls_receive` SHALL do the same for received records, delivering their plaintext as `Data`.

#### Scenario: Plaintext after install
- **WHEN** a library installs send keys and calls `send` with 100 bytes
- **THEN** the peer receives a record that decrypts with the session keys to those 100 bytes

#### Scenario: Relay over kernel TLS
- **WHEN** both directions are installed on a link that is then relayed to a plain link
- **THEN** the plain peer receives the TLS peer's plaintext and the TLS peer receives records

### Requirement: Installing keys returns a status
`install_tls_send` and `install_tls_receive` SHALL return `Installed`, or change nothing and return `Unsupported` for a version or cipher the loop cannot install, `NotAtBoundary` for receive keys while the loop holds received bytes not yet delivered, `NotOpen` for a link that is not open, and `AlreadyInstalled` for a direction already installed.

#### Scenario: A cipher the loop lacks
- **WHEN** a library installs keys with a cipher the loop does not support
- **THEN** it returns `Unsupported` and the link is unchanged, so the library can encrypt in user space

#### Scenario: A real cipher on the in-memory loop
- **WHEN** a test installs AES-GCM keys on the in-memory loop
- **THEN** it returns `Unsupported`

### Requirement: Non-application records are delivered as TlsRecord
After `install_tls_receive`, a received record whose content type is not application data SHALL be delivered as `TlsRecord { link, content_type, bytes }` with its plaintext, valid until the handler returns, in order with the link's `Data`. A received `close_notify` alert SHALL be delivered, then end the stream as the peer's end of stream does.

#### Scenario: A session ticket
- **WHEN** the peer sends a post-handshake session ticket
- **THEN** the library receives `TlsRecord` with the handshake content type and the ticket's bytes, between the `Data` before and after it

### Requirement: A record of any type can be sent
`send_tls_record(link, content_type, bytes)` SHALL send `bytes` as one record of that content type after every byte accepted before it, behaving as `send` for `Full`, `TooLarge` and `Closed`. Before `install_tls_send` it SHALL return `Closed`.

#### Scenario: Close notify
- **WHEN** a library sends a `close_notify` alert with `send_tls_record` and then calls `shutdown_write`
- **THEN** the peer receives the alert record after every application byte, then end of stream
