fn has_sizing<Io>(io: Io&) { return io.supplies_sizing(); }
fn has_batching<Io>(io: Io&) { return io.supplies_batching(); }

// Sizing: send_room(link) -> i64, send2(link, first, second) -> SendStatus.
fn require_sizing<Io>(io: Io&) {
}

// Batching: the event PassEnd.
fn require_batching<Io>(io: Io&) {}
