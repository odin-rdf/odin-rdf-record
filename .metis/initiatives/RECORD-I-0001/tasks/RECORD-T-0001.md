---
id: record-encoding-bodies-framing-and
level: task
title: "Record encoding: bodies, framing, and the hash chain — pure functions"
short_code: "RECORD-T-0001"
created_at: 2026-08-19T17:21:08.492195+00:00
updated_at: 2026-08-19T17:41:04.976687+00:00
parent: RECORD-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: RECORD-I-0001
---

# Record encoding: bodies, framing, and the hash chain — pure functions

## Parent Initiative

[[RECORD-I-0001]]

## Objective

Every record encoding as pure functions over byte slices — the segment
header, the frame, the three record bodies, and the hash chain — with
encode → decode identity, no I/O anywhere, and the layout decisions the
initiative deferred to its first task made and recorded.

## Acceptance Criteria

- [x] Layout decided and recorded in RECORD-I-0001's Detailed Design: the
      log code's package placement (`record` vs a subpackage) and the CLI
      tool's future location, with the reason.
- [x] Segment header (`log.md` §3): 64 bytes, big-endian, CRC-32C over
      bytes 0..27 only; the base hash is carried, not CRC-covered — its
      check is equality at the open path, per the header's own argument.
- [x] Frame (§4): `u32 len` + CRC-32C over len‖body; `len == 0` and
      `len > MaxRecordSize` decode as *torn*, never as records; an unknown
      record kind is a typed failure, never a skip.
- [x] CRC-32C is Castagnoli, confirmed against published test vectors;
      if `core:hash` lacks it, the table lives beside the framing code.
- [x] Epoch commit (§5.1–5.3): term definitions carry the canonical
      encoding verbatim with the `id == next expected` self-check; fact
      ops are 33 bytes read without alignment assumptions (§5.3's note —
      never cast to `[]u64`); `prevHash`/`hash` last, hashed per §6's
      hash-the-body-prefix rule.
- [x] Environment note (§5.5) carries the chain; segment seal (§5.4)
      encodes with `sigLen = 0` and stays outside the chain.
- [x] Encode-side invariants refuse violations before bytes exist: epoch
      gaps, out-of-order term ids, inline IDs outside RECORD-A-0001's
      frozen range.
- [x] Hash and CRC test vectors computed by an independent tool (Python
      `hashlib`/a reference CRC-32C) committed as constants; round-trip
      tests per record kind.
- [x] `make check` and `make test` green.

## Implementation Notes

### Technical Approach

Pure procedures over `[]byte` in the family's style; the big-endian
read/write helpers in one place. Nothing here opens a file — the writer
(RECORD-T-0002) and the open path (RECORD-T-0003) compose these.

### Dependencies

None — the first implementation task in the repository.

### Risk Considerations

A byte layout mistake that ships in a real segment is permanent (`log.md`
§10: no migration). The independent test vectors and the later Python
verifier (RECORD-T-0006) are the mitigations; both check the *document's*
bytes, not the code's opinion of them.

## Status Updates **[REQUIRED]**

- **2026-08-19 — completed.** `record/encode.odin` (the header, the frame,
  the three record bodies, the chain hash, the inline-range checks, the
  big-endian helpers) and `record/crc32c.odin` (Castagnoli table —
  `core:hash` has only IEEE — with the published check value asserted).
  Twelve tests green under `ODIN_TEST_FAIL_ON_BAD_MEMORY`, including two
  golden vectors computed by an independent Python script (a full 64-byte
  header and a full 245-byte epoch commit compared byte for byte, plus the
  frame CRC) and the refusal matrix for both encode and decode. Layout
  decisions recorded in RECORD-I-0001's Detailed Design: one `record`
  package, CLI in `tool/`. One finding worth keeping: decoded views
  borrow, and the golden-fixture helper initially returned slices of its
  own locals — the family's lifetime discipline applies to test fixtures
  too.