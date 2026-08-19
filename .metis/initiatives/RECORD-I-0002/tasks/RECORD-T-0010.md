---
id: the-read-api-match-iter-resolve
level: task
title: "The read API: Match, Iter, Resolve, Bytes, Term"
short_code: "RECORD-T-0010"
created_at: 2026-08-19T20:10:43.745002+00:00
updated_at: 2026-08-19T20:10:43.745002+00:00
parent: RECORD-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0002
---

# The read API: Match, Iter, Resolve, Bytes, Term

## Parent Initiative

[[RECORD-I-0002]]

## Objective

The pattern-matching read surface of api.md §12, layers 0–2, on a
snapshot: `Match(Pattern)` choosing a permutation and answering as one
prefix range; `Iter` streaming facts through the filter set (origin,
graph set, and the snapshot's live-at-epoch predicate — `G` is always
residual, RECORD-A-0004); `Resolve(term)` with the cheap miss; and term
materialization, `Bytes(id)` as an arena view with no copy and
`Term(id)` through the codec RECORD-T-0005 built with exactly this
consumer named. This is the surface odin-rdf-sparql and odin-rdf-shacl
eventually target, so its contracts are documented at the standard the
family's match interface set.

## Acceptance Criteria

- [ ] Every bound/wildcard shape of (S, P, O) selects the permutation
      api.md §12.2 prescribes and answers as one binary-searched prefix
      range; a bound `G` is always a residual comparison, never a prefix.
- [ ] `Iter` streams — no result materialization — through
      `Filter{origin, graphs}` composed with the snapshot's epoch
      predicate; concrete types, so the hot path is a bounds check, a
      load, and compares (api.md's stated shape).
- [ ] `Resolve(term)` interns nothing: the canonical encoding of the
      probe is built caller-side or in scratch, the miss is cheap (the
      404 fast-reject of api.md §12.2), and a hit returns the resident
      id.
- [ ] `Bytes(id)` returns the arena view, zero-copy, lifetime documented
      against the snapshot; `Term(id)` materializes through
      `record/term.odin` for both dictionary and inlined ids, and the
      two agree with what the writer interned, byte for byte.
- [ ] Conformance: every pattern shape × several epochs × filter
      combinations against a brute-force scan oracle over the fact
      table, on both the crafted test log (inlined components, named and
      default graphs, retracted generations) and the ISMS-scale log
      (sampled patterns).
- [ ] Contract-level doc comments on every public procedure — the
      family's standard.
- [ ] `make check` and `make test` green.

## Implementation Notes

### Technical Approach

Prefix ranges are two binary searches per bound prefix over one
permutation; everything after the prefix is the iterator's residual
predicate. `EntityHistory` and the attribution queries (api.md §12.6)
are deliberately NOT here — the initiative's Detailed Design leaves them
a decompose-time call, and the epoch table T-0007 builds is sufficient
for them to be added as a small follow-on task if wanted.

### Dependencies

RECORD-T-0008 (permutations) and RECORD-T-0009 (the snapshot the API
hangs off).

### Risk Considerations

The oracle is the defense against the classic prefix-range bugs
(off-by-one at range ends, a residual filter applied to the wrong
position). The oracle must share nothing with the implementation but
the fact table itself.

## Status Updates **[REQUIRED]**

*To be added during implementation*