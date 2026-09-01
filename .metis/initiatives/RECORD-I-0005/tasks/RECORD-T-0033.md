---
id: the-record-log-decision-whether
level: task
title: "The record/log decision: whether the format layer leaves the store's surface"
short_code: "RECORD-T-0033"
created_at: 2026-09-01T11:03:09.105312+00:00
updated_at: 2026-09-01T11:23:47.878468+00:00
parent: RECORD-I-0005
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: RECORD-I-0005
---

# The record/log decision: whether the format layer leaves the store's surface

## Parent Initiative

[[RECORD-I-0005]]

## Objective

Decide, with evidence and an ADR, whether the log/encoding layer moves into a
`record/log` subpackage. **Take the decision; do not execute it.** If the answer
is yes, execution is a separate initiative with a release of its own.

## Acceptance Criteria

- [ ] The full list of what would move is written down: `encode.odin`,
      `term.odin`, `crc32c.odin`, and the open/verify/replay path, with every
      symbol each currently exports and who names it.
- [ ] The cost to `tool/`, `tests/proof` and `tests/ingest` is stated as concrete
      import changes, not as an estimate.
- [ ] The cost to consumers is stated: whether any of the 47 external symbols
      would move, and if so what a pinning engine must change.
- [ ] An ADR records the decision either way. "No" is a real outcome and closes
      the question rather than deferring it again.
- [ ] If the answer is yes: a follow-up initiative exists, and this task does not
      touch a source file.

## Implementation Notes

### Technical Approach

The case for: 10 symbols are exported from `record` solely because `tool/` needs
the format layer — `verify`, `replay`, `Consumer`, `term_decode`, `inline_term`,
`HASH_SIZE`, `DEFAULT_GRAPH`, `TERM_TAG_IRI`, `Fact_Op`, `INLINE_FLAG` — and
`tests/proof` needs most of the same set. The split matches how the repository
already describes itself: `log.md` is the format, `api.md` is the store, and they
are separate documents because they are separate concerns. After it, `record`'s
surface is a store's surface.

The case against: it moves import paths in a tagged library that both engines
pin at `v0.6.0`, for a benefit no consumer asked for. The family convention is
that capability gaps become evidence and consumers drive change — and no consumer
is asking for this. It is also the one part of this initiative that cannot be
reverted with a one-line edit.

A middle answer exists and should be considered explicitly: leave the layer where
it is, keep the 10 exported, and let `doc/api-surface.txt` carry them in a
labelled second section — the surface stated accurately rather than made smaller.

### Dependencies

`RECORD-T-0030` for the symbol lists; `RECORD-T-0032` hands over the
`tests/proof` overlap.

### Risk Considerations

The real risk is scope: this is an inviting piece of restructuring attached to a
tidy-up initiative. The acceptance criteria are written to make execution
out of scope on purpose.

## Status Updates
### 2026-09-01 — decided: the narrow split. [[RECORD-A-0009]], executed by [[RECORD-I-0006]]

**Decision: move `encode.odin`, `term.odin` and `crc32c.odin` to `record/log`;
leave `open.odin`, `replay.odin` and the writer files in `record`.** Taken by
the owner on the evidence below. No source file was touched by this task.

### The two measurements that decided it

**The pure format files have zero out-edges.** Every declaration in the three
files references only other declarations in those three files — computed over
the full type surface of all 195 declarations, out-edge set empty. They are
already a subpackage and merely not stored as one, which makes the split free:
no interface to invent, no dependency to invert.

**Odin re-exports by plain alias.** `Kind :: log.Kind`, `LIMIT :: log.LIMIT`,
`encode :: log.encode` — types, constants and procedures all cross a package
boundary and compile, verified in a three-package experiment. So a name can live
in the subpackage and stay on `record`'s surface for one line, and **the split
is not a consumer-visible change**.

### Why not the wide split

Including the I/O half takes 50 names out instead of 27, but **14 of them are
store API and 7 are spelled by consumers today**: `Mem_FS`, `mem_file_ops`,
`mem_fs_destroy`, `posix_file_ops`, `Op_Kind`, `Open_Error`,
`INLINE_LEXICAL_MAX`. The first four are the `File_Ops` seam, used about two
dozen times in each engine to open a store over the memory backend — and
`File_Ops` is `store_open`'s third parameter, so it is store API however
format-adjacent it looks. Aliasing it back would leave those names on `record`'s
surface anyway: the wide split ends at 85 exported against the narrow split's
96, for seven consumer-visible moves and a genuine conceptual error about where
the seam belongs.

### What the decision buys, exactly

| | before | after |
| --- | --- | --- |
| section 1, store API | 65 | 65 (2 as aliases) |
| section 2, `tool/` | 13 | 4 — `Consumer`, `Verify_Result`, `replay`, `verify` |
| section 3, `tests/*` | 43 | 27, all projection builders |
| **total exported** | **121** | **96** |

`Op_Kind` and `INLINE_LEXICAL_MAX` are the aliases: a changeset op's kind and
the inline-lexical bound are things a consumer *states*, not things it decodes.

Section 3 becoming homogeneous is worth as much as the count: what remains is
one suite's need for hand-built stores, a single future question rather than a
mixed bag.

### Acceptance criteria

- [x] What would move is written down, with every symbol and who names it.
- [x] Cost to `tool/`, `tests/proof`, `tests/ingest` stated concretely: an
      import each; no consumer-spelled name moves.
- [x] Cost to consumers stated: **none** — no source change, two aliases carry
      the only API names in the moved files.
- [x] ADR records the decision: [[RECORD-A-0009]], decided.
- [x] Follow-up initiative exists: [[RECORD-I-0006]].
- [x] No source file touched by this task.
### 2026-09-01, later — the decision was executed as far as its first check, and reversed

**[[RECORD-A-0009]] is superseded by [[RECORD-A-0010]]; [[RECORD-I-0006]] is
closed unstarted and archived. No source file was touched.**

The status above stands as written, including its "the split is free" finding,
which was wrong in a specific and instructive way. The out-edge measurement --
the three files reference nothing outside themselves -- is true, and answers
whether the *moved* code can stand alone. It does not answer what the boundary
costs the code left behind, and that is the direction the cost was in.

`@(private)` in Odin is **package**-scoped. The three files declare 79 symbols,
52 private, and **38 of those are used by non-test code elsewhere in `record`**.
A package split forces all 38 public: `record` 121 -> 96, `record/log` 65,
**total exported 121 -> 161**. The largest forced block is `INLINE_TAG_*`,
`INLINE_BIAS`, `INLINE_VALUE_*` and `TERM_TAG_*` -- the inline-term encoding
`RECORD-A-0001` froze as one encoding used both on disk and resident, which the
boundary would have run straight through.

Lesson worth keeping for any future package split here: measure both directions.
An out-edge count says whether code can leave; an in-edge count over *private*
symbols says what leaving costs.
