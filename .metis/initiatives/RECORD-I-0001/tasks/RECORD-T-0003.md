---
id: the-open-path-chain-verification
level: task
title: "The open path: chain verification and torn-tail recovery"
short_code: "RECORD-T-0003"
created_at: 2026-08-19T17:21:11.322556+00:00
updated_at: 2026-08-19T19:02:37.095607+00:00
parent: RECORD-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


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

- [x] `verify` per §6: one sequential pass over all segments; returns the
      head hash and last epoch; seals are read but not chained; an unknown
      record kind in a sealed segment fails, never skips.
- [x] Typed verdicts, in the family's error style: clean; torn (only ever
      the final record of the open segment); corrupt/tampered, chain-broken,
      and epoch-gap — all three halt.
- [x] Torn-tail recovery: truncate to the bad record's start offset, fsync,
      and surface the truncation as a returned event for the caller to log
      and alert on — never silent (§7.2: in a system of record a truncation
      is an event someone should look at).
- [x] The position rule enforced and tested: a CRC failure before the tail,
      or anywhere in a sealed segment, halts as corruption; only the final
      record of the open segment may take the truncation path.
- [x] Fault injection: a valid multi-segment log truncated at *every* byte
      offset of its tail record recovers to exactly the last durable
      record; one flipped bit anywhere in a sealed segment halts
      verification; `len == 0` and oversized frames read as torn.
- [x] `make check` and `make test` green.

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

### 2026-08-19 — design settled, implementation starting

**Shape**: new file `record/open.odin` with two public procedures sharing one
internal walk:

- `verify(dir, ops, allocator) -> (Verify_Result, Tear, Open_Error)` — §6's
  sequential pass, strictly read-only. A recoverable tear is reported as
  `err = .Torn` with the `Tear` locating it; the file is untouched (the CLI
  verify of RECORD-T-0005 must never mutate).
- `recover(dir, ops, allocator)` — verify, then apply the tear: truncate to
  the record's start offset and fsync (`.Tail`), or remove a final segment
  whose header never became durable (`.Header` — the rotation-crash husk)
  and fsync the directory. The returned `Tear` is the surfaced event —
  never silent, per §7.2.

**`Verify_Result`** carries head + last_epoch (§6's returns) plus what
writer resume (T-0004) needs, all accumulated during the pass for free:
segments, next_term_id, fact_count, tail_size, tail_records, tail_sealed.

**`File_Ops` grows a read side** (same seam, RECORD-T-0002's rationale):
`read` (whole file, allocator-owned; Ok/Absent/Error), `truncate`
(truncate + fsync), `remove` (unlink). Segment enumeration is probing
`%06d.rlog` from 1 with one-file lookahead — numbering is contiguous by
construction, so no directory listing op is needed. POSIX impls added to
writer_posix.odin.

**Verdicts** (`Open_Error`): None, No_Store, IO_Read, IO_Recover,
Bad_Header, Base_Hash_Mismatch, Corrupt, Chain_Broken, Epoch_Gap, Torn.

**Decisions made where the document is silent, to be amended into log.md:**

1. **1–7 trailing bytes in the open segment are torn, not clean end.**
   §7.2's table reads "fewer than 8 bytes remain → clean end", but leaving
   a partial frame header in place would put garbage under the writer's
   next append. Clean end means *zero* bytes remain; a nonzero remainder
   truncates. (The every-byte-offset sweep forces this reading anyway.)
2. **Position-rule refinement**: a CRC-failed frame whose length field is
   plausible and whose extent ends *before* the file's end cannot be a
   torn append (the writer is fail-stop; nothing is ever written after a
   failed append) — it halts as .Corrupt rather than truncating, which is
   the task's stated risk (truncating evidence away) defended in code.
3. **Header cross-checks**: the verifier checks header.segment against the
   filename position and first_epoch/first_fact_id against the walk's
   running state — equality checks in the spirit of the base-hash rule.
4. **An unknown record kind halts everywhere**, including the final record
   of the open segment: a valid CRC proves the bytes were fully written,
   so it is never classified as torn.
5. **Rotation-crash husk**: a *final* segment shorter than 64 bytes, or
   exactly 64 with a magic/CRC failure, is the create-crash window (the
   header sync never returned) — recovery removes the file. `Bad_Version`
   with a valid CRC is a future format, never a husk. A husk at segment 1
   recovers to `.No_Store`. Anywhere non-final: `.Bad_Header`, halt.
6. **What verify does NOT check** (replay's business, T-0004): term-id
   contiguity, note.last_epoch, seal field values (§5.4: a summary,
   outside the chain — but its *structure* must decode, and its frame CRC
   still protects its bytes).

Tests in `record/open_test.odin` with a self-contained fake FS (writer_test's
fakes are file-private, deliberately): the every-byte-offset tail sweep, a
flip-one-bit-everywhere sweep over a sealed segment (every flip must halt —
frame CRC covers all bodies including seals), the position rule both ways,
torn shapes (len==0, oversized, short body, stray bytes), husk states,
verdict crafting (epoch gap, chain break via prev_hash and via hash field,
base-hash tamper, header-field tamper with recomputed CRC, Bad_Version).

### 2026-08-19 — complete

Implemented as designed above; `make check` and `make test` green (26 tests,
memory tracking clean). Deliverables:

- `record/open.odin` — `verify` (read-only, §6 + the header cross-checks)
  and `recover` (verify + the one repair per tear kind), sharing
  `walk_segment`; `Open_Error`, `Tear`/`Tear_Kind`, `Verify_Result` (head,
  last_epoch, plus the resume counters for T-0004).
- `File_Ops` grew `read`/`truncate`/`remove` (+ `Read_Status`), with POSIX
  implementations; the comment now names it the *log's* view of the
  filesystem, writer side and open side.
- `record/open_test.odin` — the fault-injection suite: every-byte-offset
  tail sweep over the open segment's whole record region (recovers to the
  exact preceding record boundary, then verifies clean), two-bits-per-byte
  flip sweep over a sealed segment (every flip halts; none reads torn or
  clean), position rule both ways plus sealed-final-record, the four torn
  shapes, unknown-kind-under-valid-CRC halting in both positions, husk
  states (0/1/63/garbage-64 bytes; version-2 lookalike halts as
  Bad_Header; segment-1 husk → No_Store), and crafted verdicts. Plus
  `test_posix_open_smoke` for the real read/truncate/remove.
- `log.md` amended (dated, old text stands): §6 notes the three header
  equalities the real verifier adds; §7.2 gets the three clarifications
  (1–7 trailing bytes are torn, the before-EOF CRC-failure refinement, the
  rotation-crash husk) — the Python verifier (T-0006) must mirror all of
  these to agree verdict for verdict.

**Deliberately deferred**: term-id contiguity and `note.lastEpoch`
self-checks are replay's business (T-0004) — verify answers "was this
altered?", not "is this semantically well-formed?"; the systematic
cross-check of writer crash states against the open path (writer sweep ×
recover) belongs to T-0006's fault corpus, and `scan_epochs`' comment in
writer_test.odin now says exactly that.

**Not committed** — per the user's instruction this session; working tree
holds the change.