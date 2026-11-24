## ADDED Requirements

### Requirement: The kernel TLS capability has a page
`docs/capabilities/kernel-tls.md` SHALL exist with the sections every capability page has, and SHALL explain the split between the library's handshake and the loop's record layer, reading by records before install, what relay and files gain, and when a user-space TLS wrapper is the better choice. Its examples SHALL be quoted from `examples/capabilities/tls_offload.goose` and its test, and the index SHALL have its row.

#### Scenario: A reader deciding whether to use it
- **WHEN** a library author reads the "When to use it" section of `docs/capabilities/kernel-tls.md`
- **THEN** it says to install keys when a TLS server or proxy needs relay, files or less copying, and to keep a user-space TLS wrapper when the loop does not supply kernel-tls or the cipher is not supported

#### Scenario: The page check
- **WHEN** the capability page check runs after this change
- **THEN** it finds the page, every section, every one of `install_tls_send` and the other operations and events of kernel-tls named under "What it is", and a checked example
