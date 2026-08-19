---
id: replay-the-record-reader-and-the
level: task
title: "Replay: the record reader and the consumer seam"
short_code: "RECORD-T-0004"
created_at: 2026-08-19T17:21:12.747703+00:00
updated_at: 2026-08-19T19:18:47.340952+00:00
parent: RECORD-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: RECORD-I-0001
---

# Replay: the record reader and the consumer seam

## Parent Initiative

[[RECORD-I-0001]]

## Objective

Replay as `log.md` §8 defines it, minus the resident store: read every
record in order through the verifying reader and stream what they carry —
term definitions, fact operations, environment notes — to a consumer
procedure set. That seam is the initiative's one forward-looking interface:
the next initiative binds the resident store to it; this one binds test
consumers.

## Acceptance Criteria

- [x] The consumer interface: procedures (with a context pointer, family
      style) for term definition (id, canonical encoding), fact op (op
      kind, S/P/O/G, owning epoch), environment note (lastEpoch, payload),
      and epoch commit boundary (epoch, wall, actor, reason) — narrow,
      contract-documented as the resident store's binding point, leaking
      no resident types.
- [x] Replay verifies as it reads — framing, CRC, chain, epoch contiguity,
      checked inline per §8 — and aborts with RECORD-T-0003's verdicts;
      there is no unverified read path.
- [x] The §5.2 `id == next expected` dictionary self-check enforced during
      replay, and the `api.md` §3.4 assertion that every dictionary id
      fits `u32` lands here — the boundary where the resident scheme's
      assumption belongs, even before anything resident consumes it.
- [x] A collecting test consumer proves order and completeness: what the
      writer wrote is exactly what replay delivers, counts and payloads
      both, across segment boundaries.
- [x] `make check` and `make test` green.

## Implementation Notes

### Technical Approach

Replay is the open path (RECORD-T-0003) plus delivery: verification and
reading are one pass, not two. The consumer seam should be shaped so a
future `Replay(dir, consumer)` is also what the dump tool (RECORD-T-0005)
runs — one reader, two consumers.

### Dependencies

RECORD-T-0003.

### Risk Considerations

The seam's shape is a guess about the resident store's needs until that
initiative exists. Keeping it record-shaped (deliver what the log says,
convert nothing) is the hedge — a consumer can always build more, but a
seam that pre-digests cannot deliver less.

## Status Updates **[REQUIRED]**

### 2026-08-19 — complete

`make check` and `make test` green (29 tests, memory tracking clean).

**Shape** — one reader, two callers, as the task asked: `verify` and
`replay` share the internal `open_walk`/`walk_segment` (open.odin), so
replay runs the exact verification pass with delivery threaded through it.
There is structurally no unverified read path, and no duplicated verdict
logic to drift.

- `record/replay.odin` — `Consumer` (context pointer + four procedures:
  `commit` boundary first, then `term`s in first-appearance order, then
  `op`s, with `note` between commits where the chain holds it; seals are
  never delivered per §5.4/§8). `enc`/`payload` borrow for the call only;
  a `false` return aborts with `.Consumer_Abort` — the lever a consumer
  uses for its own refusals (e.g. the §5.3 live-quad preconditions, which
  need the resident state being rebuilt and are deliberately NOT judged
  here). Nil procedures skip delivery; the judgements still run.
- `replay(dir, ops, consumer)` is read-only like verify: a torn tail
  reports `.Torn` with exactly the durable prefix already delivered — a
  caller that recovers first replays clean; one that replays first can
  recover after without replaying again.
- **Replay-only verdicts** appended to `Open_Error` (verify never returns
  them; a perfect chain around writer nonsense verifies but does not
  replay — the split is asserted test by test): `Term_Order` (§5.2
  self-check), `Term_Overflow` (resident bound), `Bad_Term_Id` (op/actor/
  reason naming an undefined id, or zero), `Inline_Range` (op component
  outside RECORD-A-0001's frozen range — api.md §3.4 rule 1 mirrored at
  the boundary), `Note_Epoch` (lastEpoch ≠ the epoch it follows),
  `Consumer_Abort`.
- **api.md §3.4 amended** (dated): the implemented dictionary-id bound is
  2³¹, not "fits in u32" — §3's own encoding spends bit 31 on the inline
  flag. `RESIDENT_ID_LIMIT :: u64(1) << 31` in replay.odin.

**Tests** (`replay_test.odin`; OFS fake + `obuild` lifted to
`fakefs_test.odin`, package-private, shared with open_test.odin): a
collecting consumer proves order and completeness against the canonical
3-segment log — exact delivery sequence "cttoonctoococo", every commit
boundary, term id + encoding bytes, op with owning epoch (inlined object
included), and the note payload; replay halts on a sealed-segment bit flip
having delivered nothing, and reports a torn tail read-only with the
durable prefix delivered; six chain-perfect crafts (encode-state lies and
patch-plus-rehash bodies) each verify `.None` and replay to their exact
verdict; a refusing consumer aborts.

**Note**: `Term_Overflow` is a scale guard proven by inspection — it fires
when the walk's own counter reaches 2³¹, which cannot be staged without
2³¹ term definitions (a crafted id fails `Term_Order` first, since the
counter is authoritative). Everything else has a failing test.