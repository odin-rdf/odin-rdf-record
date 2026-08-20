---
id: narrow-the-u32s-distinct-term-id
level: task
title: "Narrow the u32s: distinct Term_ID, Fact_ID and Epoch types across the public API"
short_code: "RECORD-T-0020"
created_at: 2026-08-20T18:06:10.904775+00:00
updated_at: 2026-08-20T18:17:45.278561+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#tech-debt"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: NULL
---

# Narrow the u32s: distinct Term_ID, Fact_ID and Epoch types across the public API

## Objective **[REQUIRED]**

Four unrelated integer spaces share one Odin type in this package, and the
compiler cannot tell them apart:

| space | where it appears | today |
| --- | --- | --- |
| **term id** (a dictionary id or an inlined term; bit 31 set means inlined, api.md §3) | `Pattern.s/p/o/g`, `Fact.s/p/o/g`, `Quad`, `Resident_Op`, `Epoch_Meta.actor/reason`; `snapshot_resolve` → id, `snapshot_kind`/`snapshot_bytes`/`snapshot_term`(id), `intern_term`, `dict_add`, `dict_bytes`; `MATCH_DEFAULT_GRAPH`, `CONSUMER_ID_FIRST ..= CONSUMER_ID_LAST` | `u32` |
| **fact id** (index into the fact table) | `scan_next` → id, `snapshot_fact`/`snapshot_visible`/`snapshot_derived`(id), `store_fact`, `fact_append` → id, `rollback(touched: []u32)` | `u32` |
| **epoch** | `apply` → epoch, `store_at(epoch)`, `Snapshot.epoch`, `Fact.assert/retract`, `snapshot_epoch_meta(epoch)`, `store_note_at`, `LIVE_EPOCH` | `u32` |
| **segment number** | `segment_path(seg_no)` and the writer | `u32` |

Across the read API's most common sequence — `scan_next` (fact id) →
`snapshot_fact` (fact id) → `f.s` (term id) → `snapshot_term` (term id) —
two spaces are crossed with nothing but parameter names keeping them apart;
`store_at(epoch)` beside `snapshot_term(snap, id)` is a third. A consumer
that swaps two of them gets a wrong answer, not a compile error. (The first
consumer noticed: odin-rdf-shacl's `Session.graph: u32` holds a term id that
must never be `0` — "every graph" in a `Pattern` — and the question "what is
this `u32`, really?" had to be answered in prose.)

Introduce distinct types and use them throughout the public API:

```odin
Term_ID :: distinct u32   // a dictionary id or an inlined term (api.md §3)
Fact_ID :: distinct u32   // an index into the fact table
Epoch   :: distinct u32   // an epoch number; 0 is the empty world
```

`api.md` §3 already sketches `type ID uint32` for the first; the
implementation never made it distinct. Counts (`snapshot_terms`, chunk
sizes, radix passes) stay `u32` — they are quantities, not identities. The
segment number is the writer's private business and may stay `u32` or take
`Segment_No :: distinct u32` at the implementer's discretion; it never
reaches a consumer.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Tech Debt - Code improvement or refactoring

### Priority
- [x] P1 - High (important for user experience)

### Technical Debt Impact **[CONDITIONAL: Tech Debt]**
- **Current Problems**: 40 `u32` struct fields and ~35 `u32`-typed
  procedures in `record/` spanning four meanings; every consumer reproduces
  the ambiguity (shacl's `Session.graph`, its `Focus_Node.id`, its
  `Bindings` arrays) and documents it by hand; a fact id passed where a term
  id goes compiles.
- **Benefits of Fixing**: the compiler enforces the boundaries on the read
  sequence above and at every `Pattern` construction; consumers inherit the
  types (`Session.graph: record.Term_ID`, `store_at(s, Epoch)`) for free and
  stop inventing veneers; the as-of coordinate is visibly an `Epoch`, not a
  number that might be a term.
- **Risk Assessment**: a signature change on a `v0.x` API with two
  consumers (odin-rdf-shacl ported, odin-rdf-sparql about to be). Now is the
  cheap moment — the cost is explicit conversions where ids are arithmetic
  (chunk indexing, the inline bit, radix sort, the on-disk `u64` widening in
  `disk_id`/`resident_id`), and the longer it waits the more consumer code
  has `u32` baked in. No format change: the log encodes `u64` and is
  untouched.

## Acceptance Criteria

**[REQUIRED]**

- [ ] `Term_ID`, `Fact_ID` and `Epoch` declared `distinct u32` in `record`,
      with one doc comment each stating what the integer is and what `0`
      means in that space (term: "none" / the default graph in a fact;
      fact: the first fact; epoch: the empty world).
- [ ] Every public procedure and struct in the table above uses them;
      `Pattern`, `Quad`, `Fact`, `Resident_Op`, `Epoch_Meta`, `Snapshot`
      included. The sentinels (`MATCH_DEFAULT_GRAPH`, `LIVE_EPOCH`,
      `CONSUMER_ID_FIRST/LAST`) are typed.
- [ ] Internal arithmetic converts explicitly at the boundary (`u32(id)`,
      `Term_ID(x)`), and the conversions are where the meaning changes —
      the inline-bit test, chunk index/mask, `disk_id`/`resident_id` — not
      sprinkled.
- [ ] `make test` and `make check` green; the Python verifier and the
      format untouched (this is resident-side only).
- [ ] `api.md` §3 / §12 amended to name the three types; the handoff
      mapping in RECORD-I-0003's Status updated (it says `u32` in several
      places).
- [ ] A tag, so consumers pin it: odin-rdf-shacl adapts in one motion
      (`Session.graph`, `Focus_Node.id`, the `u32` arrays in `Bindings`,
      `Validator`'s `check`), and odin-rdf-sparql's port starts from the
      typed API rather than migrating later.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Declare the three types; let the compiler enumerate the sites. Fields and
signatures first, then the conversions the errors point at. Watch the
places where one `u32` array carries a different space than its neighbour
(`rollback(touched: []u32)` is fact ids; the term index is term ids; the
permutation arrays are fact ids sorted by term-id columns).

### Dependencies
None on record's side. Filed from odin-rdf-shacl's SHACL-I-0004 port
(2026-08-20), where the question came up; shacl adapts after the tag.

## Status Updates **[REQUIRED]**

*To be added during implementation*