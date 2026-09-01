---
id: what-record-offers-is-what-a
level: initiative
title: "What `record.` offers is what a consumer should use: emptying sections 2 and 3"
short_code: "RECORD-I-0007"
created_at: 2026-09-01T11:31:57.888343+00:00
updated_at: 2026-09-01T11:48:28.060407+00:00
parent: RECORD-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/completed"


exit_criteria_met: false
estimated_complexity: M
initiative_id: what-record-offers-is-what-a
---

# What `record.` offers is what a consumer should use Initiative

## Context **[REQUIRED]**

`RECORD-I-0005` made this package's surface a statement: 195 exported names
became 121, and `doc/api-surface.txt` accounts for every one in three sections —
65 the store API, 13 held by `tool/`, 43 held by the `tests/*` suites.

**Stated is not the same as offered.** Typing `record.` in an editor lists all
121. The LSP does not read `doc/api-surface.txt`; it reads what is exported. So a
consumer's completion list contains `store_build_permutations`, `Index_Set`,
`Loader`, `frame_next`, `writer_create` and fifty more names that are exported
for no reason but that a test or a CLI lives in another package. The owner's
reading, and the reason this initiative exists: *that is a failed API*, however
accurately the residue is documented.

`RECORD-A-0010` closed the question of moving the format layer to a subpackage —
the reverse coupling makes it worse, not better. This initiative takes the other
route: **remove the reasons the names are exported**, rather than relocate them.

### What was measured before this was scoped

- **`tests/proof`, `tests/scale` and `tests/tool` import only `record`** (plus
  `core:*` and `rdf:rdf`). They can become `record/*_test.odin` — in-package —
  and then hold nothing public, because `@(private)` is package-scoped.
- **`when #config(NAME, false)` conditionally compiles `@(test)` procedures**,
  verified in a scratch package: the default build compiles one test, the
  `-define:` build compiles two. So `tests/scale`'s optimized separate run
  survives the move as a second `make test` pass rather than dying with it.
- **`tests/ingest` and `tests/readme` cannot move.** Both import
  `record/ingest`, which imports `record`; in-package that is an import cycle.
  `tests/readme` holds nothing. `tests/ingest` holds exactly two names,
  `store_fact` and `dict_bytes`, on two adjacent lines, and both have public
  equivalents — `snapshot_fact` and `snapshot_bytes`.
- **Four name collisions** across the joined test files (`BIN`, `WALL`,
  `append_framed`, `splitmix`), all local helpers, all renameable.

### The two sections, and why each is still there

**Section 3 (43)** is an artifact of test layout and nothing else. Every name in
it exists because Odin scopes `@(private)` to the package and four suites sit
outside it. Moving three of them in and rewriting two lines in the fourth empties
the section completely.

**Section 2 (13)** is different and is a real, if small, API design failure:
`tool/` — the `record` CLI — reconstructs term decoding by hand, so it reaches
for `term_decode`, `inline_term`, `Resolve_Iri`, `Resolve_Term`, `TERM_TAG_IRI`,
`INLINE_FLAG`, `HASH_SIZE`, `DEFAULT_GRAPH` and `Fact_Op`. The package offers no
way to read a log's contents without booting a store into memory, so the CLI
built one out of parts. That is a missing seam, and the fix is to add it rather
than to keep nine format internals exported.

The remaining four — `verify`, `Verify_Result`, `replay`, `Consumer` — are
defensible public API on their own merits: checking a log's chain without
opening it is exactly what a third party should be able to do, and it is the
repository's stated value proposition.

## Goals & Non-Goals **[REQUIRED]**

**Goals:**

- **Typing `record.` lists the API and nothing else.** Target ~69 names, every
  one in section 1 of `doc/api-surface.txt`.
- Section 3 emptied: 43 → 0.
- Section 2 emptied by *design*: 13 → 0, nine of them replaced by a log-reading
  seam and four promoted to section 1 where they belong.
- Every suite still runs, and `tests/scale` still measures optimized.
- No consumer source change; suites and read pins unmoved in both engines.

**Non-Goals:**

- **Not a facade package.** Making `record` a wall of aliases over an internal
  package would reach exactly 65, and was considered — see Alternatives. It is
  the fallback if this route stalls, not the plan.
- **Not the subpackage split.** `RECORD-A-0010` settled it.
- **Not new capability.** The log-reading seam exposes what `tool/` already
  does; it is not a feature.

## Alternatives Considered **[REQUIRED]**

**The facade** — move the implementation to `record/internal`, leave `record` as
65 alias declarations. Consumers keep `import "record:record"` and see exactly
the API; no test has to move. Rejected as the primary route because every public
symbol becomes an indirection: doc comments need a home, go-to-definition takes
an extra hop, and the alias and its definition can drift silently. Kept in
reserve: it is the only option that reaches 65 exactly, and it does not care how
the tests are laid out.

**Leave it and document harder.** The status quo after `RECORD-I-0005`. Rejected
by the owner on the grounds this initiative opens with: a completion list is an
interface, and no file the LSP does not read can fix it.

**Export nothing and make `tool/` part of `record`.** A CLI needs a `main` and
cannot share a package with a library. Not available.

## Implementation Plan **[REQUIRED]**

1. **`RECORD-T-0034` — empty section 3.** Move `tests/proof`, `tests/scale` and
   `tests/tool` in-package; gate the scale tests behind `#config(RECORD_SCALE)`
   and give `make test` its second optimized pass; rewrite `tests/ingest`'s two
   lines onto the public API; resolve the four collisions; mark all 43 private.
   → 78 exported.
2. **`RECORD-T-0035` — empty section 2.** Design and add the log-reading seam
   the CLI needs, port `tool/` onto it, mark the nine format internals private,
   and move `verify`/`Verify_Result`/`replay`/`Consumer` into section 1 as
   API. → ~69 exported.

**Exit:** `record` exports only section 1; `doc/api-surface.txt` has one section
and `make api` is green against it; every suite in this repository green,
including the scale measurement at its own flags; both engines green with no
source change and read pins unmoved.

## Status

**2026-09-01 — complete. `record.` offers 73 names, and every one is API.**

121 → 81 → 73. `doc/api-surface.txt` is a single list with no exceptions
section: sections 2 and 3 are both empty, and the residue they described is
gone rather than relocated.

- **`RECORD-T-0034`** emptied section 3 (43 → 0) by moving `tests/proof`,
  `tests/scale` and `tests/tool` into the package, where `@(private)` reaches
  them. `tests/scale`'s optimized run survives as a second `make test` pass
  behind `when #config(RECORD_SCALE, false)`; the measurement reports what it
  did before. `tests/ingest` could not move — it imports `record/ingest`, which
  imports `record` — and was ported onto the public read API instead, which is
  what a suite outside the package should have been using.
- **`RECORD-T-0035`** emptied section 2 (13 → 0) by adding `log_read`, the
  decoded counterpart to `replay`, and porting the CLI onto it. Nine format
  internals went private, and `replay`/`Consumer` with them; `verify`,
  `Verify_Result` and `HASH_SIZE` moved into the API where they belonged.

Two findings worth carrying forward:

- **The surface can be under-inclusive too.** `snapshot_bytes` had been made
  private in `RECORD-T-0031` because no consumer calls it — but `api.md` §12
  names the read API as *Match, Iter, Resolve, **Bytes**, Term*. A closure built
  from current usage misses documented API that nothing calls yet.
  `snapshot_bytes`, `snapshot_visible` and `snapshot_derived` were promoted
  back. Under-exporting is as wrong as over-exporting.
- **A commit's attribution cannot be resolved at the commit record.** The term
  definitions arrive after the header, and an epoch's actor is interned by that
  same epoch, after its ops. `log_read` holds the epoch and delivers it once its
  terms are in. The first version did not, and the dump round-trip caught it.

Verified at every step against both engines: green, `git status` clean in both,
sparql's W3C survey byte-identical to the pre-`RECORD-I-0005` baseline, eight
read pins `as pinned`, sparql's bench `all assertions passed`.