---
id: rdf-1-2-term-kinds-triple-terms
level: initiative
title: "RDF 1.2 term kinds: triple terms and base direction, for the SPARQL port"
short_code: "RECORD-I-0004"
created_at: 2026-08-24T19:26:59.050876+00:00
updated_at: 2026-08-24T21:23:26.462557+00:00
parent: RECORD-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/active"


exit_criteria_met: false
estimated_complexity: M
initiative_id: rdf-1-2-term-kinds-triple-terms
---

# RDF 1.2 term kinds: triple terms and base direction, for the SPARQL port Initiative

## Context **[REQUIRED]**

**A deferred decision has come due, and its consumer has arrived.**

`architecture.md` §11.3 raised RDF 1.2 triple terms as an open question in the
storage layer, specified the encoding that would serve them, and then deferred
everything else:

> The encoding in §3.2 extends naturally (`0x07 | sID | pID | oID`), but the
> semantics — particularly what it means to assert versus mention — are still
> moving. A.6 recommends named graphs instead for now, so **the only decision
> needed today is whether to reserve the tag byte, which costs nothing and
> preserves the option.**

The tag byte was reserved. It is reserved in three places: `record/term.odin`
("`0x07` reserved for RDF 1.2 triple terms (par. 11.3)"), `log.md` §5.2 ("with
`0x07` reserved for RDF 1.2 triple terms per §11.3 of that document"), and
architecture.md itself. **This initiative spends the option that reservation
bought.**

The consumer is **odin-rdf-sparql**, whose port off odin-rdf-store onto this
store is `SPARQL-I-0003`, founded 2026-08-24. That engine implements the SPARQL
1.2 surface, and the family owner's decision — recorded there as decision 2 —
was to **gate the port on this store gaining triple terms** rather than let the
port narrow a headline capability of the engine. So `SPARQL-I-0003` is blocked
on this initiative, and this initiative exists because that port asked for it.

**On the family stance.** `RECORD-I-0003` established that the siblings adapt to
this store, not the reverse, and shacl's port honoured it — three record tags
came out of that port and all three were places where *record* was wrong or
untyped (`v0.2.0` ingest emitting a list rather than a set; `v0.3.0` four
meanings on one `u32`). This initiative is not that. It is the other thing the
stance always allowed for: a capability this store's own design named, costed,
and deliberately left unbuilt until a consumer needed it. The consumer needs it.
The stance is not being weakened — nothing here is a workaround, nothing is
shaped by sparql's internals, and the encoding being built is the one this
store's architecture document specified before sparql asked.

### The evidence from the consumer

Measured in odin-rdf-sparql on 2026-08-24, not estimated:

- **38 evaluated W3C entries** in the vendored `sparql12-eval-triple-terms`
  directory (41 pinned manifest entries, 3 of them SPARQL Update and out of that
  engine's scope). They pass today against odin-rdf-store and would go dark on
  this store, taking that engine from 512/512 to 474/474.
- **158 triple-term syntax tests already pass and are unaffected** —
  `sparql12-syntax-triple-terms-positive` and `-negative` are parse-only. The
  engine can already *read and write* triple terms fluently; what it cannot do
  on this store is *keep* one. That asymmetry is the whole gap.
- **This also closes a piece of that repository's recorded store evidence.**
  `sparql/kvstore/eval.odin`'s `triple_adapter` takes a stored triple term apart
  by materializing the whole term and then re-resolving each of its three
  components — "two round trips through the database for something the
  dictionary knows outright", filed as `SPARQL-T-0019`. The encoding §11.3
  specifies **holds the three component ids**, so taking a triple term apart
  becomes reading three ids out of the arena with no lookup at all. The
  capability being asked for is *cheaper here than the one being left behind*,
  which is not the usual shape of a porting request.

### What the corpus actually requires — checked, not assumed

odin-rdf-parser expands RDF 1.2 reifying triples: `<< :a :b :c >> :q :z` becomes
`_:b rdf:reifies <<( :a :b :c )>> . _:b :q :z .`, verified in that repository's
turtle parser tests. Two consequences for this design:

- **Triple terms reach a store in the object position**, as the object of
  `rdf:reifies`. Nothing in the corpus obliges an S-, P- or G-position triple
  term. Whether to *restrict* the encoder to that is §4's question; the fact
  table stores a `Term_ID` in every position regardless, so permitting it costs
  nothing structurally.
- **Nesting is real.** `construct-3.ttl` carries
  `<< _:reifier2 rdf:reifies <<( :a :b :c )>> >>`, whose expansion is a triple
  term one of whose components is itself a triple term. The encoder, the intern
  and the decoder must all recurse, and the ordering rule must hold
  transitively.

### What already exists in this repository, and what to read first

Checked on 2026-08-24, so that a session starting here does not have to
rediscover it. **The family checkout root is the parent directory**: the
consumer is `../odin-rdf-sparql` and the parser is `../odin-rdf-parser`,
which this repository's own tests already reach by relative path
(`tests/ingest/ingest_test.odin`'s `W3C :: "../odin-rdf-parser/tests/w3c"`).

- **There is already a test asserting the refusal, and this initiative
  inverts it.** `test_ingest_triple_term_refused_at_apply`
  (`tests/ingest/ingest_test.odin:394`) loads
  `rdf12-turtle-eval/turtle12-eval-bnode-01.ttl`, asserts `ingest` emits
  three ops, finds the one whose object is a `^rdf.Triple`, and expects
  `apply` to return `Apply_Error{.Unsupported_Term, at}` with `n_epochs`
  still 0. **Read it first.** It is the most precise statement in the
  repository of what the gap is, it corroborates the object-position
  finding from inside this repository's own suite, and if it is not
  deliberately rewritten it will fail in RECORD-T-0023 and look like a
  regression.
- **The fixtures exist and are not vendored here.** odin-rdf-parser
  vendors `rdf12-turtle-eval` (46 documents carrying `<<`),
  `rdf12-trig-eval` (38), and four rdf12 syntax suites. This
  repository's `sweep_suite` already runs W3C suites end to end —
  ingest, apply, read back, compare against the expected `.nt`/`.nq` —
  but **only over the four rdf11 suites**. Extending it to the rdf12 eval
  suites is this initiative's strongest acceptance test: no vendoring, no
  hand-written fixtures, and the capability proven against the W3C suites
  the way everything else here is.
- **`rdf.equal_term` and `rdf.hash_triple` already handle `^rdf.Triple`**
  (`../odin-rdf-parser/rdf/equal.odin:28`, `rdf/hash.odin:22`), so
  `ingest`'s `Seen` set — which dedupes a document's statements by
  `hash_quad` — needs nothing. Checked, so nobody investigates it twice.
- **`rdf.destroy_quad` recurses through `destroy_triple`**, so
  `ingest.ops_destroy` frees a nested triple term without change.

Everything else this initiative needs is in this repository:
`architecture.md` §3.2 (the canonical encoding and its injectivity
argument), §3.4–3.5 (inlining, and why the log stays 64-bit), §11.3 (the
reservation); `log.md` §5.2 (the term-definition record and the ordering
rule) and §11 (the no-schema-evolution rule); `api.md` §12.7 (resolution
and materialisation) and §12.8 (what SPARQL will want).

**Process** is this family's usual: the `metis` CLI from the repo root
(`metis transition <CODE> <phase>`, `metis sync` after editing a
`.metis/*.md` file directly), annotated tags as `Release vX: title` with
a bulleted body, and **no push unless the owner says so**. Cross-repo
edits are discussed with the owner before being made on a sibling's side.

**Size.** Five tasks, one of which produces only decisions. For
comparison, odin-rdf-shacl's whole port off odin-rdf-store was seven
tasks in one day; this is smaller in surface but touches a *format*,
which is why the proof layer gets its own task rather than a checkbox.

### The second term kind

A literal with a **base direction** (`"x"@en--ltr`) is refused by the same
`.Unsupported_Term`, from the same `term_encode` switch. It is RDF 1.2's other
new term shape and it has **no reserved tag**. Be precise about what it buys
the consumer: odin-rdf-sparql runs `sparql12-lang-basedir` as a **syntax**
suite (11 entries, parse-only, already green), so a base-direction literal
never reaches a store in that engine today. Bundling it removes a latent limit
rather than unblocking an evaluation directory — the honest justification is
the second one below, not a test count. The owner chose to bundle it here (`SPARQL-I-0003`, decision 2, second half): same family
of term kinds, same round trip through encode/decode/intern/verify, and **one
format-version question instead of two**. It is the smaller half of this
initiative and should not be allowed to grow into the larger one.

## Goals & Non-Goals **[REQUIRED]**

**Goals:**

- **`term_encode` and `term_decode` handle triple terms** under tag `0x07`, in
  the layout architecture.md §11.3 specified: `0x07 | sID | pID | oID`, component
  ids being `u64` on disk exactly as tags `0x05` and `0x06` already carry a `u64`
  reference (api.md §3.5, "the log stays 64-bit").
- **`intern_term` recurses**, defining every component before the triple term
  that references it. This is the ordering constraint §5.2 already states for a
  typed literal's datatype IRI — "the same ordering constraint `intern` already
  enforces" — extended transitively.
- **`snapshot_kind` gains `.Triple`**, so a consumer can tell a triple term from
  an IRI, a blank node or a literal without decoding it. This is the direct
  replacement for odin-rdf-store's `id_kind(id) == .Triple`, which the sparql
  engine tests at one site.
- **Taking a triple term apart is cheap and is exposed as such.** The component
  ids are in the encoding; a consumer must be able to read them without
  materializing an `rdf.Triple` and re-resolving. The shape of that entry point
  is a design-phase question (§5); that it exists is a goal, because it is the
  evidence item this initiative closes.
- **Base-direction literals encode and decode**, under whatever tag the design
  gate chooses (`0x08` being the obvious next).
- **The W3C rdf12 eval suites swept.** `sweep_suite` extended to
  `rdf12-turtle-eval` and `rdf12-trig-eval`, so a document containing
  triple terms ingests, applies, reads back and compares equal against
  the suite's own expected result — the same standard the rdf11 suites
  are already held to here.
- **The proof layer still proves it.** Golden vectors for both new tags,
  computed independently the way `RECORD-T-0001`'s were; the fault corpus
  unchanged in spirit; the Odin and Python verifiers still agreeing verdict for
  verdict. Note what is *already* known: `tests/verify/rdflog_verify.py` reads a
  term definition as `id u64, len u32, payload` and never inspects the payload's
  tag, **so the cross-implementation verifier needs no change** — checked, and
  worth stating because it bounds this initiative's blast radius on the thing
  that makes this store worth using.
- **The format-version question answered explicitly** (§6), not left implicit in
  a writer that quietly emits bytes an older reader would halt on.
- **The documents amended, not diverged.** architecture.md §11.3 and log.md §5.2
  say "reserved"; when this lands they say what it is. The repository's
  convention — a discovered divergence amends the document, never quietly the
  code — applies to a *filled* reservation as much as to a bug.

**Non-Goals:**

- **Assert-versus-mention semantics, entailment, or reification modelling.**
  §11.3's reason for deferring was that these are still moving, and they still
  are. **They are not what the consumer needs.** A SPARQL engine needs a triple
  term to be a *term*: storable, resolvable, identical to itself, and takeable
  apart. Mentioning one is not asserting the triple it names, and nothing in this
  initiative should make it so. A.6's recommendation of named graphs for
  *modelling* stands untouched.
- **Derived triple terms, inference, or anything touching `RECORD-A-0002`.**
- **Inlining.** `RECORD-A-0001` froze the inline predicate at first write and a
  triple term is not inlineable — three ids do not fit in 28 bits. `term_inline`
  is untouched; triple terms are dictionary terms, always.
- **A query API for triple terms.** Layer 1's `Pattern` binds ids; a triple term
  is an id. Nothing in §12 needs to change, and if something does, that is a
  finding for the sparql port to report rather than a goal here.
- **Reopening `RECORD-A-0001`.** The inline encoding stays frozen. This
  initiative touches the *dictionary* encoding, which architecture.md §3.2
  designed to be extended by tag and which reserved this very byte.
- **Migration.** Whatever §6 decides, no v1 log is converted. That is this
  store's standing rule and there are no deployments.

## Detailed Design **[REQUIRED]**

Design-phase material, with leans where the analogy is strong. Every open point
below is **this repository's to settle**, not the consumer's.

**1. The encoding.** `0x07 | sID | pID | oID`, three `u64`s, 25 bytes — the
layout §11.3 named. The precedent is complete: `TERM_TAG_TYPED` (`0x05`) already
carries a `u64` datatype id and `TERM_TAG_SPLIT_IRI` (`0x06`) a `u64` namespace
id, both resolved through a callback on decode. Injectivity (§3.2's argument)
carries over: a distinct tag byte with a fixed-length payload cannot collide with
any other encoding.

**2. Ordering, and the self-check.** §5.2's rule — "a typed literal's datatype
IRI must be defined before the literal that references it" — becomes transitive.
Since ids are assigned in first-appearance order and a replayer counts them out,
a triple term's components necessarily have *lower* ids than the triple term
itself, which makes the constraint checkable by comparison rather than by
bookkeeping. Lean: assert it on both the write and the replay path, because it
is one comparison and a violation means encoder and replayer disagree about
something fundamental — the same argument §5.2 makes for the redundant `id`
field.

**3. The intern recurses.** `intern_term` currently encodes a term and looks the
bytes up; for a triple term it must first intern the three components (each of
which may recurse), then encode their ids. The `pending` map keyed on the
definition bytes works unchanged, since a triple term's bytes are as canonical as
any other's once its components have ids. Watch the scratch lifetime:
`term_encode`'s `fit` writes into a caller buffer or allocates, and a recursive
encoder needs each level's buffer to outlive the level above it long enough to
be copied.

**4. Where a triple term may appear.** The corpus needs the object position
only (see Context). Options: permit any position (a `Term_ID` is a `Term_ID`;
costs nothing; matches odin-rdf-store, whose `Term_ID` carried a `.Triple` kind
valid anywhere), or restrict to O and refuse elsewhere (states RDF 1.2's own
constraint, and a refusal is cheap to relax later while a permission is not).
**Lean: permit, and say why in the ADR** — the restriction would be this store
asserting a position on a specification §11.3 explicitly said is still moving,
which is exactly what this initiative's non-goals decline to do.

**5. Decoding needs more than `Resolve_Iri`, and this is the real design
question.** `term_decode`'s one callback resolves a `u64` to an *IRI string* —
enough for a datatype and a namespace, not enough for a triple term, whose
components are arbitrary terms and may themselves be triple terms. Two shapes to
weigh: a second callback resolving an id to a full `rdf.Term` (symmetric with
`Resolve_Datatype` on the encode side, keeps `term_decode` pure and seam-bound),
or a snapshot-level decoder above `term_decode` that walks the recursion itself
(keeps the pure layer's signature, moves the recursion where the dictionary
already is). **Weigh ownership at the same time**, because it is the sharper
half: `snapshot_term` currently *borrows* — the arena or a caller `Term_Buf` —
and a triple term must allocate an `^rdf.Triple` node per level. Whatever is
chosen must keep the borrowing contract legible rather than making
`snapshot_term` sometimes-owning by surprise. Lean: an explicit allocator
parameter and a documented rule that a decoded triple term is owned, with the
component terms borrowing as they do today — but this is the point to think
hardest about, and the consumer's `triple_adapter` wants the *ids*, not the
decoded term, for most of its work (see §7).

**6. The format version.** Adding tags does not change any existing byte, and no
v1 log contains `0x07` or a base-direction tag. But a v1-stamped log written by
a new writer would halt an older reader on an unknown tag, which is a log that
lies about what it is. Against a bump: `FORMAT_VERSION` gates the *whole* log
(`encode.odin:243`), log.md §11 says "a format version bump means a new log", and
there is no migration story by design. For a bump: honesty is cheap when there
are no deployments, and this store's sibling set the precedent (odin-rdf-store's
format v2 does not read v1 and says so). **Lean: bump, and record the reasoning
in an ADR** — but this is the design gate's call and it should be made
deliberately, because it is the first time this format has moved at all.

**7. What the consumer needs exposed.** odin-rdf-sparql binds a
`Triple_Reader :: proc(data, id) -> (parts: [3]Term_ID, ok: bool)`. Against
this encoding that is `snapshot_bytes(id)`, a tag check, and three id reads —
no allocation, no decode, no recursion. Lean: offer it as a named procedure
(`snapshot_triple_parts` or similar) rather than leaving every consumer to parse
the encoding by hand, since parsing a format by hand is exactly what a published
API exists to prevent. Cheap, and it is the shape that makes §Context's
"cheaper than what is being left behind" true in practice rather than in
principle.

**8. Base direction.** `TERM_TAG_LANG` (`0x04`) is `tag | langlen:u8 | lang |
lexical`, with the language lowercased on encode. A direction needs one more
field. Options: a new tag `0x08` (`tag | langlen:u8 | dir:u8 | lang | lexical`),
or a sentinel inside `0x04`. **Lean: a new tag** — `0x04`'s bytes stay
byte-identical for every existing term, injectivity stays obvious, and the
decoder's shape stays flat. Note that `rdf.Literal` carries `direction` as an
enum already, so the data model needs nothing.

**9. What is untouched, and should be verified to be.** `term_inline` and the
inline path (§Non-Goals); the term index, which sorts encoded bytes and treats
them opaquely (`sort_term_ids`/`multikey_sort`); the six permutations, which sort
`Term_ID`s; the fact table; `Filter`; visibility; the epoch table; and — checked
already — `tests/verify/rdflog_verify.py`. A task should *assert* that list
rather than assume it, since "nothing else changed" is the claim this store's
proof layer exists to make checkable.

## Alternatives Considered **[REQUIRED]**

- **Do nothing; let the consumer record a backend limit.** This was the
  recommendation put to the family owner on 2026-08-24 — disable the suite with
  a stated reason, keep the engine's triple-term code, file the gap here for
  later. **The owner chose to build it instead**, on the grounds that record
  reserved the tag for precisely this, the encoding is already specified, and
  the alternative permanently narrows a headline capability of the query engine
  to buy a slightly earlier port.
- **Reify in the consumer** — have odin-rdf-sparql skolemize triple terms into
  blank nodes or IRIs before they reach this store. Rejected on the family's own
  rule that capability gaps become evidence-backed upstream proposals and never
  backend-specific workarounds; it would also break term identity in a way that
  engine's corpus would catch immediately, and it would put a second term
  encoder in the system.
- **Named graphs instead of triple terms**, which is A.6's standing
  recommendation for *modelling*. It remains good advice and is untouched by
  this initiative — but it is advice to a data modeller, not an answer to a
  SPARQL engine being handed a document that already contains triple terms.
- **Waiting for RDF 1.2 to settle.** §11.3's original reason to defer, and it
  applies to the *semantics*, which this initiative's non-goals decline to
  decide. The *term encoding* is not what is moving: three component ids under a
  tag byte is the shape every RDF 1.2 draft has had.
- **Triple terms now, base direction later.** Rejected by the owner: two format
  questions and two rounds through the proof layer instead of one, for two
  members of the same RDF 1.2 family.

## Implementation Plan **[REQUIRED]**

**Not yet decomposed — that is the next check-in.** The shape, sequenced so each
step ends provable:

1. **The design gate.** §5 (the decode seam and the ownership rule), §6 (the
   format version), §4 (positions), §8 (the base-direction tag). An ADR for
   whichever of these deserves one — §6 certainly, and probably §4/§5 together
   as "how a recursive term is decoded and who owns it".
2. **The pure encoding layer**: both tags in `term_encode`/`term_decode`, with
   golden vectors computed independently the way `RECORD-T-0001`'s were.
3. **The intern and the write path**: recursion, transitive ordering, the
   self-check, `apply` no longer refusing; replay equivalence on both seams.
4. **The read side**: `snapshot_kind` gains `.Triple`, the component-ids entry
   point of §7, `snapshot_term`'s ownership rule documented and tested.
5. **The proof layer and the documents**: both verifiers still agreeing over the
   fault corpus; architecture.md §11.3 and log.md §5.2 amended from "reserved" to
   what it is; the §9 untouched-list asserted; a tag cut for the consumer to pin.

**Exit:** `make test` green with both new term kinds encoded, interned,
replayed, resolved and decoded; the Python verifier agreeing without having been
changed; the documents amended rather than diverged; a release tagged; and
odin-rdf-sparql's `SPARQL-I-0003` unblocked, with its 38 evaluated triple-term
entries reachable.

## Status

**2026-08-25 — complete. The consumer approved it, and `v0.4.0` is cut.**
All five tasks are done and every exit criterion is met: both new term
kinds encode, intern, replay, resolve and decode; the Python verifier
agrees over the fault corpus having taken one constant's change and no
encoding change; the documents are amended rather than diverged; and the
tag exists.

**The consumer's verdict, which is what the tag was waiting on.**
`RECORD-T-0025`'s risk note said not to tag before a consumer had
compiled against this, so odin-rdf-sparql's `SPARQL-T-0030` built
against the untagged head first. It reads a triple-term data file out of
its *own* vendored `sparql12-eval-triple-terms` suite — the file `apply`
used to refuse with `{.Unsupported_Term, 0}` — ingests it, applies it
clean, and walks `snapshot_triple_parts` two levels down through a
nested triple term to an inlined component, allocating nothing. Its full
suite stayed **512/512 at both widths** with the `record:` collection
added. So §Context's "cheaper here than what is being left behind" is
now demonstrated by the consumer rather than argued by us: the
`triple_adapter` this replaces materialized the whole term and
re-resolved each component.

**`v0.4.0`**, annotated, at `435c2b3`, and **published** —
`odin-rdf/odin-rdf-record` carries the tag and the commits under it.
sparql's `ci.yml` pins it, so that job resolves. One note for anyone
reading the tag: this Status block is the commit *after* it, so `v0.4.0`
holds every source and document change of the initiative but not this
paragraph. That is the reverse of `v0.3.0`'s mistake and is deliberate —
a tag is not moved once it is published.

**One thing recorded and not acted on**, from the consumer: an inlined
literal's id is `>= CONSUMER_ID_FIRST`, so a consumer testing "is this
one of my own ids?" with a bare `>=` threshold misclassifies an ordinary
term. `resident.odin:42` states the range with both ends, so the API is
not at fault — but this is the second consumer-side trap in that area,
which is weak evidence that an `is_consumer_id(id)` helper would earn
its keep. Nobody has asked for one.

**2026-08-24 — filed on behalf of the consumer.** Created from odin-rdf-sparql's
`SPARQL-I-0003` after the family owner chose to gate that port on this
capability. The evidence, the corpus facts and the "already reserved" finding are
recorded in Context above; nothing here has been designed, committed or pushed.
Awaiting the owner's review, and this repository's own design gate on the four
open points of Detailed Design.

**2026-08-24, later — the gate is closed and the initiative is active.**
`RECORD-T-0021` settled **seven** decisions, not the four filed: walking the
open points against the code rather than the documents turned up three more.
Two ADRs carry them — [[RECORD-A-0007]] (the format moves to version 2) and
[[RECORD-A-0008]] (how a recursive term is decoded, and who owns it) — and
`RECORD-T-0021`'s Status Updates hold the reasoning for each, with a
"what the downstream tasks inherit" section so `RECORD-T-0022`–`-T-0025` do
not re-derive them.

The four leans in Detailed Design all held: permit all positions (§4), the
second callback for the decode seam (§5), bump the format version (§6), a new
tag `0x08` for base direction (§8). §5's ownership half resolved to **wholly
owned**, with a new paired verb `snapshot_term_destroy` that also closes an
older gap — `snapshot_term` has been sometimes-owning since split IRIs landed
(`record/read.odin:312`) with nothing to free them by.

Three questions this document did not raise, all found in the code:

- **A triple term's component may be an inlined literal**, and inlined ids are
  the one place the on-disk and resident schemes differ. Components encode in
  **disk form**. §9's untouched-list is unaffected, but §3's "the `pending` map
  works unchanged" is only true given this.
- **A base direction with an empty language** is not an RDF 1.2 term and keeps
  being refused, rather than getting an encoding — §8 did not say.
- **`snapshot_kind` falls through to `.Literal`** for any tag it does not
  recognise (`record/read.odin:259`), so tag `0x07` would have answered
  `.Literal` silently. The switch becomes exhaustive with a panic.

One correction to a Goal, recorded rather than quietly fixed: **"the
cross-implementation verifier needs no change" is falsified by the version
bump.** Its reason survives — `tests/verify/rdflog_verify.py` reads a term
definition as `id u64, len u32, payload` and never inspects the tag, so both
new *encodings* are invisible to it — but it pins `VERSION = 1` at `:40` and
refuses a mismatch at `:110`. One constant and a docstring, for the header's
sake and not the encoding's. `RECORD-T-0025`'s matching criterion wants the
same amendment, along with regenerating both corpora at v2 and re-running the
§9 measurement rather than citing `RECORD-T-0006`'s figures.

`RECORD-T-0021` stays in `todo` with eight of its nine criteria settled: "the
injectivity argument re-checked, not assumed" is argued in
[[RECORD-A-0008]] and becomes a test in `RECORD-T-0022`, which is where
"should" turns into "does". Still nothing built, and nothing pushed.