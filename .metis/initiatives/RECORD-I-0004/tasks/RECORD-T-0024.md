---
id: the-read-side-snapshot-kind-gains
level: task
title: "The read side: snapshot_kind gains Triple, the component ids without a decode"
short_code: "RECORD-T-0024"
created_at: 2026-08-24T20:42:54.828135+00:00
updated_at: 2026-08-24T22:10:48.321433+00:00
parent: RECORD-I-0004
blocked_by: [RECORD-T-0023]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: true
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

- [x] **`snapshot_kind` gains `.Triple`.** It answers IRI, blank node or
      literal today without decoding and without exposing the encoding's
      tag layout; a fourth answer is the direct replacement for
      odin-rdf-store's `id_kind(id) == .Triple`, which the consumer tests
      at one site.
- [x] **A named entry point for the component ids**, per
      `RECORD-I-0004` §7 — the shape being `snapshot_triple_parts(snap,
      id) -> ([3]Term_ID, bool)` or whatever `RECORD-T-0021` settled.
      **Published rather than left to consumers**: a consumer parsing
      `snapshot_bytes` by hand is a consumer that has to know the format,
      which is what a published API exists to prevent. No allocation, no
      decode, no recursion.
- [x] **`snapshot_term` decodes both new kinds**, honouring whatever
      ownership rule `RECORD-T-0021` decided — and the rule is stated in
      the doc comment, not only in the ADR. A caller must be able to tell
      from the signature what it has to free.
- [x] **`snapshot_resolve` answers for both new kinds.** Resolving a
      triple term means resolving its components first and then the
      encoded bytes; a component this snapshot has never seen is a
      **miss**, and the whole term is a miss — the fast-reject property
      api.md §12.2 relies on, where a bound term the store has never seen
      costs a probe rather than a scan.
- [x] **Base-direction literals resolve, decode and compare** as ordinary
      literals, with `direction` round-tripping through
      `rdf.Literal`.
- [x] **The term index is unaffected, and that is tested.**
      `sort_term_ids`/`multikey_sort` sort *encoded bytes* and treat them
      opaquely, so a new tag should need nothing — but `term_index_find`
      is how every resolve lands, so "should" wants a test with the new
      kinds present in a snapshot's index.
- [x] **Pattern matching over triple-term ids works end to end**: a
      `Pattern` binding a triple term's id in O matches the facts that
      carry it. Layer 1 binds ids and a triple term is an id, so this
      should require nothing — the test exists to prove that claim, which
      `RECORD-I-0004` makes in its non-goals.
- [x] **`sweep_suite` extended to the rdf12 eval suites**, and this is
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
- [x] **Whatever the sweep refuses is reported, not skipped.** The rdf12
      suites also carry base-direction literals and possibly term shapes
      this initiative did not set out to support; each is either handled
      or named with a reason, because a silently shorter sweep is the
      failure mode this repository's proof discipline exists to prevent.
- [x] `make test` and `make check` green.

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

### 2026-08-25 — the read side, and the W3C verdict

All 10 criteria met. `make test` and `make check` green.

**The cheap path and the complete path are separate procedures, as the
task's technical approach asked.** `snapshot_triple_parts(snap, id)` is a
tag check and three reads out of the arena — no allocation, no decode, no
recursion — converting each on-disk component id to resident with
`resident_id`. `snapshot_term` is the answer boundary and decodes the
whole tree. Nothing collapses them into one convenience.

That is the entry point odin-rdf-sparql binds `Triple_Reader` to, and it
closes `SPARQL-T-0019`: against odin-rdf-store the same question cost a
full materialization plus three dictionary lookups; here the components
are simply in the encoding.

**`snapshot_kind` gained `.Triple` and an exhaustive switch** — every tag
named, a panic on one this store does not define, replacing the
fall-through to `.Literal` that would have answered `.Literal` for a
triple term silently.

**`snapshot_term_destroy` is the paired verb** [[RECORD-A-0008]]
promised, and it takes the **id** as well as the term. That is the design
point: the term alone cannot distinguish a split IRI's joined string from
one borrowed out of the arena, and inferring it from a pointer's address
would be a worse kind of clever. It is total over everything
`snapshot_term` returns, a no-op for the borrowing kinds, and safe on a
nil term — so a caller pairs it with *every* call rather than with some.
It also closes the older gap where a split IRI has allocated since
`RECORD-T-0005` with no verb to free it.

`resolve_snap_term` clones deliberately: an inlined literal materializes
with a *static* datatype IRI that must not be freed, and an
arena-borrowed term must not be freed either, so both are copied rather
than have the decoded tree hold a mixture no single verb could free. A
component that is already a triple term passes straight through.

### The sweep, and the two things it took to make it mean something

`sweep_suite` extended to `rdf12-turtle-eval` and `rdf12-trig-eval`, with
the trailing-`eval/` bases taken from odin-rdf-parser's own harness
rather than by analogy. **29 and 25 eval pairs** — exactly the entry
counts that harness pins, which is the cross-check the task asked for.

Two gaps had to be closed before those numbers meant anything:

- **`has_blank` did not recurse into a triple term.** A document whose
  only blank nodes are inside one would have been taken for ground and
  compared label for label against a result that names them differently.
  Same class of gap as `ingest`'s `clone_term` in `RECORD-T-0023`, and
  the second time this initiative has found a helper that stops at the
  triple term's edge.
- **The sweep only *applied* ground documents.** Most rdf12 eval
  documents carry a blank-node reifier, so gating apply on groundness
  would have swept straight past the capability: the suites would have
  been green with **zero** triple terms ever reaching `apply`. Every
  document now commits, ground or not; groundness still gates only the
  set comparison, which is the thing that actually needs labels to match.

The sweep now counts and reports what it exercised, and asserts it:
**29 of 29 and 25 of 25 documents carry a triple term, and all 54 apply.**

### Base direction has no eval directory, and the report says so

The rdf12 eval suites carry **zero** base-direction literals — which is
`RECORD-I-0004`'s own claim ("a latent limit removed rather than an
evaluation directory unblocked") turning up as a measured zero rather
than an assumption. The eight vendored documents that do carry one are
all in *syntax* suites, parse-only upstream:
`rdf12-{turtle,trig,ntriples,nquads}-syntax`.

`test_ingest_w3c_rdf12_base_direction` routes all eight through ingest,
apply and resolve — so the second term kind is exercised against W3C
documents rather than only against this repository's own fixtures, and
the zero in the eval sweep's log line is reported rather than quietly
skipped.

### Untouched, and tested to be

The term index sorts encoded bytes and treats them opaquely: every term
of a snapshot holding both new kinds is found by its own encoding
through `term_index_find`. Pattern matching over a triple term's id
works end to end — `RECORD-I-0004`'s non-goal claim that "a triple term
is an id" and layer 1 needs nothing, now proved rather than asserted.
Layer 2 did not grow: `Count`, `CountDistinct`, `History` and the
`VarIter` leapfrog view remain unbuilt.