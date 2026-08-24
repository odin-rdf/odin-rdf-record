---
id: 001-the-format-moves-to-version-2-for
level: adr
title: "The format moves to version 2 for RDF 1.2's term kinds"
number: 1
short_code: "RECORD-A-0007"
created_at: 2026-08-24T21:19:36.927564+00:00
updated_at: 2026-08-24T21:22:28.744864+00:00
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

# ADR-1: The format moves to version 2 for RDF 1.2's term kinds

**Status: accepted 2026-08-24** (`RECORD-I-0004`, `RECORD-T-0021`). The first
time this format has moved at all, which is the reason it gets an ADR rather
than a line in a task.

## Context

`RECORD-I-0004` spends the reservation `architecture.md` §11.3 made: two term
kinds RDF 1.2 added and this store has always refused with
`Term_Error.Unsupported_Term`, wanted by odin-rdf-sparql's port
(`SPARQL-I-0003`).

Two new term-definition tags, both in the canonical encoding of
`architecture.md` §3.2:

- **`0x07` — a triple term**, `0x07 | sID | pID | oID`, three `u64`s, 25 bytes.
  The layout §11.3 specified outright. The byte was reserved in three places
  (`record/term.odin:26`, `log.md` §5.2, architecture.md §11.3) against exactly
  this day.
- **`0x08` — a literal with a base direction**,
  `0x08 | langlen:u8 | dir:u8 | lang | lexical`. No reservation existed; the
  tag is chosen here. The language half applies `0x04`'s lowercase fold, or two
  encodings of one term exist and §3.2's injectivity is gone. A direction with
  an empty language is **not** encodable — RDF 1.2 has no such term, and giving
  it bytes would be this store inventing a term shape — so it keeps returning
  `.Unsupported_Term`.

> **Amended 2026-08-24, same day (`RECORD-T-0021`'s injectivity re-check).**
> Tag `0x08` as laid out above is injective **only with three decoder-side
> refusals**, none of which this ADR stated when it was written:
>
> - **`dir` must be validated against `{LTR, RTL}`.** `rdf.Direction` is a u8
>   enum of three values (`../odin-rdf-parser/rdf/terms.odin:26`), so bytes
>   `0x03`..`0xFF` are not directions. A decoder that mapped them to anything
>   would make several byte strings decode to one term.
> - **`dir` must never be `.None` (`0x00`) under `0x08`.** Otherwise `"x"@en`
>   has two encodings — `0x04`, and `0x08` with `dir = 0` — which is exactly
>   the defect §3.2 names for language-tag case: "the dictionary must not
>   admit both".
> - **`langlen` must be non-zero**, the mirror of the Context bullet's refusal
>   above. The parser's own invariant states both halves
>   (`../odin-rdf-parser/rdf/terms.odin:38`): a language is non-empty iff the
>   datatype is `rdf:langString` or `rdf:dirLangString`, and a direction is not
>   `.None` iff `rdf:dirLangString`.
>
> All three are **decoder-side**, not merely encoder-side. §3.2's injectivity
> is a property of the format rather than of this implementation's encoder, and
> the decoder is what a third party's log actually meets. `RECORD-T-0022`'s
> criteria carry them.

Neither tag changes a single existing byte, and no v1 log contains either. The
format is therefore compatible in one direction only: a v2 reader could read
every v1 log; a v1 reader meeting `0x07` cannot read a v2 one.

The question is what the header says. `FORMAT_VERSION` is `1`
(`record/encode.odin:26`) and the header check is **strict inequality** —
`if h.version != FORMAT_VERSION` (`record/encode.odin:243`), answering
`.Bad_Version`. `log.md` §11 states the rule this implements: no schema
evolution, a format version bump means a new log, and there is no migration by
design.

## Decision

**`FORMAT_VERSION` becomes 2.** No migration is written and no v1 log is
converted, which is `log.md` §11 applied rather than amended. The test fault
corpus and the §9 ISMS-scale measurement corpus are regenerated at v2
(`RECORD-T-0025`).

The strict-inequality check stays strict: a v2 binary refuses a v1 log, *even
though every byte in that v1 log is valid v2*. That is not an oversight being
preserved — it is what "no schema evolution" means when written down, and
loosening it to `<=` would introduce the migration story this format declines
to have.

## Alternatives Analysis

| Option | Pros | Cons | Risk Level | Implementation Cost |
|--------|------|------|------------|-------------------|
| **Bump to 2** (chosen) | An old binary fails at the header with a named `.Bad_Version` instead of halting deep in replay; the header stops lying about what the log contains; the format's one rule stays one rule | Every v1 log becomes unreadable, corpora included | Low | Regenerate two corpora; one constant here, one in the Python verifier |
| Stay at 1 | Every existing log stays readable; no corpora regenerated | A v1-stamped log containing `0x07` is a log that lies about what it is; an older reader discovers it inside `term_decode` as a not-ok, far from the header, where the failure is least legible | Medium | None |
| A minimum-reader-version or feature-flag header field | Fine-grained: a reader could accept a log whose features it knows | Introduces exactly the schema-evolution machinery `log.md` §11 refuses; a second compatibility concept to specify, verify and keep two implementations agreeing on | High | Format change, both verifiers, the document |

## Rationale

**The cost of a bump is at its historical minimum and will never be lower.**
There are no deployments; the only tag any consumer pins (`v0.3.0`, in
odin-rdf-shacl) is pinned by an engine that holds no durable log of its own.
Every later moment has more logs in it than this one.

**Honesty at the header is the property being bought.** This store's value
proposition is that a third party can verify a log from the specification
alone. A log whose header says "version 1" while its body carries a tag no
version-1 specification describes is the one defect that erodes that
proposition rather than merely inconveniencing a reader.

**The alternative's failure is late and illegible.** Not bumping does not
prevent the failure, it relocates it: from `.Bad_Version` at byte 8 to a
not-ok inside `term_decode` after a successful header parse, chain walk and
partial replay.

The feature-flag option is rejected on the same ground `log.md` §11 rejected
schema evolution in the first place — every mechanism that lets a reader
partially understand a log is a mechanism two independent implementations
must agree about, and the second implementation here is 270 lines of Python
whose whole worth is that it was written from the document alone.

## Consequences

### Positive
- A v1 binary meeting a v2 log fails at the header, by name, before it has
  computed anything.
- `log.md` §11's rule is exercised once and found sufficient, rather than
  quietly worked around the first time it bound.

### Negative
- **Every existing log is unreadable**, including the 29-case fault corpus and
  the ISMS-scale measurement corpus. Both are generated, so this is mechanical
  — but `RECORD-T-0025` must regenerate them and re-run the §9 measurement
  rather than cite the old figures.
- **`tests/verify/rdflog_verify.py` needs a change after all**, which falsifies
  `RECORD-T-0025`'s acceptance criterion as written. That criterion's *reason*
  survives: the verifier reads a term definition as `id u64, len u32, payload`
  and never inspects the payload's tag, so the new **encodings** are invisible
  to it. But it pins `VERSION = 1` at `tests/verify/rdflog_verify.py:40` and
  refuses a mismatch at `:110`, so the **version** is not. The change is one
  constant and the module docstring, and it is a change for the header's sake,
  not the encoding's — which is the distinction that keeps the "no Python-side
  change means the encoding went where §5.2 describes" signal intact. Record it
  as a finding, not as a surprise.

### Neutral
- Nothing about the on-disk *layout* of any existing record changes. The bump
  is a statement about what a reader must understand, not about bytes.

## Review Triggers

- A second format-affecting capability arriving before a release ships, which
  would make one bump serve both — the reason `RECORD-I-0004` bundled base
  direction with triple terms rather than moving the version twice.
- Any proposal to relax the strict-inequality header check. It would be a
  proposal to introduce migration, and belongs against `log.md` §11 rather than
  here.