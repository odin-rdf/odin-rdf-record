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

## Status: the log of record is implemented — format version 1

The log layer is real (RECORD-I-0001, 2026-08-19): the encoding layer with
golden vectors computed independently of the code, the single-writer append
path (append → fsync → acknowledge, crash-swept at every operation cut
point), the open path (full chain verification at every open, torn-tail
recovery under the position rule), replay through a consumer seam the
resident store will bind to, and the `record` CLI (`verify`, `dump`,
`head`). The proof layer is part of the suite, not a promise: an
independent Python verifier written from `log.md` alone
([`tests/verify/rdflog_verify.py`](tests/verify/rdflog_verify.py)) must
agree with the Odin implementation verdict for verdict over a shared fault
corpus on every `make test`, and a synthetic ISMS-shaped log (~4×10⁵ ops,
~10⁵ terms) is verified and replayed under the vision's sub-second
criterion — measured at tens to hundreds of milliseconds in both of
`log.md` §9's epoch shapes.

Not yet built: the memory-resident projection (fact table, dictionary
arena, permutations), the snapshot API, and `Apply` — the next
initiatives. The founding documents in [`doc/design/`](doc/design/) remain
the spec: the on-disk format ([`log.md`](doc/design/log.md)), the resident
layout and the pattern-matching API ([`api.md`](doc/design/api.md)), and
the premises both inherit ([`architecture.md`](doc/design/architecture.md)).
`.metis/vision.md` is the strategic source of truth, and the ADRs under
`.metis/adrs/` record the decisions frozen at first write — the format now
holds real bytes, so they are no longer revisable.

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
tool/         the record CLI: verify, dump, head — the auditor's read surface
doc/design/   the founding documents (the spec; see doc/design/README.md)
.metis/       vision, ADRs, initiatives — the why behind the contracts
```

## Commands

```
make test    # the test suite (builds the CLI first; tests/tool drives it)
make check   # vet every package with -vet -strict-style
make tool    # build the record CLI into build/record
make help    # list targets
make clean   # remove build/
```

`make test` needs `python3`: the cross-implementation suite runs the
independent verifier in `tests/verify/` over a fault corpus and requires
both implementations to agree verdict for verdict.

The CLI is the read surface an auditor gets (`log.md` §12 q6):

```
build/record verify <dir>                    # full chain verification; head hash and last epoch
build/record head <dir>                      # derived head beside the advisory HEAD file
build/record dump [--format=nquads|json] <dir>   # every fact operation, terms resolved
```

All three are read-only. Exit codes: 0 clean, 2 a torn tail was found
(reported, never repaired here), 1 anything else. A dump renders the log —
the sequence of operations, retractions marked as events — not the graph
they produce.

There is deliberately no `Term_ID` width matrix here: this store fixes both of
its ID widths by design — `u64` on disk, `u32` resident with an inline range —
because the inline encoding is frozen at first write (`api.md` §3.3) and a
build-time knob would put that freeze at the mercy of a flag.

## License

MIT — see [LICENSE](LICENSE).
