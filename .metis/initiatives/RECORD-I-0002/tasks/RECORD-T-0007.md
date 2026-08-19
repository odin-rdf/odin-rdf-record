---
id: the-resident-build-dictionary
level: task
title: "The resident build: dictionary arena, fact table, and the replay binding"
short_code: "RECORD-T-0007"
created_at: 2026-08-19T20:10:26.999327+00:00
updated_at: 2026-08-19T20:10:26.999327+00:00
parent: RECORD-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0002
---

# The resident build: dictionary arena, fact table, and the replay binding

## Parent Initiative

[[RECORD-I-0002]]

## Objective

Bind the resident structures to RECORD-T-0004's replay seam — the store's
only load path. The dictionary arena (api.md §4: chunked blob whose chunks
never move, `u32` offsets, a by-term map whose keys are zero-copy views),
the pointer-free fact table (§2: `u32` components, `[Assert, Retract)`
epoch intervals, origin), the epoch table (wall, actor, reason per epoch —
"who" is total), and environment notes keyed by the epoch they follow.
Replay resolves each op residently: the 64→32-bit id re-tag, and retract
resolution to the currently-live fact — with `log.md` §8's two replay
errors (retract of a non-live quad, duplicate assert of a live one) typed
and enforced here, where resident state finally exists to judge them.

## Acceptance Criteria

- [ ] The arena per api.md §4: term encodings stored verbatim (the
      dictionary is a near-literal copy of the log's term definitions),
      chunked so chunks never move — the invariant the zero-copy map keys
      depend on — with `u32` offsets locating term *i* in two loads.
- [ ] The fact table per §2: no pointer fields; `Assert`/`Retract` epoch
      interval (retract open-ended until one arrives); `Derived` from the
      op kind's high nibble; `FactID` positional over asserts, agreeing
      with the log's rule and the segment headers' first-fact-id.
- [ ] The re-tag: dictionary ids pass through (replay already bounds them
      below 2³¹); inlined ids move bit 63 → bit 31 with tag and payload
      per RECORD-A-0001 — a pure function, total on any log replay
      accepts, with its own unit tests.
- [ ] Epoch table and notes: wall/actor/reason recorded per epoch; note
      payloads keyed by the epoch they follow, resolvable as api.md §12.6
      requires (the note in effect *at* an epoch, not just the latest).
- [ ] Typed replay errors in the family style for retract-of-non-live and
      duplicate-assert, raised through the consumer's abort lever; logs
      crafted to trigger each must `verify` clean and fail the resident
      build — the judged/altered split, extended one layer up.
- [ ] Equivalence: on the canonical test log and the ISMS log, counts and
      contents agree with the T-0004 collecting consumer (terms
      byte-for-byte via `Bytes`-style access, ops one for one).
- [ ] `make check` and `make test` green.

## Implementation Notes

### Technical Approach

A `Consumer` implementation in the `record` package — the resident store
is the third consumer of a seam already proven by two. The transient
live-quad map (`log.md` §8) is replay scaffolding here; whether it
survives replay for `Apply`'s later use is the initiative's recorded
decision, measurement-shaped. The arena's chunk size and growth policy
belong in a contract comment: "chunks never move" is the sentence
everything zero-copy hangs from.

### Dependencies

RECORD-I-0001 complete (it is). Nothing else — this task deliberately
precedes permutations and snapshots so its equivalence tests can run
against the raw structures.

### Risk Considerations

The re-tag and the fact-id discipline are the two places a silent
off-by-one becomes a quietly wrong store; both get exact-value tests
against the writer's own counters, which the open path already returns
verified.

## Status Updates **[REQUIRED]**

*To be added during implementation*