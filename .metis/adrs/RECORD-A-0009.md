---
id: 001-the-pure-format-layer-moves-to
level: adr
title: "The pure format layer moves to record/log; the File_Ops seam stays"
number: 1
short_code: "RECORD-A-0009"
created_at: 2026-09-01T11:22:07.551257+00:00
updated_at: 2026-09-01T11:28:16.637519+00:00
decision_date: 
decision_maker: Greger Olsson
parent: 
archived: false

tags:
  - "#adr"
  - "#phase/superseded"


exit_criteria_met: false
initiative_id: NULL
---

---

# ADR-9: The pure format layer moves to record/log; the File_Ops seam stays

> **SUPERSEDED the same day by [[RECORD-A-0010]], 2026-09-01.** The
> Context below argues the split is free because the three files have no
> out-edges to the rest of `record`. That measurement was taken in one
> direction only. `@(private)` is package-scoped, and 38 private symbols
> in those files are used by the rest of `record` — so the split would
> force them public and take the total exported from 121 to 161. The
> decision below was not executed and no source file was touched. It
> stands as the record of what was decided and why it was wrong.

## Context

`RECORD-I-0005` set out to make this repository's public interface a statement
rather than a residue. `RECORD-T-0031` marked 74 of 195 declarations
`@(private)`, leaving 121 exported, and `doc/api-surface.txt` states them in
three sections: 65 the store API, 13 exported only because `tool/` reaches the
format directly, and 43 exported only because the `tests/*` suites are separate
packages.

Sections 2 and 3 are the residue that `@(private)` cannot remove, because the
symbols are genuinely reached from outside the package — by this repository's
own CLI and its own proof suite. The question this ADR answers is whether the
format layer should be a subpackage, so that reaching it is an import rather
than an export.

The repository already talks about itself this way: `doc/design/log.md` is the
format, `doc/design/api.md` is the store, and they are separate documents
because they are separate concerns. The package structure has never matched.

### What was measured, not assumed

**The pure format files have no coupling to the rest of the package.** Every
declaration in `encode.odin`, `term.odin` and `crc32c.odin` references only
other declarations in those three files — checked over the full type surface of
all 195 declarations, and the out-edge set is empty. They are already a
subpackage; they are merely not stored as one.

**Odin re-exports cleanly.** `Kind :: log.Kind`, `LIMIT :: log.LIMIT` and
`encode :: log.encode` all compile and run across a package boundary — types,
constants and procedures alike. So a name can live in the subpackage and remain
on `record`'s surface at the cost of one line, and a split need not be a
consumer-visible change.

**The wide split is not viable.** Moving the I/O half as well — `open.odin`,
`replay.odin`, `writer.odin`, `writer_posix.odin`, `writer_mem.odin` — takes 50
names out, but 14 of them are store API and 7 are spelled by consumers today:
`Mem_FS`, `mem_file_ops`, `mem_fs_destroy`, `posix_file_ops`, `Op_Kind`,
`Open_Error`, `INLINE_LEXICAL_MAX`. The first four are the `File_Ops` seam, which
odin-rdf-shacl and odin-rdf-sparql each use about two dozen times to open a
store over the memory backend. **`File_Ops` is store API, not log**: it is the
third parameter of `store_open`. Hiding that behind aliases would leave the
names on `record`'s surface anyway, so the wide split costs the most and gains
the least.

## Decision

**Move `encode.odin`, `term.odin` and `crc32c.odin` into a `record/log`
subpackage. Leave `open.odin`, `replay.odin` and the three writer files in
`record`.**

`Op_Kind` and `INLINE_LEXICAL_MAX` are re-exported from `record` as aliases,
because they are store API that happens to be defined in the format: a
changeset op's kind and the inline-lexical bound are things a consumer states,
not things it decodes.

`record`'s exported surface goes from **121 to 96**: the 65-name store API
unchanged (2 of them now aliases), section 2 from 13 names to 4 (`Consumer`,
`Verify_Result`, `replay`, `verify` — the I/O entry points `tool/` still needs),
and section 3 from 43 to 27, all of them projection builders held by
`tests/scale`.

**No consumer changes.** odin-rdf-shacl and odin-rdf-sparql spell no name that
moves, and the two that would have are aliased. `tool/` and `tests/proof` gain
`import "record:record/log"`.

## Alternatives Analysis

**The wide split** — rejected above on measurement: 7 consumer-spelled names,
including the `File_Ops` seam, for a surface that ends up 85 rather than 96 once
the necessary aliases are counted.

**No split** — leave the layer in `record` and let `doc/api-surface.txt`'s
sections state the residue honestly. This was a real candidate: no consumer
asked for the split, and the family convention is that consumers drive change.
Rejected because the three files are already decoupled, so the change costs
almost nothing, and because "stated honestly in a file" is weaker than "not
exported at all" for exactly the question `RECORD-I-0005` exists to answer.

**Make the format layer `@(private)` and give `tool/` and `tests/proof` a
package-internal test seam** — rejected: it would put the CLI inside the package
or duplicate the encoder, and the proof suite's independence is the point of it.

## Rationale

The split is chosen on three grounds, in order of weight:

1. **It is free.** Zero out-edges means no interface has to be invented, no
   type has to move twice, and no dependency inverts. This is the rare
   restructuring where the measurement says "already true, just not written
   down".
2. **It removes 25 names from the surface without touching a consumer.** That
   is the largest single reduction available after `RECORD-T-0031`, and the only
   one that reaches section 2 at all.
3. **It matches the documents.** `log.md` and `api.md` have described two
   layers since the founding; the package structure will now say the same.

The line is drawn at I/O rather than at "format". `File_Ops` is where a consumer
chooses a backend, so it belongs to the store's API however format-adjacent it
looks; `verify` and `replay` take `File_Ops` and stay with it.

## Consequences

### Positive

- `record` exports 96 names, of which 65 are the interface and 4 are a stated
  exception. The ratio of interface to residue goes from 65/121 to 65/96.
- `tests/proof` reaches the format by import, which is what an independent proof
  of a format ought to do.
- The remaining section 3 is homogeneous — projection builders, one suite's
  need — which makes it a single future question rather than a mixed bag.

### Negative

- Import paths move for `tool/` and `tests/proof`. In-repo only, but real.
- Two aliases in `record` are a small indirection a reader must follow, and a
  place where a future edit could let the alias and the definition drift.
- `record/log` will have its own surface, and nothing yet states it. The
  `make api` check covers `record` only; extending it is work the execution
  initiative owns.

### Neutral

- No format change, no version bump, no log-compatibility question: this moves
  source files, not bytes.
- Consumers pin `v0.6.0` and need not move at all; whether the split warrants a
  release is a separate call.

## Review Triggers

- A consumer needs to decode a term or read a frame directly — then the format
  layer has become interface, and section 2's exception should be revisited.
- `tests/scale`'s measurement stops needing hand-built stores — then section 3
  can go, and the surface is the interface exactly.
- Anything makes `record` import `record/log` cyclically — the out-edge set was
  empty on 2026-09-01 and a future edit could change that; `make api` would not
  catch it.