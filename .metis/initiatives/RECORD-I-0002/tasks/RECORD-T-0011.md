---
id: writer-resume-and-store-open-boot
level: task
title: "Writer resume and store_open: boot end to end"
short_code: "RECORD-T-0011"
created_at: 2026-08-19T20:10:49.492509+00:00
updated_at: 2026-08-19T20:10:49.492509+00:00
parent: RECORD-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0002
---

# Writer resume and store_open: boot end to end

## Parent Initiative

[[RECORD-I-0002]]

## Objective

Boot, end to end: `store_open(dir, ops)` = `recover` (truncation event
surfaced to the caller) → `replay` into the resident build → permutation
sort → publish → **resume the writer** from the verified walk. The
writer today only creates brand-new stores — `writer_create`'s doc
comment has pointed at this task since RECORD-T-0002 — so `File_Ops`
grows its last operation, open-existing-for-append, and `writer_open`
takes a `Verify_Result` and continues the chain: head, epoch counter,
term counter, fact-id high-water, segment number and size, commits in
the open segment. Resume trusts the verified walk and nothing else;
HEAD stays advisory, exactly as `log.md` §2 demands.

## Acceptance Criteria

- [ ] `File_Ops` gains open-existing-for-append (POSIX implementation
      plus the fakes); `create` keeps refusing existing paths — the two
      operations answer different questions and the writer's
      never-reopen invariant survives as "never reopened *by the
      writer's own path*".
- [ ] `writer_open(dir, ops, Verify_Result)` resumes every counter the
      walk verified; the first commit after resume chains from the
      pre-restart head, and the grown log verifies clean — through the
      Odin verifier and the Python verifier both.
- [ ] The rotation edges resume correctly: a tail segment that ends
      with a seal (rotation crashed before the new file) opens the next
      segment; an empty header-only tail appends into it; a recovered
      torn tail appends at the truncation point.
- [ ] `store_open` handles every open-path outcome: a fresh directory
      creates, a torn tail recovers with the event surfaced to the
      caller (never swallowed), a husk removes, and every halting
      verdict passes through untouched.
- [ ] The cross-restart crash sweep: every crash state of the writer's
      operation-budget sweep, booted by `store_open`, resumes and
      commits further epochs; the combined log verifies clean and
      replays to the union of both runs' acknowledged epochs.
- [ ] The environment note written at startup per `log.md` §7.1: after
      resume, `store_open` compares the current environment against the
      last note in the log and appends one only when it differs — with
      the **v1 note content decided and recorded here** (format version;
      the RECORD-A-0002 derived-facts regime declaration, "no reasoner,
      none logged" — so the first real log is self-describing), amending
      `log.md` §5.5 if the decision constrains the payload. This was
      RECORD-I-0001's one unrecorded decision; see the initiative's
      session-handoff note.
- [ ] `make check` and `make test` green.

## Implementation Notes

### Technical Approach

This task closes the loop RECORD-T-0002 and T-0003 left deliberately
open, and the cross-restart sweep is its centerpiece: the writer sweep
proved no acknowledged epoch is lost at any cut point; this proves the
store *continues* from every one of those states. The T-0003 status
update named this composition as deferred to the fault corpus — it
lands here instead, where the resume path exists to compose with.

### Dependencies

RECORD-T-0007 (the resident build store_open runs) and RECORD-T-0009
(publication at the end of boot). The proof corpus of RECORD-T-0006 is
reused: a resumed-and-grown store joins it as a clean case.

### Risk Considerations

The dangerous bug is a resume that writes a chain-valid record from
slightly wrong state (a fact-id off by one survives verification —
fact ids are not chained). The defense is exact-value comparison of a
resumed writer's counters against a never-crashed writer that performed
the same commits, byte-identical files as the criterion.

## Status Updates **[REQUIRED]**

*To be added during implementation*