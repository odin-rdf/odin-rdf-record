---
id: 001-a-permutation-is-a-copy-on-write-b
level: adr
title: "A permutation is a copy-on-write B+tree of fact ids: the commit path stops re-sorting, boot still does"
number: 1
short_code: "RECORD-A-0012"
created_at: 2026-09-04T18:49:22.948244+00:00
updated_at: 2026-09-04T18:49:22.948244+00:00
decision_date: 2026-09-04
decision_maker: Greger Olsson
parent: 
archived: false

tags:
  - "#adr"
  - "#phase/decided"


exit_criteria_met: false
initiative_id: NULL
---

# ADR-12: A permutation is a copy-on-write B+tree of fact ids

**Status: accepted 2026-09-04.** Supersedes part 3 of `RECORD-A-0005` (flat
copy-on-write, the delta structure deferred). Amends `api.md` §5.2, §9 and §10.
The measurements behind it are in `record/xbench_test.odin`'s header and the
investigation recorded in `RECORD-I-0009`.

## Context

A permutation is a sorted `[]Fact_ID`, one per order, seven orders
(`RECORD-A-0004`, `RECORD-T-0028`). `RECORD-A-0005` part 3 chose **flat
copy-on-write**: a commit sorts fresh arrays and the superseded set is freed when
its last snapshot goes. The delta-run structure `api.md` §5.2 designed to bound
per-commit copying was deferred, with `Range` keeping a permanently empty
`delta` span so adopting it later would change the scan's internals and nothing
downstream. The review trigger was re-read on 2026-08-20 (`RECORD-T-0018`): one
commit at 4×10⁵ facts cost 31–35 ms and the trigger was judged not to fire at
the premise's human-paced commit rate.

**What the trigger did not price.** Every `apply` runs
`store_build_permutations`, which is not a copy but the boot path's full radix
re-sort of all seven orders over every fact. Measured 2026-09-04 on the
arm64 darwin dev machine at `-o:speed`, 4×10⁵ facts: a commit of one or two ops
costs **37.5 ms, of which 37.1 ms is that re-sort**; the term-index merge and
the index-set build are microseconds. The transient is **20 MB per commit** —
the sort's columns and buffers plus seven fresh arrays beside the seven
published ones — over a 22.7 MB resident. A reader pinned across a commit holds
a **10.7 MB** set. None of this is allocator traffic in the sense the ADR meant;
it is the whole boot-path sort, paid on every write, in a store designed for
~200 tenant processes per machine. And the application this store now exists
for — a named graph per workspace, edited interactively (`RECORD-T-0029`) —
commits on every user action.

Two properties make the problem tractable, both already recorded: **a
permutation is insert-only** (`api.md` §5.2 — a retraction is a field write in
the fact table and never touches an index), and **no consumer names `Range`'s
spans** (`RECORD-I-0005`: a consumer writes `r := snapshot_match(...)` and never
names `Range`; verified again by grep over both engines on 2026-09-04). The
representation behind `snapshot_match`, `range_len`, `range_iter` and
`scan_next` is free to change.

## Decision

**Each of the seven permutations is a copy-on-write B+tree of `Fact_ID`s.**

1. **Leaves hold fact ids and nothing else** — 256 per leaf, 1 KB. No key is
   copied out of the fact table, the same pointer-free discipline the flat
   array had; a leaf search gathers from the table exactly as the flat binary
   search does, over 256 ids instead of 4×10⁵. **Inner nodes hold, per child,
   its minimum key** (the four components in the order's sequence, then the
   fact id as tiebreaker — the total order the radix sort's stability yields)
   **and its entry count**. A descent compares in-node keys and accumulates a
   rank; the two ranks of a prefix's bounds are what slice arithmetic gave
   before, so `range_len` stays an exact O(1)-after-match count, which the
   sparql planner prices joins with.

2. **Copy-on-write by build generation.** A node created by generation g is
   mutable by g and immutable thereafter. A commit's inserts path-copy every
   node of an earlier generation they pass, so a published root and everything
   under it are never written. An `Index_Set` holds seven roots (three words
   each) and copies of the arena's chunk lists, as it holds the fact chunk list
   today.

3. **Reclamation is per-node reference counting**, parents counted with the
   root pointer as one: a released root decrements, and a node at zero cascades
   to its children. Nodes live in chunked slot arenas that never relocate,
   addressed by index. Because `snapshot_release` runs on whichever thread
   drops the last reference and takes no lock (`RECORD-A-0005`, amended), a set
   reaching zero **retires its roots onto a list the writer drains** at its
   next apply and at close, so arena bookkeeping is mutated by the writer thread
   alone; the retire list's own lock is taken only when a set dies, never on the
   read path.

4. **Boot is sort-then-pack, unchanged in shape.** `store_open` still runs the
   seven radix sorts after replay and then packs each sorted array into full
   leaves in one linear pass — 1.1 ms on top of the 37–48 ms sort. Every wake is
   a full repack at 100% fill. `log.md` §8's argument — sort once at the end,
   never maintain order during the stream — was re-measured for the tree and
   holds by a wider margin: building by streaming inserts during replay costs
   568 ms and 15.6 MB against 44 ms and 11.1 MB.

5. **A commit inserts; a large changeset sorts.** Below a threshold of asserts
   (break-even measured at roughly 9,000, ~2% of the table) `apply` inserts each
   new fact id into each tree; above it, it takes the boot path's sort-and-pack.
   The threshold is a constant to be stated with its measurement, like
   `MERGE_SCAN_PRICE` in odin-rdf-sparql.

6. **`Range` loses its two spans**; it carries a root and two ranks, and `Scan`
   carries a cursor. `Range`'s `delta` — `RECORD-A-0005`'s promised shape —
   goes with it: the promise was that adopting a better structure changes
   nothing downstream, and it is kept, because downstream never named the field.

## Alternatives Analysis

Measured 2026-09-04, same fact table, `-o:speed`. "Per commit" is the index
cost of a one-assert commit across all seven orders.

| Option | Per commit | Match (two bounds) | Resident | What it costs | Verdict |
|---|---|---|---|---|---|
| Flat, full re-sort (today) | 37 ms, 20 MB transient | 148–380 ns | 10.7 MB | The boot sort on every write | Superseded |
| Flat, merged in place (k ids placed by binary search, array copied around them) | 440 µs, 10.7 MB allocated | same | 10.7 MB | 80× better with ~40 lines; still a fresh set per commit and a full set per pinned reader | The fallback if the tree stalls |
| Main + delta runs (`api.md` §5.2's deferred design) | ~20 KB per commit, a 43 ms rebuild every N commits | two searches + a merge in every scan | 10.7 MB + delta | Every layer-1 primitive becomes a two-run merge, and the rebuild pause returns periodically | Not built; the tree dominates it on every axis but resident bytes |
| **B+tree of fact ids (this decision)** | **9–11 µs, a few KB** | **111–337 ns, 10–30% faster** | 11.1 MB packed, drifting toward ~15.5 MB at 70% fill between wakes | +0.4 to +4.8 MB per tenant; ~500 lines; refcount reclamation | **Accepted** |
| B+tree with keys in the leaves (`api.md` §9's "inline-key B-tree", rejected there at ~82 MB) | as above | faster still — no gather in the leaf | ~5× the ids alone | Density: the reason §9 rejected it stands | Rejected again |
| Build the trees by streaming inserts during replay | — | — | 15.6 MB at 72% fill | Boot index cost 568 ms against 44 ms; §8 holds for the tree | Rejected |

## Rationale

The flat array's read behaviour was never the problem and the tree does not
trade it away: matches are faster because the descent compares keys held in
inner nodes, and scans walk leaves as sequentially as an array, 2.5 ns per
candidate on both. What the tree buys is that a commit touches what it changes
— a leaf and two inner nodes per order — instead of rebuilding everything, and
that a pinned reader retains those path copies (0.6–0.7 MB across 50 commits)
instead of a whole set. For a store whose deployment premise is density, the
allocation figures are the stronger argument: 20 MB transient per commit
becomes kilobytes.

The flat merge would have taken 80% of the latency win for a tenth of the
work, and it is kept as the recorded fallback. It was not chosen because it
leaves the two memory figures where they are, and because the main-plus-delta
design that `api.md` §5.2 keeps in reserve to fix those is more complex than
the tree, not less: it puts a two-run merge inside every primitive where the
tree puts one cursor.

`log.md` §8 was re-asked rather than inherited, since a tree is exactly the
structure §8's argument was made against. It holds — the sort is linear passes
over columns and the pack fills every leaf, where an insert is a random descent
with gathers and a memmove, and splits leave leaves at whatever fill they had.
The number is 13× and 4.5 MB, and it is why boot does not change.

## Consequences

### Positive
- A one-assert commit's index cost goes from 37 ms to ~10 µs; `apply` on the
  memory seam should land near the 0.4 ms the rest of it costs.
- Per-commit transient allocation goes from 20 MB to kilobytes; a pinned
  reader retains path copies, not a set.
- Match is 10–30% faster on every pattern shape; scans unchanged.
- Boot cost is unchanged to within 1%, and every wake repacks the trees full.
- No consumer source changes: neither engine names `Range.main`, `.delta` or
  `Scan.ids`.

### Negative
- Resident permutation bytes rise from 10.7 MB to 11.1 MB packed and drift
  toward ~15.5 MB at steady-state fill between wakes. A store that is never
  evicted pays the upper figure; a periodic repack (the boot sort, 44 ms) is the
  recorded answer if it matters, not a plan.
- ~500 lines of tree code with a reference-counting discipline where there was
  a sort and a slice. The refcount invariants need their own tests.
- `range_len` costs a descent's worth of additions rather than a subtraction —
  still O(1) after the match, but not free.
- The exported `Range` and `Scan` structs change fields. Names, not surface:
  `doc/api-surface.txt` lists both types and `make api` holds.

### Neutral
- `RECORD-A-0005` parts 1 and 2 stand: one refcounted set is still the unit of
  publication and a `Snapshot` is still a resource. Part 3 is superseded here.
- The radix sort of `permute.odin` is unchanged and still the boot path's
  dominant term.

## Review Triggers
- Steady-state fill measured below ~65% on a long-lived tenant, or resident
  permutation bytes above 16 MB at 4×10⁵ facts: the periodic repack becomes a
  task.
- A changeset shape that sits at the insert/sort threshold in practice — the
  constant is measured on this machine and should be re-measured on the
  production one.
- Any second writer (still forbidden by `log.md` §10; generation ownership
  assumes one).
