---
id: 001-the-format-layer-stays-in-record
level: adr
title: "The format layer stays in record: @(private) is package-scoped, and the split would export 38 more names than it hides"
number: 1
short_code: "RECORD-A-0010"
created_at: 2026-09-01T11:27:28.046052+00:00
updated_at: 2026-09-01T11:27:28.046052+00:00
decision_date: 2026-09-01
decision_maker: Greger Olsson
parent: 
archived: false

tags:
  - "#adr"
  - "#phase/decided"


exit_criteria_met: false
initiative_id: NULL
---
---

# ADR-10: The format layer stays in record

**Supersedes [[RECORD-A-0009]]**, decided and superseded the same day, 2026-09-01.

## Context

`RECORD-A-0009` decided to move `encode.odin`, `term.odin` and `crc32c.odin`
into a `record/log` subpackage, on the argument that the split was *free*: the
three files' type surface has no out-edges to the rest of `record`, and Odin
re-exports by alias, so no consumer would see a change. `RECORD-I-0006` was
created to execute it.

**The measurement behind "free" was taken in one direction only, and the other
direction is where the cost is.** The out-edge analysis showed that nothing
*inside* the format layer depends on the store. It said nothing about the store
depending on the format layer — which is the direction that determines what a
package boundary costs, because `@(private)` in Odin is **package**-scoped.

### What the reverse measurement found

The three files declare 79 symbols. **52 are `@(private)`, and 38 of those are
used by non-test code elsewhere in `record`.** A package boundary between them
means every one of those 38 must become public in `record/log`:

| forced public | used by |
| --- | --- |
| `INLINE_BIAS`, `INLINE_PAYLOAD_MASK`, `INLINE_TAG_SHIFT`, `INLINE_TAG_BOOLEAN`, `INLINE_TAG_INTEGER`, `INLINE_TAG_DATE`, `INLINE_VALUE_MIN`, `INLINE_VALUE_MAX` | `resident.odin`, `read.odin`, `intern.odin` |
| `TERM_TAG_BLANK`, `TERM_TAG_LANG`, `TERM_TAG_STRING`, `TERM_TAG_TYPED`, `TERM_TAG_SPLIT_IRI`, `TERM_TAG_TRIPLE`, `TERM_TAG_DIR_LANG`, `TERM_TRIPLE_PAYLOAD` | `intern.odin`, `read.odin` |
| `record_kind`, `commit_decode`, `commit_ops`, `commit_terms`, `op_next`, `term_next`, `chain_hash`, `seal_decode`, `note_decode`, `get_u32`, `get_u64`, `inline_ok`, `MAX_RECORD_SIZE`, `Commit_View`, `Note_View` | `open.odin`, `replay.odin`, `read.odin` |
| `Note`, `Seal`, `note_encode`, `seal_encode` | `writer.odin` |
| `civil_from_days`, `put_u64_at`, `term_order_ok` | `intern.odin`, `load.odin` |

`record/log` would export **65** names — the 27 intended plus these 38. Since
`record/log` is importable by anyone, exactly as `record/ingest` is, those are
public API in the same sense as any other name.

**The arithmetic inverts.** `record` goes 121 → 96, but the total exported
across the two importable packages goes **121 → 161**. `RECORD-I-0005` spent
its effort marking 74 declarations `@(private)`; this split would hand 38 of
them straight back.

### What the forced set says about the boundary

The largest block is the inline-term encoding and the term tags. `RECORD-A-0001`
froze **one** inline encoding, used both on disk and resident — `RES_INLINE_*`
in `resident.odin` is that same encoding at u32 width, and `INLINE_TAG_INTEGER`
means the same thing on both sides of the store. The proposed boundary runs
straight through it. That is not an accident of how the code was written; it is
what `RECORD-A-0001` decided, and a package split cannot honour it without
either publishing the encoding or duplicating it.

## Decision

**`encode.odin`, `term.odin` and `crc32c.odin` stay in package `record`. There
is no `record/log`.** `RECORD-A-0009` is superseded and `RECORD-I-0006` is
closed unstarted, with no source file touched.

The residue `RECORD-A-0009` was trying to remove — 13 names exported for
`tool/`, 43 held by the `tests/*` suites — stays exported and stays **stated**:
`doc/api-surface.txt` carries it in two labelled sections that say who holds each
name and why. Accurately described is the outcome available here; smaller is not.

## Alternatives Analysis

**Proceed anyway**, accepting `record/log`'s 65-name surface on the grounds that
consumers look only at `record`. Rejected: the initiative's goal was that the
exported surface be a deliberate statement, and 38 names would be exported for
no reason but a directory boundary — the exact defect being fixed, relocated.

**A three-way split**, extracting the frozen inline encoding into a small
package both sides import, so neither has to export it. This is the only shape
that could work, and it is a deeper restructure than either ADR scoped. Not
rejected on merit — deferred for want of a reason to do it, since no consumer
is asking and the accurate surface file already answers the original complaint.

## Rationale

Fewer exported names was the whole point. A change that yields more of them,
and that publishes a deliberately-frozen internal encoding to do it, fails on
its own terms whatever it does to one package's count.

There is a second reason to prefer stating over moving: `doc/api-surface.txt`
plus `make api` already make an unintended export a failing build. The residue
is visible, attributed, and defended by CI. A subpackage would move it, not
remove it.

## Consequences

### Positive

- The frozen inline encoding stays one object in one package, as
  `RECORD-A-0001` has it.
- Nothing moves: no import paths change, no aliases to drift, no second surface
  file, no release question.
- `RECORD-I-0005`'s result stands unqualified — 121 exported, 74 made private,
  every name accounted for.

### Negative

- `record` keeps 56 exported names that are not interface. They are stated, not
  hidden, and `tool/` and `tests/proof` remain the reason.
- The repository's package structure still does not mirror `log.md` / `api.md`.
  That mismatch is now a recorded decision rather than an unexamined default.

### Neutral

- No source change, no format change, no consumer impact — this ADR is the
  outcome of a measurement, and its work product is the measurement.

## Review Triggers

- The `tests/scale` measurement stops needing hand-built stores, or `tool/`
  stops needing the format directly — then the residue shrinks on its own and
  no split is needed for it.
- Someone proposes the three-way split with a consumer behind it — then the
  38-symbol coupling above is the number to design against, and this ADR is the
  starting point rather than an obstacle.
- A future Odin gains a visibility scope between `@(private)` and exported —
  that would change the arithmetic entirely.
