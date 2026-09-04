---
id: the-seal-is-cross-checked-four
level: task
title: "The seal is cross-checked: four equalities against the walk, in both verifiers"
short_code: "RECORD-T-0036"
created_at: 2026-09-02T21:25:20.278981+00:00
updated_at: 2026-09-02T21:25:20.278981+00:00
parent: RECORD-I-0008
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0008
---

# The seal is cross-checked: four equalities against the walk

## Parent Initiative

[[RECORD-I-0008]]

## Objective **[REQUIRED]**

A segment seal's summary fields are decoded and then believed by nobody —
which is the same thing as being unchecked. Make them checkable the way
`RECORD-T-0003` made the header's fields checkable: by equality against
state the walk already carries.

## Why this is first

Everything else in [[RECORD-I-0008]] is worth less without it, and the
signing seam ([[RECORD-T-0038]]) is worth *negative* without it: §5.4
offers `sig` as "optional signature over finalHash", so signing a
`finalHash` that nothing binds to the segment's content produces an
attestation that is convincing and empty.

## Reproduction, before any change

An in-package probe rewrote a seal's `finalHash` to `0xAA…`, its
`lastEpoch`, `recordCount` and `lastFactID` to `0xFF…`, and recomputed the
frame CRC as an editor of the file would. `verify` returned
`Open_Error.None` with `Tear_Kind.None`; `seal_decode` accepted the body
before and after. `rdflog_verify.py`'s `check_seal` (line 173) checks
`len(body) >= 57 and 57 + be32(body, 53) == len(body)` and nothing else.

The existing corpus case `sealed-bitflip-seal → corrupt` does not cover
this: it fails on the *frame CRC*, so it catches accidental damage only.
§4 is explicit that "anyone rewriting a record can trivially recompute its
CRC" — that is the whole reason the chain exists, and the seal sits
outside it.

## Acceptance Criteria **[REQUIRED]**

- [ ] `walk_segment`'s `.Segment_Seal` case (`open.odin:389`) checks, after
      `seal_decode` succeeds: `final_hash == r.head`, `last_epoch ==
      r.last_epoch`, `record_count == records`, `last_fact_id ==
      r.fact_count`. A mismatch is `.Corrupt` — it is a record disagreeing
      with the bytes around it, which is what `.Corrupt` already means for
      an unknown kind and a trailing-bytes seal.
- [ ] `rdflog_verify.py` performs the identical four checks, each citing
      §5.4, so the two verifiers still agree verdict for verdict. This is
      the one that keeps the third-party claim honest.
- [ ] Corpus case **`seal-lies`** → `corrupt`: a seal with a rewritten
      `finalHash` and a repaired frame CRC.
- [ ] Corpus case **`forged-clean`** → `corrupt`: the whole-store rewrite
      from `forge.py`, which today verifies clean end to end. It becomes
      `corrupt` because the forger does not update the seal — and when
      [[RECORD-T-0039]] teaches it to, the case is re-pinned as `clean`
      and stands as the standing proof that an unkeyed chain cannot do
      this job alone. **Pin what is true, not what is comfortable.**
- [ ] Both verifiers agree over the extended corpus on every `make test`.
- [ ] `make check` green, including `make api` — no exported name moves.

## Implementation Notes

- The values are all in hand at that point in the walk: `r.head` is the
  running chain head, `r.last_epoch` the running epoch, and `records` /
  `r.fact_count` the counters the header check already uses one segment
  later. No new state, no second pass.
- **Ordering inside the case matters**: `seal_decode` first (a seal that
  does not parse is already `.Corrupt`), then the equalities.
- The seal stays *outside* the chain — this task does not hash it. §5.4's
  asymmetry with the environment note is unchanged and is still right; the
  seal is a summary, and a summary that must agree with what it summarises
  is still a summary.
- `walk_segment` sets `sealed = true` in this case; leave that after the
  checks so a lying seal does not also mark the segment sealed for the
  writer-resume path.
- Watch the counter semantics: `records` is this segment's commits, while
  `r.fact_count` and `r.last_epoch` are store-wide running values. That is
  exactly what `rotate()` writes into the seal (`writer.odin:370-375`:
  `w.epoch_records`, `w.fact_count`, `w.prev_epoch`, `w.head`), so the
  four equalities are the writer's own fields read back.
- No format change, no API change, no consumer impact — a sealed segment
  our writer produced already satisfies all four.

## Status

**2026-09-02 — todo.** Filed from the adversarial review; probe removed
after reproducing.
