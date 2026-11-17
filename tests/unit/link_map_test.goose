// LinkMap: a library's state keyed by Link (specs/io-contract of the change link-keyed-state: *A link map finds state
// by link* and *A reference from a link map stays valid*). The laws are one generic body, `laws`, so a table of
// another layout with the same functions (`put`, `find`, `has`, `drop`) can be run through them: add a `main` that
// declares that table and calls `laws` on it.
import std;
import goose_io from "../..";
import goose_io.tests.support.kit;

struct Item { n: i64 = 0 }

fn link(slot: u32, gen: u32) -> goose_io::Link { goose_io::Link { slot: slot, gen: gen } }

fn value_of<M>(m: M&, l: goose_io::Link) -> i64 {
    let c = m.find(l);
    guard c != null else { return -1; }
    return c.n;
}

fn laws<M>(m: M&, what: const u8[:]) {
    // a value put for a link is found by that link
    m.put(link(3, 1), Item { n: 30 });
    kit::check(m.has(link(3, 1)) && value_of(m, link(3, 1)) == 30, "a value put for a link is found by it");

    // a stale link finds nothing; the new link finds nothing until a value is put for it
    kit::check(!m.has(link(3, 2)) && m.find(link(3, 2)) == null, "the new link of a reused slot finds nothing at first");
    m.put(link(3, 2), Item { n: 31 });
    kit::check(m.find(link(3, 1)) == null && !m.has(link(3, 1)), "a put over a stale entry replaces it: the old link finds nothing");
    kit::check(value_of(m, link(3, 2)) == 31, "and the new link finds the new value");

    // a foreign link finds nothing, whatever its slot
    kit::check(m.find(link(0, 1)) == null && m.find(link(4, 1)) == null && m.find(link(900000, 1)) == null, "a link never put finds nothing");

    // an invalid link is not stored and finds nothing
    m.put(goose_io::Link { .. }, Item { n: 99 });
    kit::check(!m.has(goose_io::Link { .. }) && m.find(goose_io::Link { .. }) == null, "an invalid link is not stored");

    // a held reference survives later puts, including one at a slot far above the current length
    let held .= m.find(link(3, 2));
    guard held != null else { kit::check(false, "fixture: a reference to find"); return; }
    for i in 200 { m.put(link(10 + i as u32, 1), Item { n: i }); }
    m.put(link(100000, 1), Item { n: 7 });
    kit::check(held.n == 31, "a held reference still reads its value after later puts");
    held.n = 32;
    kit::check(value_of(m, link(3, 2)) == 32, "and a write through it is seen by find");
    kit::check(value_of(m, link(100000, 1)) == 7, "a put at a slot far above the length is found");
    kit::check(value_of(m, link(10 + 199, 1)) == 199, "and the entries before it are intact");

    // drop touches one entry
    m.put(link(1, 1), Item { n: 11 });
    m.put(link(2, 1), Item { n: 22 });
    m.drop(link(1, 1));
    kit::check(m.find(link(1, 1)) == null && !m.has(link(1, 1)), "a dropped link finds nothing");
    kit::check(value_of(m, link(2, 1)) == 22 && value_of(m, link(3, 2)) == 32, "and drop touched no other entry");
    m.drop(link(1, 1));
    m.drop(link(1, 5));
    m.drop(link(777777, 1));
    kit::check(value_of(m, link(2, 1)) == 22, "dropping a dropped, a stale or an unknown link does nothing");

    // a reference kept past drop reads an empty value
    let kept .= m.find(link(2, 1));
    guard kept != null else { kit::check(false, "fixture: a reference to link 2"); return; }
    m.drop(link(2, 1));
    kit::check(kept.n == 0, "a reference kept past drop reads an empty value");
    kit::check(m.find(link(2, 1)) == null, "and find returns nothing for the link");

    // a dropped slot can be put again
    m.put(link(2, 3), Item { n: 23 });
    kit::check(value_of(m, link(2, 3)) == 23 && m.find(link(2, 1)) == null, "a slot can be put again after drop");
}

fn main() {
    var m = goose_io::LinkMap<Item> {};
    laws(m, "LinkMap");
    kit::finish();
}
