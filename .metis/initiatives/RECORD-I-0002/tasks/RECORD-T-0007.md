---
id: the-resident-build-dictionary
level: task
title: "The resident build: dictionary arena, fact table, and the replay binding"
short_code: "RECORD-T-0007"
created_at: 2026-08-19T20:10:26.999327+00:00
updated_at: 2026-08-19T21:52:52.867859+00:00
parent: RECORD-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


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

- [x] The arena per api.md §4: term encodings stored verbatim (the
      dictionary is a near-literal copy of the log's term definitions),
      chunked so chunks never move — the invariant the zero-copy map keys
      depend on — with `u32` offsets locating term *i* in two loads.
- [x] The fact table per §2: no pointer fields; `Assert`/`Retract` epoch
      interval (retract open-ended until one arrives); `Derived` from the
      op kind's high nibble; `FactID` positional over asserts, agreeing
      with the log's rule and the segment headers' first-fact-id.
- [x] The re-tag: dictionary ids pass through (replay already bounds them
      below 2³¹); inlined ids move bit 63 → bit 31 with tag and payload
      per RECORD-A-0001 — a pure function, total on any log replay
      accepts, with its own unit tests.
- [x] Epoch table and notes: wall/actor/reason recorded per epoch; note
      payloads keyed by the epoch they follow, resolvable as api.md §12.6
      requires (the note in effect *at* an epoch, not just the latest).
- [x] Typed replay errors in the family style for retract-of-non-live and
      duplicate-assert, raised through the consumer's abort lever; logs
      crafted to trigger each must `verify` clean and fail the resident
      build — the judged/altered split, extended one layer up.
- [x] Equivalence: on the canonical test log and the ISMS log, counts and
      contents agree with the T-0004 collecting consumer (terms
      byte-for-byte via `Bytes`-style access, ops one for one).
- [x] `make check` and `make test` green.

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

### 2026-08-19 — implemented; `make check` and `make test` green (not yet committed)

**Where the code went.** Two files, not one, split along the seam the
design documents draw: `record/resident.odin` is the resident layout —
answerable to api.md §2–§4 alone, knows nothing of replay — and
`record/load.odin` is the load path, the `Builder` consumer binding the
seam per log.md §8. "Load" rather than "build" deliberately: it is
log.md's own word ("the only load path"), and `build/` already means
the Makefile's output here — and the API is named after the file
(`Loader`, `Load_Error`, `loader_init/destroy/consumer`, `load_commit/
term/op/note`), leaving "build" free for T-0008's permutation building. Tests mirror the split
(`resident_test.odin`, `load_test.odin`); the ISMS-scale equivalence
lives in `tests/scale`. Package doc in `record.odin` updated with the
file map.

**Decisions made here, as the handoff asked:**

- **Consumer-owned errors, confirmed.** `Load_Error` behind
  `.Consumer_Abort`, the `Dumper.fail` idiom: diagnosis on the Loader
  (`err`, `epoch`, the offending `op` or `term`). `Open_Error` is
  untouched — live-quad discipline is this store's semantic, not the
  format's.
- **The taxonomy has five members, not two.** Beyond §8's
  `Retract_Not_Live` and `Duplicate_Assert`: `Duplicate_Term` (two ids
  for one encoding breaks §3.2 injectivity — the silent-join-breaker
  api.md §3.3 warns about, and the arena's by_term map cannot represent
  it honestly), `Epoch_Overflow` (an epoch at or past the resident u32's
  `LIVE_EPOCH` sentinel, api.md §2.1 — exercised at the procedure, four
  billion commits being unwritable), and `Dict_Overflow` (the arena past
  its u32 addressing).
- **The transient live map lives on the `Loader`**, `map[Quad]u32`,
  and `loader_destroy` drops it while the Store stands — so dropping
  is the default, per api.md §6. Apply (next initiative) is the one
  consumer that may keep it, and decides then; nothing resident holds it.
- **Arena concretization** (api.md §4 left it to the implementation):
  1 MB chunks; a term's location is one packed u32 — chunk index in the
  high 12 bits, offset in the low 20 — so the ceiling is 4096 chunks /
  4 GB of term bytes (three orders over the ~5 MB design scale); an
  encoding larger than a chunk gets a dedicated chunk of exact size at
  offset 0, so no term spans two; length is recovered from the next
  term's offset, or the chunk's fill at a boundary. `by_term` keys are
  zero-copy views — the chunks-never-move invariant, stated as the
  contract comment the task asked for.
- **Fact chunks 8192** (api.md §2.3's number); the epoch table chunked
  the same way (§2.4 requires it for §12.1's publication); the derived
  bit in a parallel `[dynamic]u64` bitset per §2.2.
- **`resident_id` is a single-return total function** with its
  preconditions as asserts (replay has already refused everything
  outside them): dictionary ids pass through, booleans keep their raw
  0/1 payload, integer/date rebias 2^55 → 2^27. Exact-value unit tests
  including both range ends and the order-preserving property.

**Discovered: the ISMS generator violated both write disciplines.** The
resident equivalence test caught it — `tests/scale`'s generator (a)
defined the same encoding under multiple ids (dates draw from a
630-value space; language/string literals from small pools — ~14k
duplicate definitions), and (b) could assert a quad already live
(objects come from a reused pool). A real writer interns (log.md §5.2
first-appearance order) and keeps the graph a set (§5.3), so the
generator now does both: an `enc_ids` interning map (the encoding arena
now lives for the whole run) and a `live_set` duplicate-assert check
with object re-roll. **Corpus drift, superseding RECORD-T-0006's
recorded figures:** terms 95,345 → 80,879; logs 16.5 MB (bulk) /
37.9 MB (hand-edited), from 16.9/38.4. Verify/replay times unchanged
(106/270 ms, 168/333 ms). T-0006's numbers stand as the record of what
was measured then; RECORD-T-0012 re-records at this corpus.

**Equivalence, as accepted:** canonical log exact-value (every fact's
components, intervals, origin; terms byte-for-byte both directions;
epoch metas; note-in-effect boundaries), plus a crafted epoch of
derived assert/retract and a re-assert proving disjoint-interval
generations and the origin bitset; at ISMS scale, counts against the
verified walk and the generator's own live set, and a second replay
through a `Mirror` consumer with its own live map checking every
delivery against the built store. Refusal logs verify clean AND replay
clean, then fail the build typed — the judged/altered split one layer
up, asserted explicitly.

39 record-package tests (+5), scale +1; `make check` and `make test`
green throughout. Commit and transition deferred per session
instruction.