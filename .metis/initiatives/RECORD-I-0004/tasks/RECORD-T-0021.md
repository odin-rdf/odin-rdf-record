---
id: the-design-gate-the-decode-seam
level: task
title: "The design gate: the decode seam, ownership, positions, and whether the format version moves"
short_code: "RECORD-T-0021"
created_at: 2026-08-24T20:42:50.593680+00:00
updated_at: 2026-08-24T20:42:50.593680+00:00
parent: RECORD-I-0004
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0004
---
# The design gate: the decode seam, ownership, positions, and whether the format version moves

## Parent Initiative

[[RECORD-I-0004]]

## Objective

Settle the four open points of `RECORD-I-0004`'s Detailed Design before
any byte is written, and write the ADRs the answers deserve. This is a
risk-first task: the encoding itself is nearly mechanical by analogy with
tags `0x05` and `0x06`, and everything genuinely uncertain about this
initiative is in these four questions.

The framing that governs all of them: **this store is filling a
reservation its own architecture document made, not extending a frozen
format.** `0x07` is reserved in `record/term.odin`, in `log.md` §5.2 and
in `architecture.md` §11.3, which specifies the layout outright and says
the only decision needed at the time was whether to reserve the byte.

## Acceptance Criteria

- [ ] **The decode seam decided** (`RECORD-I-0004` §5). `term_decode`'s
      one callback resolves a `u64` to an *IRI string* — enough for a
      datatype and a namespace, not for a triple term whose components are
      arbitrary terms and may themselves be triple terms. Two shapes to
      weigh, with the decision recorded: a second callback resolving an id
      to a full `rdf.Term` (symmetric with `Resolve_Datatype` on the
      encode side; keeps `term_decode` pure and seam-bound), or a
      snapshot-level decoder above `term_decode` that walks the recursion
      itself (keeps the pure layer's signature; puts the recursion where
      the dictionary already is).
- [ ] **The ownership rule decided and written down.** `snapshot_term`
      **borrows** today — the arena, or a caller-provided buffer bounded
      by `INLINE_LEXICAL_MAX`. A decoded triple term must allocate an
      `^rdf.Triple` per level. The rule must not make `snapshot_term`
      *sometimes-owning by surprise*; whatever is chosen, a caller must be
      able to tell from the signature what it has to free. This is the
      sharper half of §5 and the one most likely to be regretted.
- [ ] **Positions decided** (`RECORD-I-0004` §4): whether a triple term
      may occupy S, P and G or only O. The initiative leans **permit**,
      on the ground that restricting would have this store assert a
      position on a specification §11.3 itself called still-moving — and
      the fact table holds a `Term_ID` in every position regardless, so
      permitting costs nothing structurally. If the decision is to
      restrict, it must be a **write-path refusal only**: a *pattern*
      naming a triple term in the subject position must still evaluate to
      no matches rather than fail, or the consumer's query engine
      inherits a hard error where an empty answer is correct.
- [ ] **The format version decided** (`RECORD-I-0004` §6), with an ADR,
      because this is the first time this format has moved at all.
      Against a bump: `FORMAT_VERSION` gates the whole log
      (`encode.odin:243`), `log.md` §11 says "a format version bump means
      a new log", and there is no migration story by design. For a bump: a
      v1-stamped log containing `0x07` would halt an older reader on an
      unknown tag, which is a log that lies about what it is; honesty is
      cheap with no deployments; and the sibling set the precedent
      (odin-rdf-store's format v2 does not read v1 and says so). The
      initiative leans **bump**.
- [ ] **The base-direction tag decided** (`RECORD-I-0004` §8): a new tag
      (`0x08`, `tag | langlen:u8 | dir:u8 | lang | lexical`) or a sentinel
      inside `0x04`. The lean is a **new tag** — `0x04`'s bytes stay
      byte-identical for every term already written, injectivity stays
      obvious, and the decoder stays flat.
- [ ] **ADRs written** for whichever of these carry a decision worth
      citing later. The format version certainly; positions and the
      decode/ownership pair probably together, as "how a recursive term is
      decoded and who owns it".
- [ ] **Component ids' scheme decided** — *added 2026-08-24, not in this
      task as filed*. A triple term's component may be an **inlined
      literal** (`<<( :a :b 1 )>>` is ordinary), and inlined ids are the
      one place the on-disk and resident schemes differ: flag at bit 63
      vs. 31, tag at 56 vs. 28, bias 2^55 vs. 2^27 (`record/encode.odin:67`,
      `record/resident.odin:37`). The existing reference never exercises
      this, because a datatype is always an IRI, always a dictionary id,
      and dictionary ids are numerically identical in both schemes.
- [ ] **`snapshot_kind`'s fall-through addressed** — *added 2026-08-24,
      not in this task as filed*. `record/read.odin:259` returns
      `.Literal` for any tag it does not recognise, so tag `0x07` would
      report `.Literal` silently, and `snapshot_kind` is precisely the
      procedure that keeps the tag layout private from consumers — a
      wrong answer there is one no consumer can check.
- [ ] **The injectivity argument re-checked**, not assumed.
      `architecture.md` §3.2's argument is what makes term identity sound;
      a new tag with a fixed-length payload should extend it trivially,
      but "should" is what this task exists to convert into "does".

## Implementation Notes

### Technical Approach

**Read the consumer's need before choosing the decode seam.** The
consumer (odin-rdf-sparql, `SPARQL-I-0003`) binds a
`Triple_Reader :: proc(data, id) -> (parts: [3]Term_ID, ok: bool)` — it
wants the **component ids**, not a decoded `rdf.Triple`, for most of its
work. It only materializes a term at the answer boundary. So a design
that makes full decoding elegant but component access awkward would
optimize the rarer path; see `RECORD-I-0004` §7.

**The `0x05`/`0x06` precedent is stronger than it first looks**: both
already carry a `u64` reference resolved through a callback on decode, so
"an encoding that references other terms" is not new here — only the
recursion is.

### Dependencies

None. First task of the initiative, and the gate the other four wait on.

### Risk Considerations

**This task's output is decisions, and a wrong one is expensive later**
because it lands in a format. The bias should be toward the choice that is
cheaper to relax: a refusal can be relaxed, a permission cannot be
withdrawn; a borrowed term can become owned with a new procedure, an
owning one cannot quietly become borrowed.

**Resist scope.** `architecture.md` §11.3 deferred triple terms partly
because assert-versus-mention semantics were moving. They still are, and
they are explicitly not this initiative's business — the consumer needs a
triple term to be a *term*: storable, resolvable, identical to itself and
takeable apart. Any design discussion that starts deciding what asserting
one *means* has left the scope.

## Status Updates

### 2026-08-24 — the gate is closed; seven decisions, two ADRs

Walked the four open points of `RECORD-I-0004`'s Detailed Design against
the code rather than the documents, which turned up **three more
questions than the task was filed with**. All seven settled with the
owner, all on the recommended option. Recorded in
[[RECORD-A-0007]] (the format version) and [[RECORD-A-0008]] (the
recursive term: decode, ownership, positions, id form, kind).

**1. The decode seam — a second callback in `term_decode`.** An optional
`Resolve_Term` beside `Resolve_Iri`, defaulting to `nil`, where `nil`
means a triple term is not-ok — byte-for-byte today's behaviour, so no
existing call site changes. **The deciding fact was not in the
initiative: there are two dictionary-holding consumers, not one.**
`tool/main.odin:279` replays its own dictionary and has its own
`resolve_term`. A snapshot-level decoder would not remove the recursion,
it would duplicate it, against the claim `record/term.odin:4` opens with.

**2. Ownership — a decoded triple term is wholly owned**, components
cloned, so the parser's `rdf.destroy_triple` is correct. The hazard that
decided it: `rdf.destroy_triple` **deep-frees every component string**
(`../odin-rdf-parser/rdf/clone.odin:97`), so a borrowing design makes the
most natural free call corrupt the dictionary arena, silently. Note the
premise "`snapshot_term` borrows" was already half false — a split IRI
allocates (`record/read.odin:312`) with no paired free — so
**`snapshot_term_destroy`** is added, total over what `snapshot_term`
returns, closing that older gap in passing.

**3. The format bumps to v2.** `FORMAT_VERSION` becomes 2; no migration,
no conversion, corpora regenerated. The strict-inequality header check
(`record/encode.odin:243`) stays strict, so a v2 binary refuses a v1 log
even though every byte in it is valid v2 — that is `log.md` §11 written
down, not an oversight preserved.

**4. Positions — permitted everywhere.** The fact table holds a
`Term_ID` in every position regardless, so restricting is pure added code
that only fires on input the corpus does not produce. It also disposes of
this task's own caveat for free: a `Pattern` naming a triple term in S
evaluates to no matches, which is correct, rather than to an error.

**5. Base direction — new tag `0x08`**,
`tag | langlen:u8 | dir:u8 | lang | lexical`, with `0x04`'s lowercase
fold applied to the language half.

**6. A direction with an empty language stays `.Unsupported_Term`** —
*new question*. RDF 1.2 has no such term; giving it bytes would be this
store inventing a term shape, and would put two encodings under one
meaning, which is §3.2's injectivity gone.

**7. Component ids encode in on-disk form**, widened through
`res_inline_disk` — *new question*, and the sharpest of the three added.
Less a choice than a derived requirement: the arena is a verbatim copy of
the log's term definitions (`record/resident.odin:334`) and
`snapshot_resolve` probes by byte-exact match, so the encoder must emit
what the log carries. It is recorded because both id schemes exist in
this package and the single existing precedent never distinguishes them.
`intern_datatype` (`record/intern.odin:272`) and `resolve_snap_datatype`
(`record/read.odin:396`) both widen a *resident* id with a bare
`u64(rid)`; the triple-term path needs siblings that do not. Get it
wrong and terms silently fail to resolve on one side while tripping
`resident_id`'s assert on the other — and the silent direction is the one
a test would not catch.

**8. `snapshot_kind` becomes exhaustive** with a panic on an unknown tag
— *new question*. Its fall-through answers `.Literal`, which is right for
`0x08` and silently wrong for `0x07`.

### Finding: `RECORD-T-0025`'s Python-verifier criterion is falsified

`RECORD-T-0025` states that `tests/verify/rdflog_verify.py` needs no
change. **The reason survives and the conclusion does not.** The reason:
it reads a term definition as `id u64, len u32, payload` and never
inspects the payload's tag, so both new **encodings** are invisible to
it — checked, still true. But it pins `VERSION = 1`
(`tests/verify/rdflog_verify.py:40`) and refuses a mismatch at `:110`, so
the **version** is not invisible to it. The change is one constant and
the module docstring.

This matters beyond the line count, because that criterion carries a
signal: "if the implementation ends up needing a Python-side change, stop
and ask why — it would mean the encoding is doing something §5.2 does not
describe." The signal is intact, since this change is for the header's
sake rather than the encoding's. `RECORD-T-0025`'s criterion should be
amended to say so rather than discovered to be wrong mid-task.

### What the downstream tasks inherit

- `RECORD-T-0022`: both tag layouts are fixed above; the encoder resolves
  components through a disk-form sibling of `Resolve_Datatype`;
  `term_decode` grows the `nil`-defaulted `Resolve_Term`;
  `FORMAT_VERSION` moves to 2 in the same task as the header check and
  the Python constant.
- `RECORD-T-0023`: no position refusal to write. The ordering assert on
  the replay path is what makes unbounded recursion impossible, per
  [[RECORD-A-0008]]'s Negative consequences.
- `RECORD-T-0024`: `snapshot_kind` gets explicit arms plus a panic, not
  just a fourth answer; `snapshot_term_destroy` is part of this task's
  surface, and its doc comment is where the ownership rule has to be
  unambiguous.
- `RECORD-T-0025`: regenerate both corpora at v2 and re-run the §9
  measurement rather than citing `RECORD-T-0006`'s figures; amend the
  Python-verifier criterion as above.
