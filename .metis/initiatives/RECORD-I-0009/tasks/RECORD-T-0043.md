---
id: documents-and-v0-8-0-api-md-record
level: task
title: "Documents and v0.8.0: api.md, RECORD-A-0005 superseded, the family file, and both engines walked"
short_code: "RECORD-T-0043"
created_at: 2026-09-04T18:57:21.125104+00:00
updated_at: 2026-09-04T18:57:21.125104+00:00
parent: RECORD-I-0009
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0009
---

# Documents and v0.8.0

## Parent Initiative

[[RECORD-I-0009]]

## Objective

Bring the documents to what the code now does, tag `v0.8.0`, and walk both
engines — the family's "a release is not done until its consumers' Current
State is re-read" rule.

## Acceptance Criteria

- [ ] `doc/design/api.md` §5.2 amended under a dated note: the permutation is
      a B+tree of fact ids, the delta design is superseded, the measured table;
      §9's "inline-key B-tree" row annotated (rejected design ≠ this one, and
      why); §10's permutation row updated (11.1 MB packed, drift bound). §5's
      opening "seven sorted `[]FactID` slices" gets the note too.
- [ ] `log.md` §8 annotated: re-measured for the tree on 2026-09-04, holds by
      13×.
- [ ] `RECORD-A-0005` part 3 marked superseded by `RECORD-A-0012`, parts 1–2
      standing; `RECORD-T-0018`'s Status gains the new number.
- [ ] `permute.odin`, `snapshot.odin`, `read.odin` package comments read true
      (no "sorted []FactID views", no "delta run arrives with Apply").
- [ ] The vision's Current State and the family `CLAUDE.md` odin-rdf-record
      section amended with a dated paragraph: what moved, what did not (format,
      boot), the numbers.
- [ ] Annotated tag `v0.8.0` — `Release v0.8.0: the permutations become
      B+trees` with a bulleted body — on a commit CI proved green; GitHub
      release with notes.
- [ ] odin-rdf-shacl and odin-rdf-sparql walked: pins bumped, `make test` green
      with no source change expected, read pins unmoved (7503 on shacl's
      reference configuration; sparql's sixteen read counts), sparql's
      `make bench` re-run and re-pinned where match latency moved it. Each
      engine's vision Current State re-read and amended.

## Implementation Notes

- The expected consumer outcome is *no change*: neither engine names
  `Range.main`, `.delta` or `Scan.ids`. If either does not compile, that is a
  finding for this task's Status, not a reason to add a shim.

## Status Updates

*To be added during implementation*
