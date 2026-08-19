---
id: 001-the-inline-term-encoding-is-fixed
level: adr
title: "The inline-term encoding is fixed before the first record"
number: 1
short_code: "RECORD-A-0001"
created_at: 2026-08-19T15:55:41.920017+00:00
updated_at: 2026-08-19T17:09:54.299746+00:00
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

# ADR-1: The inline-term encoding is fixed before the first record

**Status: accepted 2026-08-19.** The measurement gate below ran on
first-pass data and did not bind; the encoding is hereby frozen — this is
what `api.md` §3.3 calls frozen at first write.

## Context

An inlined term has no dictionary entry — the ID *is* the term's entire
representation, on disk as well as in memory: `log.md` §5.3's fact operations
carry inlined IDs verbatim, so the inline scheme is part of the durable
format even though term *definitions* never mention it (`api.md` §3.4).

Dictionary IDs are assigned in first-appearance order and counted out by the
replayer (`log.md` §5.2), which is what makes resident ID *N* the same as log
ID *N* with no translation table. That identity holds only while the set of
terms receiving dictionary entries stays fixed — and the inline predicate is
exactly what determines that set. Changing the predicate after data exists
gives one term two live resident IDs, and every join comparing them silently
returns nothing: no error, no corruption, a quietly wrong answer
(`api.md` §3.3). The repair is a permanent log-ID → resident-ID translation
table, which is precisely the complexity the design's standing constraints
exist to keep out.

## Decision

Adopt `api.md` §3's 32-bit resident scheme exactly, before any code exists:

- bit 31 = inline flag; bits 30–28 = type tag; bits 27–0 = payload,
  offset-binary within each type.
- Tag 0 is **reserved and rejected on decode** — `0x80000000` must never
  decode as a plausible term.
- Tag 1 = `xsd:boolean` (1-bit payload); tag 2 = `xsd:integer`
  (±1.34×10⁸); tag 3 = `xsd:date` (days since 1970). Tags 4–7 unassigned.
- Only the canonical lexical shape inlines (`"34"`, never `"034"` or
  `"+34"`); every other form interns. Preserves lexical term identity and
  §3.2's injectivity.
- On disk, term IDs stay `u64` (`log.md` §5.2/§5.3 unchanged, per
  `api.md` §3.5), with the two safety rules of `api.md` §3.4: the writer
  restricts `inline_encode` to what the 32-bit resident scheme can hold, and
  replay asserts every dictionary ID fits in `u32`.

### The gate before acceptance

Run `api.md` §3.2's measurement: count the **distinct** `xsd:integer` terms
above 1.34×10⁸ in realistic tenant-shaped data (generated volume data is
available for a first pass), multiply by ~48 bytes, and compare against the
6.4 MB that 64-bit IDs cost per tenant. The expected outcome is that nothing
binds — monetary amounts are whole currency units, ceiling 134,217,727 units —
but this ADR is accepted only with the measurement attached.

**Result (2026-08-19, first pass):** generated ISMS-shaped volume data
(22,926 quads, seed 1) plus the consumer's checked-in vocabulary tree:
14 distinct integer lexicals in total, maximum 27,005 — zero above the
ceiling, five decimal orders of magnitude below it. Re-run against real
tenant data when some exists; the expectation stands.

## Rationale

Every other decision in the resident design is freely revisable at the next
restart; this one is shared with the log and is not. Reserving five unused
tag values costs nothing today; claiming one later costs the translation
table. Three tag bits over two buys never having to widen the tag
(`api.md` §3.1). The escalation path if the integer ceiling ever binds is
recorded in §3.2 and runs: dedicated tag for the offending type → 1-bit
prefix code for `xsd:integer` (±5.4×10⁸) → 64-bit resident IDs. 40-bit IDs
are rejected outright (`api.md` §9).

## Consequences

### Positive
- No translation table, ever; replay's re-tag from the 64-bit on-disk
  encoding is a pure narrowing that cannot fail.
- Inlined numerics sort by ID within their type, so numeric range filters
  are range scans inside the inline range (`api.md` §5.1's order-preserving
  property).
- One term encoder in the system: the dictionary payload is
  `architecture.md` §3.2's canonical encoding verbatim.

### Negative
- Integer ceiling ±1.34×10⁸; beyond it a value interns (~48 bytes per
  distinct overflow value) and a range filter spanning the boundary cannot
  be answered by a pure range scan.
- `xsd:dateTime` does not inline in v1; it interns like any term. Tag 4 is
  its obvious future home.

### Neutral
- The resident ID *width* stays re-tunable (`api.md` §3.5); only the inline
  portion of the space is frozen.