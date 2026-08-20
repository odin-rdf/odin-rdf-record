---
id: the-term-index-and-the-acquire
level: task
title: "The term index and the acquire mutex: by_term deleted, kind and exists added"
short_code: "RECORD-T-0014"
created_at: 2026-08-20T11:47:07.953588+00:00
updated_at: 2026-08-20T11:47:07.953588+00:00
parent: RECORD-I-0003
blocked_by:
  - "RECORD-T-0013"
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0003
---

# The term index and the acquire mutex: by_term deleted, kind and exists added

## Parent Initiative

[[RECORD-I-0003]]

## Objective

Make the read path safe under a live writer without a lock on it, by
removing the two structures that were not (I-0002 handoff 1 and 2), and
land the two read procedures the initiative admitted (decision 8).
Decision 2: `Dict.by_term` is deleted; the `Index_Set` gains a sorted
`[]u32` of dictionary ids ordered by canonical encoding, and
`snapshot_resolve` binary-searches it comparing arena bytes — published
atomically with everything else a reader touches, correct by
construction the way §13.8 made `n_terms` correct. Decision 3: a mutex
on `store_latest`/`store_at` and on publish closes the acquire window
outright; the workload is ~99:1 read-heavy and the lock is on the
per-request acquire, never on match/iter/resolve. Plus `snapshot_kind`
and `snapshot_exists`.

## Acceptance Criteria

- [ ] `Dict.by_term` is gone. `Index_Set` carries `terms: []u32` (ids
      sorted by their canonical encoding, the set owning the array like
      its permutations); `snapshot_resolve` probes it by binary search,
      ~17 byte-compares at 8×10⁴ terms; the miss stays cheap.
- [ ] Boot builds the array once after replay (a sort of the dictionary
      by arena bytes); the boot-time delta is measured and recorded in
      this task (estimate ~10 ms on the 246 ms boot).
- [ ] A *merge* primitive for the writer: published array + the
      changeset's new ids (already sorted by the intern's pending order
      being irrelevant — sort the few new ones, then one O(n) merge into
      a fresh array). T-0015 calls it per commit.
- [ ] Replay's `log.md` §5.2 duplicate-encoding self-check is preserved
      via a transient map in the `Loader`, dropped at boot's end exactly
      like the live-quad map; `.Duplicate_Term` still fires on a crafted
      log.
- [ ] A `sync.Mutex` in `Store` taken by `store_latest`, `store_at` and
      `store_publish` (and by nothing else); `store_at`'s retry loop and
      the "documented window" paragraph in `snapshot.odin`'s package
      comment are removed and replaced by the proof. Refcounts stay for
      release. `snapshot_match`, `range_iter`, `scan_next`,
      `snapshot_resolve`, `snapshot_bytes`, `snapshot_term` take no lock.
- [ ] `snapshot_kind(snap, id) -> Term_Kind` (`IRI`, `Blank`, `Literal`):
      inline flag → `.Literal`; else the arena's tag byte; asserts on an
      id outside the snapshot's `n_terms` as `snapshot_bytes` does.
      Allocation-free.
- [ ] `snapshot_exists(snap, p: Pattern, f: Filter) -> bool` — `api.md`
      §12.5's layer-2 existence as a loop around layer 1 (`snapshot_match`
      + `range_iter`, first hit), so that T-0015's live-quad check is a
      public procedure rather than a private helper.
- [ ] Tests: resolve conformance over every term shape at head and at a
      historical epoch (a term interned later is a miss earlier — the
      `n_terms` bound, now an index bound); `snapshot_kind` over every
      tag and inline type against the decoded term's union variant;
      `snapshot_exists` against the brute-force oracle; and a
      reader/writer torture test — threads acquiring, resolving,
      matching and releasing while a writer thread appends, merges,
      builds and publishes many times — under
      `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`. (Until T-0015 exists the
      writer side of the torture test drives `fact_append`,
      `dict_add`, the merge and `store_publish` directly.)
- [ ] `api.md` §4 (the map's role) and §12.7 (how `Resolve` probes)
      amended; `RECORD-A-0005`'s "lock-free" sentence amended to state
      the acquire/read distinction and the mutex, dated.
- [ ] Contract-level doc comments; `make check` and `make test` green;
      the footprint delta (−~3.5 MB expected) noted for T-0018.

## Implementation Notes

### Technical Approach

The comparison for the sort and the probe is plain byte order over
canonical encodings — it need not be meaningful, only total and
consistent between sort and search. `dict_add` loses its duplicate
check (the Loader's transient map takes it); on the write path the
intern (T-0013) already guarantees no duplicate reaches `dict_add`.

The mutex is *not* held across a reader's use of a snapshot — only
across load-and-increment in acquire and swap-and-release in publish.
`snapshot_release` needs no lock: a release can only drop a count the
acquirer raised under the lock, and the free-on-zero happens after the
store's own reference has been released under the lock by a later
publish.

### Dependencies

RECORD-T-0013 (the encoder, for the resolve probe's bytes). T-0015
depends on this task's merge primitive and `snapshot_exists`.
