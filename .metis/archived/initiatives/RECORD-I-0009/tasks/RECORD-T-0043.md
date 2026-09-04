---
id: documents-and-v0-8-0-api-md-record
level: task
title: "Documents and v0.8.0: api.md, RECORD-A-0005 superseded, the family file, and both engines walked"
short_code: "RECORD-T-0043"
created_at: 2026-09-04T18:57:21.125104+00:00
updated_at: 2026-09-04T19:31:41.367084+00:00
parent: RECORD-I-0009
blocked_by: []
archived: true

tags:
  - "#task"
  - "#phase/completed"


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

- [x] `doc/design/api.md` §5.2 amended under a dated note: the permutation is
      a B+tree of fact ids, the delta design is superseded, the measured table;
      §9's "inline-key B-tree" row annotated (rejected design ≠ this one, and
      why); §10's permutation row updated (11.1 MB packed, drift bound). §5's
      opening "seven sorted `[]FactID` slices" gets the note too.
- [x] `log.md` §8 annotated: re-measured for the tree on 2026-09-04, holds by
      13×.
- [x] `RECORD-A-0005` part 3 marked superseded by `RECORD-A-0012`, parts 1–2
      standing; `RECORD-T-0018`'s Status gains the new number.
- [x] `permute.odin`, `snapshot.odin`, `read.odin` package comments read true
      (no "sorted []FactID views", no "delta run arrives with Apply").
- [x] The vision's Current State and the family `CLAUDE.md` odin-rdf-record
      section amended with a dated paragraph: what moved, what did not (format,
      boot), the numbers.
- [x] Annotated tag `v0.8.0` — `Release v0.8.0: the permutations become
      B+trees` with a bulleted body — on a commit CI proved green; GitHub
      release with notes.
- [x] odin-rdf-shacl and odin-rdf-sparql walked: pins bumped, `make test` green
      with no source change expected, read pins unmoved (7503 on shacl's
      reference configuration; sparql's sixteen read counts), sparql's
      `make bench` re-run and re-pinned where match latency moved it. Each
      engine's vision Current State re-read and amended.

## Implementation Notes

- The expected consumer outcome is *no change*: neither engine names
  `Range.main`, `.delta` or `Scan.ids`. If either does not compile, that is a
  finding for this task's Status, not a reason to add a shim.

## Status Updates

**2026-09-04 — done. `v0.8.0` is tagged at `975693b` and released; both
engines pin it, green.**

- Documents: `api.md` §5's opening note, §5.2 superseded with the measured
  reasons, §9's two rows annotated, §10's permutation row; `log.md` §8
  re-asked for the tree (13×); `RECORD-A-0005` part 3 marked superseded and
  its trigger annotated; `RECORD-T-0018`'s Status carries the new number; the
  vision's Current State and the README gain the dated paragraph; the family
  `CLAUDE.md` (odin-rdf/.github, `4040115`) too. `permute.odin`, `snapshot.odin`
  and `read.odin` package comments were already rewritten in T-0041.
- Release: annotated tag `Release v0.8.0: the permutations become B+trees — a
  commit costs a quarter of a millisecond` on the commit CI proved green
  (run 33911182960), GitHub release from the tag's notes.
- odin-rdf-shacl walked (`SHACL-T-0043`, `eced08f`): pin `v0.8.0`, `make test`
  green, `make bench` 7503 as pinned, README + vision noted, CI green.
- odin-rdf-sparql walked (`SPARQL-T-0048`, `6e514ef`): pin `v0.8.0`, `make
  test` green with the survey byte-identical, `make bench` every read count and
  solution count unmoved at both sizes (nothing re-pinned; timings unpinned and
  within noise), vision noted, CI green.
- Found on the walk: both engines' previous walk tasks (`SHACL-T-0042`,
  `SPARQL-T-0047`) lacked the closing `---` of their frontmatter, so `metis
  sync` could not read them and each backlog counter had fallen behind by one.
  Repaired and pushed in both.

No consumer source changed — the third release running for which that is the
evidence the convention wants.