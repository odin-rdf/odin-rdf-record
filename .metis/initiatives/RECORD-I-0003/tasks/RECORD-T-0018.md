---
id: measurement-and-the-record-commit
level: task
title: "Measurement and the record: commit latency, footprint, the id range, the amendments"
short_code: "RECORD-T-0018"
created_at: 2026-08-20T11:47:13.417008+00:00
updated_at: 2026-08-20T11:47:13.417008+00:00
parent: RECORD-I-0003
blocked_by:
  - "RECORD-T-0014"
  - "RECORD-T-0015"
  - "RECORD-T-0016"
  - "RECORD-T-0017"
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0003
---

# Measurement and the record: commit latency, footprint, the id range, the amendments

## Parent Initiative

[[RECORD-I-0003]]

## Objective

The numbers the initiative promised, and the documents that must stop
saying what is no longer true. Commit latency and resident footprint at
ISMS scale through `apply`; `RECORD-A-0005`'s review trigger re-read
against the measured number; the consumer id range stated in `api.md`
§3 (decision 10); and the release-convention walk — README, vision, the
family CLAUDE.md — including the "second store beside, not a
replacement" paragraphs, which stand with a dated note.

## Acceptance Criteria

- [ ] `tests/scale` gains an `apply` path: the ISMS corpus committed
      through `apply` in both §9 shapes (bulk: one epoch of 4×10⁵ ops;
      hand-edited: 2×10⁵ small changesets on `mem_ops`), measuring per-
      commit latency at 3.4×10⁵ facts (the rebuild baseline is 45–57 ms;
      the term-index merge is new) and the resident footprint after
      T-0014 removed `by_term`. Numbers recorded in the initiative's
      Status section, as I-0002 did.
- [ ] `RECORD-A-0005`'s review trigger ("measured commit latency") is
      re-read against the number and the ADR annotated: the delta
      structure stays deferred, or a follow-on is filed — a sentence
      either way.
- [ ] `api.md` §3 states the consumer id range — inline flag set, tag 0,
      `0x8000_0001 ..= 0x8FFF_FFFF` — as ids that can never name a term
      and are available to consumers' own rows; a named constant in
      `record` (`CONSUMER_ID_FIRST`, or the range as a pair) with a doc
      comment saying the store never sees these ids. No runtime check.
- [ ] The release walk (family CLAUDE.md convention): README's Status
      section says the store accepts changesets through `apply`, has a
      validator seam, an `ingest` subpackage and a memory `File_Ops`,
      and states what the log does not record (decision 5);
      `.metis/vision.md` Current State amended with a dated paragraph —
      the write path is real, and the "second store beside" stance is
      superseded by the family's 2026-08-20 decision to move the
      siblings here; the family `CLAUDE.md`'s record section and its
      "not a replacement" sentences amended the same way, old text
      standing with the dated note.
- [ ] A short list, in the initiative's Status section, of what the
      siblings' CI needs from a published repository: a tag to pin
      (`checkout@vX`), `-collection:record=../odin-rdf-record` in their
      Makefiles and `ols.json`, and the POSIX-only note for their
      Windows leg. Publication and tagging themselves are the owner's.
- [ ] A handoff section for the sibling port initiatives (on their
      side): the read-API mapping the survey found, the 64-bit widening
      rule, `snapshot_kind` and `snapshot_exists`, the `Validator`
      shape shacl binds, the memory `File_Ops` for their suites, and
      the triple-term limit sparql must record.
- [ ] `make check` and `make test` green; the initiative's exit
      criteria checked off and the initiative completed.

## Implementation Notes

### Technical Approach

`tests/scale` measures optimized (a debug harness measures the
harness), with the tracking allocator for true bytes, as T-0012 did.
Hand-edited shape on `mem_ops` only — 2×10⁵ real fsyncs on darwin is
an hour (the standing note).

### Dependencies

Everything before it: RECORD-T-0014 through RECORD-T-0017.
