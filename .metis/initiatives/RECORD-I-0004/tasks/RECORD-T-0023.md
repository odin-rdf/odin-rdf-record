---
id: the-intern-recurses-and-apply
level: task
title: "The intern recurses and apply stops refusing: transitive ordering and the self-check"
short_code: "RECORD-T-0023"
created_at: 2026-08-24T20:42:53.419799+00:00
updated_at: 2026-08-24T22:04:41.065909+00:00
parent: RECORD-I-0004
blocked_by: [RECORD-T-0022]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: true
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

- [x] **`intern_term` recurses.** For a triple term it interns the three
      components first — each of which may itself recurse — then encodes
      their ids. The `pending` map keyed on definition bytes works
      unchanged: a triple term's bytes are as canonical as any other's
      once its components have ids.
- [x] **The ordering constraint holds transitively, and is checked.**
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
- [x] **`apply` accepts a changeset carrying either new term kind**, with
      `Apply_Error.Unsupported_Term` no longer raised for them. Every
      other refusal in that enum is unchanged.
- [x] **`test_ingest_triple_term_refused_at_apply` is inverted, not
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
- [x] **`record/ingest` carries them through.** The consumer loads through
      `ingest.turtle`/`trig`/`ntriples`/`nquads`; a document containing
      `<<( :a :b :c )>>` must become ops that `apply` accepts.
      odin-rdf-parser already parses them and expands reifying triples to
      `_:b rdf:reifies <<( s p o )>>`, so the ops arrive with the triple
      term as an **object** — but see `RECORD-T-0021`'s position decision
      for whether other positions are refused.
- [x] **Replay equivalence on both seams.** A log written with the new
      term kinds replays to a resident state identical to the writer's,
      on `mem_file_ops` and on the POSIX ops — the property
      `RECORD-I-0003` established for `apply` and the one that must not
      weaken.
- [x] **A crash sweep across the new path.** The existing sweep cuts at
      every operation point and asserts no acknowledged epoch is lost and
      nothing partial is ever read as a record; a changeset defining
      recursive terms is a new shape for it, not a new mechanism.
- [x] **Rollback still exact.** `apply` mutates resident state before the
      fsync, in writer-private state no published reader can observe, and
      rolls back exactly on failure (`RECORD-I-0003` decision 1). A
      changeset whose *third* op fails after two triple terms have been
      interned recursively is the case worth constructing.
- [x] `make test` and `make check` green.

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

### 2026-08-25 — the write path accepts both kinds; 9 of 9 criteria

**`intern_term` recurses** through `intern_component`, a
`Resolve_Term_ID` that interns a component and returns `disk_id(rid)` —
on-disk form per [[RECORD-A-0008]] decision 3. `apply` needed no change
at all: its job was always to intern, judge, mutate, append, and
resolving an op's terms now defines several dictionary entries where it
defined one.

**The ordering rule is enforced on both paths, and it is one
comparison.** `term_refs` (new, in the codec) reports the dictionary ids
an encoding names — a datatype, a namespace, or a triple term's
components, with inlined components excluded because they have no
definition to be ordered against. `term_order_ok` is the rule: every
reference strictly lower than the id being defined. The write path
asserts it; **the replay path refuses it** with a new
`Load_Error.Term_Order`, because a malformed log is data and this is
code. Two fault-corpus crafts prove it fires: a forward reference and a
self-reference, the degenerate cycle.

That refusal is what bounds the decoder's recursion on a *hostile* log,
which the task flagged as a risk to close rather than assume. A cycle
needs a forward reference; there are none past `load_term`.

### Three things the task as filed did not have

- **`record/ingest` had a real bug waiting, not just a pass-through.**
  `clone_term`'s `^rdf.Triple` branch did a plain `rdf.clone_term` with
  **no blank prefix applied** — and said so in a comment, on the ground
  that `apply` refused triple terms anyway. The moment `apply` accepts
  them that is a scoping hole: RDF 1.2's reifying syntax puts blank
  nodes *inside* triple terms, and the very fixture the inverted test
  loads is `_:b :p :o . <<_:b :p :o>> :q :z .` — `_:b` is the triple
  term's own subject. Two documents loaded under different
  `blank_prefix` values would have collided. The prefix now recurses,
  and the inverted test asserts the scope survives into the component.
- **`snapshot_resolve` had to learn components in this task, not the
  next.** This task's own criterion says the inverted test proves the
  term is "resolvable afterwards", and resolution builds the encoding
  and probes the arena byte for byte — so it needs the same on-disk
  component resolver the intern uses. `resolve_snap_component` is the
  read side's, and it is what makes the bytes built at probe time
  byte-identical to the arena's. `RECORD-T-0024` keeps the rest of the
  read surface.
- **The intern's refusal contract had to be made transactional.** It
  promised "an unsupported term leaves the table as it found it", and a
  recursion breaks that: a triple term whose third component refuses had
  already defined the first two. `intern_rollback` undoes to a mark —
  pending keys first, because they are views into the bytes being freed
  — so the promise survives rather than being weakened in the doc. The
  intern also never reports `.Unknown_Component`: it defines what it
  lacks, so a component only fails because the component itself is
  unsupported, and `component_err` carries that cause back through
  `Resolve_Term_ID`'s `(id, ok)` shape.

Also moved: `disk_id`, from file-private in `apply.odin` to
package-private beside `resident_id` in `resident.odin`. It has two
callers now — the write path and the intern — and `RECORD-T-0020`'s
commit already named the pair together.

### The tests, and where each criterion is proved

- **Replay equivalence on both seams**: the equivalence vocabulary gained
  a dir-lang literal, a triple term, a triple term **nested** inside
  another, and a structurally equal twin of the first — so 60 random
  changesets over both seams now drive recursive definitions through
  apply, replay and `same_projection`.
- **Crash sweep**: changeset 3 of `sweep_apply` carries a triple term, so
  every cut point runs against a changeset defining terms recursively.
- **Term identity, and that a triple term is a term and not a quad**:
  `test_apply_triple_terms` — two independently built equal triple terms
  resolve to one id; each component is numbered below the term naming
  it; the same triple term in two different quads is two facts and no
  `.Already_Live`; the same quad twice still refuses at op 1.
- **Rollback exact under recursion**: the same test's changeset whose
  third op refuses after two triple terms have interned — dictionary
  size, fact count and epoch count all unchanged.
- **`test_ingest_triple_term_refused_at_apply` inverted, not deleted**,
  and renamed `test_ingest_triple_term_commits`. Same document, same
  three ops, same op carrying the triple term; now one epoch, three
  facts, the term resolvable, a pattern binding its id matching, and the
  blank node inside it carrying the document's scope.

`make test` and `make check` green; 76 tests in `record`.