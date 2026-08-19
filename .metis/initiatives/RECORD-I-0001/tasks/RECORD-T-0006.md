---
id: the-proof-layer-independent
level: task
title: "The proof layer: independent verifier, fault corpus, scale measurement"
short_code: "RECORD-T-0006"
created_at: 2026-08-19T17:21:14.857699+00:00
updated_at: 2026-08-19T17:21:14.857699+00:00
parent: RECORD-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0001
---

# The proof layer: independent verifier, fault corpus, scale measurement

## Parent Initiative

[[RECORD-I-0001]]

## Objective

The initiative's exit gate: the vision's "afternoon claim" made executable
(an independent verifier in another language, written from the document
alone), the fault corpus shared between both implementations, and the
scale measurement against the sub-second criterion.

## Acceptance Criteria

- [ ] A Python verifier under `tests/`, written from `doc/design/log.md`
      alone — the constraint is stated in its header comment, and it uses
      only the standard library (CRC-32C is not in it; the table is ~20
      lines and is part of the afternoon).
- [ ] `make test` runs it over segments the Odin writer produced and over
      the fault corpus; both implementations must agree verdict for
      verdict — clean, torn, halt — and on the head hash and epoch for the
      clean cases.
- [ ] A repo-local synthetic generator producing an ISMS-shaped log —
      ~4×10⁵ ops, ~10⁵ distinct terms with realistic lengths, epochs in
      both the bulk-loaded and hand-edited shapes of `log.md` §9 — as a
      test/bench utility, deterministic by seed.
- [ ] Measured on that log: full chain verification and full replay (with
      a collecting consumer) each timed; the sub-second criterion of
      `RECORD-V-0001` checked and the numbers recorded in RECORD-I-0001's
      status.
- [ ] The README's status section moves from "design" to an implemented
      format version 1; `make help` and the Commands section reflect
      everything that now exists.
- [ ] `make check` and `make test` green, including the cross-
      implementation suite.

## Implementation Notes

### Technical Approach

The Python verifier is deliberately boring: sequential file reads,
`struct.unpack`, `hashlib.sha256`, a CRC-32C table. If writing it takes
more than an afternoon or needs a fact this repository's code knows and
the document does not state, that is a *documentation bug* — fix `log.md`,
which is the point of the exercise.

### Dependencies

RECORD-T-0005 (everything it proves must exist). Running `make test` now
requires `python3` on the machine; the Makefile should say so when it is
missing rather than failing cryptically.

### Risk Considerations

The honor system in "written from the document alone" is real but cheap to
keep honest: the verifier cites the section number for every constant it
uses, so a reviewer can check it against the document rather than against
the Odin code.

## Status Updates **[REQUIRED]**

*To be added during implementation*