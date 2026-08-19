---
id: the-tools-verify-dump-head
level: task
title: "The tools: verify, dump, head"
short_code: "RECORD-T-0005"
created_at: 2026-08-19T17:21:14.137245+00:00
updated_at: 2026-08-19T17:21:14.137245+00:00
parent: RECORD-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0001
---

# The tools: verify, dump, head

## Parent Initiative

[[RECORD-I-0001]]

## Objective

The auditor's read surface (`log.md` §12 question 6): one CLI with
`verify`, `dump`, and `head`, built with the format rather than after it —
`dump` in particular carries a load-bearing part of §11.2's readability
argument, since the answer to "binary is unreadable" is a dump tool, and
that answer must exist.

## Acceptance Criteria

- [ ] One main package at the location RECORD-T-0001 decided.
      `verify <dir>` runs the full chain verification, prints the head
      hash and last epoch, and exits non-zero on any halting verdict.
      `head <dir>` prints the derived head and the advisory `HEAD` file's
      content, warning on mismatch. `dump --format=nquads|json <dir>`
      replays with a dictionary-building consumer and emits every fact
      operation with terms resolved.
- [ ] N-Quads emission reuses the `rdf:` collection's emitters rather than
      hand-formatting terms; JSON is one operation per line, carrying op
      kind, epoch, and the epoch's actor/reason/wall.
- [ ] Retractions are marked distinctly in both formats — a retract is an
      *event*, not a quad in the graph — with the chosen representation
      documented in the tool's doc comment.
- [ ] Derived-op kinds (`0x11`/`0x12`) are dumped correctly even though
      RECORD-A-0002 means our writer never emits them: the tool reads the
      format, not our writer's habits.
- [ ] A Makefile target builds the tool; the README's Commands section is
      updated; a test drives the built binary over a known log and asserts
      its output.
- [ ] `make check` and `make test` green.

## Implementation Notes

### Technical Approach

`dump` is RECORD-T-0004's replay with a second consumer — one reader, two
consumers is the design test the seam was shaped for. The tool holds no
logic the library lacks; it is argument parsing around published calls.

### Dependencies

RECORD-T-0004.

### Risk Considerations

Output formats become de-facto contracts. Keeping N-Quads emission on the
parser repo's emitters means the format is the W3C's, not ours; the JSON
shape is ours and should be minimal for exactly that reason.

## Status Updates **[REQUIRED]**

*To be added during implementation*