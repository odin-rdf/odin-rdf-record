---
id: the-boundary-written-down-doc-api
level: task
title: "The boundary written down: doc/api-surface.txt, reconciled against api.md"
short_code: "RECORD-T-0030"
created_at: 2026-09-01T11:03:01.195451+00:00
updated_at: 2026-09-01T11:12:24.098223+00:00
parent: RECORD-I-0005
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: RECORD-I-0005
---

# The boundary written down: doc/api-surface.txt, reconciled against api.md

## Parent Initiative

[[RECORD-I-0005]]

## Objective

Produce the normative list of what `record` exports, before a single
`@(private)` is added. Every later step in this initiative is checked against
this file; without it, "is this symbol interface?" is answered 195 times by
whoever happens to be holding the keyboard.

Nothing in `record/` changes in this task.

## Acceptance Criteria

- [ ] `doc/api-surface.txt` exists: one exported name per line, sorted, no
      commentary — a file a diff can be read against.
- [ ] Its starting point is the 47 symbols measured as reached by name from
      odin-rdf-shacl and odin-rdf-sparql, plus the types those 47 reach through
      their own signatures and struct fields (`Origin`, `Range`, `File_Ops`,
      `Index_Set`, `Read_Status` and whatever else the closure finds).
- [ ] `doc/design/api.md` and the list agree. Where they disagree, the
      disagreement is resolved in the document and noted — api.md is the
      specification, and if it describes something not exported, or omits
      something that must be, that is a finding worth recording rather than
      quietly reconciling.
- [ ] The 10 symbols `tool/` and `record/ingest` reach are listed separately and
      explicitly, as the format layer, not merged into the store's surface.
      `RECORD-T-0033` decides where they belong.
- [ ] The measurement is reproducible: the script or command that produced the
      external-use counts is recorded in the task, so the next session can rerun
      it rather than trust it.

## Implementation Notes

### Technical Approach

The external counts come from grepping `\b(record|rec)\.<symbol>\b` across
odin-rdf-shacl and odin-rdf-sparql — both aliases, since sources use bare
`record.` and `rec.` both. That grep is necessary and not sufficient: a type
reached only by inference never appears. The closure over public signatures has
to be computed from this repository's own sources, not from the consumers'.

Order of work: dump the exported set, subtract nothing, then justify each name's
presence. A name nobody can justify is a finding for `RECORD-T-0031`.

### Dependencies

None. This is the first task.

### Risk Considerations

The temptation is to skip this and start marking things private, letting the
compiler decide. That produces a boundary that is *whatever compiled*, which is
the situation this initiative exists to end.

## Status Updates

### 2026-09-01 — the boundary is written down, and it is 78 of 195

`doc/api-surface.txt` exists: **65 names in the store API, 13 in the format
layer, 117 to become private.** The tool that derives it is
`tests/api/api_surface.py`, in the repository rather than in a session's
scratchpad, with two commands — `closure` (recompute and justify) and `check`
(diff today's exports against the file, which is what `RECORD-T-0032` wires into
`make api`).

**Grep was not enough, by a third.** 47 names are spelled by odin-rdf-shacl or
odin-rdf-sparql as `record.X` or `rec.X`. Another **18 are reached only by
inference** and appear in no consumer source: `Range` (a consumer writes
`r := snapshot_match(...)`), `Origin` and `Graph_Scope` (`Filter{origin = .Any}`
uses implicit selectors), `File_Ops` (`store_open`'s third parameter, passed as
`mem_file_ops(&fs)`), `Fact`, `Fact_ID`, `Quad`, `Component`, `Tear`,
`Tear_Kind`, `Load_Error`, `Writer_Error`, `Read_Status`, `File_Handle`,
`Epoch_Meta`, `Changeset`, `Apply_Error_Kind`, `SEGMENT_TARGET_SIZE`. Had the
marking pass been driven by the grep, every one of these would have been made
private, and — per the initiative's Context experiment — **most would still have
compiled**, leaving the docs naming types they no longer define.

**The load-bearing decision: traversal stops at the opaque handles.** `Store` is
public because consumers declare one, and its struct body references `Dict`,
`Writer`, `Index_Set`, `Env_Note` and the chunk constants. Expanding it puts 9
more internal names on the surface for no consumer benefit — nobody reads
`s.dict`. So the closure reaches a handle and stops: `Store`, `Snapshot`,
`Writer`, `Range`, `Scan`, `Index_Set`, `Dict`, `Loader`, `Intern`, `Mem_FS`,
`Mem_File`, `Term_Iter`, `Op_Iter`. Odin has no opaque struct, so this is a
decision recorded in the tool's `OPAQUE` set, not something the language
enforces; changing that set changes the surface and shows up in review.

**Three false positives the extractor had to be taught about**, each of which
would have inflated the surface:

- proc *bodies* — cut the signature at the body brace, but keep the return type
  (the first cut dropped `Range` from `snapshot_match`);
- *enum members* — `Apply_Error_Kind` has a member named `Writer`, which dragged
  the `Writer` type into the API closure;
- *comments* — struct-body prose naming `verify`, `replay` and `Consumer` made
  three procedures look type-reachable, which is not a thing that can be true.

### The reconciliation with api.md, and what it found

`doc/design/api.md` **is not a list of exported names and never was**: it
mentions 25 of the 195 in backticks, and it is written in design names —
`Match`, `Iter`, `Resolve`, `Bytes`, `Term` — where the Odin identifiers are
`snapshot_match`, `range_iter`, `snapshot_resolve`. So `api-surface.txt` is new
information beside it, not a restatement of it, and the header says so. Two
genuine disagreements, both resolved rather than papered over:

- **`LIVE_EPOCH` is promoted to the API.** Nothing spells it — the counts put it
  in tests only — but `Fact` is public by inference through `snapshot_fact`, and
  `Fact.epoch_end == LIVE_EPOCH` is the only way to read a fact's liveness.
  api.md par. 10 documents the sentinel. Exporting a struct whose fields cannot
  be interpreted is the worse of the two errors. Recorded as `PROMOTED` in the
  tool with that reasoning, so it is a decision and not a leak.
- **`Dict` stays private** though api.md names it. It is described there as part
  of the resident design — the arena — not as something a consumer touches, and
  it is reachable only through `Store`'s body.

### Reproducing it

```
python3 tests/api/api_surface.py closure           # the classification
python3 tests/api/api_surface.py closure -v        # with every name listed
python3 tests/api/api_surface.py check             # diff against the file
```

`closure` takes `--consumers` (default `../odin-rdf-shacl ../odin-rdf-sparql`),
so a new consumer is one flag rather than an edit. `check` fails today, loudly
and correctly: 117 names are still exported that the file does not list. That is
`RECORD-T-0031`.

Note for whoever runs this next: `odin doc -doc-format` aborts the compiler on
`dev-2026-08:8412dc37a` (`src/docs_writer.cpp(268)` assertion, reproducible on
`core/strings`), so the textual output is the only available input and the name
extraction parses it. If a later Odin fixes `-doc-format`, that is the more
robust input.

**No source file in `record/` changed in this task**, which was the point.