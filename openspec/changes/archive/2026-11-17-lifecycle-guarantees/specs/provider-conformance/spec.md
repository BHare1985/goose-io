# Spec Delta

## ADDED Requirements

### Requirement: The suite checks every link operation in every state
The suite SHALL check the result of each link operation in each link state that the scenarios of `io-contract` name: core operations in the core suite, and each group's operations in that group's suite. The batching and unix groups have no link operation and SHALL have no such check. The suite SHALL check that a `Closed` send result is final, the keep-open window, and how operations complete. Each check SHALL have a fault of the in-memory event loop that makes it fail.

#### Scenario: A loop that ignores a pause before Opened fails
- **WHEN** the in-memory event loop is made to forget a `pause_reading` call made on a dialling link
- **THEN** the check of pausing before `Opened` fails and names its requirement

#### Scenario: A loop that closes twice fails
- **WHEN** the in-memory event loop is made to deliver a second `Closed` for a second `close` on a closing link
- **THEN** the check of closing twice fails

#### Scenario: A loop that wakes a link after a Closed result fails
- **WHEN** the in-memory event loop is made to deliver a `Writable` owed to a link after `send` has returned `Closed` on it
- **THEN** the check that a `Closed` result is final fails

#### Scenario: A loop that honours a late keep-open fails
- **WHEN** the in-memory event loop is made to apply `set_keep_open_on_eof` called after the link's `Opened` handler has returned
- **THEN** the check of the keep-open window fails

#### Scenario: A loop that forgets a closing link's address fails
- **WHEN** the in-memory event loop is made to return an empty `peer_address` once `close` has been called on a link
- **THEN** the inspection group's check of link states fails

#### Scenario: Group operations stay in their group
- **WHEN** the operations called by the new checks are compared with the groups the checks belong to
- **THEN** each check calls no operation outside the core and its own group

### Requirement: The suite checks how handles are issued
In every part of every group's suite, the driver SHALL record each link handle it is given. The handle `dial` returns and the same handle in that link's `Opened` count as one issuance. The driver SHALL fail `handles_pair_unique` when a pair is issued again or has generation 0. It SHALL fail `handles_slot_held` when a slot is issued while the `Closed` of its previous link is still to be delivered.

#### Scenario: A loop that does not advance the generation fails
- **WHEN** the in-memory event loop is made to reuse a slot without changing its generation
- **THEN** `handles_pair_unique` fails, naming the slot and the generation issued twice

#### Scenario: A loop that reuses a slot early fails
- **WHEN** the in-memory event loop is made to free a slot when `close` is called, before that link's `Closed` is delivered, while still advancing the generation
- **THEN** `handles_slot_held` fails and `handles_pair_unique` does not

#### Scenario: A dialled link seen twice is one issuance
- **WHEN** a check dials a link and later receives that link's `Opened`
- **THEN** neither handle check fails

### Requirement: The suite checks the life of a loop
Every entry point SHALL listen and dial before it calls `serve`, and SHALL check that the events of those calls arrive from `serve`. In a part that calls `stop`, once `serve` has returned, it SHALL check what the operations of its group do on the finished loop, including that `dial` returns the invalid link, and that a second `serve` returns at once. The core suite SHALL check that a link closed before the end of the grace period ends with `Local`, whether it was closed before or after `stop`.

#### Scenario: A loop that accepts sends after serve fails
- **WHEN** the in-memory event loop is made to return `Sent` from `send` once `serve` has returned
- **THEN** the finished-loop check fails

#### Scenario: A loop that issues a link after serve fails
- **WHEN** the in-memory event loop is made to return a valid link from `dial` once `serve` has returned
- **THEN** the finished-loop check fails

#### Scenario: A loop that runs again fails
- **WHEN** the in-memory event loop is made to deliver a `Tick` from a second `serve`
- **THEN** the finished-loop check fails

#### Scenario: A loop that overrides Local with Shutdown fails
- **WHEN** the in-memory event loop is made to keep a closed link whose peer has not read until the end of the grace period, and to end it with `Shutdown`
- **THEN** the check of the end of the grace period fails for the link closed before `stop` and for the link closed after it

### Requirement: The in-memory event loop retires an exhausted slot
The in-memory event loop SHALL retire a slot once the link holding the slot's last generation has had its `Closed` delivered. It SHALL let a test set the generation of the next link a slot issues, so that the retirement can be shown without 2^32 reuses.

#### Scenario: The last generation retires the slot
- **WHEN** a test sets a free slot's next generation to the largest value, a link is issued in that slot, and the link is closed
- **THEN** no later link is issued in that slot, and no later link has generation 0 or any generation the slot issued before

#### Scenario: A retired slot does not lower the link limit
- **WHEN** a slot has been retired on a loop configured with `max_links` of 4, and libraries then open links until four link ends are open
- **THEN** every one of those dials opens, and none of them is issued in the retired slot
