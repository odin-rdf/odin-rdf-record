---
id: ingest-emits-a-document-s-set-of
level: task
title: "ingest emits a document's set of statements, not its list: a repeated statement no longer refuses the load"
short_code: "RECORD-T-0019"
created_at: 2026-08-20T16:50:59.789597+00:00
updated_at: 2026-08-20T16:55:09.968915+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#bug"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: NULL
---

# ingest emits a document's set of statements, not its list: a repeated statement no longer refuses the load

## Objective **[REQUIRED]**

`record/ingest` translates a document statement by statement into `[]Op`,
and `apply` judges every assert against the published head **and the
changeset's own earlier ops** (`log.md` §5.3; `apply.odin`, "What a
changeset may not do"). A document that states one triple twice — legal
in every RDF syntax, since a document denotes a *graph* and a graph is a
*set* — therefore yields two identical asserts, and `apply` refuses the
second as `.Already_Live`. **A valid document cannot be loaded**, and the
error names an op index in a slice the caller never looked inside.

The fix is in the loader, not in `apply`: `ingest.turtle`, `ntriples`,
`trig` and `nquads` emit the document's **set** of statements — a repeated
statement yields one op, at its first position — so the ops of one
document are always a changeset `apply` accepts on that count. `apply`'s
in-changeset check stays exactly as it is: it protects the log (a second
live fact for one quad, `log.md` §5.3), and the document's repetition was
never the log's concern.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Bug - Production issue that needs fixing

### Priority
- [x] P1 - High (important for user experience)

### Impact Assessment **[CONDITIONAL: Bug]**
- **Affected Users**: every consumer loading documents through `ingest` —
  found by the first one, odin-rdf-shacl's port (SHACL-T-0033); next in
  line odin-rdf-sparql's (~170 call sites, 20+ vendored data files), and
  any application ingesting real-world documents.
- **Reproduction Steps**:
  1. Ingest the W3C SHACL suite's `core/complex/shacl-shacl-data-shapes.ttl`
     (vendored in odin-rdf-shacl under `tests/w3c/`), whose lines 75–76 list
     `sh:qualifiedValueShape` and `sh:qualifiedValueShapesDisjoint` twice in
     one `sh:targetSubjectsOf` object list: 417 ops.
  2. `apply(&s, {ops = ops})`.
- **Expected vs Actual**: the document's 415 distinct statements become one
  epoch; instead `Apply_Error{.Already_Live, op = 79}` — op 79 asserts
  `shsh:ShapeShape sh:targetSubjectsOf sh:qualifiedValueShape`, which op 78
  already did — and nothing loads. odin-rdf-shacl's harness worked around
  it with its own dedup before `apply` (`distinct_ops`), which is the loop
  this subpackage exists so that no consumer writes.

## Acceptance Criteria

**[REQUIRED]**

- [ ] All four loaders emit the document's set: a statement the document
      repeats yields exactly one op, at its first position, order
      otherwise preserved — under `.Assert` and `.Retract` alike.
- [ ] Identity is the quad's, including the graph: the same triple in two
      graphs of a TriG/N-Quads document is two ops; a repeated blank node
      is one after prefixing.
- [ ] Hash collisions cost a comparison, not a wrong answer (structural
      equality verifies every hash hit).
- [ ] The package doc and each loader's contract say so; no `apply`
      change.
- [ ] Proven by a test in `tests/ingest`; the W3C sweep still green; the
      shacl harness's own dedup deleted and the 98 `core/` entries still
      green against the fixed loader.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
A per-document `Seen` set in the loaders' shared `push`: `map[u64]int` from
`rdf.hash_quad` of the *owned* (prefixed) quad to the first op index with
that hash, chained through a parallel `[dynamic]int` (`next[i]` = the next
op sharing the hash, `-1` to end) — two allocations per document, not one
per quad — verified by `rdf.equal_quad` before a statement is dropped. The
clone happens before the check, so a dropped duplicate costs one clone and
destroy; duplicates are rare and the alternative (hashing the parser's
borrowed terms) would lean on lifetimes RDF-A-0001 does not promise across
statements.

### Dependencies
None. Consumers pick it up at the next tag.

## Status Updates **[REQUIRED]**

**2026-08-20 — implemented and released as `v0.2.0`.** The `Seen` set in
`ingest.odin`'s shared `push`, exactly as the approach above: two
allocations per document, `rdf.hash_quad` over the owned quad, every hit
verified by `rdf.equal_quad`, the duplicate's clone freed and nothing
appended; all four loaders construct and destroy one. `apply` untouched.
The package doc gained "A document is a set" and `turtle`'s contract the
one-line statement of it.

Proven by `tests/ingest.test_ingest_repeated_statement_is_one_op`: a
Turtle document with a predicate repeated inside an object list and a
repeated blank node yields three ops in first-occurrence order and applies
as one epoch; its `.Retract` form is the same three and unloads cleanly;
the same triple in two N-Quads graphs is two ops; and two ingests of one
document concatenated into one changeset are still `.Already_Live` at the
second's first op — dedup is per document, the changeset rule stays
`apply`'s. The W3C sweep over the parser repo's suites (which compares
each document's op count with its result file's) is unchanged; `make
test` green throughout, scale suite included — the bulk-apply and commit
measurements build ops synthetically and never pass through `ingest`.

Validated downstream the same hour: odin-rdf-shacl deleted its harness's
`distinct_ops` and re-ran the 98 W3C `core/` entries against this
checkout — `core/complex/shacl-shacl`, the entry that found this, loads
and passes through the plain `ingest` → `apply` path (SHACL-T-0033).