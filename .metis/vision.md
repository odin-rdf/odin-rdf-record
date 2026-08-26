---
id: odin-rdf-record
level: vision
title: "odin-rdf-record"
short_code: "RECORD-V-0001"
created_at: 2026-08-19T15:53:53.175284+00:00
updated_at: 2026-08-19T17:42:29.629887+00:00
archived: false

tags:
  - "#vision"
  - "#phase/published"


exit_criteria_met: false
initiative_id: NULL
---

# odin-rdf-record Vision

## Purpose

odin-rdf-record is a tamper-evident RDF **system of record** with a
memory-resident query layer. One representation is durable — an append-only,
hash-chained, segmented log — and everything queryable is derived from it by
replay: a pointer-free fact table, a dictionary arena, sorted permutations,
an epoch table. The running store is a cache of the record, never a second
authority.

Three properties are the point, in order:

1. **Independent verifiability.** A third party can verify the chain over
   epochs from the format specification alone — framing, CRC-32C, SHA-256,
   big-endian integers — without this repository's code. Term *definitions*
   live inside the chain, so the hash covers term meaning, not just integer
   identity.
2. **History by construction.** Nothing is deleted or rewritten; every
   generation of every quad keeps its `[Assert, Retract)` interval and every
   epoch carries actor, reason, and time as ordinary RDF terms. "Who changed
   what, when, and why" is a range scan whose answer is checkable against the
   chain.
3. **Density.** Snapshots are values over immutable resident structures, cheap
   enough that many tenant processes per machine each embed a store, idle
   tenants evict theirs, and a wake is a sub-second replay — the recovery path
   exercised continuously by ordinary traffic.

**Why a sibling rather than growth of odin-rdf-store.** The store's identity
is its LMDB-backed match contract (`STORE-A-0003`, `STORE-A-0007`,
`STORE-A-0008`); this repository's identity is the log-plus-projection thesis.
The two share no durable format, no transaction model, no ID scheme, and
different definitions of what a snapshot is. Bending one into the other would
produce a hybrid carrying both designs' costs; a sibling costs one more
repository, and odin-rdf-store is untouched.

## Current State

Design phase; no implementation. The founding documents in `doc/design/` are
the specification — `architecture.md` (premises, data model, reasoning
appendices), `log.md` (the on-disk format), `api.md` (the resident layout, the
cost model, and the layered pattern-matching API, with §13 deriving the API's
final shape from the first application written against it). They were written
against a Go implementation; the Odin translation notes in
`doc/design/README.md` govern where the languages diverge.

The phase-0 ADRs (`RECORD-A-0001` onwards) hold the decisions that must be
settled before the first record is written — several are frozen at first
write and are not revisable afterwards. All six were decided on 2026-08-19,
`RECORD-A-0001` with its measurement gate run and the result attached — the
inline encoding is now frozen.

odin-rdf-shacl and odin-rdf-sparql target odin-rdf-store today and are
unaffected; their adoption of this repository's snapshot API is tracked on
their side, once that API is real.

> **Amended 2026-08-20 (RECORD-I-0001, I-0002, I-0003 complete).** The
> paragraphs above stand as the record of the founding day. Since then: the
> log of record is real (format v1, frozen, verified by an independent Python
> implementation on every test run); the resident store boots from it in
> 205–278 ms at ISMS scale and serves epoch-pinned reads through the §12 API;
> and the write path is real — `apply` as the one entrance, `log.md` §5.3's
> preconditions as typed caller errors, resident mutation before the fsync
> in state no reader can observe with exact rollback, a `Validator` seam at
> `store_open` receiving the post-state as an ordinary snapshot, the
> `record/ingest` subpackage, an in-memory `File_Ops`. One commit at 4×10⁵
> facts costs 31–35 ms on the memory seam; the footprint is 21.2 MB. The
> "second store beside odin-rdf-store" stance is superseded: on 2026-08-20
> the family decided to move odin-rdf-shacl and then odin-rdf-sparql onto
> this repository and retire odin-rdf-store, the siblings adapting to this
> store and not the reverse. Their port initiatives live on their side; what
> they need from here is listed in RECORD-I-0003's Status. Publication of
> the repository and its first tag are the owner's — *done the same
> evening: `odin-rdf/odin-rdf-record`, tag `v0.1.0` at `e29764e`.*

> **Amended 2026-08-20, later the same evening (`v0.2.0`).** The first
> sibling port found the first gap: `ingest` emitted a document's *list*
> of statements, and `apply` — correctly — refused the second assert of a
> statement the document repeated, so a legal document (the W3C SHACL
> suite's own shacl-shacl shapes graph) could not be loaded. The loaders
> now emit the document's *set* (RECORD-T-0019); `apply` is unchanged.
> Tagged `v0.2.0`, the pin odin-rdf-shacl's port moves to.

> **Amended 2026-08-20, later still (`v0.3.0`).** The second sibling-port
> finding: four id spaces shared one `u32`. The resident ids are now three
> distinct types — `Term_ID`, `Fact_ID`, `Epoch` — across the public API and
> the store's own code (RECORD-T-0020); widths, format and sentinels are
> unchanged. Tagged `v0.3.0`; the siblings adopt the types at their next pin.

> **Amended 2026-08-25 (`RECORD-I-0004`): the format moved, for the first
> time.** The three amendments above are all sibling-port findings where *this*
> store was wrong or untyped. This one is the other thing the family stance
> allowed for: a capability this store's own architecture document named,
> costed and deliberately left unbuilt until a consumer needed it.
> odin-rdf-sparql's port (`SPARQL-I-0003`) needed it, and the family owner
> gated that port on it rather than let it narrow a headline capability of the
> query engine.
>
> **RDF 1.2's two term kinds are real, and the format is version 2.** Tag
> `0x07` is a triple term — three on-disk component ids, the layout
> architecture.md §11.3 specified when it reserved the byte — and tag `0x08` is
> a literal with a base direction. The intern recurses; §5.2's ordering rule is
> transitive and enforced on both paths, as an assert on the write path and as
> a refusal on the replay path, which is what makes a hostile log's recursion
> finite. A triple term is takeable apart without decoding it
> (`snapshot_triple_parts`: a tag check and three reads out of the arena),
> which is **cheaper than the store the sibling is porting away from**, where
> the same question cost a materialisation plus three dictionary lookups.
>
> **Version 2 does not read version 1, and there is no migration.** The cost is
> that a v1 log needs a v1 binary; it was acceptable because no v1 log exists
> outside this repository's own regenerated corpora, and it will never be
> cheaper than it was here. The proof layer holds: both verifiers still agree
> verdict for verdict over the fault corpus, now over logs that contain both new
> tags, and the Python verifier needed **one constant** — the version — because
> it reads a term definition as `id u64, len u32, payload` and never looks at
> the tag. The capability is proven against the W3C rdf12 eval suites end to
> end, 29 turtle and 25 trig documents, every one of them carrying a triple
> term and every one of them committing.
>
> What is **not** decided here, and stays deferred exactly as §11.3 left it:
> what it means to *assert* versus *mention* a triple term. A triple term is a
> term; mentioning one asserts nothing.

> **Amended 2026-08-27 (`v0.5.0`, `RECORD-T-0029`): the first release cut for
> the application rather than for an engine, and the entry above is `v0.4.0`,
> tagged 2026-08-25 at `39be085` — that entry described the release without
> naming the tag.** The application's workspace design (a named graph per
> workspace, a read scope computed per request as a graph set that is an
> authorization ceiling) was the first consumer to design a *computed*
> `Filter.graphs`, and `Filter.graphs` decided scoped-versus-unscoped by
> whether the slice was nil — which Odin makes a fact about allocation
> history, so the same empty set read every graph or nothing. `Filter` now
> carries `scope: Graph_Scope { All, Set }` beside `origin`, under `origin`'s
> rule: no valid zero, refused at the first read; under `.Set` the length
> alone decides. An API change and not a format change — permutations and log
> untouched, both verifiers unchanged, the scale numbers unmoved. Tagged
> `v0.5.0` at `6bc27c4`; both engines walked the same day (ten sites state
> `.All`, nothing else moves). Filed beside it from the same design and not
> yet built: `RECORD-T-0028`, a seventh order `GPOS` so that "which Risks are
> in this workspace" is a prefix rather than a scan over every Risk.

## Future State

An embedded store where:

- **Opening is verifying.** Open = verify the chain + replay + rebuild the
  resident structures, well under a second at the target scale, on every
  start and every post-eviction wake.
- **Reads are epoch-pinned values.** `Latest()`/`At(e)` return a `Snapshot`;
  layer 1 answers patterns as ranges over sorted permutations
  (`Match`/`Iter`/`Vars`/`GroupBy`); layer 2 is counting, distinctness, and
  existence as loops around layer 1; `History`/`EntityHistory` answer audit
  questions from the same structures. Origin (asserted vs. derived) is
  explicit everywhere, with no default.
- **There is one write path.** `Apply(Changeset)`: intern terms, check
  value-level preconditions (every retract names a live quad, every assert a
  non-live one) with typed per-quad errors, run validation through a
  consumer-wired hook in `Enforce` or `Record` mode, then encode one epoch —
  append, fsync, apply, publish, in that order.
- **Tooling stands alone.** `verify`, `dump` (N-Quads/JSON), and `head` give
  an auditor the read side of the format with no server anywhere.

Consumers: **odin-rdf-app** as the placeholder consumer; **odin-rdf-shacl**
validating through the snapshot API so validate-before-commit sits inside
`Apply`; **odin-rdf-sparql** evaluating BGPs over layer 1, eventually — the
layer is drafted for it (merge orders, `MatchAs`, leapfrog-triejoin views).

## Major Features

- **The log of record** (`log.md`): segment files with chained base hashes,
  uniform record framing, epoch commits carrying term definitions and fact
  operations, environment notes inside the chain, seal records; the
  append-fsync-acknowledge write path; torn-tail detection and truncation
  with the position rule separating crash artifacts from tampering.
- **Replay and verification** as the only load path, run on every start.
- **The resident store** (`api.md` §§2–6): 24-byte facts in chunked tables,
  `u32` IDs with an inline range, the dictionary arena, six `[]FactID`
  permutations, the epoch table, the derived-origin bitset.
- **The snapshot API** (`api.md` §12–13): layers 0–2, `GroupBy`, history, the
  fast-reject rule, exact candidate counts as the planner's currency.
- **The write surface**: `Apply(Changeset)` with `Enforce`/`Record` validation
  modes and typed per-quad errors (`RECORD-A-0006` decides where the
  validator and the shape catalogue live).
- **Tooling**: `verify`, `dump`, `head`.

## Success Criteria

- **The afternoon claim is executable.** A verifier written from `log.md`
  alone, in another language, using no code from this repository, verifies
  real segments — and lives in the test suite as the standing proof.
- **Replay is measured, not assumed**: chain verification plus full replay of
  4×10⁵ facts / 10⁵ terms in under one second on commodity hardware.
- **The budget holds**: resident footprint at that scale within `api.md`
  §10's ~30 MB, measured.
- **Crash safety is demonstrated**: fault injection at every step of the
  write path loses no acknowledged epoch and admits no torn record.
- **The edit-surface asks are satisfied**: `Apply` with preconditions as
  typed errors, validation modes, and epoch metadata (actor, reason, wall)
  reachable from every read.
- **The seam is real**: odin-rdf-shacl validates through a `Snapshot` using
  layers 0–1 only — proven by the port compiling against the published API
  and nothing else.

## Principles

- **The log is the record; memory is a disposable projection.** No durable
  state the log does not determine. Anything resident may be rebuilt at any
  time and re-tuned at any restart; the log format is conservative because it
  is forever.
- **Verifiable by strangers.** Format decisions favor the independent
  verifier; nothing on disk requires our binary to read. Canonical bytes over
  convenient encodings.
- **Never delete, never rewrite.** Terms and facts are permanent; retraction
  is an event, not an erasure; a format version bump means new segments,
  never a migration.
- **An inference is never presented as a record** (`architecture.md` A.5).
  Origin is carried in the log, kept resident, and required — never
  defaulted — at every API surface.
- **One access path per layer.** Layer 2 is a loop around layer 1; a
  convenience layer 1 cannot express is a missing layer-1 primitive, never a
  licence to reach past it.
- **Frozen means frozen.** Decisions the design marks as frozen at first
  write (the inline encoding above all) get an ADR and their measurement gate
  *before* code exists.
- **Family conventions hold.** Primitives over frameworks, contract-level doc
  comments, explicit memory management and allocator awareness, tests with
  `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`.

## Constraints

- **Odin.** The founding documents' Go-specific material is translated per
  `doc/design/README.md`; the on-disk format is implemented exactly as
  specified either way.
- **Single writer per store**, structurally — epoch allocation, hash
  chaining, and fact-ID assignment are trivially correct as a consequence,
  and all three would need real machinery otherwise (`log.md` §10).
- **The scale premise is load-bearing**: ~4×10⁵ facts, ~10⁵ terms,
  human-paced writes, many embedded processes per RAM-bound machine
  (`api.md` §1). Design arguments inherited from the documents are re-argued,
  not assumed, if the premise moves.
- **Depends on odin-rdf-parser only.** No servers, no protocol layers, no
  HTTP — the edit surface belongs to consumers.
- **The consumer is `odin-rdf-app`** (family `CONTRIBUTING.md`); nothing in
  this repository names or describes any specific application.
- **No compression, no encryption, no random access, no compaction** in the
  log (`log.md` §10) — each would trade away a property the record exists to
  keep.