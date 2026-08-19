---
id: writer-resume-and-store-open-boot
level: task
title: "Writer resume and store_open: boot end to end"
short_code: "RECORD-T-0011"
created_at: 2026-08-19T20:10:49.492509+00:00
updated_at: 2026-08-19T23:53:29.496451+00:00
parent: RECORD-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


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

- [x] `File_Ops` gains open-existing-for-append (POSIX implementation
      plus the fakes); `create` keeps refusing existing paths — the two
      operations answer different questions and the writer's
      never-reopen invariant survives as "never reopened *by the
      writer's own path*".
- [x] `writer_open(dir, ops, Verify_Result)` resumes every counter the
      walk verified; the first commit after resume chains from the
      pre-restart head, and the grown log verifies clean — through the
      Odin verifier and the Python verifier both.
- [x] The rotation edges resume correctly: a tail segment that ends
      with a seal (rotation crashed before the new file) opens the next
      segment; an empty header-only tail appends into it; a recovered
      torn tail appends at the truncation point.
- [x] `store_open` handles every open-path outcome: a fresh directory
      creates, a torn tail recovers with the event surfaced to the
      caller (never swallowed), a husk removes, and every halting
      verdict passes through untouched.
- [x] The cross-restart crash sweep: every crash state of the writer's
      operation-budget sweep, booted by `store_open`, resumes and
      commits further epochs; the combined log verifies clean and
      replays to the union of both runs' acknowledged epochs.
- [x] The environment note written at startup per `log.md` §7.1: after
      resume, `store_open` compares the current environment against the
      last note in the log and appends one only when it differs — with
      the **v1 note content decided and recorded here** (format version;
      the RECORD-A-0002 derived-facts regime declaration, "no reasoner,
      none logged" — so the first real log is self-describing), amending
      `log.md` §5.5 if the decision constrains the payload. This was
      RECORD-I-0001's one unrecorded decision; see the initiative's
      session-handoff note.
- [x] `make check` and `make test` green.

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

### 2026-08-20 — implemented; `make check` and `make test` green

**Where the code went.** `record/boot.odin` (`store_open`,
`ENV_NOTE_V1`) + `boot_test.odin`; `writer_open` and
`File_Ops.open_append` in `writer.odin` beside their kin;
`posix_open_append` in `writer_posix.odin`; and the OFS extension in
`fakefs_test.odin`. `build_proof_store` in `tests/proof` now boots the
corpus substrate through `store_open` and grows it one epoch through
the resumed writer, so all 29 corpus cases prove resume against the
independent Python verifier.

**Decisions recorded:**

- **The environment note's v1 content** (RECORD-I-0001's unrecorded
  decision, assigned here): `{"format":1,"derived":"none"}` — format
  version plus the RECORD-A-0002 regime declaration, keys in fixed
  order so "differs" is a byte comparison. Written by `store_open`
  after the writer resumes; mirrored into the resident note table so
  `store_note_at` answers about the current boot. `log.md` §5.5
  amended with the decision.
- **The test-fake composition** went the handoff's preferred way
  (option a): OFS gained the operation budget, synced/linked
  durability tracking, and `ofs_durable` — one full-fidelity fake;
  `Fake_FS` stays for the writer's own sweep (retiring it remains
  future cleanup). `ofs_create` now refuses existing live paths and
  reuses removed slots as fresh files.
- **`store_open`'s failure surface keeps three taxonomies** rather
  than flattening: `err: Open_Error` (walk verdicts pass through
  untouched), `load_err: Load_Error` (set iff err is .Consumer_Abort),
  `write_err: Writer_Error` (the resume path). Exactly one set on
  failure; a recovery event rides in `tear`, never swallowed.
- **The boot-peak sequencing recorded in T-0007's conversation is
  implemented**: the Loader (and its transient live map) is destroyed
  before the permutation sort allocates, so boot's transient peak is
  max(live map, sort scaffolding), not the sum.
- **Resume trusts the walk and nothing else**: every writer counter
  comes from `Verify_Result`; HEAD is rewritten on resume, never read.
  A sealed tail finishes the interrupted rotation by creating the next
  segment (byte-identical to rotation's own); anything else reopens
  the tail at its verified end via `open_append` — which refuses
  absent paths, `create`'s mirror image, so the never-reopen invariant
  survives as "never reopened by the writer's own append path".
  `Writer_Error` gained `.IO_Open`.

**Tests.** `writer_open` counters exact against the original writer's
own state (the fact-id-off-by-one defense), the grown log verifying to
the resumed head; **byte-identical files** from a writer that never
stopped versus six epochs split across two boots — HEAD included; the
rotation edges (sealed tail creates, header-only tail appends, torn
tail appends at the truncation point with the tear surfaced, husk
removed and rotation finished); a halting verdict passing through
untouched with the store destroyed clean; fresh-create with the
startup note as the first record and no duplicate note on an
unchanged-environment reboot. **The cross-restart sweep**: a scripted
writer life (four commits, a note, an explicit seal, rotation forced
by a 200-byte target) crashed at every operation cut point × both
durable-view variants (synced-only, plus half the unsynced tail), each
state booted by `store_open`, required to lose no acknowledged epoch,
resume, commit two more epochs, and verify + replay to the union of
both runs. One test bug worth remembering: a range loop bounded by
`w.prev_epoch` that the loop body advances never terminates — bounds
hoisted. 55 record tests (+5); proof and scale suites green.