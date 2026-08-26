---
id: filter-graphs-an-empty-set-reads
level: task
title: "Filter.graphs: an empty set reads every graph, by allocation history — scope must be stated like origin is"
short_code: "RECORD-T-0029"
created_at: 2026-08-26T21:29:05.621624+00:00
updated_at: 2026-08-26T21:29:05.621624+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#bug"


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
its set path gains `.Set`.

## Acceptance Criteria **[REQUIRED]**

- [ ] `Graph_Scope` with an invalid zero; `range_iter` asserts a stated
      scope, as it does origin.
- [ ] A test builds all four empty sets from the table against a store
      with two named graphs and the default graph, and asserts that
      under `.Set` **each yields no fact** — the first row is the
      regression, the other three pin that the fix did not move them.
- [ ] Under `.Set`, a non-empty set still yields exactly its graphs'
      facts; `MATCH_DEFAULT_GRAPH` and stored `0` in the set still admit
      the default graph; `Pattern.g` and the set still intersect.
- [ ] Under `.All`, every graph, `graphs` ignored.
- [ ] No `!= nil` on `graphs` remains in `read.odin`.
- [ ] `Filter`'s doc comment rewritten; `api.md` §12.8's "graph sets"
      bullet and the §12.2 amendment that describes `Filter.Graphs`
      amended with a dated note — the old text stands, the note says
      what moved and why.
- [ ] The record's own suites updated to state scope; `make test` and
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
