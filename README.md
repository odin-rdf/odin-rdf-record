# odin-rdf-record

A tamper-evident RDF **system of record** for Odin: an append-only, hash-chained,
segmented log is the only durable representation of the dataset, and everything
queryable — a pointer-free fact table, a dictionary arena, sorted permutations —
is a memory-resident projection rebuilt from it by replay on every start. The
running store is a cache of the record, never a second authority. What that
buys, in order of why the repository exists:

- **Independent verifiability.** The chain over epochs is checkable by a third
  party from the format specification alone — framing, CRC-32C, SHA-256,
  big-endian integers — without this repository's code. Verification runs on
  every start, not as a scheduled job.
- **History by construction.** Nothing is ever deleted or rewritten; every
  generation of every quad keeps its `[Assert, Retract)` interval, so "who
  changed what, and when, and why" is a range scan, and every answer is
  checkable against the hash chain.
- **Attributed, atomic change.** One committed transaction is one epoch,
  carrying actor and reason as ordinary RDF terms — the *why* of a change is
  itself data.
- **Epoch-pinned reads.** A snapshot is a value, not a lock or a transaction;
  any historical epoch is readable at any time, at no retention cost.

## Status: design

Implementation has not begun. The founding documents in [`doc/design/`](doc/design/)
specify the on-disk format ([`log.md`](doc/design/log.md)), the resident layout
and the pattern-matching API ([`api.md`](doc/design/api.md)), and the premises
both inherit ([`architecture.md`](doc/design/architecture.md)).
`.metis/vision.md` is the strategic source of truth, and the phase-0 ADRs under
`.metis/adrs/` record the decisions that must be settled before the first
record is written — several of them are frozen at first write and are not
revisable afterwards.

## Position in the family

A second store, beside [odin-rdf-store](https://github.com/odin-rdf/odin-rdf-store),
not a replacement for it and not a fork of it. The two answer different
premises and share no contracts:

|  | odin-rdf-store | odin-rdf-record |
|---|---|---|
| durable form | LMDB B+tree, format v2 | append-only hash-chained log |
| read model | a read transaction *is* the snapshot (`STORE-A-0007`) | a `Snapshot` is a 24-byte value over immutable resident structures |
| indices | on disk, three permutations | in memory, rebuilt by replay |
| history | epoch-suffixed index keys, `match_history` | every fact generation resident, one prefix range |
| verifiability | trusts the backend | third-party chain verification, by design |

Both consume [odin-rdf-parser](https://github.com/odin-rdf/odin-rdf-parser) and
nothing else. [odin-rdf-shacl](https://github.com/odin-rdf/odin-rdf-shacl) and
[odin-rdf-sparql](https://github.com/odin-rdf/odin-rdf-sparql) target the
store today; consuming this repository's snapshot API is future work tracked
on their side once the API here is real.

## Layout

```
record/       the package: log, replay, resident store, snapshot API
doc/design/   the founding documents (the spec; see doc/design/README.md)
.metis/       vision, ADRs, initiatives — the why behind the contracts
```

## Commands

```
make test    # the test suite
make check   # vet every package with -vet -strict-style
make help    # list targets
make clean   # remove build/
```

There is deliberately no `Term_ID` width matrix here: this store fixes both of
its ID widths by design — `u64` on disk, `u32` resident with an inline range —
because the inline encoding is frozen at first write (`api.md` §3.3) and a
build-time knob would put that freeze at the mercy of a flag.

## License

MIT — see [LICENSE](LICENSE).
