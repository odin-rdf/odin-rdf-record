---
id: the-encoder-and-intern-terms-to
level: task
title: "The encoder and intern: terms to ids, datatype-first, unsupported refused"
short_code: "RECORD-T-0013"
created_at: 2026-08-20T11:47:06.576061+00:00
updated_at: 2026-08-20T11:47:06.576061+00:00
parent: RECORD-I-0003
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
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

- [ ] One encoder, package-visible, used by both `snapshot_resolve` and
      the intern; `probe_encode` no longer exists as a second copy. It
      emits full IRIs only (never the split form, tag `0x06`), so the
      read-side probe stays correct — the T-0010 caveat, now structural.
- [ ] The intern resolves a term to: an inline id; a published
      dictionary id (bounded by the snapshot's `n_terms`); or a new
      pending id = `n_terms + 1 + k` in first-appearance order, recorded
      as a `Term_Def` for the commit. A typed literal's datatype IRI is
      interned *before* the literal (§3.2's ordering rule), and the
      literal's encoding carries the datatype's on-disk `u64` id.
- [ ] Language tags are lowercased into the encoding; a tag over 255
      bytes is refused.
- [ ] `.Unsupported_Term` for: a triple term (`^rdf.Triple` in any
      position), a literal
      with `direction != .None`, a language tag over 255 bytes. A typed
      error naming the op index, never a guess (decision on the stance:
      the format is not reopened for the siblings).
- [ ] The graph component is an `rdf.Graph_Label` (`union { IRI,
      Blank_Node }`), so `log.md` §5.3's rule — a graph label is an IRI
      or a blank node, never a literal and so never inlined — is
      unrepresentable rather than checked: no `.Bad_Graph` exists. A nil
      label is the default graph and encodes as `G = 0`.
- [ ] Blank-node labels are interned as given (decision 4) — no
      renaming, no minting.
- [ ] The pending set is a transient per-changeset map (bulk loads
      define 10⁵ terms in one epoch; a linear pending list would be
      quadratic), freed with the changeset's scratch.
- [ ] Golden tests: the encoder's bytes for each term shape equal the
      vectors the Python verifier already accepts
      (`tests/verify`, RECORD-T-0001's vectors); an interned-then-resolved
      round trip returns the same id for every shape, inline and
      dictionary; re-interning a just-pending term returns the pending
      id, not a second definition.
- [ ] Contract-level doc comments; `make check` and `make test` green.

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
