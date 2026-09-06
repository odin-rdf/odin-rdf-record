---
id: the-environment-note-says-format-1
level: task
title: "The environment note says format 1 on a format 2 store"
short_code: "RECORD-T-0053"
created_at: 2026-09-06T21:34:54.782659+00:00
updated_at: 2026-09-06T21:34:54.782659+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#bug"


exit_criteria_met: false
initiative_id: NULL
---

# The environment note says format 1 on a format 2 store

## Objective

`ENV_NOTE_V1` is `{"format":1,"derived":"none"}` and `FORMAT_VERSION` is 2. The
one record whose job is to make a log self-describing describes it wrongly, on
every store written since `v0.4.0`.

## Backlog Item Details

### Type
- [x] Bug - Production issue that needs fixing

### Priority
- [x] P2 - Medium (nice to have)

### Impact Assessment

- **Affected Users**: every store created or booted since `v0.4.0` (2026-08-25),
  which is every store that exists -- format 2 does not read format 1 logs, so
  there are no surviving format 1 stores for the note to be right about.
- **Reproduction Steps**:
  1. `strings -a <store>/000001.rlog | grep -o '{"format":[^}]*}'` -> `{"format":1,"derived":"none"}`
  2. `xxd -s 8 -l 4 <store>/000001.rlog` -> `0000 0002`
  Reproduced on `vsuite-be/build/volume.record`, 2026-09-06.
- **Expected vs Actual**: `log.md` par. 5.5 specifies the payload's `format` key as
  "the format version this writer speaks". A format 2 writer says 1.

**Severity is about honesty, not operation.** Nothing reads the note today: the
open path compares it byte-for-byte against the previous note and never parses
it, so no code branches on the wrong value and no data is at risk. What is
damaged is the property the record exists for -- `log.md` par. 5.5's "the first
record after any store's header makes the log self-describing" -- and it is
damaged for exactly the reader the record was put there for: a third party
reading the log from the specification, who would conclude format 1 and then find
a header saying 2. In a format whose value proposition is independent
verifiability, a self-description that contradicts the header is worse than none.

## Acceptance Criteria

- [ ] The note's `format` value is `FORMAT_VERSION` rather than a literal, so the
      next bump cannot leave it behind.
- [ ] A test that would have caught this: assert the *written* payload against the
      header's version, not against the constant that produced it.
- [ ] `log.md` par. 5.5's amendment is updated -- it quotes the v1 payload verbatim
      and so states the wrong value too.
- [ ] Decide and record what existing stores do. A changed payload differs from
      the last note, so **every store writes a corrected note at its next boot**,
      by the mechanism already designed for exactly this. That is the right
      outcome and should be stated rather than discovered.

## Implementation Notes

### Technical Approach

The value cannot stay a literal in a `::` constant if it must track
`FORMAT_VERSION`, and the payload has to remain byte-stable for the "differs from
the last note" comparison, which is a `string` compare. Either build it once at
startup with `fmt.aprintf` and own it, or keep a small `when`/lookup keyed on
`FORMAT_VERSION`. The first is simpler and the allocation is once per process.

### Root Cause

Two different version numbers coincided at 1 when the note was designed
(RECORD-T-0011, 2026-08-20): the **payload schema** version, which is what
`ENV_NOTE_V1`'s name refers to and is still 1, and the **log format** version,
which is the value of the `format` key and became 2 at RECORD-I-0004. Bumping the
format changed one and not the other, and nothing pointed at the difference.

`boot_test.odin:77` asserts the written payload equals `ENV_NOTE_V1` -- it
compares the constant against itself, so it pins the shape and can never catch
the value being wrong. That is the test worth fixing alongside, and the general
lesson: **a redundant field is only checkable against something independently
derived**, which is the argument `open.odin` already makes about the header's
positional fields and RECORD-T-0036 makes about the seal.

### Risk Considerations

Low. Changing the payload changes bytes appended at the next boot of every
store, which is the designed behaviour of a note, and the chain accommodates it
by construction. No format version bump: the note's payload is opaque to the
format.

## Status Updates

*Filed 2026-09-06, found while answering "what goes into an environment note?".
Nothing implemented.*
