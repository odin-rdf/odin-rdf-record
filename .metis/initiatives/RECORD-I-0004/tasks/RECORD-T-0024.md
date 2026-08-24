---
id: the-read-side-snapshot-kind-gains
level: task
title: "The read side: snapshot_kind gains Triple, the component ids without a decode"
short_code: "RECORD-T-0024"
created_at: 2026-08-24T20:42:54.828135+00:00
updated_at: 2026-08-24T20:42:54.828135+00:00
parent: RECORD-I-0004
blocked_by: ["RECORD-T-0023"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0004
---
# The read side: snapshot_kind gains Triple, the component ids without a decode

## Parent Initiative

[[RECORD-I-0004]]

## Objective

Make the new term kinds readable — and make the triple term's *structure*
readable cheaply, which is the part that turns this initiative from
"parity with the store the consumer is leaving" into an improvement on it.

The consumer's binding is
`Triple_Reader :: proc(data, id) -> (parts: [3]Term_ID, ok: bool)`.
Against odin-rdf-store that cost a full term materialization plus three
dictionary lookups — "two round trips through the database for something
the dictionary knows outright", recorded as odin-rdf-sparql's
`SPARQL-T-0019`. Against this encoding it is a tag check and three id
reads out of the arena.

## Acceptance Criteria

- [ ] **`snapshot_kind` gains `.Triple`.** It answers IRI, blank node or
      literal today without decoding and without exposing the encoding's
      tag layout; a fourth answer is the direct replacement for
      odin-rdf-store's `id_kind(id) == .Triple`, which the consumer tests
      at one site.
- [ ] **A named entry point for the component ids**, per
      `RECORD-I-0004` §7 — the shape being `snapshot_triple_parts(snap,
      id) -> ([3]Term_ID, bool)` or whatever `RECORD-T-0021` settled.
      **Published rather than left to consumers**: a consumer parsing
      `snapshot_bytes` by hand is a consumer that has to know the format,
      which is what a published API exists to prevent. No allocation, no
      decode, no recursion.
- [ ] **`snapshot_term` decodes both new kinds**, honouring whatever
      ownership rule `RECORD-T-0021` decided — and the rule is stated in
      the doc comment, not only in the ADR. A caller must be able to tell
      from the signature what it has to free.
- [ ] **`snapshot_resolve` answers for both new kinds.** Resolving a
      triple term means resolving its components first and then the
      encoded bytes; a component this snapshot has never seen is a
      **miss**, and the whole term is a miss — the fast-reject property
      api.md §12.2 relies on, where a bound term the store has never seen
      costs a probe rather than a scan.
- [ ] **Base-direction literals resolve, decode and compare** as ordinary
      literals, with `direction` round-tripping through
      `rdf.Literal`.
- [ ] **The term index is unaffected, and that is tested.**
      `sort_term_ids`/`multikey_sort` sort *encoded bytes* and treat them
      opaquely, so a new tag should need nothing — but `term_index_find`
      is how every resolve lands, so "should" wants a test with the new
      kinds present in a snapshot's index.
- [ ] **Pattern matching over triple-term ids works end to end**: a
      `Pattern` binding a triple term's id in O matches the facts that
      carry it. Layer 1 binds ids and a triple term is an id, so this
      should require nothing — the test exists to prove that claim, which
      `RECORD-I-0004` makes in its non-goals.
- [ ] **`sweep_suite` extended to the rdf12 eval suites**, and this is
      the task's real verdict. `tests/ingest/ingest_test.odin` already
      runs W3C suites end to end — ingest, apply, read back, compare
      against the expected `.nt`/`.nq` — but only over the four rdf11
      suites. Add `rdf12-turtle-eval` and `rdf12-trig-eval`, following
      `test_ingest_w3c_turtle`/`_trig` exactly. The bases carry a
      trailing `eval/` and differ from the rdf11 pattern — take them from
      odin-rdf-parser's own harness
      (`tests/w3c/harness/harness_test.odin:62`, `:72`) rather than by
      analogy:
      `https://w3c.github.io/rdf-tests/rdf/rdf12/rdf-turtle/eval/` and
      `https://w3c.github.io/rdf-tests/rdf/rdf12/rdf-trig/eval/`, the
      latter with `quads = true`. That harness also pins the entry counts
      — 29 and 25 — which are a useful cross-check on the sweep's own
      pinned lower bound. **No vendoring**: both suites are on disk at
      `../odin-rdf-parser/tests/w3c/`, reached by the existing `W3C`
      constant.
- [ ] **Whatever the sweep refuses is reported, not skipped.** The rdf12
      suites also carry base-direction literals and possibly term shapes
      this initiative did not set out to support; each is either handled
      or named with a reason, because a silently shorter sweep is the
      failure mode this repository's proof discipline exists to prevent.
- [ ] `make test` and `make check` green.

## Implementation Notes

### Technical Approach

**The cheap path and the complete path are different procedures, and
that is the design.** `snapshot_triple_parts` gives structure without
materialization; `snapshot_term` gives the `rdf.Term`. A consumer's query
engine uses the first on the hot path and the second at the answer
boundary. Do not collapse them into one convenience that always decodes.

**`snapshot_bytes` returns a view into the arena** — no copy, no
allocation — which is what makes the parts read free. Keep it that way;
if the parts entry point copies, the improvement this initiative is
claiming does not exist.

### Dependencies

Blocked by RECORD-T-0023 — a term has to be storable before it is worth
reading.

### Risk Considerations

**Arena lifetime.** A borrowed view dies with the store, and a decoded
triple term's *components* borrow while the `^rdf.Triple` node is owned —
a mixed-ownership term is exactly the kind of thing a consumer gets
wrong. Whatever `RECORD-T-0021` decided, the doc comment here is where a
consumer will actually read it, so it has to be unambiguous rather than
merely correct.

**Do not grow layer 2.** `Count`, `CountDistinct`, `History` and the
`VarIter` leapfrog view are all specified in api.md §12 and all unbuilt.
None of them is this initiative's business, and a triple term does not
change any of them.

## Status Updates

*To be added during implementation*
