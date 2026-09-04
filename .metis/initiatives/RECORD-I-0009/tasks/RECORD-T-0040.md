---
id: the-tree-as-a-package-structure
level: task
title: "The tree as a package structure: btree.odin promoted from the prototype, with its own suite and no wiring"
short_code: "RECORD-T-0040"
created_at: 2026-09-04T18:57:16.691212+00:00
updated_at: 2026-09-04T19:05:06.867645+00:00
parent: RECORD-I-0009
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/active"


exit_criteria_met: false
initiative_id: RECORD-I-0009
---

# The tree as a package structure

## Parent Initiative

[[RECORD-I-0009]]

## Objective

Promote the investigation's prototype (`record/xbtree.odin`, `RECORD-A-0012`)
into `record/btree.odin`: the copy-on-write B+tree of fact ids as a private
package structure with contract comments and its own suite, **wired into
nothing yet**. The benchmark that decided the ADR stays behind its define as the
measurement's home. At the end of this task the store still runs on flat
arrays; what exists is a tree that is proven against them.

## Acceptance Criteria

- [x] `record/btree.odin` holds the tree — leaves of 256 `Fact_ID`s, inner
      nodes of ≤64 children with the child's minimum 5-tuple key and entry
      count, chunked slot arenas that never relocate, per-node refcounts,
      generation-owned mutability — every declaration `@(private)` (file tag
      `#+private`), with contract comments on every procedure a later task
      will call: build, insert, rank, cursor, retain, release, arena live.
- [x] Root ownership is stated in the insert's contract and nowhere else: the
      root reference belongs to the set that published it; a replaced root is
      left for its set; an unchanged root is retained by the new set before the
      old releases. (The prototype's one refcount bug was exactly this.)
- [x] `record/btree_test.odin`: (1) oracle — a tree built by packing equals the
      radix-sorted permutation, and a tree built by inserting every fact in id
      order equals it entry for entry, over the permute suite's duplicate-heavy
      4096-fact corpus (`oracle_fill`) and a larger random one; (2) both split
      paths — a leaf split and an inner split, including the root growing a
      level — with counts and `total` checked after each; (3) the cursor across
      leaf and inner boundaries, from every rank, `remaining` exact; (4)
      refcounts: a set held across inserts keeps its window intact while the
      new one sees the inserts; releasing in either order ends with every slot
      free; `xb_arena_live` reports zero; (5) a random-insert property test —
      interleaved generations, held and released, checked against a sorted
      slice after every generation.
- [x] `ODIN_TEST_FAIL_ON_BAD_MEMORY` clean; `make check` green, the surface
      still 73 names.
- [x] `xbench_test.odin` renamed to `btree_bench_test.odin` (or kept), still
      behind `RECORD_XBENCH`, its header table intact — it is the ADR's
      evidence and the way the numbers are re-taken on another machine.

## Implementation Notes

- The prototype is complete for what this task needs; the work is naming,
  contracts, and the suite. `XB_` prefixes become the package's own; keep the
  `xb_`-style verb set if it reads well beside `snapshot_*` and `store_*`.
- `XB_BUILD_FILL` stays a `#config` for the benchmark only; production packs
  full (the ADR's decision 4).
- Nothing in this task touches `Index_Set`, `Range`, `Scan`, or `apply`.

## Status Updates

**2026-09-04 — done.** `record/btree.odin` (file-private, `Perm_*` / `perm_*`)
is the prototype promoted, with the package comment carrying the shape, the
generation rule, the reclamation argument and the §8 re-measurement, and root
ownership stated on `perm_insert` alone. `perm_rank` and `perm_cursor` take the
chunk lists rather than the arena, so T-0041's reader passes its set's copies.
`record/btree_test.odin` holds the five groups; `permute_test.odin`'s
`oracle_fill` / `oracle_tuple` / `oracle_lt` went package-private so the tree
suite shares the duplicate-heavy corpus. The benchmark is
`record/btree_bench_test.odin`, still behind `RECORD_XBENCH`, header table
intact; re-run after the rename: 11.1 µs mean for a one-assert commit.

**One finding, fixed.** The invariant check (`bt_check`: inner keys equal the
child's minimum) failed on the streamed build: an insert below a node's first
child left `key[0]` stale. Routing never reads `key[0]` — `i = max(lo-1, 0)` —
which is why every window comparison in the investigation had passed. The
insert now lowers `key[0]` when the new key is the child's new minimum, so the
stated invariant is exact rather than "true where it matters". Nothing else
moved.

`make check`: 73 names. `make test`: 90 + 11 + 1 + 97, all green under
`ODIN_TEST_FAIL_ON_BAD_MEMORY`.