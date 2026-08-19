---
id: replay-the-record-reader-and-the
level: task
title: "Replay: the record reader and the consumer seam"
short_code: "RECORD-T-0004"
created_at: 2026-08-19T17:21:12.747703+00:00
updated_at: 2026-08-19T17:21:12.747703+00:00
parent: RECORD-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


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

- [ ] The consumer interface: procedures (with a context pointer, family
      style) for term definition (id, canonical encoding), fact op (op
      kind, S/P/O/G, owning epoch), environment note (lastEpoch, payload),
      and epoch commit boundary (epoch, wall, actor, reason) — narrow,
      contract-documented as the resident store's binding point, leaking
      no resident types.
- [ ] Replay verifies as it reads — framing, CRC, chain, epoch contiguity,
      checked inline per §8 — and aborts with RECORD-T-0003's verdicts;
      there is no unverified read path.
- [ ] The §5.2 `id == next expected` dictionary self-check enforced during
      replay, and the `api.md` §3.4 assertion that every dictionary id
      fits `u32` lands here — the boundary where the resident scheme's
      assumption belongs, even before anything resident consumes it.
- [ ] A collecting test consumer proves order and completeness: what the
      writer wrote is exactly what replay delivers, counts and payloads
      both, across segment boundaries.
- [ ] `make check` and `make test` green.

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

*To be added during implementation*