---
id: filter-graphs-an-empty-set-reads
level: task
title: "Filter.graphs: an empty set reads every graph, by allocation history — scope must be stated like origin is"
short_code: "RECORD-T-0029"
created_at: 2026-08-26T21:29:05.621624+00:00
updated_at: 2026-08-26T21:50:39.151562+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#bug"
  - "#phase/active"


exit_criteria_met: false
initiative_id: NULL
---

# Filter.graphs: an empty set reads every graph, by allocation history — scope must be stated like origin is

## Objective **[REQUIRED]**

`Filter.graphs` carries the difference between "unscoped" and "scoped
to this set" in the slice's **data pointer**, and Odin puts a nil pointer
in some empty slices and not others. So the same logical value — an
empty graph set — reaches `scan_next` as either of two opposite reads,
depending on how the caller's buffer was allocated. One of the two is
**every graph**. Fix the contract so that scope is *stated*, the way
`Origin` already is, and an empty set is empty whatever pointer it
carries.

**Status, plainly: latent.** The code does what its comment says
(`record/read.odin:50-58`: "nil means every graph, otherwise a small
slice"), and **no consumer passes a set today** — neither engine
constructs `Filter.graphs`. It becomes a live defect the day the first
computed set arrives, and three are on their way: the application's
workspace design (2026-08-26; a named graph per workspace, the read
scope `{W} ∪ ancestors(W)` or `{A} ∪ descendants(A)` computed per
request, and read **directly through this API** as well as through the
engines), `SPARQL-T-0044`, and `SHACL-T-0039`. The set is an
**authorization ceiling**; the failing direction is open.

## Backlog Item Details

### Type
- [x] Bug — a contract with an input it did not consider, on which it
      silently does the most permissive thing

### Priority
- [x] P1 — latent today; a ceiling for the application's first workspace
      read. Sequenced **before** `SPARQL-T-0044`, `SHACL-T-0039` and
      `RECORD-T-0028`, so that all three are written against the fixed
      `Filter`.

### Impact Assessment

- **Affected consumers**: none today. The application (direct reads),
  odin-rdf-sparql and odin-rdf-shacl as soon as they pass a set. The two
  engine tasks each guard on their own side; the application has no
  engine in front of it.

- **Reproduction** (verified 2026-08-26, Odin on darwin arm64 —
  `slice == nil` compares the data pointer): four ordinary ways to hold
  a workspace's empty descendant set, then `range_iter(rng,
  Filter{origin = .Any, graphs = set})` over a store with two named
  graphs and a default graph:

  | how the empty set was built | `set == nil` | `scan_next` yields |
  | --- | --- | --- |
  | `d: [dynamic]Term_ID`, nothing appended, `d[:]` | true | **every fact in the store** |
  | `make([dynamic]Term_ID, 0, 8)`, nothing appended, `d[:]` | false | nothing |
  | appended once, then `clear(&d)`, `d[:]` | false | nothing |
  | `buf: [N]Term_ID`, `buf[:0]` | false | nothing |

  Whether a leaf workspace's report reads the whole store or nothing
  turns on a capacity hint, or on whether an earlier request ever
  appended to the same buffer. The path that fails open is the plainest
  code.

- **Expected vs actual**: an empty set admits nothing, always. Actual:
  the first row.

## Why this is the record's to fix, not the caller's to avoid

- **The record already ruled on this shape, one field over.** `Origin`
  "has no default deliberately: asserted-only and any answer different
  questions … The zero value is invalid and `range_iter` refuses it"
  (`read.odin:43-48`, `api.md` §12.5). Scoped and unscoped answer
  different questions too, and here the zero value silently picks the
  wide one. This is the record's own principle, not applied to the field
  beside the one it was applied to.
- **A convention is not a ceiling.** "Always include `W` itself" or
  "check `len` before reading" works, but it lives in every consumer,
  including one this repository will never see. A system of record
  should not hold an authorization invariant by convention in code it
  does not own — and the family's rule is that a gap becomes an upstream
  fix, not a workaround.
- **The failing input is ordinary.** A user permitted nothing and a
  workspace with no children are the first day, not an edge.

## The fix

The `Origin` precedent, exactly:

```odin
// Graph_Scope says what a Filter's graph set means, and has no default
// deliberately — "every graph" and "only these" answer different
// questions, and the zero value picking one silently is how an empty
// set came to read the whole store (RECORD-T-0029).
Graph_Scope :: enum u8 {
	All = 1, // every graph; `graphs` is ignored
	Set = 2, // only the graphs listed — an empty list admits nothing
}

Filter :: struct {
	origin: Origin,
	scope:  Graph_Scope,
	graphs: []Term_ID, // read under .Set only
}
```

- `range_iter` refuses an unstated scope the way it refuses an unstated
  origin (an assert naming this task and `api.md`).
- Under `.Set` the check is a loop over `graphs` — a zero-length loop
  admits nothing — and **no pointer is compared anywhere**. `Scan`
  mirrors the field. `0` and `MATCH_DEFAULT_GRAPH` in the set still name
  the default graph, unchanged.
- Under `.All`, `graphs` is ignored and documented so.
- **Rejected**: redefining `nil` as "nothing" — it silently empties every
  existing read; and `Maybe([]Term_ID)` — untested whether Odin's union
  distinguishes a present nil slice from an absent one, and it would
  hide the same pointer question inside a union where the enum states it
  beside the field that set the precedent.

**This is an API change and wants a tag.** Every `Filter` literal must
now state `scope`; a caller that does not is caught at its first read,
not at compile — the same shape as `Origin`, and as `v0.3.0`'s typed
ids. The consumer sites are known: odin-rdf-sparql `sparql/exec.odin:307,
332`; odin-rdf-shacl `shacl/session.odin:156, 182, 207`. Each gains
`scope = .All`; if `SPARQL-T-0044` or `SHACL-T-0039` has landed first,
its set path gains `.Set`. *(Corrected in Status, 2026-08-27: **ten**
sites, not five — that count came from grepping `Filter{`, and Odin's
untyped compound literals `{origin = .Any}` do not name the type.)*

## Acceptance Criteria

**[REQUIRED]**

- [x] `Graph_Scope` with an invalid zero; `range_iter` asserts a stated
      scope, as it does origin.
- [x] A test builds all four empty sets from the table against a store
      with two named graphs and the default graph, and asserts that
      under `.Set` **each yields no fact** — the first row is the
      regression, the other three pin that the fix did not move them.
- [x] Under `.Set`, a non-empty set still yields exactly its graphs'
      facts; `MATCH_DEFAULT_GRAPH` and stored `0` in the set still admit
      the default graph; `Pattern.g` and the set still intersect.
- [x] Under `.All`, every graph, `graphs` ignored.
- [x] No `!= nil` on `graphs` remains in `read.odin`.
- [x] `Filter`'s doc comment rewritten; `api.md` §12.8's "graph sets"
      bullet and the §12.2 amendment that describes `Filter.Graphs`
      amended with a dated note — the old text stands, the note says
      what moved and why.
- [x] The record's own suites updated to state scope; `make test` and
      `make check` green; both verifiers untouched (no format change).
- [ ] Tagged, with release notes naming the five consumer sites; the
      family's release convention walked — pins bumped, each consumer's
      Current State re-read.

## Implementation Notes

### Dependencies

- None. Effort S: one enum, one field, one assert, one loop, the tests
  and the documents. Consumers: `SPARQL-T-0044`, `SHACL-T-0039`,
  `RECORD-T-0028` — all three should be written against the fixed
  `Filter`, which is why this goes first.

## Status Updates **[REQUIRED]**

- **2026-08-26 — Filed**, at the owner's direction, after the workspace
  design discussion and an elaboration of why this is the record's
  defect rather than a caller's mistake. The four-construction table is
  from a scratch program run that day; the acceptance test is its
  permanent form. Not started.
- **2026-08-26 — Active. Plan**, before code (kept as written; what it
  missed is in the completion note):
  1. `record/read.odin`: `Graph_Scope :: enum u8 { All = 1, Set = 2 }`
     with the doc comment naming `Origin`'s reason; `Filter` gains
     `scope`; `Scan` carries `scoped: bool` in place of the nil test;
     `range_iter` refuses an unstated scope (assert, beside origin's)
     and refuses `.All` carrying a non-empty set — a contradiction, not
     a default; `scan_next`'s graph check becomes `if sc.scoped { loop
     }` with no pointer comparison. `Filter`'s comment rewritten.
  2. `record/read_test.odin`: the oracle mirrors the new rule; the
     oracle test's four graph sets state their scope; every `Filter`
     literal states `scope = .All`; a new test builds the four empty
     sets from the table over `rt_build`'s store and asserts each yields
     nothing under `.Set` — and asserts the four *differ* in nil-ness,
     so the test is known to cover both branches and says so if a
     compiler ever unifies them.
  3. `api.md`: a dated note beside §12.5's "`Origin` has no default",
     pointers at the §12 `Filter` sketch, the §12.2 amendment, and the
     §12.8 graph-sets bullet. The old text stands.
  4. `make test`, `make check`; commit `record:`; then the release walk
     — tag, the five consumer sites, the family file — as a separate
     step, since a tag is the owner's.
  Only `read.odin`, `read_test.odin` and `api.md` in this repository
  mention the field; `snapshot_exists` takes a `Filter` and forwards it.
- **2026-08-27 — Done on the record's side; the release walk is the
  owner's.** `record/read.odin`: `Graph_Scope { All = 1, Set = 2 }`,
  `Filter.scope`, `Scan.scoped`, two asserts in `range_iter` (an
  unstated scope, and `.All` carrying a set — refused as a
  contradiction rather than resolved), and `scan_next`'s check is
  `if sc.scoped { loop }` with no pointer compared anywhere.
  `read_test.odin`: the oracle mirrors the rule; the oracle test's four
  scopings state `.All`/`.Set`; `test_read_graph_scope_empty` builds the
  table's four empty sets over `rt_build`'s store, asserts each admits
  nothing under `.Set` and that the four *differ* in nil-ness (so both
  former branches are known covered), then that the same stack buffer
  holding one graph admits exactly f2 and f5. `api.md` amended in four
  places with dated notes, the old text standing. **79 record tests and
  the full `make test` green**, `make check` clean, both verifiers
  untouched; the scale run is unmoved (permutation sort 45 ms, commit
  latency 34.5/35.9/42.1 ms min/mean/max, bulk boot 221 ms, verify
  53/88 ms, replay 57/100 ms).

  **Two findings the plan did not have, both worth carrying into the
  consumer walk:**

  1. **The plan's "only `read.odin` and `read_test.odin` mention the
     field" was wrong, and so was the task's "five consumer sites".**
     Both counts came from grepping `Filter{`; Odin's untyped compound
     literals — `range_iter(r, {origin = .Any})` — do not name the
     type. This repository had **18** more: one in production
     (`apply.odin:363`, the live-quad precondition check inside
     `apply`), the rest in `termindex_test`, `apply_test`,
     `tests/scale`, `tests/ingest`. The grep that finds them all:
     `grep -rn -E 'origin *= *\.(Any|Asserted|Derived)' --include='*.odin'
     | grep -v scope`. Run against the siblings it gives **ten** sites,
     not five: odin-rdf-sparql `sparql/exec.odin:307`, `:332`,
     `tests/w3c/harness/dataset.odin:128`; odin-rdf-shacl
     `shacl/session.odin:156`, `:182`, `:207`, `shacl/query.odin:38`,
     `tests/smoke/smoke_test.odin:63`, `shacl/validator_test.odin:135`,
     `shacl/as_of_test.odin:122`.
  2. **"Caught at first read" can present as a hang.** With
     `apply.odin:363` unstated, the first assert fired inside
     `test_term_index_reader_writer_torture`'s spawned threads, and the
     test runner did not fail — it sat at ~360% CPU for twenty minutes
     until killed. An assert in a thread the runner is waiting on is a
     deadlock, not a failure. A consumer adopting the tag whose first
     unstated site is reached from a thread will see the same; grep
     first, run second.

  **Left for the release step, deliberately**: the tag and its notes
  (a tag is the owner's act), the ten consumer sites and their pin
  bumps, the family file's "origin must be stated" line (CLAUDE.md:461)
  gaining "and scope", and `SPARQL-T-0044`/`SHACL-T-0039` being written
  against the new `Filter`. The task stays active until those are
  decided.