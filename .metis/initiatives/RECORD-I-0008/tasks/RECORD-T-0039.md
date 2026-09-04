---
id: the-claim-scoped-what-tamper
level: task
title: "The claim, scoped: what tamper-evident means here, and forge.py as a maintained corpus artifact"
short_code: "RECORD-T-0039"
created_at: 2026-09-02T21:26:55.777240+00:00
updated_at: 2026-09-02T21:26:55.777240+00:00
parent: RECORD-I-0008
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0008
---

# The claim, scoped

## Parent Initiative

[[RECORD-I-0008]]

## Objective **[REQUIRED]**

Make the repository state its own trust model, so a reader learns the scope
of "tamper-evident" from us rather than from an adversarial review — and
keep the forgery as a live artifact rather than a war story.

## What overstates today

- **`README.md:3`** — "A tamper-evident RDF **system of record**",
  unqualified, and further down "Nothing is ever deleted or rewritten",
  which is a property of *our writer*, not of the format under an
  adversary.
- **`.metis/vision.md:23`** — the same headline.
- **`log.md` §1 goal 2** — "Be tamper-evident, and provably so by a third
  party." Half-met and worth saying so: a third party really can verify
  without our code, and what they prove is "internally consistent", not
  "this is the history that was written".

`log.md` §5.4 and `:696` already get this right ("cannot be tampered with
*silently, in the middle*", and the protection against re-writing "is the
externally published head hash"). The fix is to lift that honesty to the
top-level claims rather than leave it 400 lines into the format spec.

## Acceptance Criteria **[REQUIRED]**

- [ ] `README.md`, `.metis/vision.md` and `log.md` §1 goal 2 state, in one
      or two sentences each, that the chain provides **integrity** —
      detecting alteration by anything that cannot recompute it — and that
      **authenticity requires an anchor or a signature outside the store**,
      because the chain is unkeyed. Point at the seams once they exist.
- [ ] Amend rather than rewrite, per the family convention: the existing
      sentence stands with a dated note saying what moved.
- [ ] `CLAUDE.md` in the family root gets the same amendment — it is what
      the next session trusts, and the release convention says to walk it.
- [ ] `forge.py` moves from `.metis/initiatives/RECORD-I-0008/` into
      `tests/verify/` beside `rdflog_verify.py`, with a header saying what
      it is for: **the adversary's tool, kept so the claim stays honest.**
- [ ] `forge.py` is taught to update the seal too, and the `forged-clean`
      corpus case pinned by [[RECORD-T-0036]] is re-pinned to `clean`,
      with a comment explaining that this is correct and expected: an
      unkeyed chain cannot detect a full rewrite, and the case exists to
      prove that the *anchor* ([[RECORD-T-0037]]) is what catches it.
- [ ] A test that the anchor check catches the forged store — the positive
      form of the same evidence.
- [ ] `make test` green with the extended corpus; both verifiers agreeing.

## Notes

- **Do not weaken the claim into uselessness.** What the chain buys is
  real and should be stated as plainly as the limit: tampering is
  **total** — one record cannot be touched without rewriting every
  subsequent record, every segment header, and every sealed file, which is
  exactly the property that a WORM archive or a published head converts
  into a hard barrier. The honest sentence has both halves.
- `architecture.md:1104` already contains the right framing
  (tamper-*evident* vs tamper-*evident-and-attributable*); reuse its
  vocabulary rather than inventing new terms.
- Sequenced last so the documents can describe seams that exist. If the
  initiative stalls after [[RECORD-T-0036]], **do this one anyway** — the
  documentation half is independently valuable and is the part that costs
  nothing.

## Status

**2026-09-02 — todo.**
