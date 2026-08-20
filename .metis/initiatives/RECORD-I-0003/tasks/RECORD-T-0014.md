---
id: the-term-index-and-the-acquire
level: task
title: "The term index and the acquire mutex: by_term deleted, kind and exists added"
short_code: "RECORD-T-0014"
created_at: 2026-08-20T11:47:07.953588+00:00
updated_at: 2026-08-20T14:10:00.000000+00:00
parent: RECORD-I-0003
blocked_by:
  - "RECORD-T-0013"
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: true
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

- [x] `Dict.by_term` is gone. `Index_Set` carries `terms: []u32` (ids
      sorted by their canonical encoding, the set owning the array like
      its permutations); `snapshot_resolve` probes it by binary search,
      ~17 byte-compares at 8×10⁴ terms; the miss stays cheap.
- [x] Boot builds the array once after replay (a sort of the dictionary
      by arena bytes); the boot-time delta is measured and recorded in
      this task (estimate ~10 ms on the 246 ms boot).
- [x] A *merge* primitive for the writer: published array + the
      changeset's new ids (already sorted by the intern's pending order
      being irrelevant — sort the few new ones, then one O(n) merge into
      a fresh array). T-0015 calls it per commit.
- [x] Replay's `log.md` §5.2 duplicate-encoding self-check is preserved
      via a transient map in the `Loader`, dropped at boot's end exactly
      like the live-quad map; `.Duplicate_Term` still fires on a crafted
      log.
- [x] A `sync.Mutex` in `Store` taken by `store_latest`, `store_at` and
      `store_publish` (and by nothing else); `store_at`'s retry loop and
      the "documented window" paragraph in `snapshot.odin`'s package
      comment are removed and replaced by the proof. Refcounts stay for
      release. `snapshot_match`, `range_iter`, `scan_next`,
      `snapshot_resolve`, `snapshot_bytes`, `snapshot_term` take no lock.
- [x] `snapshot_kind(snap, id) -> Term_Kind` (`IRI`, `Blank`, `Literal`):
      inline flag → `.Literal`; else the arena's tag byte; asserts on an
      id outside the snapshot's `n_terms` as `snapshot_bytes` does.
      Allocation-free.
- [x] `snapshot_exists(snap, p: Pattern, f: Filter) -> bool` — `api.md`
      §12.5's layer-2 existence as a loop around layer 1 (`snapshot_match`
      + `range_iter`, first hit), so that T-0015's live-quad check is a
      public procedure rather than a private helper.
- [x] Tests: resolve conformance over every term shape at head and at a
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
- [x] `api.md` §4 (the map's role) and §12.7 (how `Resolve` probes)
      amended; `RECORD-A-0005`'s "lock-free" sentence amended to state
      the acquire/read distinction and the mutex, dated.
- [x] Contract-level doc comments; `make check` and `make test` green;
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

## Implementation record — 2026-08-20

Landed as `record/termindex.odin` (+ `termindex_test.odin`), a rewritten
`snapshot.odin`, and edits to `resident.odin`, `read.odin`, `load.odin`,
`boot.odin`, the scale suite, `api.md` (§4, §12.7, §13.8), `RECORD-A-0005`.
64 record tests green, `make check` and `make test` green.

**Measured** (tests/scale, `-o:speed`, Apple Silicon dev machine, same
session as the baseline):

| | before | after |
|---|---|---|
| bulk-loaded boot | 197 ms (replay+build 154, sort 43) | **205 ms** (replay+build 152, sort 43, **term index 7**) |
| hand-edited boot | 269 ms (218, 39) | **272 ms** (212, 39, **7**) |
| resident, bulk | 22.9 MB ("by-term map+rest" 3.5) | **20.0 MB** (term index + set copies 0.62, rest 0.0) |
| resident, edited | 25.9 MB | **23.0 MB** |

Footprint delta for T-0018: **−2.9 MB** (−3.5 map, +0.31 index, +0.31 `off`
copy, headers negligible). Torture: 300 publishes, ~255–273k reader
acquisitions across 4 threads, ~99.9% of them mid-run, 0 faults under
`ODIN_TEST_FAIL_ON_BAD_MEMORY`.

**What was decided in passing, for T-0015/T-0018:**

1. **The sort is a multikey quicksort, not a comparison sort.** The
   first cut (`slice.sort_by` over `dict_bytes`) measured **56 ms**, not
   the estimated ~10 — five times the permutations' share per element —
   because the ISMS IRIs share ~30-byte prefixes that every comparison
   re-scans. Materializing (view, id) keys took it to 43 ms; a
   three-way string quicksort (Bentley–Sedgewick, ~40 lines, partitions
   on one byte per depth) to **7 ms**. The merge stays a plain O(n)
   byte-compare merge: 8×10⁴ compares per commit, ~3 ms worst case.
2. **The set copies the lists a reader indexes — a discovered
   divergence from `api.md` §13.8, now implemented as the document
   says.** The handoff's claim that "everything else a reader touches
   is protected by chunks-never-move plus the n_terms bound" was wrong:
   `Store.facts`, `Dict.chunks`, `Dict.used`, `Dict.off` and
   `Store.epochs` are `[dynamic]` arrays whose *backing storage*
   relocates on growth (`off` at every doubling — live, with readers,
   at 131072 terms on the ISMS corpus), and without a collector nothing
   keeps the old backing alive for a reader mid-read. §13.8's Go
   `indexSet` has `chunks [][]Fact` and `epochs [][]EpochMeta` for
   exactly this reason; the Odin port read the store's lists instead,
   masked by boot being the only publisher. `Index_Set` now carries
   `facts`, `dict`, `used`, `off`, `epochs` — copies taken at publish
   (4 B/term for `off`, headers otherwise) — and a reader touches the
   store through chunk payloads alone. New reader accessors:
   `snapshot_fact`, `snapshot_epoch_meta`, private `set_bytes`;
   `store_fact`/`store_epoch_meta`/`dict_bytes` remain the writer's and
   boot's. Environment notes are the one exception, documented: boot-only
   appends. Chunking `off` (never-moving 256 KB chunks) was the
   alternative that avoids the per-commit copy; deferred until T-0018
   prices the commit, since the copy is 4% of the permutation rebuild.
3. **`store_publish` still builds-and-installs in one procedure**, now
   asserting the term index too (`len(s.terms) == len(s.dict.off)`).
   T-0015 splits it (handoff 2a) — the copies and the `s.terms` move
   belong to the build half, the mutexed swap to the install half.
4. **Under the mutex, `acquire` reads `idx` and `published` together**, so
   `store_latest` never observes a set newer than its epoch; the
   package comment's old "at least as new" reasoning is gone with the
   retry loop. Publish still stores with release semantics — harmless,
   and `store_destroy` reads plainly.
5. **`dict_add` no longer checks duplicates**; `Loader.seen`
   (arena-view keys, dropped with the Loader) does, and `load_test`'s
   crafted `.Duplicate_Term` log still fires. The intern never presents
   one.
6. **`snapshot_find` is the seam it was meant to be**: one line changed
   from `dict_find` to `term_index_find`, neither caller touched.
7. Process: `testing.expect` is not called from reader threads; faults
   are atomic counters checked on the main thread. Threads take
   `init_context = context` so the test's tracking allocator sees them.

