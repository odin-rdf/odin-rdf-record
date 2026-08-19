---
id: the-segment-writer-append-fsync
level: task
title: "The segment writer: append, fsync discipline, rotation, HEAD"
short_code: "RECORD-T-0002"
created_at: 2026-08-19T17:21:09.903184+00:00
updated_at: 2026-08-19T17:21:09.903184+00:00
parent: RECORD-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0001
---

# The segment writer: append, fsync discipline, rotation, HEAD

## Parent Initiative

[[RECORD-I-0001]]

## Objective

The single-writer append path of `log.md` §7.1 steps 1–3 — encode, append,
fsync, and only then acknowledge — plus segment rotation with the directory
fsync, and the advisory `HEAD` file. Steps 4–5 (apply, publish) belong to
the resident store's initiative and are explicitly absent here.

## Acceptance Criteria

- [ ] Append path: framed records written at the tail; the call returns
      success only after `fsync` returns — §7.1's durability boundary,
      stated in the procedure's contract comment.
- [ ] Rotation per §7.1: seal record appended, old segment fsynced, new
      segment created with a header carrying the old head as base hash,
      fsynced, then the *directory* fsynced — the step people forget,
      tested explicitly.
- [ ] Sealing triggers: target size (64 MiB default) and an explicit seal
      call for the operator case; both produce identical bytes.
- [ ] `HEAD` written advisorily (head hash hex + epoch); no read path ever
      trusts it.
- [ ] File operations sit behind an injectable seam (a procedure set in
      the family's style) so crash tests can cut between any two steps.
- [ ] Crash-ordering tests: for every cut point in the sequence, recovery
      over the resulting files shows no acknowledged record lost and no
      partial record surviving as valid (a frame-scan stand-in until
      RECORD-T-0003's full open path lands).
- [ ] The darwin fsync question is investigated and the choice recorded:
      `fsync` on macOS does not flush the drive cache — whether the writer
      uses `F_FULLFSYNC`, and what Linux does, is a durability decision
      that belongs in a doc comment, not in folklore.
- [ ] `make check` and `make test` green.

## Implementation Notes

### Technical Approach

One writer, no locks — the single-writer premise (`log.md` §10) is what
makes epoch allocation and chaining trivially correct, and this task is
where that premise becomes code shape. Writer state: current segment file,
offset, previous hash, next epoch, next fact ID.

### Dependencies

RECORD-T-0001 (the encodings this path writes).

### Risk Considerations

A durability claim that is wrong is worse than one that is absent. The
injectable file seam is the mitigation: every ordering claim in §7.1 gets a
test that breaks if the order changes.

## Status Updates **[REQUIRED]**

*To be added during implementation*