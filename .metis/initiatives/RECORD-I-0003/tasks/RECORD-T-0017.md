---
id: record-ingest-ops-from-turtle
level: task
title: "record/ingest: turtle, ntriples, trig, nquads"
short_code: "RECORD-T-0017"
created_at: 2026-08-20T11:47:12.218212+00:00
updated_at: 2026-08-20T16:40:00.000000+00:00
parent: RECORD-I-0003
blocked_by:
  - "RECORD-T-0015"
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: true
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

- [x] `ingest.turtle(src, graph: rdf.Graph_Label, allocator, kind :=
      .Assert, blank_prefix := "") -> ([]record.Op, Error)` and
      `ingest.ntriples` with the same signature; `ingest.trig(src,
      allocator, kind, blank_prefix)` and `ingest.nquads` taking graphs
      from the document. Named by format alone: the package says
      "ingest", the return type says `[]Op`. `Error` carries the parser's position
      for a syntax error, distinct from an allocation failure.
- [x] `kind = .Retract` produces the retract of every statement — the
      "unload this source" shape; the test asserts
      `apply(.Retract ops)` after `apply(.Assert ops)` leaves the graph
      empty at head and intact at the earlier epoch.
- [x] `blank_prefix` is prepended to every blank-node label in the
      document; empty means labels as written. Two documents with
      `_:b0` under different prefixes are two nodes; under the same
      prefix, one (decision 4's consequence, pinned).
- [x] Terms borrow from `src` (`RDF-A-0001`); the doc comment states
      the caller keeps `src` alive until `apply` returns and `apply`
      copies what it interns. The returned slice is the only allocation
      from `allocator` besides prefixed labels (which are allocated, so
      the `[]Op` owns them; a `ops_destroy` frees both).
- [x] Tests: each procedure over the parser repo's own conformance
      inputs for that format (vendored by reference through the `rdf:`
      collection's test data, or a small copied subset with provenance
      noted); triple terms in input produce `.Unsupported_Term` at
      `apply`, not a silent drop at ingest (the op is emitted; the
      store refuses it — the gap is visible where the stance put it);
      a store filled through `ingest` + `apply` round-trips through
      `dump --format=nquads` and re-ingests to the same projection; the
      Python verifier runs over that log.
- [x] `Makefile` and `ols.json` know the subpackage; `make check` vets
      it; `doc/design/README.md`'s layout gains it; the README gains a
      six-line example (`store_open` → `ingest.turtle` → `apply`),
      compiled in `tests/readme` per the family convention.
- [x] Contract-level doc comments; `make check` and `make test` green.

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

## Implementation record — 2026-08-20

Landed as `record/ingest/ingest.odin` (the subpackage, ~250 lines),
`tests/ingest/ingest_test.odin` (the W3C sweep, scoping, retract, the
triple-term refusal, the dump round trip under the Python verifier),
`tests/readme/readme_test.odin` (the README example, compiled), the
Makefile's `PKGS`, and the README's layout and example. `make check` and
`make test` green across seven packages.

**Two departures from the acceptance criteria, both forced by the parser
repo's contract, recorded here rather than silently:**

1. **The ops own their terms; they do not borrow from `src`.** RDF-A-0001's
   validity contract, as the parser packages state it: prefix expansions,
   resolved IRIs and synthesized blank-node labels are owned by the parser's
   intern table and die with `parser_destroy`; everything else in a yielded
   statement dies when the next statement is drained. A `[]Op` that outlives
   the parser therefore cannot borrow. Every term is cloned into `allocator`
   as it is yielded (allocation failure reported as `.Allocation`, not
   ignored as `rdf.clone` does), and `ops_destroy` frees the lot. `apply`
   copies what it interns, so the ops may be destroyed the moment it
   returns. The README and the doc comments say so.
2. **`turtle` and `trig` take `base := ""`.** A Turtle/TriG document's
   relative IRIs resolve against its location, which only the caller knows;
   the W3C eval inputs need it (their results resolve against
   `https://w3c.github.io/rdf-tests/rdf/rdf11/rdf-turtle/`, not the older
   `http://www.w3.org/2013/TurtleTests/`). N-Triples/N-Quads have no
   relative IRIs and no parameter.

**Other things learned, for the consumers and T-0018:**

3. **`blank_prefix` is part of the label, so it must be label characters**
   if the store is ever dumped and re-ingested: `_:upload-1/b0` is not a
   BLANK_NODE_LABEL in any of the four grammars, and the dump's N-Quads
   then fail to re-parse (found the hard way; the store itself accepts any
   bytes). The doc comment says "letters, digits, `_` and `-`". The parser
   also synthesizes its own labels for a document's nodes (`_:b0` becomes
   `Bb0`); the prefix goes in front of those.
4. **The sweep is by file siblings, not by manifest**: every `X.ttl` with an
   `X.nt` (or `.trig`/`.nq`) is taken as a positive eval pair — both ingest,
   yield the same number of ops, and, when neither uses blank nodes, the
   same statements as a set (applied into two stores, each statement of one
   live in the other); documents without a sibling are syntax tests,
   negative iff the name says `bad`. One stray file (`test-38.ttl`, a librdf
   regression with a surrogate-pair `\u` escape, absent from the manifest)
   is skipped by name. Counts on this run: rdf11-turtle 111 pairs (84
   ground), 111 positive / 94 negative syntax; rdf11-trig 108 pairs (82
   ground), 134 / 115; rdf11-ntriples 43 / 29; rdf11-nquads 55 / 34.
5. **Parser-side observation, for odin-rdf-parser**: on an unterminated long
   string (`turtle-syntax-bad-string-04/05`, the TriG twins) the error's
   `column` comes out negative (−10..−12) while `offset` and `line` are
   right. The sweep asserts the line only.
6. **RDF 1.2 `<< >>` is a reifier**: `<<_:b :p :o>> :q :z .` expands to two
   triples about a fresh reifier node, one carrying the triple term as the
   object of `rdf:reifies`; ingest emits all three ops and `apply` refuses
   the one with the triple term at its index — the gap visible where the
   stance put it.
7. **Round trip**: a store filled through `ingest.trig` + `apply` (every
   shape, a named graph, a blank-node graph), dumped with
   `record dump --format=nquads`, re-ingested through `ingest.nquads` and
   applied with the same actor, yields the same facts and the same
   dictionary term for term; both verifiers say `clean`.
8. `ols.json` needed nothing: collections resolve the subpackage. The
   "layout" the criteria place in `doc/design/README.md` lives in the
   top-level README, which is where it was amended.

