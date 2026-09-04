---
id: the-set-holds-roots-index-set-boot
level: task
title: "The set holds roots: Index_Set, boot's pack, Range and Scan over ranks and a cursor, the retire list"
short_code: "RECORD-T-0041"
created_at: 2026-09-04T18:57:18.175550+00:00
updated_at: 2026-09-04T19:18:37.070914+00:00
parent: RECORD-I-0009
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: RECORD-I-0009
---

# The set holds roots

## Parent Initiative

[[RECORD-I-0009]]

## Objective

Make the tree the store's permutation for **reads and boot**, with the commit
path still rebuilding by sort-and-pack. `Index_Set.ord` becomes seven roots
plus the set's copies of the arena's chunk lists; `store_build_permutations`
keeps the radix sort and packs each order; `Range` carries a root and two ranks,
`Scan` a cursor; a dying set retires its roots onto a list the writer drains.
Every existing read test passes unchanged, and the commit number does not move
yet — that is `RECORD-T-0042`'s — so this task can be judged on reads alone.

## Acceptance Criteria

- [x] `Store.ord` is `[Order]Root` plus one arena; `Index_Set` holds
      `[Order]Root` and clones of the leaf and inner chunk lists, taken at
      publication as `facts`, `dict`, `used`, `off`, `epochs` are today. A
      reader reaches nodes only through its set's copies.
- [x] `store_build_permutations` sorts as before and packs each sorted array
      into a full tree, releasing whatever roots `s.ord` held (the boot path;
      also the large-changeset path, and `apply`'s only path until T-0042).
- [x] `snapshot_match_as` is two rank descents; `range_len` is `hi - lo`;
      `range_iter` opens a cursor; `scan_next` is unchanged except for where the
      next id comes from; `prefix_bound` is deleted. `Range` and `Scan` lose
      `main`, `delta`, `ids`; `make api` still reports 73 names.
- [x] Ordered output of `snapshot_match_as` is asserted by a test over every
      order, since odin-rdf-sparql's merge join depends on it
      (`SPARQL-T-0029`).
- [x] Reclamation off the reader thread: `release_set` at zero pushes the
      seven roots onto `Store.retired` under a mutex distinct from `mu`; the
      writer drains it at the top of `apply` and in `store_destroy`;
      `store_destroy`'s `refs == 1` assertion stands and the arena is empty
      after it. A test holds a snapshot across two publishes, releases it from
      a spawned thread, and checks the arena reaches zero after the next drain.
- [x] The six direct-access sites (`permute_test.odin` ×4 via `s.ord[o]`,
      `apply_test.odin`'s `same_projection` and its RDF 1.2 count,
      `snapshot_test.odin`, `scale_test.odin` ×3) move to a private
      enumeration helper over a root.
- [x] `make test` green in full, both verifiers agreeing; the reader/writer
      torture and the crash sweep unchanged.
- [x] Boot re-measured with `test_scale_boot_bulk` / `_edited`: within a few
      ms of 197 / 273 ms; the log line gains the pack.

## Implementation Notes

- The arena lives in `Store`; sets copy only its chunk lists. Node contents
  reachable from a published set are never written (generation rule), and a
  freed slot is only reused by the writer for current-generation nodes, which
  no published set reaches.
- `rollback` in `apply` currently deletes `s.ord[o]`; here it releases the
  roots `store_build_permutations` produced. T-0042 replaces that with
  generation-scoped release.
- The prototype's `xb_tree_match` / `xb_prefix` in the benchmark are the
  shape `snapshot_match_as` takes; `choose_order` is unchanged.

## Status Updates

**2026-09-04 — done.** The tree is the store's permutation for reads and
boot; `apply` still sort-and-packs (T-0042's move).

- `Store`: `ord: [Order]Perm_Root`, `ord_built`, `perm: Perm_Arena`,
  `retired` + `retire_mu`. `store_destroy` releases an unpublished build,
  drains, asserts the arena empty, then destroys it.
- `store_build_permutations`: sort as before, pack each order under
  generation `n_epochs`; releases an unpublished build's roots *once, before
  the loop* — the first cut released per order and freed leaf 0 seven times,
  which the whole suite caught as a refcount underflow at the first publish.
- `Index_Set`: seven roots plus clones of the arena's two chunk lists;
  `release_set` at zero retires `set.ord` under `retire_mu`;
  `store_drain_retired` (writer only) runs after every install, at the top
  of `apply`, in `rollback`, and in `store_destroy`.
- `read.odin`: `Range{lo, hi}`, `Scan{cur: Perm_Cursor}`, two `perm_rank`
  descents through the set's copies, `prefix_bound` deleted. `make api`: 73.
- Tests: the six direct-access sites go through `perm_collect` (package-
  private, in `btree_test.odin`). New: `test_read_ordered_output` (every
  order × nine prefixes over the duplicate-heavy corpus, keys strictly
  ascending, counts equal to the oracle) and
  `test_snapshot_retire_from_reader_thread` (a set dying on a spawned thread
  retires, nothing moves until the writer drains, then exactly set 1's
  leaves go). The reader/writer torture passed unchanged — its 300 publishes
  against 256k acquisitions are the retire list's first real workout.
- Benchmark: the flat read path lives in `btree_bench_test.odin` now
  (`xb_flat_bound` is the old `prefix_bound`), so the comparison survives.

**Measured** (alone, `-o:speed`): boot 193 ms bulk-loaded / 282 ms
hand-edited (197 / 273 before), sort+pack 46–47 ms; awake from disk
198 ms with the pack at 0.9 ms. Resident "permutations" is the arena's live
bytes, 9.4 MB at the scale corpus; the 1.2 MB "rest" is the partially used
last leaf and inner chunks. Commit latency is 37–43 ms as expected until
T-0042.

`make check` green (73 names); `make test` 92 + 11 + 1 + 99, all green.