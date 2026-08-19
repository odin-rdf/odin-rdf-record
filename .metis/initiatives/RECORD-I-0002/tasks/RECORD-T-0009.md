---
id: snapshots-and-publication
level: task
title: "Snapshots and publication: refcounts, Latest/At, the epoch discipline"
short_code: "RECORD-T-0009"
created_at: 2026-08-19T20:10:38.429839+00:00
updated_at: 2026-08-19T22:43:47.251274+00:00
parent: RECORD-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: RECORD-I-0002
---

# Snapshots and publication: refcounts, Latest/At, the epoch discipline

## Parent Initiative

[[RECORD-I-0002]]

## Objective

Snapshots as RECORD-A-0005 fixed them — refcounted resources with
acquire/use/release, `Latest()` and `At(epoch)` — and the published-epoch
discipline of `log.md` par. 7.1 steps 4–5, the apply/publish halves the
writer task deliberately left to this layer: readers run at a published
epoch, the publish trails the apply, and partial state is unobservable
for free because a fact not yet applied carries an epoch the reader is
already rejecting. In this initiative the publisher is replay itself
(one publish, at the end of the build); the mechanics must nonetheless be
the real ones, because `Apply` inherits them unchanged next initiative.

## Acceptance Criteria

- [x] `Snapshot` is a small value handle over the immutable resident
      structures, acquired from the store and released back; the
      refcount discipline is real (a live snapshot pins what it reads;
      double-release and use-after-release are caught in tests), even
      though nothing is reclaimed until copy-on-write arrives with
      `Apply`.
- [x] `Latest()` pins the published epoch; `At(e)` pins any
      `0 <= e <= published` and refuses a future epoch with a typed
      error — the same "the past is readable" contract the family's
      store ships, at zero retention cost here by construction.
- [x] Visibility is exact: a fact is visible at epoch e iff
      `Assert <= e < Retract`, proven across assert → retract →
      re-assert → retract chains (two generations, disjoint intervals),
      and `At(historical)` answers identically before and after later
      epochs exist.
- [x] The single-writer/N-reader model is documented precisely at the
      publication point (which loads/stores are atomic and why), in
      contract-level comments — the reasoning of log.md par. 7.1 step 5
      carried into code the next initiative extends rather than rewrites.
- [x] `make check` and `make test` green.

## Implementation Notes

### Technical Approach

The snapshot's fields are the pinned epoch plus views of the structures
— nothing a reader follows can move underneath it, because in this
initiative nothing moves at all after replay. The refcount and release
path exist so `Apply`'s copy-on-write can slot in without changing a
caller (RECORD-A-0005's v1 stance: flat COW later, same handle now).

### Dependencies

RECORD-T-0007 and RECORD-T-0008 (the structures a snapshot pins).

### Risk Considerations

The temptation is to skip the refcount because v1 never reclaims —
resisted, because the acquire/release contract is the public API and
retrofitting discipline onto released consumers is the expensive
direction.

## Status Updates **[REQUIRED]**

### 2026-08-19 — implemented; `make check` and `make test` green

**Where the code went.** `record/snapshot.odin` + `snapshot_test.odin`.
`Index_Set` (the publication unit: the six permutations, a copy of the
origin bitset, epoch/n_facts/n_terms high-water marks, an atomic
refcount), `Snapshot` (epoch + set + store — a resource, acquired and
released, per RECORD-A-0005), `store_publish`, `store_latest`,
`store_at`, `snapshot_release`, and the read predicates
`snapshot_visible` / `snapshot_derived` / `snapshot_terms`. `Store`
gained the two atomics: `idx` (the set pointer) and `published` (the
epoch), stored in that order.

**The ownership decision this task had to make** (recorded here
because it goes beyond the ADR's wording): `store_publish` *moves* the
permutation arrays out of `Store.ord` into the new set, so the set
owns what publication replaces and a later
`store_build_permutations` + publish cycle can never dangle a
published set's arrays — the danger a view-based design would carry.
The origin bitset is copied (0.7 MB at scale — inside RECORD-A-0005's
accepted per-commit allocator traffic), because the store's copy is a
relocating `[dynamic]u64` the writer keeps growing. Free-on-last-
release is therefore real now, not deferred: the store holds one
reference per published set, hands it over on supersession, and
`store_destroy` asserts the published set's count is exactly the
store's own — the ADR's close assertion, making a leaked snapshot
loud (and `ODIN_TEST_FAIL_ON_BAD_MEMORY` makes a double-free loud).

**The memory model, documented at the publication point** (the package
comment of snapshot.odin): writer stores set then epoch (.Release
both); reader loads epoch then set (.Acquire both), so the set is at
least as new as the pinned epoch and newer facts are rejected by
visibility — api.md §12.1's load-order argument carried into code.
`Fact.retract` is loaded atomically; a retraction a reader misses
carries retract > e (the §2.3 monotonicity argument), and the tests
exercise it directly. One window is documented rather than closed:
between a reader's idx load and its refcount increment, a concurrent
publish could free the set. `store_at` already re-checks idx after
incrementing; making the increment itself safe needs the writer to
defer frees (a retire list) — recorded in the package comment as
Apply's obligation, since this initiative's only publisher is boot,
before concurrent readers exist.

**Tests.** Lifecycle: refcounts observed at every step (acquire,
refuse-future takes no reference, release, inert handle), Unpublished
and Future_Epoch typed refusals, epoch 0 as the empty world.
Visibility: the assert(1)→retract(2)→re-assert(3)→retract(4) chain as
a 5-epoch truth table over both generations plus a live fact, with
the origin bitset checked from the set's copy. Publication
discipline: epoch 4 applied but unpublished (a new fact past the
set's bound AND an in-place retraction on a live fact) — both
unobservable at the pinned epoch; At(2) answers identically before
the append, after it, and from the successor set; the superseded set
drains to the last reader and frees on its release, proven by the
memory tracker. 46 record-package tests (+3).