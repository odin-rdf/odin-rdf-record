---
id: the-commit-path-inserts-the
level: task
title: "The commit path inserts: the threshold, rollback, and RECORD-T-0018's number re-measured"
short_code: "RECORD-T-0042"
created_at: 2026-09-04T18:57:19.724917+00:00
updated_at: 2026-09-04T19:23:13.082098+00:00
parent: RECORD-I-0009
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: RECORD-I-0009
---

# The commit path inserts

## Parent Initiative

[[RECORD-I-0009]]

## Objective

Replace `apply`'s sort-and-pack with inserts under generation E, above a stated
threshold falling back to the sort. This is the task the initiative exists for:
`RECORD-T-0018`'s number moves from 37 ms to the sub-millisecond the rest of
`apply` costs, and the transient from 20 MB to kilobytes.

## Acceptance Criteria

- [x] `apply`: after the fact appends, for each order, either insert each new
      fact id (generation E) into a handle starting from the published root, or
      — when the changeset's assert count exceeds `INSERT_SORT_THRESHOLD` — run
      `store_build_permutations`. The threshold is a named constant with its
      measurement in the comment (break-even ~9,000 asserts at 4×10⁵ facts on
      the dev machine, from `btree_bench_test.odin`'s k=100 figure against the
      sort).
- [x] The candidate set the validator sees is built from the new roots exactly
      as the published one will be; `.Enforce` refusal, writer failure and
      dictionary overflow all release the candidate's roots and the arena
      returns to its pre-apply live count (checked by `test_apply_rollback_exact`
      extended with `arena_live`).
- [x] The retire list is drained at the top of `apply`, before the mark is
      taken.
- [x] Retracts still touch no index (a retract-only changeset allocates no
      node); asserts of a quad retracted earlier produce a new generation
      correctly ordered after the old one by fact id.
- [x] `test_apply_replay_equivalence_*`, `test_apply_crash_sweep`, the boot
      cross-restart sweep and the reader/writer torture pass unchanged — a
      store built by inserts and one built by replay's sort-and-pack answer
      identically (`same_projection` compares windows, not node shapes).
- [x] `test_scale_commit_latency` re-measured and its log line amended:
      target mean ≤ 1 ms on the memory seam, transient per commit reported;
      `test_scale_bulk_apply` (one 4×10⁵-op changeset) takes the sort path and
      stays at ~260 ms.
- [x] `RECORD-A-0005`'s review-trigger paragraph annotated with the date and
      the new figure; the full amendment is T-0043's.

## Implementation Notes

- Inserts are per order, sequential; the seven trees share one arena and one
  generation. Nothing here is parallel and nothing should be — the premise is
  ~200 tenants per machine, not one fast tenant.
- Fill drift is expected and is not this task's problem (`RECORD-A-0012`'s
  trigger); the scale test may log the arena's fill after its 24 commits for
  the record.

## Status Updates

**2026-09-04 — done. RECORD-T-0018's number: 37.1 ms → 0.24 ms.**

- `store_insert_permutations` (permute.odin): each order from the published
  root, inserts under generation `n_epochs` (= E), an untouched order's root
  retained for the new set. `INSERT_SORT_THRESHOLD :: 8192` (`@(private)` —
  `make api` caught it exported), with the break-even measurement in its
  comment; `apply` takes `store_build_permutations` above it.
- **One design correction found by the leaf counts**: `apply` released its
  own head snapshot at return, after the publish, so the superseded set died
  at return and its nodes waited for the *next* apply's drain — a set's worth
  of nodes always one commit behind. Head is now released right after the
  install and the retire list drained there, so reclamation is exact within
  the commit and the scale test's transient figure is honest.
- Rollback: `test_apply_rollback_exact` now checks the arena's live counts
  before and after the failed apply. New `test_apply_permutation_paths`: the
  sort path packs full (leaves = 7 × ⌈n/256⌉), the insert path stays sorted,
  a retract-only changeset allocates nothing and republishes the same roots,
  and a re-asserted quad's two generations are both indexed, id-ordered, and
  visible one at a time by epoch.
- Crash sweep, replay equivalence (both seams), cross-restart sweep, the
  reader/writer torture and the two verifiers: unchanged and green.

**Measured** (`test_scale_commit_latency`, alone, `-o:speed`, 4×10⁵ facts,
memory seam): min 0.18 ms, **mean 0.24 ms**, max 1.04 ms; transient
**0.43 MB** per commit over 23.7 MB resident (was 20.1 MB); permutations
11.21 MB live, 11,009 leaves at 99% fill after the 24 commits. Bulk apply of
4×10⁵ ops takes the sort path: 248 ms (was 277). The benchmark's IRI-heavy
apply: 0.5 ms mean. `RECORD-A-0005`'s trigger paragraph annotated.

`make check` 73 names; `make test` 93 + 11 + 1 + 100, green.