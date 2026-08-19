---
id: the-six-permutations-sort-built-g
level: task
title: "The six permutations: sort-built, G-residual"
short_code: "RECORD-T-0008"
created_at: 2026-08-19T20:10:33.206253+00:00
updated_at: 2026-08-19T20:10:33.206253+00:00
parent: RECORD-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0002
---

# The six permutations: sort-built, G-residual

## Parent Initiative

[[RECORD-I-0002]]

## Objective

The six sorted `[]FactID` permutations — the 3! orders of (S, P, O), each
with `G` as the residual tiebreaker and no graph-first order anywhere
(RECORD-A-0004) — built once at the end of replay by sorting, never by
incremental insertion (`log.md` §8's cost argument). Every fact
generation is indexed, retracted ones included: visibility at an epoch is
the reader's filter, never the index's shape — which is what makes
`At(historical)` a filter change instead of a different index.

## Acceptance Criteria

- [ ] Exactly six permutations, the 3! of (S, P, O), `G` residual in each;
      nothing graph-first exists (RECORD-A-0004 enforced by the type
      surface, not by discipline).
- [ ] Built by sorting `[]FactID` after replay completes; the fact table
      itself stays in log order (append-built, never reordered).
- [ ] Comparator correctness against a brute-force ordering oracle on
      generated data, covering duplicate prefixes at every depth, the
      retracted-generation case (same quad re-asserted — two FactIDs,
      adjacent under every order), and inlined components (offset-binary
      payloads sort numerically, the property RECORD-A-0001 bought).
- [ ] Deterministic: the same log yields byte-identical permutations,
      ties broken by `FactID`.
- [ ] Sortedness asserted over the ISMS-scale log; build time logged here
      (the formal measurement is RECORD-T-0012's).
- [ ] `make check` and `make test` green.

## Implementation Notes

### Technical Approach

One comparator generator over the fact table (components are resident
`u32`s, so every comparison is integer compares), six sort calls. The
comparator reads facts through the table, not through copies — the
permutations are `[]FactID` and nothing else, which is the noscan
property api.md §4.1 prices.

### Dependencies

RECORD-T-0007 (the fact table the sorts order).

### Risk Considerations

The quiet failure is a comparator that agrees with the oracle on random
data and disagrees on adjacent duplicates — the oracle corpus must be
constructed to contain them, not hoped to.

## Status Updates **[REQUIRED]**

*To be added during implementation*