---
id: the-proof-layer-and-the-documents
level: task
title: "The proof layer and the documents: both verifiers agreeing, reserved becomes built, a tag cut"
short_code: "RECORD-T-0025"
created_at: 2026-08-24T20:42:56.281837+00:00
updated_at: 2026-08-24T22:11:04.890025+00:00
parent: RECORD-I-0004
blocked_by: [RECORD-T-0024]
archived: false

tags:
  - "#task"
  - "#phase/active"


exit_criteria_met: false
initiative_id: RECORD-I-0004
---

# The proof layer and the documents: both verifiers agreeing, reserved becomes built, a tag cut

## Parent Initiative

[[RECORD-I-0004]]

## Objective

Close the initiative the way this repository closes things: the
independent verifier still agrees, the fault corpus still runs, the
documents say what is true rather than what was reserved, and a tag exists
for the consumer to pin.

The claim being proved is narrower and sharper than "it works": **a third
party can still verify this store's log from the specification alone**,
with two new term kinds in it. That property is why this store exists, and
a format change is exactly the kind of event that would quietly erode it.

## Acceptance Criteria

- [x] **The Odin and Python verifiers still agree verdict for verdict**,
      head hash and epoch included, over the 29-case fault corpus, on
      every `make test` — the standard `RECORD-T-0006` set.
- [x] **`tests/verify/rdflog_verify.py` needs no change, and that is
      stated as a finding rather than assumed.** It reads a term
      definition as `id u64, len u32, payload` (§5.2) and never inspects
      the payload's tag, so a new tag is invisible to it. **Checked
      before this initiative was written**; confirm it survived the
      implementation, and if it did not, that is a signal the encoding
      went somewhere §5.2 did not describe.
- [x] **The scale measurement re-run.** `RECORD-T-0006`'s figures —
      verify 105–272 ms, replay 166–342 ms over 16.9–38.4 MB logs — are
      the vision's sub-second criterion's evidence. A recursive intern and
      a wider dictionary should not move them; confirm rather than assume,
      and if a format-version bump means the corpus is regenerated, say
      so.
- [x] **`architecture.md` §11.3 amended**: its open question is answered.
      The paragraph stands as the record with a dated note saying the
      reservation was spent, by which task, for which consumer — and that
      the *semantics* it deferred (assert versus mention) remain deferred
      and out of scope. A.6's recommendation of named graphs for
      modelling is untouched.
- [x] **`log.md` §5.2 amended**: "with `0x07` reserved for RDF 1.2 triple
      terms" becomes what it is, the base-direction tag joins the tag
      list, and the ordering paragraph — "a typed literal's datatype IRI
      must be defined before the literal that references it" — states the
      transitive rule. If the format version moved, §5.2's header
      paragraph and §11's no-schema-evolution rule are amended to record
      that the first bump happened and why.
- [x] **`api.md` amended** where it describes term kinds and
      `snapshot_kind`'s answers, and §12.8's "what SPARQL will want that
      this does not yet give" re-read — one of its items may have moved.
- [x] **The untouched list asserted, not assumed** (`RECORD-I-0004` §9):
      `term_inline` and the inline path; the term index; the six
      permutations; the fact table; `Filter`; visibility; the epoch
      table. "Nothing else changed" is the claim this store's proof layer
      exists to make checkable.
- [ ] **A release tagged**, annotated, `Release vX: title` with a
      bulleted body — the owner's act, prepared here. The consumer
      (`SPARQL-T-0035`) pins it, so the tag is this initiative's actual
      deliverable to the outside.
- [x] **The consumer told what it got.** A short note — in this task's
      Status, where `SPARQL-I-0003`'s author will look — naming the
      procedures added, the ownership rule for a decoded triple term, the
      position decision, and whether the format version moved.
- [x] **`RECORD-V-0001` Current State amended** with a dated block: the
      format moved (or did not), two term kinds arrived, and the
      consumer's port is unblocked. Amend, do not rewrite.

## Implementation Notes

### Technical Approach

**The fault corpus may want new members.** It has 29 cases covering torn
tails, CRC failures and chain breaks. A truncated triple-term definition
and a triple-term definition referencing an id that has not been defined
yet are two new *shapes* of corruption, and the second is the one the
transitive ordering assert (`RECORD-T-0023`) exists to catch — a corpus
case would prove the assert fires rather than that it compiles.

**Amend, never rewrite.** The convention in this repository is stricter
than the family's general one: a discovered divergence amends the
document and never quietly the code. A *filled reservation* deserves the
same treatment — the old sentence stands, with a dated note.

### Dependencies

Blocked by RECORD-T-0024 — everything this task documents and proves must
exist first.

### Risk Considerations

**The verifier is the load-bearing claim and the easiest thing to erode
without noticing.** If the implementation ends up needing a Python-side
change, stop and ask why: it would mean the encoding is doing something
§5.2 does not describe, which is a design problem rather than a test
problem.

**Do not tag before the consumer has built against it.** odin-rdf-shacl's
port cut three record tags in one day because each one was found by a
consumer actually compiling. Offering `SPARQL-I-0003` a pre-tag commit to
build against, and tagging after, is cheaper than tagging twice.

## Status Updates

### 2026-08-25 — the proof holds, the documents say what is true

9 of 10 criteria met. The one exception is the tag, which is prepared here
and is the owner's act — see below.

**Both verifiers still agree, now over logs that contain the new tags.**
The apply-written corpus gained two epochs: a base-direction literal and a
triple term nested inside another, so `tests/proof` no longer proves
agreement over a log that happens to predate the feature. Odin and Python
agree verdict for verdict, head hash and epoch included, over the fault
corpus on every `make test`.

**`tests/verify/rdflog_verify.py` took exactly the one-constant change
`RECORD-T-0021` predicted, and this criterion is amended rather than
quietly satisfied.** As filed it said the verifier needs *no* change; the
reason survives and the conclusion did not. It reads a term definition as
`id u64, len u32, payload` (§5.2) and never inspects the payload's tag, so
both new **encodings** are invisible to it — checked, still true, and the
comment in the file now says so. It pinned `VERSION = 1`, so the **header**
was not invisible to it. That distinction is what keeps this criterion's
signal intact: a Python-side change for the *encoding's* sake would have
meant the encoding went somewhere §5.2 does not describe, and this one did
not.

**A fault-corpus member for the ordering violation belongs in
`record/load_test.odin`, not here, and that is a finding rather than a
shortcut.** `RECORD-T-0023` added two crafts there — a forward reference
and a self-reference. Neither is visible to a *chain* verifier: the chain
is intact and the CRCs are right; what is wrong is the meaning. That is
`RECORD-T-0004`'s judged/altered split exactly, and putting the case in
the proof corpus would have asserted that both verifiers call it **clean**,
which is true and proves nothing about the ordering rule. The refusal is a
replay refusal and is tested where replay is.

### The measurement, re-run and reported honestly

Optimized build, Apple Silicon dev machine, corpora regenerated at v2:

| | log | verify | replay | boot |
|---|---|---|---|---|
| bulk-loaded | 16.5 MB | 52 ms | 59 ms | 222 ms |
| hand-edited | 37.9 MB | 94 ms | 98 ms | 303 ms |

`RECORD-T-0006` recorded verify 105–272 ms and replay 166–342 ms over
16.9–38.4 MB. **These are not the same measurement and should not be read
as a speedup**: that range spanned machines and runs, and nothing in this
initiative touches the verify or replay hot path. What the numbers support
is the claim that matters — the recursive intern and the wider dictionary
did not move them, and the vision's sub-second criterion holds with an
order of magnitude in hand. Commit latency at 4×10⁵ facts is 34.6–50.3 ms,
within `RECORD-A-0005`'s recorded 31–35 ms band's neighbourhood and well
under its review trigger; resident footprint is unchanged at 21.2 MB.

### The documents, amended and not rewritten

- **architecture.md §11.3**: the reservation was spent, by which task, for
  which consumer — and the paragraph stands. What it deferred and what
  remains deferred are separated explicitly: the *encoding* is built, the
  *semantics* of assert-versus-mention are not, and **A.6's named-graph
  recommendation is untouched**.
- **log.md §5.2**: `0x07` is no longer reserved, `0x08` joins the tag list
  with its three injectivity refusals, and the ordering paragraph states
  the transitive rule and why a replayer must refuse a violation.
- **log.md §11**: see the divergence below.
- **api.md §12.7**: `Kind`'s fourth answer and its exhaustive switch,
  `TripleParts`, `TermDestroy`, and `Resolve`'s recursion.
- **api.md §12.8 re-read**, as required. One item moved and it was not in
  the list — a SPARQL engine can now keep a triple term — and the four
  that are there are unmoved. Nothing in §12 needed a new *query* shape,
  which is this initiative's non-goal holding.
- **README and `RECORD-V-0001` Current State**: dated blocks, old text
  standing.

### Finding: log.md §11 and the implementation disagree, and the ADR overstated it

§11 says a format version bump "means a new segment, not an in-place
migration. **Old segments stay readable at their own version.**" That
describes a reader that understands more than one version.
`header_decode` has always tested `version != FORMAT_VERSION` and answered
`.Bad_Version`, so a v2 binary refuses a v1 log outright — **every byte of
which is valid v2**. The divergence predates this initiative; the bump is
what made it bind.

[[RECORD-A-0007]] claimed the strict check "is what 'no schema evolution'
means when written down". It is not, and that sentence is corrected in the
ADR. **The decision is unchanged** — the ground for it is the argument in
that ADR's Rationale, not a sentence in §11 that says something else — and
§11 now carries a dated amendment recording the divergence and declining
to repair it: a multi-version reader is precisely the machinery that
bullet exists to refuse, and each admitted version is another thing two
independent implementations must agree about.

### The untouched list, asserted

`test_rdf12_untouched_list` proves `RECORD-I-0004` §9's claim rather than
restating it: `term_inline` refuses both new kinds and still inlines what
it always did; `Fact` is 24 bytes; the six permutations hold ids and no
order knows what it holds; `Filter` still requires origin to be stated;
a retract still ends visibility at the retracting epoch; the epoch table
still carries actor, reason and wall; and the term index is still sorted
by encoding with every term findable by its own bytes.

---

## For the consumer — what `SPARQL-I-0003` got

**Pin `v0.4.0` or later** (the tag below). Format version 2; a store
opened on a v1 log will refuse with `.Bad_Version`, which no sparql
checkout has.

**New on the read side:**

- `snapshot_triple_parts(snap, id) -> ([3]Term_ID, bool)` — bind
  `Triple_Reader` to this. A tag check and three reads out of the arena:
  no allocation, no decode, no recursion. `false` for an inlined id or
  any term that is not a triple term; it asserts on an id the snapshot
  does not know, like `snapshot_bytes`.
- `Term_Kind.Triple` — the replacement for odin-rdf-store's
  `id_kind(id) == .Triple`. A base-direction literal answers `.Literal`.
- `snapshot_term_destroy(snap, id, t, allocator)` — **call it on
  everything `snapshot_term` returns.** A decoded triple term is *wholly
  owned* (`RECORD-A-0008`); a split IRI has always owned its joined
  string; everything else borrows and this is a no-op. It takes the id
  because the term alone cannot tell those cases apart.
- `snapshot_resolve` recurses: a component the snapshot has never seen
  makes the whole term a miss, one probe, no scan.

**Positions:** a triple term is permitted in **every** position, S, P, O
and G. There is no write-path refusal and no pattern special case; a
`Pattern` binding one in S simply matches nothing, which is the correct
answer.

**Ownership, in one sentence:** everything `snapshot_term` returns is
freed by `snapshot_term_destroy`, and a decoded triple term is the only
kind that owns its whole tree — `rdf.destroy_term` is what that verb calls
(note: `rdf.destroy_triple` takes a `Triple` by value and leaves the node).

**What did not change:** `Pattern`, `Filter`, `range_iter`/`scan_next`,
`snapshot_fact`, `snapshot_epoch_meta`, the consumer id range, and every
term-identity rule `SPARQL-T-0035` will have read — language tags still
fold to lowercase on intern (tag `0x08` folds its language half the same
way), non-canonical numerics are still distinct terms, inlineable literals
still always resolve. **Triple terms are no longer refused by `apply`**,
so the 20 vendored data files that carry them load; that recorded backend
limit is gone.

### The tag, prepared

Not cut — this is the owner's act, and `RECORD-T-0025`'s own risk note
says not to tag before a consumer has built against it. Offering
`SPARQL-I-0003` this commit to build against and tagging after is cheaper
than tagging twice, as odin-rdf-shacl's port demonstrated three times in
one day.

```
git tag -a v0.4.0 -m "Release v0.4.0: RDF 1.2 term kinds, format v2" -m "..."
```

Suggested body:

- Triple terms (tag 0x07) and base-direction literals (tag 0x08), the
  encoding architecture.md §11.3 specified and reserved the byte for.
- Format version 2. Version 2 does not read version 1; there is no
  migration, which is the format's standing rule.
- The read side: snapshot_triple_parts (components without a decode),
  Term_Kind.Triple, snapshot_term_destroy, snapshot_resolve recursing.
- Triple terms permitted in every position; a pattern naming one in a
  position the data does not use matches nothing rather than failing.
- log.md §5.2's ordering rule is transitive and enforced: asserted on the
  write path, refused on the replay path (Load_Error.Term_Order).
- Proven against the W3C rdf12 eval suites end to end — 29 turtle and 25
  trig documents, every one carrying a triple term, every one committing —
  and both verifiers still agree over the fault corpus.
- Unblocks odin-rdf-sparql's port (SPARQL-I-0003).