---
id: the-segment-writer-append-fsync
level: task
title: "The segment writer: append, fsync discipline, rotation, HEAD"
short_code: "RECORD-T-0002"
created_at: 2026-08-19T17:21:09.903184+00:00
updated_at: 2026-08-19T17:56:19.145185+00:00
parent: RECORD-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


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

- [x] Append path: framed records written at the tail; the call returns
      success only after `fsync` returns — §7.1's durability boundary,
      stated in the procedure's contract comment.
- [x] Rotation per §7.1: seal record appended, old segment fsynced, new
      segment created with a header carrying the old head as base hash,
      fsynced, then the *directory* fsynced — the step people forget,
      tested explicitly.
- [x] Sealing triggers: target size (64 MiB default) and an explicit seal
      call for the operator case; both produce identical bytes.
- [x] `HEAD` written advisorily (head hash hex + epoch); no read path ever
      trusts it.
- [x] File operations sit behind an injectable seam (a procedure set in
      the family's style) so crash tests can cut between any two steps.
- [x] Crash-ordering tests: for every cut point in the sequence, recovery
      over the resulting files shows no acknowledged record lost and no
      partial record surviving as valid (a frame-scan stand-in until
      RECORD-T-0003's full open path lands).
- [x] The darwin fsync question is investigated and the choice recorded:
      `fsync` on macOS does not flush the drive cache — whether the writer
      uses `F_FULLFSYNC`, and what Linux does, is a durability decision
      that belongs in a doc comment, not in folklore.
- [x] `make check` and `make test` green.

## Implementation Notes

### Technical Approach

One writer, no locks — the single-writer premise (`log.md` §10) is what
makes epoch allocation and chaining trivially correct, and this task is
where that premise becomes code shape. Writer state: current segment file,
offset, previous hash, next epoch, next fact ID.

**No batched-append API, decided 2026-08-19 (owner + session).** The
append surface is one shape — write, fsync, acknowledge, one record at a
time — because the *epoch* is the batch: `nOps` makes "many entries, one
fsync" a property of the format, not of the API (`log.md` §7.1's bulk-
import amortization), and at 33 bytes per op `MaxRecordSize` holds ~2
million ops, so the ceiling never binds at the target scale. An API that
shared one fsync across several epochs would either acknowledge before
durability (violating §7.1's boundary) or be group commit, which coalesces
concurrent committers we structurally do not have. The epoch is also the
audit grain — one actor, one reason — and the API should not tempt anyone
to widen it for throughput. `sync(2)` is never used: the primitives are
`fsync` on the segment file (F_FULLFSYNC question per the criteria) and
`fsync` on the directory at rotation.

### Dependencies

RECORD-T-0001 (the encodings this path writes).

### Risk Considerations

A durability claim that is wrong is worse than one that is absent. The
injectable file seam is the mitigation: every ordering claim in §7.1 gets a
test that breaks if the order changes.

## Status Updates **[REQUIRED]**

- **2026-08-19 — completed.** `record/writer.odin` (the single-writer
  append path behind the injectable `File_Ops` seam) and
  `record/writer_os.odin` (the POSIX implementation, build-tagged
  `linux, darwin`). Eighteen tests green under
  `ODIN_TEST_FAIL_ON_BAD_MEMORY`, the centerpiece being the crash sweep:
  the full script (four commits, a note, one size-triggered and one
  explicit rotation) replayed at *every* operation cut point, under two
  durable views (synced-only, and synced plus half the unsynced tail) —
  no acknowledged epoch lost, epochs always contiguous, nothing partial
  ever read as a record.
- **Design points settled during implementation:**
  - **Rotation happens before an append, never after one.** Sealing after
    a successful append would put failable IO between the fsync and the
    acknowledgement; an error there would report failure for a durable
    epoch. Same reasoning: a HEAD write failure is swallowed — advisory,
    derived, never trusted, and the commit it trails is already on disk.
  - **The durability decision (owner input, 2026-08-19): Linux is the
    production environment; darwin is development only.** On Linux,
    `fsync(2)` is the guarantee production relies on. On darwin the OS
    ops issue `F_FULLFSYNC` (constant defined locally — `core:sys/posix`
    does not expose it) and fall back to `fsync` where the filesystem
    refuses it, so dev machines do not silently hold weaker guarantees.
    Windows has no `File_Ops` implementation and the OS-backed tests are
    absent there by build tag — per the owner, sync-primitive CI tests
    may be gated to Linux.
  - **`writer_note` fills `last_epoch` itself** — the note follows the
    last committed epoch by construction, so the field cannot be wrong.
  - **The writer is fail-stop**: after any IO error it refuses further
    use; recovery is the open path, not a retry.
  - **Format clarification to fold into `log.md` §5.4 eventually**: the
    seal's `lastFactID` and the header's `first fact ID` are implemented
    as the fact-ID *high-water mark* (the id the next assert receives),
    so a segment with no asserts is representable without underflow;
    fact IDs are 0-based per `api.md` §2's positional FactID.
  - **`writer_create` only creates brand-new stores.** Resuming an
    existing store needs the verified head, segment number, and counters
    that only the open path can supply — that seam lands with
    RECORD-T-0003/T-0004.