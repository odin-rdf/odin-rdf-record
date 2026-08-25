---
id: the-proof-layer-and-the-documents
level: task
title: "The proof layer and the documents: both verifiers agreeing, reserved becomes built, a tag cut"
short_code: "RECORD-T-0025"
created_at: 2026-08-24T20:42:56.281837+00:00
updated_at: 2026-08-25T09:30:01.321700+00:00
parent: RECORD-I-0004
blocked_by: [RECORD-T-0024]
archived: false

tags:
  - "#task"
  - "#phase/completed"


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
- [x] **A release tagged**, annotated, `Release vX: title` with a
      bulleted body — the owner's act, prepared here. The consumer
      (`SPARQL-T-0035`) pins it, so the tag is this initiative's actual
      deliverable to the outside.
      **Done 2026-08-25**: `v0.4.0`, annotated, at this initiative's
      last commit rather than at the source commit `77982ce`, so that
      everything this task wrote — the measurement, the document
      amendments and the consumer's verdict — is inside the tag.
      `v0.3.0` was cut one commit early and `RECORD-T-0020`'s own title
      records that as a regret. The risk note below was honoured to the
      letter: the consumer built against the commit before the tag
      existed (see the section after next). **Published** at `435c2b3`.
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
initiative touches the verify or replay hot path. The vision's sub-second
criterion holds with an order of magnitude in hand, and the resident
footprint is unchanged at 21.2 MB.

### Amended the same day — the regression question, measured A/B

The paragraph above compares against *recorded* figures from other
machines and other days, which cannot answer "did this initiative make
anything slower". Two numbers looked like they might have moved — bulk
apply against `RECORD-T-0018`'s 222–267 ms, and commit latency against
`RECORD-A-0005`'s 31–35 ms — so both were measured **A/B on one machine,
back to back**: a worktree at `43ed124` (the commit before this
initiative) against `77982ce`, seven optimized runs each.

| | baseline (43ed124) | post (77982ce) |
|---|---|---|
| bulk apply, one epoch | min 382, median 393, **mean 401**, max 432 ms | min 381, median 420, **mean 410**, max 450 ms |
| commit latency, mean of 24 | min 35.8, **mean 35.9**, max 36.4 ms | min 35.4, **mean 36.0**, max 36.4 ms |
| verify / replay | 48–64 / 56–64 ms bulk-loaded | 50–55 / 56–65 ms bulk-loaded |

**No regression is detectable.** Commit latency is flat to three
significant figures (+0.08%). Bulk apply's means differ by **+2.1%**,
inside a run-to-run spread of **13–18%** on this machine — the two
distributions overlap almost completely (baseline min 382 / max 432, post
min 381 / max 450). At n=7 with that variance, +2% is not a measurement.

What it is not is a proof of *zero* cost. There is a plausible mechanism
for a small one: `term_order_ok` is an `assert` on the write path, so it
runs on **every new dictionary term** — 50,494 of them in the bulk-apply
corpus — and `load_term`'s refusal runs on every term on the replay path.
Both are one switch and up to three comparisons. If that costs anything it
is below this harness's noise floor, and the harness would need a tighter
benchmark than `tests/scale` to see it. Recorded as a known, unmeasured
cost rather than claimed to be nothing.

**A separate finding, and it is not this initiative's.** Today's bulk
apply is ~400 ms against `RECORD-T-0018`'s recorded **222–267 ms**, and
today's commit latency ~36 ms against `RECORD-A-0005`'s recorded
**31–35 ms**. The baseline commit measures the same as the post commit on
both, so **the drift from those recorded figures predates
`RECORD-I-0004` entirely** — it happened somewhere between `RECORD-T-0018`
and `43ed124`, or it is this machine differing from the one that recorded
them. Either way the repository's recorded numbers no longer describe this
machine, which is worth someone's attention: `RECORD-A-0005`'s review
trigger is phrased against the 31–35 ms band, and a band that no longer
reproduces is a trigger that cannot fire honestly. Filed here rather than
chased, because chasing it is not this initiative's scope.

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

### 2026-08-25 — the consumer built against it, and the tag is cut

The risk note said not to tag before a consumer had compiled against
this, and odin-rdf-sparql's `SPARQL-T-0030` did exactly that before the
tag existed. What it verified, on the commit rather than on a tag:

- **The `record:` collection resolves and the library links** from a
  repository that is not this one — `Makefile`, `ols.json` and a new
  `tests/smoke` package, `make check` clean.
- **This repository's promise held against the consumer's own corpus,
  not against fixtures written here.** `tests/smoke` reads
  `tests/w3c/sparql12-eval-triple-terms/data-0-tripleterms.ttl` out of
  sparql's vendored suite — the file `apply` used to refuse with
  `{.Unsupported_Term, 0}` — ingests it, applies it clean, and walks
  `snapshot_triple_parts` down through the nested triple term to the
  inlined `123` at the bottom. Two levels of recursion, an inlined
  component, no allocation. That is `RECORD-I-0004`'s §7 consumer ask
  answered by the consumer rather than by us.
- **`snapshot_kind` answers `.Triple`, `snapshot_term_destroy` pairs
  with `snapshot_term`, and `ingest` set-semantics still holds.** All
  four verbs `RECORD-T-0024` added are exercised from outside.
- sparql's full suite is still **512/512 at both widths** with the
  collection added — this store's arrival broke nothing that was
  already there.

**One thing the consumer found that is worth this repository knowing**,
though it is sparql's bug and not ours: an inlined literal's id is
`>= CONSUMER_ID_FIRST`, so a consumer testing "is this one of my own
synthetic ids?" with a bare `>=` threshold misclassifies an ordinary
inlined term. `resident.odin:42`'s comment states the range with both
ends, so the API is not at fault — but it is the second consumer-side
trap in this area (`SPARQL-T-0027` was the first), which is weak
evidence that a `is_consumer_id(id)` helper would be earning its keep.
Recorded, not acted on: no consumer has asked.

### The tag, cut

Annotated, with the body below plus one line naming the consumer that
built against it first, and placed so that the consumer's verdict is
inside it rather than one commit past it — the reverse of `v0.3.0`'s
mistake. **Published** at `435c2b3`, tag and commits both; sparql's
`ci.yml` pins `v0.4.0` and resolves it.

### The tag, as prepared

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