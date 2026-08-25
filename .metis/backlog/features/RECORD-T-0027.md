---
id: ordered-reads-are-unusable-for-sparql
level: task
title: "Ordered reads are unusable for SPARQL ORDER BY: what RECORD-A-0001's id scheme costs, measured"
short_code: "RECORD-T-0027"
created_at: 2026-08-25T15:05:00.000000+00:00
updated_at: 2026-08-25T15:05:00.000000+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#feature"
  - "#phase/backlog"


exit_criteria_met: false
initiative_id: NULL
---

# Ordered reads are unusable for SPARQL ORDER BY: what RECORD-A-0001's id scheme costs, measured

## Objective **[REQUIRED]**

**Evidence, not a request, and not a precondition** — the same standing as
`RECORD-T-0026`, filed alongside it by odin-rdf-sparql at the close of its
port (`SPARQL-I-0003`, `SPARQL-T-0039`). Nothing is blocked on it.

`api.md` §12.8 already says "`ORDER BY` has no cheap path", and it is
right. **It is right in a stronger sense than it states**, and that
correction is the reason this is filed rather than left as a known note.
§12.8 continues: "IDs are inlined in order within their type (§5.1), so
numeric ordering is nearly free while string ordering is not — an
asymmetry worth knowing before someone benchmarks it."

**Numeric ordering is not nearly free either.** It is unavailable, for the
same reason string ordering is.

## The measurement

`snapshot_match_as` lets a planner name the permutation outright, and
`Range.order` reports what it got — a better shape than the store
odin-rdf-sparql came from, which could only answer yes or no to "can this
pattern lead with that position?". odin-rdf-sparql planned to use it for
three things: `MIN`/`MAX` in one read, a streaming `ORDER BY`, and an
`ORDER BY … LIMIT n` that stops at n. It could take none of them.

`RECORD-A-0001`'s frozen scheme: bit 31 flags an inlined term, bits 30..28
tag it, the low 28 bits are an offset-binary payload. So **inlined
integers do sort numerically among themselves** — the property §5.1
claims, and it holds — and **every dictionary id (< 2^31) sorts before
every inlined id (>= 2^31)**.

Five ordinary values in one store, ids read back with `snapshot_resolve`:

| term | id | |
| --- | --- | --- |
| `1` | 0xa8000001 | inlined |
| `3` | 0xa8000003 | inlined |
| `200000000` | 6 | **dictionary** — past the 2^27 payload |
| `"2.5"^^xsd:decimal` | 9 | **dictionary** — only booleans, canonical integers and dates inline |
| `"007"^^xsd:integer` | 11 | **dictionary** — a non-canonical lexical form is a different term |

- **By this store's id order**: 200000000, 2.5, 007, 1, 3.
- **By SPARQL's `ORDER BY`**: 1, 2.5, 3, 007, 200000000.

Not one position apart — unrelated. The largest value sorts first and the
smallest fourth.

## Why no planner can work around it

Three independent mechanisms produce the disagreement, each fatal alone,
and **each is ordinary data**: an integer past 1.34x10^8; any decimal,
float or double, which SPARQL compares by value across the whole numeric
tower; and any non-canonical lexical form, which is RDF term identity done
*correctly* and which this store is right about.

What disqualifies a value is a property of **that value**. SPARQL has no
static types — a variable's datatype is not knowable from the query text,
and `FILTER(?r < 100)` admits `"5.0"^^xsd:decimal` — so an engine cannot
establish, from a pattern and a sort key, that the two orders agree. The
set of statically provable cases is **empty**, not small.

It applies to `MIN`/`MAX` identically, since SPARQL defines them over the
`ORDER BY` ordering. So the "small, self-contained" half of that work had
the same blocker as the large half rather than a lesser one.

odin-rdf-sparql closed its task as evidence on this basis (owner decision,
2026-08-25) and guards the finding in `sparql/order_id_gap_test.odin`:
one test asserts these id relationships against a live store, so a future
encoding change here will say so on their side.

## What this is not

- **Not a request to make the dictionary order-preserving.** `api.md`
  §5.3 rejected that because renumbering is fatal, and the reasoning
  stands. `architecture.md` §10.3 sketches a per-type order-preserving
  subspace as the narrower alternative; §5.1's own note that a *per-type*
  subspace "could get most of the benefit" is the thread, if anyone ever
  pulls it. **It would be a format change to a frozen encoding**, which is
  a much larger thing than this note.
- **Not a defect.** `snapshot_match_as` does exactly what it documents.
  The gap is between what an ordered read gives and what SPARQL's
  ordering requires, and no one had written the two down side by side
  before.
- **Not urgent, and possibly never actionable.** odin-rdf-sparql sorts,
  as it always did, and is green.

## The general observation, which may be the useful part

`api.md` §12 was drafted against "a SPARQL engine will eventually sit on
this", and largely that paid off — snapshots cost the engine nothing, and
`range_len` turned out to be *better* than the cardinality estimate it
went looking for, exact where it expected an estimate that could decline.
**Ordered iteration is the one that did not**, and the reason is worth
generalizing: the surface was designed correctly for the operation, and
the mismatch was in the *semantics of the values flowing through it*.
Designing an API for a consumer is not the same as the consumer being
able to use it, and no amount of consultation would have surfaced this
earlier than a working engine did.

## Status Updates **[REQUIRED]**

- **2026-08-25 — Filed by odin-rdf-sparql at the close of `SPARQL-I-0003`**
  (`SPARQL-T-0039`), with the owner's agreement to file cross-repository.
  The measurement is reproducible from `sparql/order_id_gap_test.odin`;
  the analysis is in `SPARQL-T-0038`'s Status.
