---
id: record-log-moving-the-pure-format
level: initiative
title: "record/log: moving the pure format layer out of the store's surface"
short_code: "RECORD-I-0006"
created_at: 2026-09-01T11:23:04.727049+00:00
updated_at: 2026-09-01T11:25:47.093562+00:00
parent: RECORD-V-0001
blocked_by: []
archived: true

tags:
  - "#initiative"
  - "#phase/design"


exit_criteria_met: false
estimated_complexity: S
initiative_id: record-log-moving-the-pure-format
---

# record/log: moving the pure format layer out of the store's surface Initiative

## Context **[REQUIRED]**

Execution of [[RECORD-A-0009]], decided 2026-09-01 out of `RECORD-T-0033`. The
analysis is done and is in the ADR; this initiative does the move.

In one line: `encode.odin`, `term.odin` and `crc32c.odin` become package
`record/log`; `record` re-exports `Op_Kind` and `INLINE_LEXICAL_MAX` as aliases;
`tool/` and `tests/proof` gain an import; `record`'s exported surface goes from
**121 to 96**, with the store API's 65 names unchanged and no
consumer touched.

The two measurements the decision rests on, both reproducible:

- the three files' type surface has **no out-edges** to the rest of `record`
  (`python3 tests/api/api_surface.py closure` is the tool the check was built
  in);
- Odin re-exports types, constants and procedures across a package boundary by
  plain alias, verified by a three-package experiment before the ADR was
  written.

## Goals & Non-Goals **[REQUIRED]**

**Goals:**

- `record/log` exists and holds the pure format layer.
- `record` exports 96 names, `make api` green against an updated
  `doc/api-surface.txt`.
- `tool/`, `tests/proof` and `tests/ingest` build and pass.
- **No source change in odin-rdf-shacl or odin-rdf-sparql**, and their suites and
  read pins unmoved — the same verification `RECORD-T-0031` ran.

**Non-Goals:**

- **Not the wide split.** `open.odin`, `replay.odin` and the writer files stay
  in `record`; `File_Ops` is store API. The ADR rejects the wide split on
  measurement and that is not reopened here.
- **Not a format change.** No bytes move, no version bumps, no compatibility
  question.
- **Not the section-3 question.** The 27 projection builders `tests/scale` holds
  are untouched; `RECORD-T-0032` established that moving that suite frees one
  symbol.

## Implementation Plan **[REQUIRED]**

Small enough to be one or two tasks; sequenced so the repository is green at
each step:

1. **The move.** `git mv` the three files into `record/log/`, change the package
   clause, add the two aliases to `record`, fix imports in `tool/`,
   `tests/proof` and anything else the compiler names. `make check && make test`.
2. **The surface.** Update `doc/api-surface.txt` to the new 96, with section 2
   down to its four I/O entry points. Decide whether `make api` should also
   check `record/log`'s own surface — the ADR flags that it currently would not,
   and a second surface file is the obvious answer.
3. **The consumers and the documents.** Both sibling suites and both benches;
   `doc/design/log.md` and `api.md` get a line saying the package boundary now
   matches the document boundary; the family `CLAUDE.md` entry for this
   repository is amended.

**Exit:** `record` exports 96; `make api` green; every suite in this repository
and in both engines green with no consumer source change; the ADR's Consequences
section confirmed rather than predicted.

## Status

**2026-09-01 — closed unstarted. The split does not do what it was for.**
Superseded by [[RECORD-A-0010]] before a source file was touched.

Execution began with the one check `RECORD-T-0033` had not run: not what the
three files reference, but what references *them*. `@(private)` in Odin is
**package**-scoped, and the three files declare 79 symbols of which 52 are
private — **38 of those are used by non-test code elsewhere in `record`**
(`resident.odin`, `read.odin`, `intern.odin`, `open.odin`, `replay.odin`,
`writer.odin`, `load.odin`). A package boundary forces all 38 public in
`record/log`.

So the arithmetic inverts: `record` 121 → 96, `record/log` 65, and the **total
exported across two importable packages 121 → 161**. `RECORD-I-0005` made 74
declarations private; this hands 38 back.

The forced set also says the boundary is misplaced. Its largest block is
`INLINE_TAG_*`, `INLINE_BIAS`, `INLINE_VALUE_*` and the `TERM_TAG_*` set —
the inline-term encoding `RECORD-A-0001` froze as **one** encoding used both on
disk and resident. The proposed boundary runs through the middle of it.

The Context section above stands as written, including its "zero out-edges,
therefore free" claim, which was true and irrelevant. It is left as the record
of the error: an out-edge measurement answers whether the moved code can stand
alone, not what a boundary costs the code left behind.