---
id: the-six-permutations-sort-built-g
level: task
title: "The six permutations: sort-built, G-residual"
short_code: "RECORD-T-0008"
created_at: 2026-08-19T20:10:33.206253+00:00
updated_at: 2026-08-19T22:04:52.358576+00:00
parent: RECORD-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


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

- [x] Exactly six permutations, the 3! of (S, P, O), `G` residual in each;
      nothing graph-first exists (RECORD-A-0004 enforced by the type
      surface, not by discipline).
- [x] Built by sorting `[]FactID` after replay completes; the fact table
      itself stays in log order (append-built, never reordered).
- [x] Comparator correctness against a brute-force ordering oracle on
      generated data, covering duplicate prefixes at every depth, the
      retracted-generation case (same quad re-asserted — two FactIDs,
      adjacent under every order), and inlined components (offset-binary
      payloads sort numerically, the property RECORD-A-0001 bought).
- [x] Deterministic: the same log yields byte-identical permutations,
      ties broken by `FactID`.
- [x] Sortedness asserted over the ISMS-scale log; build time logged here
      (the formal measurement is RECORD-T-0012's).
- [x] `make check` and `make test` green.

## Implementation Notes

### Technical Approach

One comparator generator over the fact table (components are resident
`u32`s, so every comparison is integer compares), six sort calls. The
comparator reads facts through the table, not through copies — the
permutations are `[]FactID` and nothing else, which is the noscan
property api.md §4.1 prices.

*Amended 2026-08-19 during implementation: through-the-table comparison
was measured at 756 ms for the six sorts at ISMS scale — see the status
update. The sort now materializes transient key-beside-id records,
freed before returning; the resident form ([]FactID only, noscan) is
exactly as specified above.*

### Dependencies

RECORD-T-0007 (the fact table the sorts order).

### Risk Considerations

The quiet failure is a comparator that agrees with the oracle on random
data and disagrees on adjacent duplicates — the oracle corpus must be
constructed to contain them, not hoped to.

## Status Updates **[REQUIRED]**

### 2026-08-19 — implemented; `make check` and `make test` green

**Where the code went.** `record/permute.odin` + `permute_test.odin`,
beside `resident.odin` as the layout files. `Order` (SPOG, SOPG, PSOG,
POSG, OSPG, OPSG — RECORD-A-0004 enforced by the enum having no
graph-first member), `Component`, `order_key` (G at depth 3 in every
order), `fact_component`, and `store_build_permutations` — log.md §8's
buildPermutations, also the future delta-merge rebuild (api.md §5.2),
one code path. `Store` gained `ord: [Order][]u32`; rebuilding replaces
an order wholesale.

**One divergence from this task's own Technical Approach, measured and
recorded.** "The comparator reads facts through the table, not through
copies" costs 756 ms at `-o:speed` for the six sorts at ISMS scale
(3.4×10⁵ facts) — two random gathers into an 8 MB table per compare —
against api.md §5.2's ~30 ms estimate and most of the sub-second boot
budget. The implementation sorts *transient* key-beside-id records
instead (one buffer, reused across the six orders, freed before
returning — scaffolding in log.md §8's live-map sense), packing the
key into two u64s: **535 ms at `-o:speed`, 1753 ms in the debug test
build** (from 3536 ms through-the-table debug). The resident form is
unchanged — `[]FactID` and nothing else, the noscan property intact.
The remaining floor is the sort's indirect comparator call; the known
next lever is a ~50-line radix sort, deliberately not spent here —
RECORD-T-0012's formal measurement decides whether it is needed.
**Both documents amended** with dated measurement notes (api.md §5.2,
log.md §8): the ~30 ms / "tens of milliseconds" estimates were
optimistic ~18×; the build-by-sorting and readers-unaffected
conclusions stand.

**Determinism is structural**: FactID is the final comparator key, so
the order is total and any correct sort — stability regardless —
reproduces it byte-identically; tested by rebuilding twice and across
two stores from one corpus.

**Tests.** Exact expected orders for all six permutations on a
hand-computed 7-fact corpus colliding at every depth (G-residual
decides f3/f4; f4/f5 are one quad re-asserted — two generations,
adjacent, FactID-tied; the retracted generation indexed like any
other). Inline ordering: dict id < boolean < integer(-3) < integer(4)
< date under OSPG/OPSG — the offset-binary property surviving the
re-tag. The oracle suite: 4096 facts over 108 distinct quads
(duplicate prefixes wall-to-wall, per this task's risk note), each
order checked as a true permutation and strictly ascending under an
independent materialized-tuple compare. At ISMS scale: sortedness of
all six asserted through the public key surface in `tests/scale`, and
the build time logged there per the acceptance criterion.

42 record-package tests (+3); `make check` and `make test` green.

### 2026-08-19 (follow-up, same session) — the radix sort, spent

The session chose not to leave the 535 ms on the boot path: under the
eviction model (api.md §8) every wake pays store_build_permutations,
staggered machine boots multiply it by hundreds of stores, and the
next user after an idle eviction pays it interactively. The sort is
now LSD radix: per order, one stable 16-bit counting pass per
component digit, least-significant component first, from FactID order
— stability carries the tie, so determinism needs no comparator at
all. Component values are gathered once into dense columns; a
component whose values never reach the high 16 bits (every
dictionary-id-only column in practice) skips that digit's pass, and a
single-digit pass is detected from its histogram and skipped as the
identity.

**Measured: 39 ms at `-o:speed`** (193 ms in the debug harness) for
the six orders at 3.4×10⁵ facts — 14× over the record sort, and the
"tens of milliseconds" both documents assumed, restored. Optimized
boot at ISMS bulk scale is now verify 40 ms + replay ~50 ms + sort
39 ms — well inside the sub-second criterion with margin for T-0011's
end-to-end path. Both document amendments updated to tell the whole
story (comparison sorts miss the estimate ~18×; the implemented radix
meets it). The oracle, exact-order, inline-order, and determinism
tests passed unchanged across the algorithm swap — they are
algorithm-independent by construction, which is what made the swap
safe — plus a new empty-store case (43 record tests).