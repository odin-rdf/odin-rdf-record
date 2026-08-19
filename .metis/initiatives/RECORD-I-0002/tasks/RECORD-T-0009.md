---
id: snapshots-and-publication
level: task
title: "Snapshots and publication: refcounts, Latest/At, the epoch discipline"
short_code: "RECORD-T-0009"
created_at: 2026-08-19T20:10:38.429839+00:00
updated_at: 2026-08-19T20:10:38.429839+00:00
parent: RECORD-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


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

- [ ] `Snapshot` is a small value handle over the immutable resident
      structures, acquired from the store and released back; the
      refcount discipline is real (a live snapshot pins what it reads;
      double-release and use-after-release are caught in tests), even
      though nothing is reclaimed until copy-on-write arrives with
      `Apply`.
- [ ] `Latest()` pins the published epoch; `At(e)` pins any
      `0 <= e <= published` and refuses a future epoch with a typed
      error — the same "the past is readable" contract the family's
      store ships, at zero retention cost here by construction.
- [ ] Visibility is exact: a fact is visible at epoch e iff
      `Assert <= e < Retract`, proven across assert → retract →
      re-assert → retract chains (two generations, disjoint intervals),
      and `At(historical)` answers identically before and after later
      epochs exist.
- [ ] The single-writer/N-reader model is documented precisely at the
      publication point (which loads/stores are atomic and why), in
      contract-level comments — the reasoning of log.md par. 7.1 step 5
      carried into code the next initiative extends rather than rewrites.
- [ ] `make check` and `make test` green.

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

*To be added during implementation*