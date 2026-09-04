---
id: the-commit-path-inserts-the
level: task
title: "The commit path inserts: the threshold, rollback, and RECORD-T-0018's number re-measured"
short_code: "RECORD-T-0042"
created_at: 2026-09-04T18:57:19.724917+00:00
updated_at: 2026-09-04T18:57:19.724917+00:00
parent: RECORD-I-0009
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


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

- [ ] `apply`: after the fact appends, for each order, either insert each new
      fact id (generation E) into a handle starting from the published root, or
      — when the changeset's assert count exceeds `INSERT_SORT_THRESHOLD` — run
      `store_build_permutations`. The threshold is a named constant with its
      measurement in the comment (break-even ~9,000 asserts at 4×10⁵ facts on
      the dev machine, from `btree_bench_test.odin`'s k=100 figure against the
      sort).
- [ ] The candidate set the validator sees is built from the new roots exactly
      as the published one will be; `.Enforce` refusal, writer failure and
      dictionary overflow all release the candidate's roots and the arena
      returns to its pre-apply live count (checked by `test_apply_rollback_exact`
      extended with `arena_live`).
- [ ] The retire list is drained at the top of `apply`, before the mark is
      taken.
- [ ] Retracts still touch no index (a retract-only changeset allocates no
      node); asserts of a quad retracted earlier produce a new generation
      correctly ordered after the old one by fact id.
- [ ] `test_apply_replay_equivalence_*`, `test_apply_crash_sweep`, the boot
      cross-restart sweep and the reader/writer torture pass unchanged — a
      store built by inserts and one built by replay's sort-and-pack answer
      identically (`same_projection` compares windows, not node shapes).
- [ ] `test_scale_commit_latency` re-measured and its log line amended:
      target mean ≤ 1 ms on the memory seam, transient per commit reported;
      `test_scale_bulk_apply` (one 4×10⁵-op changeset) takes the sort path and
      stays at ~260 ms.
- [ ] `RECORD-A-0005`'s review-trigger paragraph annotated with the date and
      the new figure; the full amendment is T-0043's.

## Implementation Notes

- Inserts are per order, sequential; the seven trees share one arena and one
  generation. Nothing here is parallel and nothing should be — the premise is
  ~200 tenants per machine, not one fast tenant.
- Fill drift is expected and is not this task's problem (`RECORD-A-0012`'s
  trigger); the scale test may log the arena's fill after its 24 commits for
  the record.

## Status Updates

*To be added during implementation*
