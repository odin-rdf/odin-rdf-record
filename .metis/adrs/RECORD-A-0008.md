---
id: 001-how-a-recursive-term-is-decoded
level: adr
title: "How a recursive term is decoded, and who owns it"
number: 1
short_code: "RECORD-A-0008"
created_at: 2026-08-24T21:19:38.041293+00:00
updated_at: 2026-08-24T21:22:28.778740+00:00
decision_date: 
decision_maker: 
parent: 
archived: false

tags:
  - "#adr"
  - "#phase/decided"


exit_criteria_met: false
initiative_id: NULL
---

# ADR-1: How a recursive term is decoded, and who owns it

**Status: accepted 2026-08-24** (`RECORD-I-0004`, `RECORD-T-0021`). A triple
term is the first term in this store whose encoding references other *terms*
rather than other IRIs, and the first whose decoded form cannot borrow. Five
decisions, taken together because each one's answer constrains the next.

## Context

Before `RECORD-I-0004` every term this store held decoded into something that
borrowed the bytes it came from, with one exception: a split IRI (`0x06`) joins
its namespace and local name in one allocation (`record/read.odin:312`). Two
existing tags carry a reference — a typed literal's datatype (`0x05`) and a
split IRI's namespace (`0x06`) — and both resolve through one callback,
`Resolve_Iri`, which answers with an **IRI string** (`record/term.odin:44`).

A triple term breaks three assumptions at once:

1. Its components are **arbitrary terms**, not IRIs, and may themselves be
   triple terms. `Resolve_Iri` cannot answer for them.
2. Its decoded form is a **tree**. `^rdf.Triple` is a pointer; something must
   allocate the node, and the parser's `rdf.destroy_triple` deep-frees every
   component string it reaches (`../odin-rdf-parser/rdf/clone.odin:97`).
3. Its components may be **inlined literals** — `<<( :a :b 1 )>>` is ordinary —
   and inlined ids are the one place the on-disk and resident id schemes
   differ: flag at bit 63 vs. 31, tag at 56 vs. 28, bias 2⁵⁵ vs. 2²⁷
   (`record/encode.odin:67`, `record/resident.odin:37`). The existing reference
   never exercised this, because a datatype is always an IRI, always a
   dictionary id, and dictionary ids are numerically identical in both schemes.

The consumer's shape matters to all three. odin-rdf-sparql binds
`Triple_Reader :: proc(data, id) -> (parts: [3]Term_ID, ok: bool)` — it wants
the **component ids** for its hot path and materializes a term only at the
answer boundary (`RECORD-I-0004` §7). A design that makes full decoding elegant
and component access awkward would optimize the rarer path.

## Decision

**1. The recursion lives in `term_decode`, behind a second callback.**
`term_decode` gains an optional `Resolve_Term` parameter alongside
`Resolve_Iri`, defaulting to `nil`. `nil` means a triple term is not-ok —
byte-for-byte today's behaviour — so no existing call site changes, and a
consumer that holds a dictionary opts in with one procedure.

**2. A decoded triple term is wholly owned by its allocator.** Every component
is cloned from `allocator`; the tree contains no borrowed view.
**`rdf.destroy_term`** is therefore the correct and obvious free — note the
verb, corrected 2026-08-24 while implementing `RECORD-T-0022`: for a
`^rdf.Triple` it deep frees every component *and then the node*
(`../odin-rdf-parser/rdf/clone.odin:89`), where `rdf.destroy_triple` takes a
`Triple` by value and leaves the node behind. The hazard this decision is
about is unchanged — both reach every component string — but the verb a
consumer should be told to call is `destroy_term`. To keep the boundary legible,
`snapshot_term` gains a paired verb — **`snapshot_term_destroy`**, total over
everything `snapshot_term` returns, a no-op for the borrowing kinds and a deep
free for a triple term.

**3. Component ids encode in on-disk form.** The encoder widens through
`res_inline_disk` for an inlined component. `intern_datatype`
(`record/intern.odin:272`) and `resolve_snap_datatype` (`record/read.odin:396`)
both widen a *resident* id with a bare `u64(rid)` today; the triple-term path
gets siblings that do not.

**4. A triple term may occupy any position** — S, P, O and G. No write-path
refusal, no pattern-path special case.

**5. `snapshot_kind`'s tag switch becomes exhaustive**, with an explicit arm per
tag and a panic on an unrecognised one, replacing today's fall-through to
`.Literal` (`record/read.odin:259`). `.Triple` joins `Term_Kind`.

## Alternatives Analysis

| Option | Pros | Cons | Risk Level | Implementation Cost |
|--------|------|------|------------|-------------------|
| **Second callback** (chosen, 1) | One decoder in the system; symmetric with the encode side; recursion depth and strictness live in one place; `nil` default means no call-site churn | A wider signature for a callback most tags never use | Low | One parameter, one proc per consumer |
| Snapshot-level decoder above `term_decode` | `term_decode`'s signature untouched; recursion sits where the dictionary is | **There are two dictionary-holding consumers, not one**: `tool/main.odin:279` replays its own dictionary and has its own `resolve_term`. It would need a duplicate recursion, against the claim `record/term.odin:4` opens with | Medium | Two implementations to keep agreeing |
| **Wholly owned** (chosen, 2) | `rdf.destroy_triple` is correct; one rule, one sentence; the hot path never decodes so the copy is at the rare boundary | Abandons zero-copy for this one term kind | Low | Clone per component |
| Borrow components, own only the nodes | Preserves zero-copy discipline; faster | A consumer reflexively calling `rdf.destroy_triple` frees **arena memory** — silent, catastrophic, and the most natural thing to write | High | Needs a record-specific free verb regardless |
| Allocator-owned, "free the allocator" | Idiomatic Odin; dodges ownership entirely | A caller using `context.allocator` has no way to free at all | Medium | None |
| **Permit all positions** (chosen, 4) | The fact table holds a `Term_ID` in every position regardless | Permits what RDF 1.2 currently does not produce | Low | None |
| Refuse outside O on the write path | States RDF 1.2's constraint; a refusal relaxes cheaply where a permission cannot be withdrawn | Pure added code that only ever fires on input the corpus does not produce; asserts a position on a specification §11.3 itself called still-moving | Low | A refusal path plus care that patterns still return empty |

## Rationale

**On the seam (1).** The deciding fact is not in `RECORD-I-0004`: the CLI is a
second consumer that already holds a replayed dictionary and already resolves
ids to terms. Putting the recursion at snapshot level does not remove it, it
duplicates it — and the duplicate would be the one written from memory rather
than from the format. The `nil` default is what makes this cheap: the
capability is opt-in, and a caller that has no dictionary keeps getting the
refusal it gets today.

**On ownership (2).** The premise "`snapshot_term` borrows" is *already* half
false — a split IRI allocates, and there has never been a paired destroy verb
to say so. This initiative does not create the mixed-ownership problem; it makes
it load-bearing, and the cheapest honest fix closes both at once. The choice
between owning and borrowing is then decided by the failure modes rather than
by cost: borrowing is faster, and its failure is a consumer calling the
parser's own free procedure and corrupting the dictionary arena with no
diagnostic. Owning is slower exactly where speed does not matter, because
`snapshot_triple_parts` — not `snapshot_term` — is what a query engine calls
per candidate.

**On the id form (3).** This is less a choice than a derived requirement, which
is why it is recorded rather than argued: the arena is a verbatim copy of the
log's term definitions (`record/resident.odin:334`) and `snapshot_resolve`
probes by byte-exact match, so the encoder must emit whatever the log carries.
It is written down because the two id schemes both exist in this package and
the single existing precedent never distinguishes them — a path that widens the
resident id instead would make terms silently fail to resolve on one side while
tripping `resident_id`'s assert on the other. Loud in one direction, silent in
the other, and the silent direction is the one a test would not catch.

**On positions (4).** Restricting would cost code to assert a constraint on a
specification this initiative's non-goals explicitly decline to have opinions
about. It also disposes of `RECORD-T-0021`'s own caveat for free: a `Pattern`
naming a triple term in the subject position evaluates to no matches, which is
the correct answer, rather than to an error a query engine would have to
special-case.

**On `snapshot_kind` (5).** The existing fall-through answers `.Literal` for any
tag it does not recognise. That is correct for `0x08` and **wrong for `0x07`**,
and wrong silently. Since the whole point of `snapshot_kind` is to keep the tag
layout private from consumers, a wrong answer there is a wrong answer no
consumer can check. Making the switch exhaustive costs nothing and disarms the
same trap for whatever tag is reserved next.

## Consequences

### Positive
- One term decoder in the system, still — the claim `record/term.odin:4` makes
  survives a recursive term.
- Taking a triple term apart costs a tag check and three id reads out of the
  arena, no allocation and no decode. That is cheaper than odin-rdf-store's
  answer to the same question, which materialized the term and re-resolved each
  component — odin-rdf-sparql's `SPARQL-T-0019`. A port that gains a capability
  usually pays for it; here it does not.
- `snapshot_term` acquires the destroy verb it has been missing since split
  IRIs landed.

### Negative
- `term_decode` grows a parameter, and its contract now has a mode (`nil`
  resolver) in which a legal stored term is refused.
- A decoded triple term allocates per component, per level. Bounded by the
  dictionary — a component's id is always lower than the id of the term
  referencing it, so a cycle is impossible in a well-formed log — but that
  bound is a property of the log, which is why `RECORD-T-0023` asserts the
  ordering on the replay path rather than trusting it.
- Two ownership rules now exist under one procedure. Mitigated by the paired
  verb and by stating the rule in `snapshot_term`'s doc comment, which is where
  a consumer will actually read it.

> **Amended 2026-08-24, same day (`RECORD-T-0021`'s injectivity re-check).**
> Decision 3 is load-bearing in a way this ADR understated. Tag `0x07`'s
> injectivity is **conditional on each component id being the canonical id for
> its term**, which is architecture.md §3.4's invariant — "bit 63 = 1 ->
> inlined term, **no dictionary entry exists**". The writer maintains it by
> construction (`intern_term` tries `term_inline` first, and `snapshot_resolve`
> does the same), but **replay does not check it**: `load_term`
> (`record/load.odin:110`) refuses only `.Duplicate_Term`, which is
> byte-identical encodings.
>
> So a chain-perfect, verifier-clean log that defines `0x05 | xsd:integer | "1"`
> as a dictionary term gives one abstract term two ids. **Today that is a
> fact-level defect** — two facts about "the same" literal do not unify — and
> pre-existing. **With triple terms it becomes a dictionary-level one**: the
> ambiguity is baked into another term's bytes, so two distinct `0x07`
> encodings, and therefore two dictionary ids, denote one abstract triple term.
> A silent term *split*, the inverse of the silent merge §3.2's hashed-key path
> takes care to prevent.
>
> Escalated by this initiative, not created by it, and closing it is a change to
> the replay path rather than to either new tag — see `RECORD-T-0021`'s Status
> for the finding as filed.

### Neutral
- `term_inline` and the inline path are untouched: three ids do not fit in 28
  bits, so a triple term is a dictionary term always, and `RECORD-A-0001` stays
  frozen.

## Review Triggers

- A consumer needing the *decoded* triple term on a hot path, which would make
  the copy in decision 2 measurable rather than incidental. The recorded answer
  is a borrowing variant beside the owning one, never a change of what the
  existing procedure returns.
- RDF 1.2 settling the positions question in a direction that makes decision 4
  wrong. Note the asymmetry the decision accepts: a permission cannot be
  withdrawn without breaking logs that used it.
- A third consumer of `term_decode` appearing without a dictionary, which would
  test whether the `nil`-resolver mode reads as a contract or as a trap.