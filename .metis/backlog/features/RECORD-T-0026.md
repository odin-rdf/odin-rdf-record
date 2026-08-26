---
id: a-bound-graph-is-always-a-scan
level: task
title: "A bound graph is always a scan: what RECORD-A-0004 costs a SPARQL engine, measured"
short_code: "RECORD-T-0026"
created_at: 2026-08-25T15:00:00.000000+00:00
updated_at: 2026-08-25T15:00:00.000000+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#feature"
  - "#phase/backlog"


exit_criteria_met: false
initiative_id: NULL
---

# A bound graph is always a scan: what RECORD-A-0004 costs a SPARQL engine, measured

## Objective **[REQUIRED]**

**This is evidence, not a request, and not a precondition for anything.**
It is filed under the family's "capability gaps become evidence-backed
upstream proposals, never backend-specific workarounds" convention, by
odin-rdf-sparql at the close of its port to this store (`SPARQL-I-0003`,
`SPARQL-T-0039`). Nothing in odin-rdf-sparql is blocked on it, nothing
was worked around, and the engine ships green.

`RECORD-A-0004` gives this store six permutations, all ending in `G` as a
residual tiebreaker, so **a bound graph never enters a prefix**.
`snapshot_match` for `GRAPH <g> { ?s ?p ?o }` — s, p and o all unbound —
narrows to nothing and returns a window over the entire permutation,
which `scan_next` then filters one fact at a time.

`GRAPH` is a first-class SPARQL operator, and the family's deployment
shape is ~200 processes per machine each embedding a store, so the
capability is worth pricing even where the absolute numbers are small.

## The measurement

odin-rdf-sparql had **no benchmark before its port**, and one was built
inside it precisely so this would be a number rather than a prediction
(`SPARQL-T-0040`, then `SPARQL-T-0036`). The experiment holds the named
graph fixed at 4,122 triples and grows the *default* graph tenfold — so
the question it answers is: **does naming a graph cost you the data you
did not name?**

| | odin-rdf-store (graph-first indexes) | odin-rdf-record |
| --- | --- | --- |
| `GRAPH b:g1 { ?s ?p ?o }`, 16,495-triple default graph | 0.100 ms | 0.078 ms |
| the same query, 164,933-triple default graph | **0.101 ms** | **0.244 ms** |
| candidate facts considered, smaller store | — | 20,617 |
| candidate facts considered, larger store | — | **169,055** |
| solutions, both | 4,122 | 4,122 |

**169,055 candidates for 4,122 answers, and 169,055 is the whole store.**
The old store answered from a prefix range and never looked at the rest;
this one looks at all of it. `graph` is the **only case of the sixteen in
that benchmark that got slower** across the port — everything else moved
1.5x to 3.4x *faster*, which is what makes this one legible rather than
noise.

Two observations that are worth more than the numbers:

- **It is invisible in wall clock at the smaller size**, because this
  store's own speed covers it: scanning 20,617 resident facts still beats
  seeking 4,122 through LMDB. Only at the larger corpus does the scan
  overtake the win. A consumer benchmarking one dataset size would
  conclude there was no regression.
- **A consumer instrumenting its own calls cannot see it at all.**
  `scan_next` filters the residual pattern inside its own loop, so a
  skipped candidate never reaches the caller and increments nothing on
  their side. odin-rdf-sparql's read counter — which reproduced *fourteen
  of sixteen pinned counts to the integer* across the port, so it is a
  precise instrument — reports the identical `1 match / 4123 next` for
  this query at both store sizes. It had to add a sixth verb summing
  `range_len` over every window opened before it could see anything at
  all. **That is the part most worth knowing here**: the store's own
  `range_len` is the only way a consumer can price a residual scan, and
  nothing signposts that.

## A second, smaller consequence of the same decision

`GRAPH ?g { … }` — a graph *variable* — ranges over the **named** graphs
only; the default graph has no name to bind. This store cannot express
that: an unbound `G` spans both, and `Filter.graphs` takes a set of names
rather than a class. So odin-rdf-sparql over-fetches and discards the
default graph's quads in `unify_quad`, one at a time. odin-rdf-store had
the same gap and closed it with a `NAMED_GRAPHS` sentinel that was free
there — `DEFAULT_GRAPH` carried the highest kind tag, so in a graph-first
index the named graphs were a prefix and the default graph was the tail,
and the backend answered by *ending* the scan rather than filtering it.
There is no graph-first index here to end, so the same trick does not
transfer. Recorded as one note with the above because it is one cause.

## What this is not

- **Not a request to add a graph-first permutation.** `RECORD-A-0004`
  reasoned about seven orders and chose six; that trade is this store's
  to make, and it was made with the residual cost named. If it is ever
  revisited, this is the consumer-side number to revisit it against.
- **Not a defect.** Correctness is unaffected; odin-rdf-sparql's
  `sparql10-graph` is 17/17 and `sparql10-dataset` is 12/12 against this
  store.
- **Not urgent.** 0.244 ms is not a number a user notices, and the whole
  W3C harness runs in 1.7 s. The argument is the **41x over-scan and the
  fact that it grows with the store rather than with the answer**, not a
  wall-clock complaint.

## Status Updates **[REQUIRED]**

- **2026-08-25 — Filed by odin-rdf-sparql at the close of `SPARQL-I-0003`**
  (`SPARQL-T-0039`), with the owner's agreement to file cross-repository.
  The reproduction is `make bench` in odin-rdf-sparql: the `graph` case,
  `small` and `large` configurations, `candidates` column. Both halves of
  the comparison — the graph-first number and this one — are in
  `SPARQL-T-0040` and `SPARQL-T-0036`, and `SPARQL-I-0003` §12 carries
  the joined table. Neither half alone was evidence, which is why the
  benchmark was built before the port rather than after.
- **2026-08-27 — Answered on `main`, unreleased (`RECORD-T-0028`).** The
  application's workspace design fired `RECORD-A-0004`'s review trigger
  on a `(G, P, O)` shape, and the escape hatch was spent as one
  graph-first order, `GPOS`. This note's shape — `GRAPH <g> { ?s ?p
  ?o }`, G alone — is that order's `(G)` row: a prefix window that is
  exactly the graph, where it was the whole permutation filtered. Its
  second half (`GRAPH ?g` over the named graphs) is not built, but the
  default graph is stored as `G = 0` and so sorts first in `GPOS`; the
  named graphs are that order's tail, which is the cheap answer if a
  consumer asks. Nothing in odin-rdf-sparql changes: it calls
  `snapshot_match`, and the 169,055 candidates become 4,122 at whatever
  pin includes this. Still evidence; now evidence with an answer.
- **2026-08-27, later — pinned and measured.** `v0.6.0`; odin-rdf-sparql's
  `make bench` (`SPARQL-T-0046`): this case is **4,122 candidates for
  4,122 answers at both store sizes, 0.064 / 0.065 ms**, where the table
  above says 20,617 / 169,055 and 0.078 / 0.244 ms — flat across the
  sizes, which is the property the measurement was built to check, and
  faster than the graph-first store it was compared against. Every
  solution count unchanged.
