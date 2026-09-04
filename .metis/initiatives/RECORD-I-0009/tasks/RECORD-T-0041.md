---
id: the-set-holds-roots-index-set-boot
level: task
title: "The set holds roots: Index_Set, boot's pack, Range and Scan over ranks and a cursor, the retire list"
short_code: "RECORD-T-0041"
created_at: 2026-09-04T18:57:18.175550+00:00
updated_at: 2026-09-04T18:57:18.175550+00:00
parent: RECORD-I-0009
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


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

- [ ] `Store.ord` is `[Order]Root` plus one arena; `Index_Set` holds
      `[Order]Root` and clones of the leaf and inner chunk lists, taken at
      publication as `facts`, `dict`, `used`, `off`, `epochs` are today. A
      reader reaches nodes only through its set's copies.
- [ ] `store_build_permutations` sorts as before and packs each sorted array
      into a full tree, releasing whatever roots `s.ord` held (the boot path;
      also the large-changeset path, and `apply`'s only path until T-0042).
- [ ] `snapshot_match_as` is two rank descents; `range_len` is `hi - lo`;
      `range_iter` opens a cursor; `scan_next` is unchanged except for where the
      next id comes from; `prefix_bound` is deleted. `Range` and `Scan` lose
      `main`, `delta`, `ids`; `make api` still reports 73 names.
- [ ] Ordered output of `snapshot_match_as` is asserted by a test over every
      order, since odin-rdf-sparql's merge join depends on it
      (`SPARQL-T-0029`).
- [ ] Reclamation off the reader thread: `release_set` at zero pushes the
      seven roots onto `Store.retired` under a mutex distinct from `mu`; the
      writer drains it at the top of `apply` and in `store_destroy`;
      `store_destroy`'s `refs == 1` assertion stands and the arena is empty
      after it. A test holds a snapshot across two publishes, releases it from
      a spawned thread, and checks the arena reaches zero after the next drain.
- [ ] The six direct-access sites (`permute_test.odin` ×4 via `s.ord[o]`,
      `apply_test.odin`'s `same_projection` and its RDF 1.2 count,
      `snapshot_test.odin`, `scale_test.odin` ×3) move to a private
      enumeration helper over a root.
- [ ] `make test` green in full, both verifiers agreeing; the reader/writer
      torture and the crash sweep unchanged.
- [ ] Boot re-measured with `test_scale_boot_bulk` / `_edited`: within a few
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

*To be added during implementation*
