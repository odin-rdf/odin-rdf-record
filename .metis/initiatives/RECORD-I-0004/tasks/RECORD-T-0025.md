---
id: the-proof-layer-and-the-documents
level: task
title: "The proof layer and the documents: both verifiers agreeing, reserved becomes built, a tag cut"
short_code: "RECORD-T-0025"
created_at: 2026-08-24T20:42:56.281837+00:00
updated_at: 2026-08-24T20:42:56.281837+00:00
parent: RECORD-I-0004
blocked_by: ["RECORD-T-0024"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


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

- [ ] **The Odin and Python verifiers still agree verdict for verdict**,
      head hash and epoch included, over the 29-case fault corpus, on
      every `make test` — the standard `RECORD-T-0006` set.
- [ ] **`tests/verify/rdflog_verify.py` needs no change, and that is
      stated as a finding rather than assumed.** It reads a term
      definition as `id u64, len u32, payload` (§5.2) and never inspects
      the payload's tag, so a new tag is invisible to it. **Checked
      before this initiative was written**; confirm it survived the
      implementation, and if it did not, that is a signal the encoding
      went somewhere §5.2 did not describe.
- [ ] **The scale measurement re-run.** `RECORD-T-0006`'s figures —
      verify 105–272 ms, replay 166–342 ms over 16.9–38.4 MB logs — are
      the vision's sub-second criterion's evidence. A recursive intern and
      a wider dictionary should not move them; confirm rather than assume,
      and if a format-version bump means the corpus is regenerated, say
      so.
- [ ] **`architecture.md` §11.3 amended**: its open question is answered.
      The paragraph stands as the record with a dated note saying the
      reservation was spent, by which task, for which consumer — and that
      the *semantics* it deferred (assert versus mention) remain deferred
      and out of scope. A.6's recommendation of named graphs for
      modelling is untouched.
- [ ] **`log.md` §5.2 amended**: "with `0x07` reserved for RDF 1.2 triple
      terms" becomes what it is, the base-direction tag joins the tag
      list, and the ordering paragraph — "a typed literal's datatype IRI
      must be defined before the literal that references it" — states the
      transitive rule. If the format version moved, §5.2's header
      paragraph and §11's no-schema-evolution rule are amended to record
      that the first bump happened and why.
- [ ] **`api.md` amended** where it describes term kinds and
      `snapshot_kind`'s answers, and §12.8's "what SPARQL will want that
      this does not yet give" re-read — one of its items may have moved.
- [ ] **The untouched list asserted, not assumed** (`RECORD-I-0004` §9):
      `term_inline` and the inline path; the term index; the six
      permutations; the fact table; `Filter`; visibility; the epoch
      table. "Nothing else changed" is the claim this store's proof layer
      exists to make checkable.
- [ ] **A release tagged**, annotated, `Release vX: title` with a
      bulleted body — the owner's act, prepared here. The consumer
      (`SPARQL-T-0035`) pins it, so the tag is this initiative's actual
      deliverable to the outside.
- [ ] **The consumer told what it got.** A short note — in this task's
      Status, where `SPARQL-I-0003`'s author will look — naming the
      procedures added, the ownership rule for a decoded triple term, the
      position decision, and whether the format version moved.
- [ ] **`RECORD-V-0001` Current State amended** with a dated block: the
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

*To be added during implementation*
