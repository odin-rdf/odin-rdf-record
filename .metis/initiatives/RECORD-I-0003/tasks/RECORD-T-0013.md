---
id: the-encoder-and-intern-terms-to
level: task
title: "The encoder and intern: terms to ids, datatype-first, unsupported refused"
short_code: "RECORD-T-0013"
created_at: 2026-08-20T11:47:06.576061+00:00
updated_at: 2026-08-20T13:40:00.000000+00:00
parent: RECORD-I-0003
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: true
initiative_id: RECORD-I-0003
---

# The encoder and intern: terms to ids, datatype-first, unsupported refused

## Parent Initiative

[[RECORD-I-0003]]

## Objective

The store's first term *encoder*: `rdf.Term` → canonical encoding
(`architecture.md` §3.2) → resident id, shared by the read side's probe
and the write side's intern. `probe_encode` (`read.odin`, file-private)
already builds exactly these bytes for `snapshot_resolve`; this task
promotes it to the package's one encoder rather than writing a second
(I-0002 handoff 5), and builds the intern on it: inline first
(`RECORD-A-0001` — a canonical `xsd:integer`, `xsd:boolean`, `xsd:date`
in range is its own id and touches no dictionary), then the published
dictionary, then a *pending* definition the commit will carry. Every
id the intern issues is one the log will define in the same epoch, in
first-appearance order, so replay's §5.2 self-check reproduces them.

## Acceptance Criteria

- [x] One encoder, package-visible, used by both `snapshot_resolve` and
      the intern; `probe_encode` no longer exists as a second copy. It
      emits full IRIs only (never the split form, tag `0x06`), so the
      read-side probe stays correct — the T-0010 caveat, now structural.
- [x] The intern resolves a term to: an inline id; a published
      dictionary id (bounded by the snapshot's `n_terms`); or a new
      pending id = `n_terms + 1 + k` in first-appearance order, recorded
      as a `Term_Def` for the commit. A typed literal's datatype IRI is
      interned *before* the literal (§3.2's ordering rule), and the
      literal's encoding carries the datatype's on-disk `u64` id.
- [x] Language tags are lowercased into the encoding; a tag over 255
      bytes is refused.
- [x] `.Unsupported_Term` for: a triple term (`^rdf.Triple` in any
      position), a literal
      with `direction != .None`, a language tag over 255 bytes. A typed
      error naming the op index, never a guess (decision on the stance:
      the format is not reopened for the siblings).
- [x] The graph component is an `rdf.Graph_Label` (`union { IRI,
      Blank_Node }`), so `log.md` §5.3's rule — a graph label is an IRI
      or a blank node, never a literal and so never inlined — is
      unrepresentable rather than checked: no `.Bad_Graph` exists. A nil
      label is the default graph and encodes as `G = 0`.
- [x] Blank-node labels are interned as given (decision 4) — no
      renaming, no minting.
- [x] The pending set is a transient per-changeset map (bulk loads
      define 10⁵ terms in one epoch; a linear pending list would be
      quadratic), freed with the changeset's scratch.
- [x] Golden tests: the encoder's bytes for each term shape equal the
      vectors the Python verifier already accepts
      (`tests/verify`, RECORD-T-0001's vectors); an interned-then-resolved
      round trip returns the same id for every shape, inline and
      dictionary; re-interning a just-pending term returns the pending
      id, not a second definition.
- [x] Contract-level doc comments; `make check` and `make test` green.

## Implementation Notes

### Technical Approach

The intern is a pure function over (snapshot, pending map, term) with
the commit's `[]Term_Def` as its output; it does not touch the arena —
`apply` (T-0015) appends the definitions to the resident dictionary as
part of the candidate build. Keeping the intern arena-free is what
makes rollback in T-0015 a truncation and nothing more. Encode into a
caller scratch buffer with an allocator fallback, as `probe_encode`
does today.

`res_inline_encode`'s canonical checks (`canonical_integer`,
`canonical_date`) are the inline gate; a non-canonical lexical form
(`"01"^^xsd:integer`) is a dictionary term, distinct from the inline
`"1"^^xsd:integer` — that is RDF term identity, and SPARQL value
equality is the engine's job.

### Dependencies

None within the initiative. First task; T-0014 and T-0015 build on it.

## Implementation record — 2026-08-20

Landed as `record/intern.odin` (+ `intern_test.odin`); `read.odin` lost
`probe_encode`, `res_inline_encode`, `canonical_*` and `days_from_civil`
to it and gained `snapshot_find`. 60 record tests green, `make check`
and `make test` green. What was decided in passing, for T-0014/T-0015:

1. **The encoder's shape mirrors the decoder's.** `term_encode(t,
   resolve: Resolve_Datatype, data, buf, allocator) -> (enc, Term_Error)`
   takes a datatype callback exactly as `term_decode` takes
   `Resolve_Iri` — the probe's callback answers from the published
   dictionary and fails on a miss; the intern's answers by interning.
   That callback is the *one* place the two callers differ, as the
   handoff predicted. `enc` aliases `buf` when it fits, else is
   allocated (compare `raw_data`); the same idiom `probe_encode` had.
2. **The inline gate is a separate procedure, `term_inline(t)`**, not
   folded into the encoder: a caller that wants an id tries it first,
   and the encoder never sees a canonical inlined form. It refuses a
   literal with a language *or a direction* itself, so a malformed
   `"5"^^xsd:integer` with `direction = .LTR` is not inlined and is then
   refused by the encoder — unsupported never slips in through the gate.
3. **One error type for both layers, `Term_Error {None,
   Unsupported_Term, Unknown_Datatype}`.** `Unsupported_Term` is named
   to map one-to-one onto `Apply_Error_Kind.Unsupported_Term`;
   `Unknown_Datatype` is the probe's miss and is *never* returned by
   the intern (its callback cannot fail — an IRI always interns; this is
   asserted). Checks are ordered so an unsupported term is refused
   *before* the datatype callback runs: a refused literal never leaves a
   pending datatype definition behind. Tested.
4. **The intern's API**: `Intern{snap, pending: map[string]u32, defs:
   [dynamic]Term_Def, allocator}`; `intern_init(it, snap)`,
   `intern_term(it, t) -> (u32, Term_Error)`, `intern_graph(it,
   rdf.Graph_Label)` (nil → 0), `intern_defs(it) -> []Term_Def`,
   `intern_destroy`. The snapshot is borrowed — apply keeps the head
   snapshot acquired for the intern's lifetime. Order of lookup: inline
   → published (`snapshot_find`, bounded by `n_terms`) → pending → new.
   Each new definition is one allocation owned by the intern; the map's
   keys are views into those bytes. Pending id = `n_terms + 1 + k`; the
   below-inline-flag assertion is unreachable before `dict_add`'s
   `.Dict_Overflow` (2³¹ terms exceed the 4 GB arena) and the comment
   says so.
5. **`snapshot_find(snap, enc)` is the seam T-0014 swaps.** It is the
   only call to `dict_find` on the resolve path and the intern's only
   read of the published dictionary; replacing its body with the
   binary search over the sorted id index changes neither caller.
6. **The numbering proof is a test through the real pipe**
   (`test_intern_numbering_is_the_logs`): intern against the empty
   world, `writer_commit` the definitions — `commit_encode` refuses any
   id that is not `next_term_id`, so success is the proof — replay into
   a second store, `snapshot_resolve` every term to the id the intern
   issued, and a fresh intern over the replayed store defines nothing.
7. **No document amended.** `architecture.md` §3.2 is implemented as
   written (full IRIs only, lowercased tags, 255-byte limit refused not
   truncated, datatype-first); `log.md` §5.2's "the same ordering
   constraint `intern` already enforces" is now literally true. `api.md`
   §12.7's "then `Dict.byTerm`" is T-0014's amendment. The README's
   "Not yet built: `Apply`" stands until T-0018.

