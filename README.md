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

## Status: the store boots and accepts changesets — log, projection, read API, `apply`

The log layer is real (RECORD-I-0001, 2026-08-19): the encoding layer with
golden vectors computed independently of the code, the single-writer append
path (append → fsync → acknowledge, crash-swept at every operation cut
point), the open path (full chain verification at every open, torn-tail
recovery under the position rule), replay through a consumer seam the
resident store binds to, and the `record` CLI (`verify`, `dump`,
`head`). The proof layer is part of the suite, not a promise: an
independent Python verifier written from `log.md` alone
([`tests/verify/rdflog_verify.py`](tests/verify/rdflog_verify.py)) must
agree with the Odin implementation verdict for verdict over a shared fault
corpus on every `make test`.

The resident store is real too (RECORD-I-0002, 2026-08-20): `store_open`
boots end to end — recovery, replay into the pointer-free fact table and
dictionary arena, the six radix-sorted permutations, one atomic
publication, and the writer resumed from the verified walk to continue
the chain (crash-swept across the restart, byte-identical to a writer
that never stopped). Reads go through refcounted epoch-pinned snapshots:
`Match` as binary-searched prefix ranges, streaming iteration under
origin/graph/epoch filters, `Resolve` with the cheap miss, zero-copy
`Bytes` and codec-backed `Term` — every pattern shape proven against a
brute-force oracle. Measured on the synthetic ISMS corpus (~4×10⁵ ops,
~10⁵ terms, optimized build, Apple Silicon dev machine): **full boot
246 ms bulk-loaded / 325 ms fully hand-edited** against the vision's
sub-second criterion, resident footprint **22.9 / 25.9 MB** against
`api.md` §10's ~26–29 MB budget.

Not yet built: `Apply` — the write path with its live-quad preconditions
and the validation hook — the next initiative. *(Superseded 2026-08-20,
RECORD-I-0003: `apply` is the one write path — a changeset of asserts and
retracts in RDF terms, the live-quad preconditions judged against head and
the changeset's own earlier ops, the resident mutation made before the
fsync in state no reader can observe and rolled back exactly on failure,
then append, fsync, publish. The validation hook is a `Validator` wired
once at `store_open`; the default, no validator, is the consumer's stated
posture, and the store alone guarantees only "no epoch commits unjudged
when a judge is wired". Under `Enforce` a refusal writes nothing; under
`Record` the epoch commits and `conforms` reports the verdict — **the log
does not record that a judge objected**; a consumer that wants the verdict
durable writes it as facts.)* The founding documents in
[`doc/design/`](doc/design/) remain the spec: the on-disk format
([`log.md`](doc/design/log.md)), the resident layout and the
pattern-matching API ([`api.md`](doc/design/api.md)), and the premises
both inherit ([`architecture.md`](doc/design/architecture.md)).
`.metis/vision.md` is the strategic source of truth, and the ADRs under
`.metis/adrs/` record the decisions frozen at first write — the format
holds real bytes, so they are no longer revisable.

The write path is real (RECORD-I-0003, 2026-08-20): `apply` is the one
entrance — a changeset of asserts and retracts in RDF terms, refused with a
typed error naming the op where `log.md` §5.3 forbids it, applied to
writer-private state before the fsync and rolled back exactly on failure,
then appended, fsynced, published; a `Validator` seam wired at `store_open`
that sees the post-state as an ordinary snapshot before a byte is durable;
`record/ingest` for Turtle, N-Triples, TriG and N-Quads; an in-memory
`File_Ops` for tests and scratch; and a read path proven safe under a live
writer (the acquire mutex, the published term index). What the log does
**not** record: that a validator objected under `Record` mode — the
verdict is returned, not written. Measured (optimized, Apple Silicon dev
machine, memory seam): **one commit of one or two ops at 4×10⁵ facts costs
31–35 ms** (means over two runs; min 30.5, max 36.2, 24 commits each), the six-permutation
rebuild of `RECORD-A-0005`'s flat copy-on-write being nearly all of it;
the ISMS corpus as one changeset commits in 222–267 ms; resident footprint
**21.2 MB** at 4×10⁵ facts and 5×10⁴ terms (20.0 / 23.0 MB booted from the
generator's logs, down from 22.9 / 25.9 MB once the term map went). On the
production seam a commit adds the disk's fsync.

## Position in the family

> **Amended 2026-08-20 (RECORD-I-0003).** The paragraph and table below
> record the founding stance and stand as written. On 2026-08-20 the family
> decided to move odin-rdf-shacl and odin-rdf-sparql off odin-rdf-store and
> onto this repository — shacl first, sparql second — and to retire
> odin-rdf-store afterwards; the siblings adapt to this store, not the
> reverse. The comparison remains accurate; "not a replacement" no longer
> describes the plan.

A second store, beside [odin-rdf-store](https://github.com/odin-rdf/odin-rdf-store),
not a replacement for it and not a fork of it. The two answer different
premises and share no contracts:

|  | odin-rdf-store | odin-rdf-record |
|---|---|---|
| durable form | LMDB B+tree, format v2 | append-only hash-chained log |
| read model | a read transaction *is* the snapshot (`STORE-A-0007`) | a refcounted `Snapshot` over immutable resident structures (`RECORD-A-0005`) |
| indices | on disk, three permutations | in memory, rebuilt by replay |
| history | epoch-suffixed index keys, `match_history` | every fact generation resident, one prefix range |
| verifiability | trusts the backend | third-party chain verification, by design |

Both consume [odin-rdf-parser](https://github.com/odin-rdf/odin-rdf-parser) and
nothing else. [odin-rdf-shacl](https://github.com/odin-rdf/odin-rdf-shacl) and
[odin-rdf-sparql](https://github.com/odin-rdf/odin-rdf-sparql) target the
store today; the snapshot read API here is real as of 2026-08-20, and
consuming it is future work tracked on their side.

## Layout

```
record/         the package: log, replay, resident store, snapshot API, apply
record/ingest/  opt-in: parsed Turtle/N-Triples/TriG/N-Quads documents → []Op
tool/           the record CLI: verify, dump, head — the auditor's read surface
doc/design/     the founding documents (the spec; see doc/design/README.md)
.metis/         vision, ADRs, initiatives — the why behind the contracts
```

## Example

Open a store, turn a document into ops, commit them as one epoch
(compiled and asserted in [`tests/readme`](tests/readme)):

```odin
fs: rec.Mem_FS // tests and scratch; rec.posix_file_ops() for a directory on disk
s: rec.Store
_, err, _, _ := rec.store_open(&s, "store", rec.mem_file_ops(&fs))
ops, ierr := ingest.turtle(transmute([]byte)string(SOURCE), nil, context.allocator, blank_prefix = "upload-1/")
epoch, _, aerr := rec.apply(&s, {ops = ops, actor = rdf.IRI("http://example.org/alice")})
ingest.ops_destroy(ops, context.allocator)
rec.store_close(&s)
```

`record/ingest` is a subpackage so that the core links no parser unless a
consumer asks for one; `blank_prefix` scopes a document's blank-node labels
(decision 4 of RECORD-I-0003: labels are interned as given, so scoping is
the loader's job and the prefix makes them predictable for a later
retract). The ops own their terms — the parser's validity contract does not
allow borrowing past a statement — and `apply` copies what it interns.

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

The three resident id spaces are three distinct types — `Term_ID` (a term,
dictionary or inlined), `Fact_ID` (a position in the fact table) and `Epoch` (a
commit number) — all `u32` underneath. `Pattern`, `Quad` and `Fact` carry
`Term_ID`s; `scan_next` yields and `snapshot_fact` takes a `Fact_ID`; `store_at`
and `Snapshot.epoch` are `Epoch`. A fact id where a term id goes does not
compile; a conversion is spelled out where one is meant.

## License

MIT — see [LICENSE](LICENSE).
