---
id: the-proof-layer-independent
level: task
title: "The proof layer: independent verifier, fault corpus, scale measurement"
short_code: "RECORD-T-0006"
created_at: 2026-08-19T17:21:14.857699+00:00
updated_at: 2026-08-19T19:53:59.921720+00:00
parent: RECORD-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


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

- [x] A Python verifier under `tests/`, written from `doc/design/log.md`
      alone — the constraint is stated in its header comment, and it uses
      only the standard library (CRC-32C is not in it; the table is ~20
      lines and is part of the afternoon).
- [x] `make test` runs it over segments the Odin writer produced and over
      the fault corpus; both implementations must agree verdict for
      verdict — clean, torn, halt — and on the head hash and epoch for the
      clean cases.
- [x] A repo-local synthetic generator producing an ISMS-shaped log —
      ~4×10⁵ ops, ~10⁵ distinct terms with realistic lengths, epochs in
      both the bulk-loaded and hand-edited shapes of `log.md` §9 — as a
      test/bench utility, deterministic by seed.
- [x] Measured on that log: full chain verification and full replay (with
      a collecting consumer) each timed; the sub-second criterion of
      `RECORD-V-0001` checked and the numbers recorded in RECORD-I-0001's
      status.
- [x] The README's status section moves from "design" to an implemented
      format version 1; `make help` and the Commands section reflect
      everything that now exists.
- [x] `make check` and `make test` green, including the cross-
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

### 2026-08-19 — complete

`make check` and `make test` green: 35 tests across record, tests/tool,
tests/proof, tests/scale. Deliverables:

- **`tests/verify/rdflog_verify.py`** — ~270 lines of Python stdlib,
  written from log.md alone (constraint stated in the header; every
  constant cites its section). Mirrors `verify` exactly, the §6 and §7.2
  amendments included: header cross-checks by equality, the base-hash
  rule, frame taxonomy under the position rule with the before-EOF
  refinement, the rotation-crash husk, unknown-kind-never-torn, seals
  read but not chained. Output is one canonical line (clean/torn-tail/
  torn-header/halting-word) with the same 0/2/1 exit contract as the
  Odin tool. **The afternoon claim held, and no documentation bug
  surfaced** — the T-0003/T-0005 amendments were sufficient.
- **`tests/proof`** — the shared fault corpus: a 3-segment store written
  through the real posix ops, 29 cases (truncations at and off record
  boundaries, all four torn shapes, bit flips in sealed bodies / open
  non-final / open final / the seal itself, header tampering with
  recomputed CRCs, wrong segment/first-epoch/first-fact-id, base-hash
  flip, future-version header, three husk shapes, crafted epoch gap and
  both chain breaks, removed segment 1, trailing bytes on a sealed
  segment). Both implementations produce one canonical line per case;
  the lines must be equal (verdict + head hash + epoch + tear location
  in one comparison) AND match the case's pinned expected verdict, so
  the implementations cannot drift together.
- **`tests/scale`** — the deterministic generator (splitmix64, seed
  constant): 400k ops, 95,343 terms with realistic encodings (IRIs,
  string/lang literals, typed dates with the §5.2 datatype-first
  ordering, inlined integers, named + default graphs, retracts of live
  quads), written through the real writer against an in-memory File_Ops
  and flushed to disk, then verified and replayed through the posix
  path. Measured (Apple Silicon dev machine): bulk-loaded (10³ epochs,
  16.9 MB) verify 105 ms, replay 166 ms; hand-edited (2×10⁵ epochs,
  38.4 MB) verify 272 ms, replay 342 ms. Recorded in RECORD-I-0001's
  new Status section; sizes land inside §9's 18–41 MB projection.
- Makefile: PKGS grew tests/proof and tests/scale; `make test` refuses
  with a clear message when python3 is absent. README status moved from
  "design" to implemented format version 1, with the proof layer and
  the not-yet-built resident store stated plainly.

The initiative's exit criteria are all met; RECORD-I-0001 completion is
the user's call (human-in-the-loop for initiative transitions).