---
id: the-public-interface-stated
level: initiative
title: "The public interface, stated: @(private) for everything that is not it, and a check that keeps it that way"
short_code: "RECORD-I-0005"
created_at: 2026-09-01T11:01:54.765717+00:00
updated_at: 2026-09-01T11:24:06.402211+00:00
parent: RECORD-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/completed"


exit_criteria_met: false
estimated_complexity: M
initiative_id: the-public-interface-stated
---

# The public interface, stated Initiative

## Context **[REQUIRED]**

**This repository has 195 exported symbols and no statement of which of them are
the interface.** Odin exports every top-level declaration not marked
`@(private)`, so the surface is not a decision anyone made — it is the residue of
what the package needed to share with `tool/`, with the `tests/*` suites, and
with itself across files. `doc/design/api.md` describes the intended read and
write surface, and has never been reconciled against what the compiler actually
lets a consumer reach.

The cost is not hypothetical. `RECORD-T-0028`'s session had to ask, of
`store_build_permutations`, whether a consumer was expected to call it — a
procedure that rebuilds all seven orders wholesale against the current
`n_facts`, does not publish, and races the published `Index_Set` any live reader
is bounded by. The answer was in the call sites (`boot.odin`, `apply.odin`, and
otherwise tests), not in the declaration, and not in the doc comment. Two
engines and an application now build against this repository. The question will
be asked again, by someone with less context, and the compiler will keep
answering "yes, it is public".

### What the surface actually is, measured

195 exported symbols in `record`. Reached by name from outside the package:

| class | count | what it means |
| --- | --- | --- |
| external consumers (odin-rdf-shacl, odin-rdf-sparql) | 47 | the real interface |
| in-repo, non-test (`tool/`, `record/ingest`) | 10 | the format layer, reached by the CLI |
| in-repo tests only (`tests/*`, separate packages) | 43 | exported *because a test is not in the package* |
| named nowhere outside `record` | 95 | candidates |

`Term_ID` alone accounts for 273 uses across the two engines; `Snapshot` 36,
`snapshot_release` 39, `Apply_Error` 42. At the other end, 95 symbols — nearly
half the surface — are exported and named by nothing outside the package.

**The 95 is an upper bound, not the answer.** `Origin`, `Range`, `File_Ops`,
`Index_Set` and `Read_Status` are all in it, and every one is load-bearing:
`Filter.origin`, `snapshot_match`'s return type, `store_open`'s third parameter.
A consumer reaches them by inference and never spells them, so no grep can see
the dependency. Reachability, not textual use, is the criterion.

### What `@(private)` can and cannot express — tested, not assumed

Measured in a two-package experiment before planning any of this:

- A consumer **cannot name** a private identifier: `lib.Res` fails with
  `Error: 'Res' is not exported by 'lib'`. This is the whole value of the
  mechanism, and it is enough for every procedure and every standalone type.
- A consumer **can still use** a private type it never names: constructing
  `lib.Cfg{h = .B}` with the enum `Hidden` private (implicit selector),
  receiving a private `Res` by inference from a public procedure, and passing it
  back, compiles and runs.
- `odin doc` **still prints the signature**: `give :: proc(c: Cfg) -> Res` and
  `Cfg :: struct {h: Hidden}` appear with no definition for the private names.

So marking a signature-reachable type private does not close the boundary — it
produces documentation that names types it does not define. `@(private)` states
the boundary correctly for anything standalone and *misstates* it for anything
reachable through a public signature. That asymmetry is why this initiative is
two mechanisms and not one: `@(private)` at the declaration, and a checked-in
surface list that a build target diffs.

`@(private)` is package-scoped, so `record/*_test.odin` keeps its access at no
cost. Only the separate packages — `tests/*`, `tool/` — and the sibling repos
are constrained by it.

## Goals & Non-Goals **[REQUIRED]**

**Goals:**

- **A reader can tell what the interface is from the source.** Every exported
  symbol is exported because it is the interface; everything else is
  `@(private)`.
- **The boundary is stated once, normatively**, in a checked-in list that
  `doc/design/api.md` agrees with.
- **An unintended addition to the surface fails a build**, and shows up as a
  line in a diff a reviewer reads.
- **No consumer breaks.** odin-rdf-shacl and odin-rdf-sparql compile unchanged,
  and their read pins hold.

**Non-Goals:**

- **Not a format change.** Nothing here touches the log, the encoding, or the
  resident representation. No version moves.
- **Not an API redesign.** Nothing is renamed, resignatured, added or removed
  from what consumers actually use. This initiative changes *visibility* and
  nothing else.
- **Not the `record/log` split, yet.** Extracting the format layer into a
  subpackage is the one structural fix that would close the `tool/` leak
  properly, and it moves import paths in a tagged library that two engines pin.
  It is scoped here as a decision to take, with its evidence gathered, and
  deliberately not taken inside this initiative.
- **Not a test-suite reorganisation for its own sake.** The `tests/*` question
  is examined; moving a suite is only justified if the suite's meaning survives.

## Detailed Design **[REQUIRED]**

### The two mechanisms

1. **`@(private)` at every declaration that is not interface.** Precise where it
   works, free for in-package tests, and it puts the statement where a reader of
   the code is looking.
2. **`doc/api-surface.txt`, checked in, diffed by `make api`.** Generated from
   `odin doc record -short`, one exported name per line. This is what catches the
   half `@(private)` cannot express, and — more importantly — what catches a
   *new* export added a year from now by someone who never read this initiative.

The first states intent; the second makes it hold.

### How the closure is decided

Not by grep. The sequence, per candidate:

1. Mark private.
2. Build everything that could name it: `make check`, `make tool`, `make test`,
   then `make check` in odin-rdf-shacl and odin-rdf-sparql with `record:` pointed
   at this working tree. A compile error names a hard blocker; revert it.
3. Regenerate `odin doc record -short` and flag any type named in a public
   signature or public struct field that no longer has a definition in the
   output. This is the step that catches `Origin`, `Range`, `File_Ops` — the ones
   step 2 will *not* catch, because a private type reachable by inference still
   compiles for the consumer.

Step 3 is the one a future session will be tempted to skip. It is the reason the
`make api` target exists rather than a one-time audit.

### The three leaks, and what each costs

- **95 candidates named nowhere.** Minus the signature-reachable set, this is the
  free win, and the bulk of the value. Mechanical and reversible.
- **43 symbols held public by `tests/*`.** `writer_create`, `Loader`,
  `store_init`, `store_build_permutations`, `frame_next` and their kind are
  exported because `tests/scale`, `tests/proof`, `tests/tool` and `tests/ingest`
  are separate packages. Some of these — `tests/scale`'s hand-built-store cases —
  are unit tests wearing a suite's clothes and could move in-package. The
  obstacle is real: `make test` runs `tests/scale` optimized and separately on
  purpose, and an in-package `_test.odin` inherits the debug build, so a
  measurement that moves stops measuring what it was gating. Examined in
  `RECORD-T-0032`, moved only where the meaning survives.
- **10 symbols held public by `tool/`.** `verify`, `replay`, `Consumer`,
  `term_decode`, `inline_term`, `HASH_SIZE`, `DEFAULT_GRAPH`, `TERM_TAG_IRI`,
  `Fact_Op`, `INLINE_FLAG` — the log/format layer, reached by the CLI. The clean
  fix is a `record/log` subpackage, which also matches how the repo already
  describes itself (`log.md` against `api.md`). It is an ADR and a release of its
  own; `RECORD-T-0033` gathers the evidence and takes the decision, and does not
  execute it.

## Alternatives Considered **[REQUIRED]**

**Documentation alone — a doc comment on each internal declaration saying "not
for consumers".** This is the status quo plus prose, and the status quo already
failed: `store_build_permutations` has a nine-line doc comment that explains what
it does, why it is a radix sort, and what it costs, and does not say who may call
it. A comment does not fail a build.

**A naming convention — a leading underscore, an `internal_` prefix.** Renames
195 symbols' worth of call sites for a signal the compiler still ignores, and
Odin has a real mechanism.

**The `record/log` split alone, without the `@(private)` pass.** Closes the
`tool/` leak and none of the other two, moves import paths for a tagged library,
and leaves the 95 exported. It is the right eventual structure and the wrong
first move.

**`@(private = "file")` rather than package-private.** Stronger, and wrong here:
it breaks `record/*_test.odin`, which is where most of this repository's tests
live, and it would force test code into the implementation files.

## Implementation Plan **[REQUIRED]**

Sequenced so each step ends provable, and so the cheap, reversible value lands
before either structural question is opened:

1. **`RECORD-T-0030` — the boundary, written down.** `doc/api-surface.txt` as
   the normative list, reconciled against `doc/design/api.md` and the 47
   measured external uses. Nothing in `record/` changes. This is the artifact
   every later step is checked against.
2. **`RECORD-T-0031` — the closure computed, and `@(private)` applied.** The
   three-step method above, over the 95 candidates. Consumers built, docs
   regenerated and read.
3. **`RECORD-T-0032` — `make api`, and the `tests/*` question.** The target that
   makes the boundary hold, wired into `make check`; then the examination of
   which of the 43 can move in-package without spoiling what the suite measures.
4. **`RECORD-T-0033` — the `record/log` decision.** Evidence gathered, ADR
   written, decision taken. Execution, if the answer is yes, is a separate
   initiative with a release of its own.

**Exit:** every exported symbol in `record` is exported deliberately;
`doc/api-surface.txt` names them and `make api` fails on a difference;
`make test` green here; **`make check && make test` green in both
`../odin-rdf-shacl` and `../odin-rdf-sparql` with no source change in either** —
shacl's 98 W3C entries, sparql's 546 of 556 and 288 tests, and both repositories'
read pins unmoved; and the `record/log` question is decided either way rather
than left open.

Both siblings' Makefiles already declare `-collection:record=../odin-rdf-record`,
so those runs build against the working tree rather than the `v0.6.0` tag their
CI pins. The consumer suites are the verification, not a courtesy check after
it.

## Status

**2026-09-01 — complete. All four tasks done, 74 of 195 declarations private.**

`record` exports **121** names where it exported 195: 65 the store API, 13 the
format layer `tool/` reaches, 43 held by the `tests/*` suites — each stated in
`doc/api-surface.txt`, which `make api` diffs on every `make check`.

What each task actually found, beyond doing its job:

- **`RECORD-T-0030`** — grep under-reports the surface by a third. 18 of the 65
  API names are reached only by inference (`Range`, `Origin`, `File_Ops`) and
  appear in no consumer source. `api.md` turned out not to be a list of exported
  names at all — 25 of 195, written in design names — so the surface file is new
  information beside it, not a restatement.
- **`RECORD-T-0031`** — the documentation check earned its place. After the
  compile passed *and* both consumer suites passed, eleven public procedures
  still had private types in their signatures. The tests-held set is 43, not 33:
  a suite naming an exported procedure holds its whole type closure public.
- **`RECORD-T-0032`** — the initiative's own hypothesis was wrong. Moving
  `tests/scale`'s builder cases in-package frees **one** symbol, because
  `measure_boot` hand-builds a store itself and must stay optimized and
  out-of-package. Recorded rather than forced.
- **`RECORD-T-0033`** — decided the narrow `record/log` split ([[RECORD-A-0009]]),
  then **reversed it the same day on a second measurement** ([[RECORD-A-0010]]).
  The out-edge count that made the split look free answers whether the moved
  code can stand alone; it does not answer what the boundary costs the code left
  behind. `@(private)` is package-scoped, and 38 private symbols in those files
  are used by the rest of `record` — the split would force them public and take
  the total exported from 121 to **161**, publishing the inline-term encoding
  `RECORD-A-0001` froze. `RECORD-I-0006` is closed unstarted and archived; no
  source file was touched. **The format layer stays in `record`, stated rather
  than moved.**

Verification throughout was the consumers: `make check && make test` in
`../odin-rdf-shacl` and `../odin-rdf-sparql`, green with **no source change in
either**, sparql's W3C survey byte-identical against a pre-change baseline, and
both read pins holding (shacl `pin: 7503 reads, as pinned`; sparql's bench
assertions).

What did not change: no format version, no API redesign, no renamed or removed
symbol, no test suite reorganised. The
measurement in Context is done and reproducible; the two open questions are
`tests/scale`'s builder cases and whether the `record/log` split is on the table
at all, and they are `RECORD-T-0032` and `RECORD-T-0033` respectively. If the
split is ruled out, steps 1–3 still stand and carry most of the value.