---
id: 001-snapshot-reclamation-without-a
level: adr
title: "Snapshot reclamation without a garbage collector"
number: 1
short_code: "RECORD-A-0005"
created_at: 2026-08-19T15:55:47.538925+00:00
updated_at: 2026-08-19T17:09:58.676055+00:00
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

# ADR-1: Snapshot reclamation without a garbage collector

**Status: accepted 2026-08-19.** The one place the founding documents' Go premise is
load-bearing rather than incidental: an immutable-snapshot design leans on a
garbage collector to reclaim superseded structures, and Odin has none.

## Context

The writer publishes each commit as a fresh immutable index set behind an
atomic pointer; readers holding older snapshots keep computing correct
answers against the sets they loaded (`api.md` §12.1,
`architecture.md` §6.6). In Go, a superseded set is reclaimed when the last
snapshot referencing it goes away — for free. In Odin someone must free it,
and freeing it while a reader walks it is use-after-free, the exact hazard
the immutability discipline exists to prevent.

Related, because it is the same allocator question: `api.md` §5.2's
main-plus-delta permutations exist to bound *GC garbage* per commit —
"9.6 MB of garbage per commit defeats the GC strategy". With explicit
allocation there is no collector to defeat.

## Decision

Three parts:

1. **The publication unit is one refcounted index set.** `latest()`/`at()`
   atomically load the current set and increment its count;
   `snapshot_release` decrements. The writer publishes the new set and
   releases its reference to the old; a set whose count reaches zero frees
   what it exclusively owns. Chunked, append-only structures shared across
   sets — fact-table chunks, dictionary blob chunks — are owned by the
   store, never by a set, and live until the store closes; refcounting
   governs only the replaced permutation arrays and the set header.
2. **A `Snapshot` is therefore a resource, not a plain value** — the one
   deliberate API departure from the Go sketch. Acquire, use, release;
   contract-documented like every lifetime in the family. The expected
   consumer discipline (request-scoped snapshots, nothing held across
   think-time) keeps lifetimes trivial in practice.
3. **v1 permutation maintenance is flat copy-on-write.** A commit sorts
   fresh arrays for the changed orders and frees the old ones when their
   set's count drops to zero. At the premise's single-digit human-paced
   commits per second this is allocator traffic, not garbage. The delta-run
   structure is deferred; `Range` keeps the two-span shape (`main`, `delta`)
   with `delta` permanently empty, so adopting deltas later changes the
   maintenance code and nothing downstream.

## Rationale

Refcounting is the smallest mechanism that makes "free the old set" safe,
and it is uncontended: one atomic increment per snapshot at request rates.
The alternatives are worse fits — epoch-based reclamation is machinery for
lock-free writers we do not have (there is exactly one writer), and never
freeing (arena-per-set) leaks a set per commit. Deferring the delta
structure follows the documents' own logic: it was priced against a GC
budget that no longer exists, and `api.md` §5.2 itself derives N=1024 from
constants it says must be measured.

## Consequences

### Positive
- Superseded sets are freed promptly and provably; no collector, no pauses,
  no headroom multiplier — `api.md` §10's GC row simply disappears.
- Commit-path code is the naive, readable form (sort fresh arrays), with
  the optimized form's API shape already in place.

### Negative
- `snapshot_release` is a caller obligation; forgetting it leaks an index
  set. `ODIN_TEST_FAIL_ON_BAD_MEMORY` and a store-close assertion that all
  counts are zero make the leak loud in tests.
- A long-lived snapshot pins its whole set, permutations included — the
  same pinning `api.md` §13.2 warns about, now with explicit ownership.

### Neutral
- ~9.6 MB allocated and freed per commit at target scale. Within budget at
  the premised write rate.

## Review Triggers

- Measured commit latency or allocator pressure from flat copy-on-write —
  the delta structure is the recorded answer, already API-compatible.
- Any second writer ever being contemplated (it is forbidden by
  `log.md` §10; this ADR's simplicity is part of why).