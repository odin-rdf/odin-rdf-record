---
id: the-intern-recurses-and-apply
level: task
title: "The intern recurses and apply stops refusing: transitive ordering and the self-check"
short_code: "RECORD-T-0023"
created_at: 2026-08-24T20:42:53.419799+00:00
updated_at: 2026-08-24T20:42:53.419799+00:00
parent: RECORD-I-0004
blocked_by: ["RECORD-T-0022"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0004
---
# The intern recurses and apply stops refusing: transitive ordering and the self-check

## Parent Initiative

[[RECORD-I-0004]]

## Objective

Make the write path accept the two new term kinds. `intern_term`
recurses, defining every component before the term that references it;
`apply` stops returning `.Unsupported_Term` for a triple term or a
base-direction literal; and a log written this way replays to the same
resident state it was written from.

## Acceptance Criteria

- [ ] **`intern_term` recurses.** For a triple term it interns the three
      components first — each of which may itself recurse — then encodes
      their ids. The `pending` map keyed on definition bytes works
      unchanged: a triple term's bytes are as canonical as any other's
      once its components have ids.
- [ ] **The ordering constraint holds transitively, and is checked.**
      `log.md` §5.2 already requires that "a typed literal's datatype IRI
      must be defined before the literal that references it, which is the
      same ordering constraint `intern` already enforces". A triple term's
      components extend it. Because ids are assigned in first-appearance
      order, **a component's id is necessarily lower than the id of the
      term referencing it** — which makes the constraint checkable by
      comparison rather than by bookkeeping. Assert it on both the write
      and the replay path: it is one comparison, and a violation means the
      encoder and the replayer disagree about something fundamental. That
      is the same argument §5.2 makes for keeping the redundant `id`
      field.
- [ ] **`apply` accepts a changeset carrying either new term kind**, with
      `Apply_Error.Unsupported_Term` no longer raised for them. Every
      other refusal in that enum is unchanged.
- [ ] **`test_ingest_triple_term_refused_at_apply` is inverted, not
      deleted** (`tests/ingest/ingest_test.odin:394`). It is the most
      precise existing statement of the gap: it loads
      `rdf12-turtle-eval/turtle12-eval-bnode-01.ttl`, asserts `ingest`
      emits **three** ops (RDF 1.2's `<< >>` is a reifier, so the
      statement expands to two triples about a fresh reifier node, one
      carrying the triple term as the object of `rdf:reifies`), finds the
      op whose object is a `^rdf.Triple`, and expects
      `Apply_Error{.Unsupported_Term, at}` with `n_epochs` still 0. It
      becomes the test that the same document **commits**: one epoch,
      three facts, and the triple term resolvable afterwards. **Expect it
      to fail before it is rewritten** — that is not a regression, it is
      this task arriving.
- [ ] **`record/ingest` carries them through.** The consumer loads through
      `ingest.turtle`/`trig`/`ntriples`/`nquads`; a document containing
      `<<( :a :b :c )>>` must become ops that `apply` accepts.
      odin-rdf-parser already parses them and expands reifying triples to
      `_:b rdf:reifies <<( s p o )>>`, so the ops arrive with the triple
      term as an **object** — but see `RECORD-T-0021`'s position decision
      for whether other positions are refused.
- [ ] **Replay equivalence on both seams.** A log written with the new
      term kinds replays to a resident state identical to the writer's,
      on `mem_file_ops` and on the POSIX ops — the property
      `RECORD-I-0003` established for `apply` and the one that must not
      weaken.
- [ ] **A crash sweep across the new path.** The existing sweep cuts at
      every operation point and asserts no acknowledged epoch is lost and
      nothing partial is ever read as a record; a changeset defining
      recursive terms is a new shape for it, not a new mechanism.
- [ ] **Rollback still exact.** `apply` mutates resident state before the
      fsync, in writer-private state no published reader can observe, and
      rolls back exactly on failure (`RECORD-I-0003` decision 1). A
      changeset whose *third* op fails after two triple terms have been
      interned recursively is the case worth constructing.
- [ ] `make test` and `make check` green.

## Implementation Notes

### Technical Approach

**The recursion is in the intern, not in `apply`.** `apply`'s job is
unchanged: judge preconditions against head and the changeset's own
earlier ops, mutate, append, fsync, publish. What changes is that
resolving an op's terms may now define several dictionary entries per
term rather than one.

**Term identity is RDF's, and recursion inherits it.** Two triple terms
whose components are the same terms are the same term and must intern to
the same id. That falls out of the pending map keyed on bytes — provided
the components were interned first, which is the ordering rule. Worth a
direct test, because it is the property that makes a triple term a term
rather than a structure.

**`.Already_Live` interacts here.** Re-asserting a live quad is refused
at the op — a candidate is the delta. A changeset that mentions the same
triple term twice in *different* quads is fine and must stay fine; only
a repeated quad is refused.

### Dependencies

Blocked by RECORD-T-0022 — the encoding must exist before anything can
intern one.

Fixtures need no vendoring: odin-rdf-parser's `rdf12-turtle-eval` (46
documents carrying `<<`) and `rdf12-trig-eval` (38) are on disk at
`../odin-rdf-parser/tests/w3c/`, already reached by this repository's
`W3C` constant. RECORD-T-0024 sweeps them; this task can borrow single
documents from them the way the refusal test already does.

### Risk Considerations

**Depth.** Nothing in this design bounds how deeply a triple term nests,
and a replayer walking a hostile log should not recurse without limit.
The first-appearance-order property gives a natural bound (a component's
id is lower, so a cycle is impossible in a well-formed log), but a
malformed log is exactly what the verifier exists to catch — make the
replay path's ordering assert the thing that makes unbounded recursion
impossible, rather than relying on it being impossible.

**The rollback case is the one most likely to be missed**, because it
needs a deliberately constructed failing changeset and the happy path
will pass without it. `RECORD-I-0003` paid for exact rollback; a
recursive intern is the first thing since that could leave partial
dictionary state behind.

## Status Updates

*To be added during implementation*
