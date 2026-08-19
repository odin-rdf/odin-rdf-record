---
id: the-resident-measurement-boot-time
level: task
title: "The resident measurement: boot time and memory at ISMS scale"
short_code: "RECORD-T-0012"
created_at: 2026-08-19T20:10:55.154675+00:00
updated_at: 2026-08-19T20:10:55.154675+00:00
parent: RECORD-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0002
---

# The resident measurement: boot time and memory at ISMS scale

## Parent Initiative

[[RECORD-I-0002]]

## Objective

The initiative's exit gate, mirroring RECORD-T-0006's role: full boot —
`store_open`, verification through resident build through permutation
sort to a served snapshot — timed at ISMS scale in both of `log.md` §9's
epoch shapes against the vision's sub-second criterion, and the resident
footprint measured against api.md's ~30 MB shape. Numbers recorded in
RECORD-I-0002's status, the README amended, and the family CLAUDE.md
Current State re-read for claims this initiative falsifies — the
release convention, executed rather than remembered.

## Acceptance Criteria

- [ ] `tests/scale` grows a full-boot measurement: `store_open` on the
      bulk-loaded and hand-edited ISMS logs, timed end to end and broken
      down (verify+replay+build vs permutation sort), asserted under one
      second with the numbers logged.
- [ ] Resident memory measured — arena bytes, fact table, permutations,
      the by-term map, and the live-quad map if it was kept — with the
      method documented, and compared against api.md's budget; a
      material divergence is investigated, not shrugged at.
- [ ] Read-path sanity at scale: a handful of `Match` shapes on the
      booted store return oracle-checked results (wired through the
      T-0010 suite, not duplicated).
- [ ] Numbers recorded in RECORD-I-0002's status; the README's status
      section amended (the resident store exists; `Apply` is what
      remains); the family CLAUDE.md odin-rdf-record section re-read and
      amended with a dated note.
- [ ] `make check` and `make test` green.

## Implementation Notes

### Technical Approach

The generator, the two epoch shapes, and the timing scaffolding all
exist from RECORD-T-0006; this task points them at `store_open` instead
of `verify`/`replay` and adds the memory accounting. Dev-machine numbers
(Apple Silicon) are what get recorded, with the standing note that Linux
production numbers are taken when a production host exists.

### Dependencies

Every other task in the initiative — this is the gate.

### Risk Considerations

The number most likely to surprise is the by-term map's overhead (api.md
§4 prices the arena, and Odin's map internals differ from the document's
Go arithmetic). If the footprint diverges materially from the budget,
the finding goes to the initiative's status and, if it changes a
decision, to an ADR — not into silent acceptance.

## Status Updates **[REQUIRED]**

*To be added during implementation*