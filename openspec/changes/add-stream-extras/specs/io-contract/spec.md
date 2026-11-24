## MODIFIED Requirements

### Requirement: Each capability is named by its parts
The capabilities SHALL be half-close (`shutdown_write`, `set_keep_open_on_eof`, `PeerEof`), sizing (`send_room`, `send2`), abort (`reset`), inspection (`peer_address`, `stop_listening`), batching (`PassEnd`), unix (the address form `unix:/path`), relay (`relay`, `relayed_bytes`), peek (`peek`, `wait_input`, `discard_input`, `Input`), revoke (`discard_unsent`, `write_deadline`), wake (`waker`, `wake`, `wake_with`, `Woken`) limits (`set_limit`, `Expired`), files (`open_file`, `close_file`, `send_file`), loans (`loan`, `loan_bytes`, `send_loan`, `release_loan`), parts (`send_parts`) and addresses (`local_address`, `original_destination`).

#### Scenario: An operation that was removed
- **WHEN** a library calls `set_user` or `user`, or passes a tag to `listen` or `dial`
- **THEN** the build fails and the error names the call

## ADDED Requirements

### Requirement: A file can be opened for sending
The files capability SHALL offer `open_file(path)` and `close_file(file)`. `open_file` SHALL return an opaque `File` handle and the file's size in bytes, or an invalid handle when the file cannot be opened, and SHALL block the loop on nothing but the open itself. A file closed while a send of it is accepted SHALL remain readable by that send until it completes.

#### Scenario: A file that does not exist
- **WHEN** `open_file` is called with a path that does not exist
- **THEN** it returns an invalid handle, and `send_file` with it returns `Closed`

### Requirement: A file is sent as a range
The files capability SHALL offer `send_file(link, file, offset, len)`, which SHALL behave as `send` of the `len` bytes of the file from `offset`: all or nothing, with the same `SendStatus` values, the same `Full` and `Writable` rules and the same order with other sends on the link. A range outside the file SHALL be refused with `TooLarge`.

#### Scenario: A file is sent
- **WHEN** a library opens a file of 100 KiB and sends it to a peer with `send_file`
- **THEN** the peer receives exactly the file's bytes, in order, and a `send` before and after it arrives before and after

#### Scenario: A range past the end
- **WHEN** `send_file` is called with `offset` and `len` that extend past the file's end
- **THEN** it returns `TooLarge` and sends nothing

### Requirement: A loan is a buffer the loop lends
The loans capability SHALL offer `loan(size)`, `loan_bytes(loan)` and `release_loan(loan)`. `loan` SHALL return a handle to a buffer of at least `size` bytes owned by the loop, or an invalid handle when the loop has none to lend; `loan_bytes` returns the buffer for the library to fill; `release_loan` returns it. A loop SHALL bound the buffers it has lent, so that a library that never releases cannot make memory grow without limit.

#### Scenario: Loans are bounded
- **WHEN** a library takes loans and never releases them
- **THEN** `loan` eventually returns an invalid handle and the loop's memory does not grow beyond its bound

### Requirement: A loan is sent without a copy
The loans capability SHALL offer `send_loan(link, loan, len)`, which SHALL behave as `send` of the first `len` bytes of the buffer: all or nothing, with the same `SendStatus` values and the same `Full` and `Writable` rules. On `Sent` the loop owns the buffer and the handle is stale; on any other result the library keeps the loan. A loop MAY send the bytes without copying them.

#### Scenario: A loan is sent
- **WHEN** a library takes a loan, fills it with 1 KiB and sends it
- **THEN** the peer receives those bytes, and `send_loan` returned `Sent`

#### Scenario: A refused loan is kept
- **WHEN** `send_loan` returns `Full`
- **THEN** the library still holds the loan, receives one `Writable`, and a second `send_loan` of the same loan returns `Sent`

### Requirement: Send parts takes any number of parts as one send
The parts capability SHALL offer `send_parts(link, parts)`, where `parts` is a list of byte ranges. It SHALL behave as one `send` of the ranges joined: its size for `Full` and `TooLarge` is the sum of the lengths, it takes every part or none, and a list longer than the loop's bound returns `TooLarge`.

#### Scenario: Three parts arrive joined
- **WHEN** a library sends three parts with `send_parts`
- **THEN** the peer receives their bytes in order with nothing between them

#### Scenario: All or nothing
- **WHEN** the sum of the parts does not fit in the room of the link
- **THEN** `send_parts` returns `Full`, no part is taken, and one `Writable` follows when the whole sum would fit

### Requirement: Addresses report the local end
The addresses capability SHALL offer `local_address(link)`, which returns the loop's own end of the link as an `Address` in the contract's text form, valid inside the handler of `Closed`, and empty for a link that has not opened, a stale link and a link on a `unix:` path.

#### Scenario: The local end of a link
- **WHEN** a library asks for `local_address` of an accepted link on a listener bound to `127.0.0.1:port`
- **THEN** it returns `127.0.0.1:port` as text

#### Scenario: A stale handle
- **WHEN** it is called with a link whose `Closed` has been handled
- **THEN** it returns an empty address

### Requirement: Addresses report the original destination
The addresses capability SHALL offer `original_destination(link)`, which returns the address the peer connected to before any redirection by the system (a transparent proxy), and the same text as `local_address` when there was none.

#### Scenario: No redirection
- **WHEN** a library asks for `original_destination` of a link that was never redirected
- **THEN** it returns the same text as `local_address`

### Requirement: The stream capabilities are declared and may be used optionally
The files, loans, parts and addresses capabilities SHALL each have a declaration and a query, as every capability does, and a loop that supplies one SHALL declare it. A library SHALL be able to use files, loans and parts optionally, because each has a core path with the same bytes on the wire: reading the file and sending it, sending from the library's own buffer, and joining the parts before one `send`.

#### Scenario: A file server on a loop without files
- **WHEN** a library that uses `send_file` only when the loop declares files is built against a loop that does not
- **THEN** it builds, reads the file itself and sends it with `send`, and the peer receives the same bytes

#### Scenario: Parts on a loop without parts
- **WHEN** a library that uses `send_parts` only when the loop declares parts is built against a loop that does not
- **THEN** it builds and sends the joined parts with one `send`, with the same `Full` and `TooLarge` results for the same sizes

#### Scenario: The query for addresses
- **WHEN** a program asks whether the in-memory loop supplies addresses
- **THEN** it is told that it does, and the core-only loop is told that it does not
