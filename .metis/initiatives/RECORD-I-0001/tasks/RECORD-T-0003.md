---
id: the-open-path-chain-verification
level: task
title: "The open path: chain verification and torn-tail recovery"
short_code: "RECORD-T-0003"
created_at: 2026-08-19T17:21:11.322556+00:00
updated_at: 2026-08-19T17:21:11.322556+00:00
parent: RECORD-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0001
---

# The open path: chain verification and torn-tail recovery

## Parent Initiative

[[RECORD-I-0001]]

## Objective

The open path: walk the segments in order, validate every header, check
each base hash by equality against the previous segment's head, verify the
chain over commits and environment notes, enforce epoch contiguity, and
recover the torn tail under `log.md` §7.2's position rule. This is the code
that runs at every open, and the fault-injection suite is part of the task,
not a follow-up.

## Acceptance Criteria

- [ ] `verify` per §6: one sequential pass over all segments; returns the
      head hash and last epoch; seals are read but not chained; an unknown
      record kind in a sealed segment fails, never skips.
- [ ] Typed verdicts, in the family's error style: clean; torn (only ever
      the final record of the open segment); corrupt/tampered, chain-broken,
      and epoch-gap — all three halt.
- [ ] Torn-tail recovery: truncate to the bad record's start offset, fsync,
      and surface the truncation as a returned event for the caller to log
      and alert on — never silent (§7.2: in a system of record a truncation
      is an event someone should look at).
- [ ] The position rule enforced and tested: a CRC failure before the tail,
      or anywhere in a sealed segment, halts as corruption; only the final
      record of the open segment may take the truncation path.
- [ ] Fault injection: a valid multi-segment log truncated at *every* byte
      offset of its tail record recovers to exactly the last durable
      record; one flipped bit anywhere in a sealed segment halts
      verification; `len == 0` and oversized frames read as torn.
- [ ] `make check` and `make test` green.

## Implementation Notes

### Technical Approach

The verification loop is `log.md` §6's `Verify` translated to Odin — small
enough to read against the document side by side, which is the property to
preserve: this is the code the Python verifier (RECORD-T-0006) must agree
with verdict for verdict.

### Dependencies

RECORD-T-0001 (decoding), RECORD-T-0002 (a writer to produce logs to
injure).

### Risk Considerations

The dangerous failure is misclassifying tampering as a torn tail and
truncating evidence away. The position rule is the defense, and the
fault-injection suite exists to prove the classifier, not just the happy
path.

## Status Updates **[REQUIRED]**

*To be added during implementation*