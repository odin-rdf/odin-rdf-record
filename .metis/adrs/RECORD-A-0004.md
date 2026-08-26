---
id: 001-six-triple-orders-with-g-as
level: adr
title: "Six triple orders with G as tiebreaker; no graph-first permutations"
number: 1
short_code: "RECORD-A-0004"
created_at: 2026-08-19T15:55:46.128148+00:00
updated_at: 2026-08-19T17:09:57.122562+00:00
decision_date: 
decision_maker: 
parent: 
archived: false

tags:
  - "#adr"
  - "#phase/decided"


exit_criteria_met: false
initiative_id: NULL
---

# ADR-1: Six triple orders with G as tiebreaker; no graph-first permutations

**Status: accepted 2026-08-19.** `api.md` §5.1's open seam, created when `log.md` §5.3
made the graph component mandatory and nobody revisited the index design.

## Context

Two incompatible sets of six exist in the founding documents.
`architecture.md` §4.1's six are triple orders — SPO, SOP, PSO, POS, OSP,
OPS — giving every join ordering but no graph-bound prefix. Its §9's six —
three graph-last, three graph-first — cover all sixteen quad patterns but
only three join orders per family. §9's cost argument (quads at 2.4× on
disk) was a B+tree artifact and is gone: in memory every order is a
`[]FactID` at 1.6 MB flat, so the choice is purely about which access
patterns to privilege.

## Decision

**`architecture.md` §4.1's six with `G` appended as the final tiebreaker** —
SPOG, SOPG, PSOG, POSG, OSPG, OPSG — and no graph-first permutations. A
bound graph is always residual: one comparison against a `Fact` field that
the visibility test has already loaded into a register (`api.md` §12.2's
prefix table). If graph-bound queries against a small graph ever get hot,
the escape hatch is a per-graph sorted `[]FactID` posting list — 1.6 MB
total, since every fact is in exactly one graph — never three more full
permutations.

**Amended 2026-08-27 (RECORD-T-0028): the escape hatch was spent, as one
graph-first order, on this decision's own review trigger — ahead of the
measurement it asks for, on a consumer's stated query shape.** The consumer is
the application's workspace design (a named graph per workspace; the read scope
a graph set), and the shape is `GRAPH <W> { ?r a risk:Risk }` — G, P, O bound —
required not to scan every Risk in the store. The posting list as written above,
sorted by fact id, answers `(G)` alone; that shape needs POS order within each
graph, and per-graph POS-ordered lists laid end to end *are* the `GPOS`
permutation. So `Order` has a seventh member, `GPOS`, built through the same
radix sort, 4 bytes per fact — one order, not §9's three, and "never three more
full permutations" holds. `choose_order` lets `G` lead in exactly one case:
bound, with S unbound and O not bound without P. Everything with S bound keeps
this decision's rule. The negative consequence below is answered for `(G)`,
`(G,P)` and `(G,P,O)`; the format is untouched; the measurement is in the task.

## Rationale

Join-order coverage is what the downstream engines need: merge joins want
their inputs sorted on the join variable, and leapfrog triejoin wants every
variable order available (`api.md` §12.3). Graph filtering, by contrast, is
one predicate on data already in hand — the same reasoning that deleted the
side value index at this scale (`architecture.md` §Scale), applied to the
graph position. Choosing §9's six instead would trade join orders the
planner will actually use for prefix coverage the residual check already
provides at negligible cost.

## Consequences

### Positive
- Every triple pattern prefix-covered; every join order available from the
  start; `MatchAs` can honor any planner request.
- One rule for `G` everywhere: never in the prefix, always residual —
  simpler order-selection logic and no sixteen-pattern table.

### Negative
- `GRAPH <g> { ?s ?p ?o }` with nothing else bound scans the whole SPOG
  order and filters, rather than seeking a `G` prefix. At 4×10⁵ facts that
  is the ~10 ms full-scan ceiling, acceptable per the scale premise.
  *(No longer: since RECORD-T-0028 it is a `GPOS` prefix, as are `(G,P)` and
  `(G,P,O)`. `(G,O)` and every S-bound shape are as this bullet describes.)*

### Neutral
- `Filter.Graphs` (graph *sets*, for `FROM`/`FROM NAMED`) is unaffected —
  it was always residual, whichever six were chosen.

## Review Triggers

- A measured hot path of graph-bound queries where the bound graph is a
  small fraction of the store (the TBox case `api.md` §5.1 names) — answer
  with the posting-list escape hatch, not with new permutations.
- The scale premise moving: at 10⁷+ facts the full-scan ceiling stops being
  10 ms and this whole trade must be re-argued.