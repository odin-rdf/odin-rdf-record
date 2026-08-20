---
id: record-ingest-ops-from-turtle
level: task
title: "record/ingest: turtle, ntriples, trig, nquads"
short_code: "RECORD-T-0017"
created_at: 2026-08-20T11:47:12.218212+00:00
updated_at: 2026-08-20T11:47:12.218212+00:00
parent: RECORD-I-0003
blocked_by:
  - "RECORD-T-0015"
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0003
---

# record/ingest: turtle, ntriples, trig, nquads

## Parent Initiative

[[RECORD-I-0003]]

## Objective

Decision 7: the pure translation from a parsed document to `[]Op`, as
the opt-in subpackage `record/ingest` — importing `record` and the
parser repo's four format packages, so `record`'s own imports stay
`rdf` alone and a consumer that never ingests documents links no
parser. Four procedures, no new types: the caller sets actor, reason
and mode, may concatenate documents into one epoch, and the store never
decides "one document, one epoch". Named `ingest`, not `load`, because
`load.odin` is replay's `Loader`; this package loads nothing.

## Acceptance Criteria

- [ ] `ingest.turtle(src, graph: rdf.Graph_Label, allocator, kind :=
      .Assert, blank_prefix := "") -> ([]record.Op, Error)` and
      `ingest.ntriples` with the same signature; `ingest.trig(src,
      allocator, kind, blank_prefix)` and `ingest.nquads` taking graphs
      from the document. Named by format alone: the package says
      "ingest", the return type says `[]Op`. `Error` carries the parser's position
      for a syntax error, distinct from an allocation failure.
- [ ] `kind = .Retract` produces the retract of every statement — the
      "unload this source" shape; the test asserts
      `apply(.Retract ops)` after `apply(.Assert ops)` leaves the graph
      empty at head and intact at the earlier epoch.
- [ ] `blank_prefix` is prepended to every blank-node label in the
      document; empty means labels as written. Two documents with
      `_:b0` under different prefixes are two nodes; under the same
      prefix, one (decision 4's consequence, pinned).
- [ ] Terms borrow from `src` (`RDF-A-0001`); the doc comment states
      the caller keeps `src` alive until `apply` returns and `apply`
      copies what it interns. The returned slice is the only allocation
      from `allocator` besides prefixed labels (which are allocated, so
      the `[]Op` owns them; a `ops_destroy` frees both).
- [ ] Tests: each procedure over the parser repo's own conformance
      inputs for that format (vendored by reference through the `rdf:`
      collection's test data, or a small copied subset with provenance
      noted); triple terms in input produce `.Unsupported_Term` at
      `apply`, not a silent drop at ingest (the op is emitted; the
      store refuses it — the gap is visible where the stance put it);
      a store filled through `ingest` + `apply` round-trips through
      `dump --format=nquads` and re-ingests to the same projection; the
      Python verifier runs over that log.
- [ ] `Makefile` and `ols.json` know the subpackage; `make check` vets
      it; `doc/design/README.md`'s layout gains it; the README gains a
      six-line example (`store_open` → `ingest.turtle` → `apply`),
      compiled in `tests/readme` per the family convention.
- [ ] Contract-level doc comments; `make check` and `make test` green.

## Implementation Notes

### Technical Approach

A `parser_init`/`parser_next`/`parser_destroy` loop per format. Because
`Op` embeds `rdf.Quad`, there is no per-field mapping: TriG and N-Quads
yield `Op{kind, q}` from the quad `parser_next` returns; Turtle and
N-Triples yield `Op{kind, rdf.Quad{triple = t, graph = graph}}` with the
caller's graph. Prefixing a blank label is the only per-term work. The
`dump` round trip is likewise direct — `quads.emit(w, op.quad)`. Not added,
per decision 7: a `Changeset` builder, an `apply_turtle` shortcut, a
`tool` subcommand.

### Dependencies

RECORD-T-0015 (the `Op` type and `apply`, which the tests drive
end-to-end). The procedures themselves depend on `Op` alone.
