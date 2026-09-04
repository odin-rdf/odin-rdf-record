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
3. **v1 permutation maintenance is flat copy-on-write.** *(Superseded
   2026-09-04 by `RECORD-A-0012`: a permutation is a copy-on-write B+tree of
   fact ids, and a commit inserts. Parts 1 and 2 stand.)* A commit sorts
   fresh arrays for the changed orders and frees the old ones when their
   set's count drops to zero. At the premise's single-digit human-paced
   commits per second this is allocator traffic, not garbage. The delta-run
   structure is deferred; `Range` keeps the two-span shape (`main`, `delta`)
   with `delta` permanently empty, so adopting deltas later changes the
   maintenance code and nothing downstream.

## Rationale

Refcounting is the smallest mechanism that makes "free the old set" safe,
and it is uncontended: one atomic increment per snapshot at request rates.

> **Amended 2026-08-20 (RECORD-I-0003 decision 3, RECORD-T-0014).** "Atomically
> load the current set and increment its count" is two operations, and a
> publish between them frees the set the count is about to be raised on. The
> increment is therefore taken under a mutex that the publisher also takes
> around its pointer swap — on *acquire* (`store_latest`, `store_at`) and on
> *publish*, and nowhere else. The distinction this ADR should have drawn: the
> **read path** is lock-free — match, iterate, resolve, bytes, term take no lock
> and never will — and the **acquire path** is one uncontended lock per request.
> At the workload's ~99:1 read-to-write ratio that is the whole cost, and it
> buys a proof instead of a bound; a retire list (freeing a superseded set one
> publish later) was considered and rejected because it narrows the window to
> one commit interval without closing it. Release still takes no lock: it can
> only lower a count the lock saw raised. The set also grew its own copies of
> the chunk lists a reader indexes (`api.md` §13.8 amendment) — part 1's "owned
> by the store, never by a set" stands for the chunk payloads, and the lists
> that locate them are the set's.
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
  > **Re-read 2026-08-20 (RECORD-T-0018).** Measured: one commit of one or
  > two ops at 4×10⁵ facts costs 31–35 ms on the memory seam (means over two
  > runs; min 30.5, max 36.2, 24 commits each), with up to 18.6 MB of transient
  > allocation per commit over a 21.2 MB resident — the six-permutation
  > rebuild and its scaffolding, as this ADR's Neutral consequence priced.
  > At the premise's human-paced commit rate that is allocator traffic, not
  > a bound; the trigger does not fire and **the delta structure stays
  > deferred**. It would fire at sustained rates above ~10 commits/s, or
  > if a consumer's commit path turned out latency-bound at tens of
  > milliseconds; neither is on any plan.
  > **Re-read 2026-09-04 (RECORD-I-0009, RECORD-A-0012).** The 31–35 ms was
  > not the copy this ADR priced but the boot path's full radix re-sort run
  > on every commit — 37.1 ms of a 37.5 ms apply at 4×10⁵ facts, with 20 MB
  > transient. The trigger fired on the application's interactive commit
  > rate, and the answer was not the delta structure: part 3 is superseded
  > by `RECORD-A-0012`, a copy-on-write B+tree of fact ids, and
  > `RECORD-T-0042` carries the new commit number.
- Any second writer ever being contemplated (it is forbidden by
  `log.md` §10; this ADR's simplicity is part of why).