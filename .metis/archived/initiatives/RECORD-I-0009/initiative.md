---
id: the-permutations-become-b-trees-a
level: initiative
title: "The permutations become B+trees: a commit costs microseconds, a wake costs what it did"
short_code: "RECORD-I-0009"
created_at: 2026-09-04T18:49:24.560947+00:00
updated_at: 2026-09-04T19:33:05.734966+00:00
parent: RECORD-V-0001
blocked_by: []
archived: true

tags:
  - "#initiative"
  - "#phase/completed"


exit_criteria_met: false
estimated_complexity: M
initiative_id: the-permutations-become-b-trees-a
---

# The permutations become B+trees Initiative

## Context **[REQUIRED]**

Every `apply` rebuilds all seven permutations from scratch with the boot path's
radix sort, and that sort is the commit: **37.5 ms per commit at 4×10⁵ facts,
37.1 ms of it the sort**, 20 MB allocated transiently, 10.7 MB held by any
reader pinned across it. `RECORD-A-0005` part 3 chose this as "flat
copy-on-write" and deferred `api.md` §5.2's delta structure; the 2026-08-20
re-read of its trigger priced the copies and not the sort.

An investigation on 2026-09-04 prototyped a copy-on-write B+tree of fact ids
beside the flat array, over the same fact table, and measured both against a
flat array merged in place. The prototype is `record/xbtree.odin` (all private)
and the benchmark `record/xbench_test.odin` (behind `RECORD_XBENCH`), whose
header carries the table. The decision is `RECORD-A-0012`. The numbers that
decided it, arm64 darwin, `-o:speed`:

| | flat, re-sort (today) | flat, merged in place | B+tree |
|---|---|---|---|
| index cost, 1-assert commit | 37 ms | 440 µs | 9–11 µs |
| index cost, 100-assert commit | 37 ms | 1.2 ms | 420–475 µs |
| allocated per commit | 20 MB transient | 10.7 MB | a few KB |
| retained by a reader pinned across 50 commits | 10.7 MB | 10.7 MB | 0.6–0.7 MB |
| match, two bounds, nine shapes | 148–380 ns | same | 111–337 ns |
| scan per candidate | 2.5 ns | same | 2.5 ns |
| `{S***}` / `{SP**}` per query incl. match | 0.52 / 0.36 µs | same | 0.43 / 0.29 µs |
| resident, packed | 10.7 MB | 10.7 MB | 11.1 MB (→ ~15.5 MB at 70% fill) |
| boot (`store_open` from disk, POSIX seam) | 196 ms | — | 197 ms (sort 37 ms + pack 1.1 ms) |
| build by streaming inserts during replay | — | — | 568 ms, 15.6 MB: **`log.md` §8 holds** |

The prototype's windows equal the flat windows id for id across 18,000 patterns
of nine shapes, both structures end strictly ordered against the oracle after
5,700 random inserts, a tree built by streaming equals the sorted permutation
entry for entry, and every node is reclaimed.

## Goals & Non-Goals **[REQUIRED]**

**Goals:**
- A one- or two-op `apply` on the memory seam costs well under a millisecond,
  measured by `RECORD-T-0018`'s scale test with its number amended.
- Per-commit transient allocation in kilobytes; a pinned reader retains path
  copies, not a set.
- Reads no slower on any pattern shape; `range_len` exact; ordered output of
  `snapshot_match_as` preserved for the sparql merge join.
- Boot unchanged in shape and within a few ms of today.
- Every suite green, both verifiers agreeing, the crash sweep and replay
  equivalence passing through `apply` unchanged; no consumer source change.

**Non-Goals:**
- Not the format. Nothing on disk changes; a `v0.7.0` store reads and writes
  identically.
- Not the sort. `permute.odin`'s radix sort stays as the boot path and the
  large-changeset path.
- Not keys in leaves, not a per-graph posting structure, not a second writer.
- Not a periodic repack of a long-lived tenant's trees. Recorded as the answer
  if fill drift is ever measured to matter (`RECORD-A-0012`'s trigger).

## Detailed Design **[REQUIRED]**

**The tree** is the prototype promoted: leaves of 256 `Fact_ID`s, inner nodes
of up to 64 children each carrying the child's minimum 5-tuple key and entry
count, chunked slot arenas that never move, per-node refcounts, generation-owned
mutability. `range_len` is `hi - lo` of two ranks. The cursor holds a path of
(node, child index) to the current leaf and steps siblings without leaf links,
because sibling links would make every leaf copy cascade.

**What changes in the store**, file by file:

- `permute.odin`: `store_build_permutations` keeps the sort and packs each
  sorted array into a tree; `Store.ord` becomes seven roots plus the arena.
- `snapshot.odin`: `Index_Set.ord` becomes seven roots and copies of the two
  arena chunk lists (as `facts`, `dict`, `epochs` are copied today).
  `release_set` at zero retires the seven roots onto a list under a small mutex;
  the writer drains it at the start of `apply` and in `store_destroy`, so arena
  bookkeeping is mutated by one thread. The `s.idx.refs == 1` close assertion
  stands.
- `read.odin`: `snapshot_match_as` becomes two rank descents; `Range` carries
  `{snap, order, root, lo, hi, residual}`; `Scan` carries a cursor;
  `scan_next`'s per-candidate loop is unchanged in everything but where the
  next id comes from. `prefix_bound` goes.
- `apply.odin`: after the fact appends, for each order either insert the new
  ids under generation E or, above the threshold, sort-and-pack; `rollback`
  releases the candidate's roots (the generation's nodes cascade to the free
  lists). The candidate set the validator sees is built the same way.
- Tests: six sites read `s.ord[o]` or `idx.ord[o]` directly (`permute_test`,
  `apply_test`'s `same_projection`, `snapshot_test`, `scale_test`); they move to
  a private enumeration helper over a root. The tree gets its own suite:
  oracle against the sort, split paths at both node kinds, cursor across leaf
  and inner boundaries, refcounts under held and released sets, a
  random-insert property test.

**Threshold.** A constant stating the assert count above which `apply` sorts
rather than inserts, with its measurement beside it (break-even ~9,000 at
4×10⁵ facts on the dev machine).

## Alternatives Considered **[REQUIRED]**

Carried in `RECORD-A-0012`'s table. The flat array merged in place is the
recorded fallback: 440 µs per commit for ~40 lines, if the tree's reclamation
discipline proves harder to make loud in tests than expected.

## Implementation Plan **[REQUIRED]**

Four tasks, one commit each, in order (decomposed 2026-09-04):

1. **`RECORD-T-0040` — The tree as a package structure with its own suite.** Promote
   `xbtree.odin` to `btree.odin` with contract comments; the tree suite above;
   the benchmark kept behind its define as the measurement's home. No wiring.
2. **`RECORD-T-0041` — The set holds roots.** `Index_Set`, boot's pack, `Range`/`Scan` over ranks
   and a cursor, the retire list, the six direct-access test sites. Every
   existing read test passes unchanged; `apply` still rebuilds by sort-and-pack
   at this step, so the commit number does not yet move.
3. **`RECORD-T-0042` — The commit path inserts.** The threshold and its measurement; rollback of a
   refused or failed apply; the crash sweep, replay equivalence and the
   reader/writer torture re-run; `RECORD-T-0018`'s scale number amended and
   `RECORD-A-0005`'s trigger paragraph annotated.
4. **`RECORD-T-0043` — Documents and release.** `api.md` §5.2, §9 and §10 amended; `RECORD-A-0005`
   part 3 marked superseded; the family `CLAUDE.md` section; tag `v0.8.0` and
   walk both engines (expected: no source change, read pins unmoved, sparql's
   bench re-run since match got faster).