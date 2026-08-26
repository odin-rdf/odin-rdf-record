---
id: a-graph-first-order-gpos-which
level: task
title: "A graph-first order, GPOS: 'which Risks are in this workspace' as a prefix, not a scan"
short_code: "RECORD-T-0028"
created_at: 2026-08-26T21:10:55.899140+00:00
updated_at: 2026-08-26T22:39:45.929941+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#feature"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: NULL
---

# A graph-first order, GPOS: 'which Risks are in this workspace' as a prefix, not a scan

## Objective **[REQUIRED]**

**This is a request, not evidence** — the first one filed against
`RECORD-A-0004`, and it fires that ADR's own review trigger ahead of the
measurement the trigger asks for, on a consumer's stated query shape.
It stands beside `RECORD-T-0026`, which measured the residual-graph cost
from odin-rdf-sparql's side and asked for nothing.

**The consumer.** The application above the engines is introducing a
**workspace**: users work in one at a time; sibling workspaces never see
each other's data; a workspace links to data in its ancestors **and in
its descendants** — an escalation written in `A` citing the team risks in
`B`, `C`, `D` that led to it — and reports over its descendants (design
discussion, 2026-08-26). The decision is
**a named graph per workspace** — a statement's graph records the
workspace it was made in, `Filter.graphs` holding `{W} ∪ ancestors(W)` or
`{A} ∪ descendants(A)` is the read scope, and that scope is an
authorization ceiling the record enforces per fact, below either engine.
The alternative, stamping *entities* with a `ws:definedIn` property, was
rejected because scope is a property of a **statement**: a link made in
workspace B between two entities that both live in ancestor A carries no
stamp at all, and every sibling of B would see it.

*Refined the same day.* A workspace's statements can have **two
audiences** — what its descendants may see and what they may not (an
organisation keeping `risk:Risk` private to the workspace that owns it)
— and a statement's audience *is* its graph, so a workspace is **two
graphs**, `W` and `W/private`: the writer places each statement in the
most restrictive graph of any entity it mentions, and the application
composes every read scope from graphs, tree and policy (`{B, B/private,
A}` for a team; `{A, A/private, B, B/private, …}` for A's report). The
record maintains no per-graph structure, so this costs two dictionary
terms per workspace and doubles the number of ids in a read's
`Filter.graphs` — `2k` seeks under `GPOS` — and nothing per fact. A
read-side policy callback was considered and **reserved** for policies
the layout cannot carry (visibility depending on a mutable attribute or
on the reader); none exists today, and one would be filed as evidence
when it does.

**The query shape**, stated by the owner as a requirement: *"What
`risk:Risk` are in workspace `my-workspace`" — without scanning every
`risk:Risk` in the whole store.* That is

```
GRAPH <W> { ?r a risk:Risk }        — G, P, O bound; S free
```

**What it costs today.** `choose_order` (`record/read.odin:410`) never
lets `G` into the prefix, by `RECORD-A-0004`'s one rule. The pattern goes
to `POSG` on (`rdf:type`, `risk:Risk`) — a window over **every Risk in
the store** — and `scan_next` drops the ones outside `W` one at a time
(`read.odin:184`). The over-scan is `|Risks store-wide| / |Risks in W|`;
with `N` workspaces of similar size, roughly `N×`, and it grows with the
number of workspaces rather than with the answer. `RECORD-T-0026`
measured the same mechanism on the all-unbound shape: 169,055 candidates
for 4,122 answers.

**Why the stamp would not have answered it either**, for the record:
there is no index on two predicates' `(P,O)` pairs, so
`?r ws:definedIn W . ?r a risk:Risk` is a join whose cheaper side is
`|entities in W|` or `|Risks store-wide|` — one index probe per row,
random access — and its best case is bounded by the *whole workspace*,
never by the answer. Only a composite prefix answers the question, and
the named graph plus a graph-first order is that prefix.

## What RECORD-A-0004 reserved, and how it needs sharpening

The ADR's escape hatch is "a per-graph sorted `[]FactID` posting list —
1.6 MB total, since every fact is in exactly one graph — never three more
full permutations." Sorted **by fact id**, such a list answers `(G)` alone
— `GRAPH <W> { ?s ?p ?o }`, `T-0026`'s shape — and not the consumer's
`(G, P, O)`: intersecting it with a `POSG` window is a merge of two lists
in different orders. The consumer's shape needs the list in **POS order
within each graph**, and per-graph POS-ordered lists laid end to end
*are* the `GPOS` permutation. So the escape hatch, made concrete for this
shape, is **one more `Order`**, not a new structure:

```
GPOS   key {.G, .P, .O, .S}
```

Building it as a seventh order reuses everything: `order_key`
(`permute.odin:44`), the radix build `store_build_permutations`
(`permute.odin:141`), the `[Order][]Fact_ID` arrays in the resident store
and every `Index_Set` (`resident.odin:194`, `snapshot.odin:81`), and the
`for o in Order` loops in `apply.odin:433`, `permute.odin:168`,
`resident.odin:244`, `snapshot.odin:131,282`. `order_key`'s switch is
exhaustive, so the compiler names every site that must learn the new
member — the failure mode `RECORD-I-0004` already used for `.Triple`.

It is **not** three graph-first orders (`architecture.md` §9's family),
which the ADR rejected and which this task does not reopen: `(G, S, …)`
stays on the `SPO` family with `G` residual, because one entity's facts
are selective enough that the residual compare is noise.

### What GPOS answers

| bound | order today | order after | window |
| --- | --- | --- | --- |
| G, P, O | POSG, residual G | **GPOS**, k=3 | exactly the answer |
| G, P | PSOG, residual G | **GPOS**, k=2 | exactly the answer |
| G | SPOG full scan, residual G (`T-0026`) | **GPOS**, k=1 | exactly the graph |
| G, O (no P) | OSPG, residual G | unchanged | — |
| G with S | SPO family, residual G | unchanged | — |
| no G | unchanged | unchanged | — |

Two properties that come free:

- **A `GPOS` window within a `(G, P, O)` prefix ascends in S** — the same
  order a `POSG` window within `(P, O)` has — so odin-rdf-sparql's merge
  join on `?r` (`SPARQL-T-0029`, on `snapshot_match_as`) composes with it
  and `range_len` on that window is the **exact** count of Risks in `W`,
  which is what its connected-first/cheapest planner prices with.
- **The default graph is stored as `G = 0`** and so sorts *first* in
  `GPOS`; the named graphs are the tail. `T-0026`'s second half — `GRAPH
  ?g` ranges over the *named* graphs and this store had no way to end a
  scan at the default graph — gets a cheap answer from the same order,
  if anyone asks: start after `G = 0`'s range.

### Graph sets

`Filter.graphs` arrives at `range_iter`, after the order is chosen, so
the store cannot turn a set into `k` prefix seeks by itself. A consumer
holding `{W} ∪ ancestors(W)` issues `k` calls of
`snapshot_match(Pattern{g, p, o})`, one per graph, each yielding exactly
its answer and an exact `range_len` — no API change needed. A
`snapshot_match_graphs(snap, p, graphs)` returning `k` ranges is the
obvious convenience and is **deferred until a consumer asks**; `k` seeks
against one `POSG` window plus a residual set is a choice `range_len`
already lets the caller make.

## What it costs

- **Memory**: 4 B per fact — 1.6 MB at 4×10⁵; permutations 9.6 → 11.2 MB.
  At the vision's ~200 processes per machine, +1.6 MB each.
- **Rebuild**: the radix build is per order, 39 ms for six
  (`RECORD-T-0008`) → roughly +6.5 ms on every boot and every wake.
- **Per commit**: one more 1.6 MB flat copy-on-write (`RECORD-A-0005`;
  31–35 ms measured for six at 4×10⁵ facts, `RECORD-I-0003`) until the
  delta structure lands.
- **`choose_order`**: the rule "G never enters the choice" gains one case
  — `G` leads when it is bound, `S` is not, and `O` is not bound without
  `P`. `pattern_component` must map `MATCH_DEFAULT_GRAPH` to the stored
  `0` for the prefix search, as `range_iter` already does for the
  residual (`read.odin:154`).
- **Format: untouched.** Permutations are resident-only, built at
  replay. No version bump, no migration, no frozen decision, both
  verifiers unaffected. This is the kind of decision `RECORD-A-0004` can
  revisit, and its review trigger — *"graph-bound queries where the bound
  graph is a small fraction of the store"* — describes a workspace by
  construction.

## Acceptance Criteria

**[REQUIRED]**

- [x] `Order.GPOS` with key `{.G, .P, .O, .S}`, built by
      `store_build_permutations`, present in every `Index_Set`, and
      every `for o in Order` site handling it (the compiler enforces
      this).
- [x] `choose_order` selects `GPOS` for `{G}`, `{G,P}`, `{G,P,O}` and is
      **unchanged** for every pattern with `S` bound, with `{G,O}`, and
      with `G` unbound — pinned by a test over the full bound-set table.
- [x] A test with two named graphs and the default graph: for
      `Pattern{g = W, p = rdf:type, o = risk:Risk}`,
      `range_len(snapshot_match(...)) == |matching facts in W|` — over-scan
      1×, where today it equals the store-wide count.
- [x] `MATCH_DEFAULT_GRAPH` works as a `GPOS` prefix (stored `0`), and
      `Pattern.g` bound plus `Filter.graphs` still intersect in
      `scan_next`.
- [x] A `snapshot_match_as(.GPOS)` window for a `(G,P,O)` pattern ascends
      in S — a test, since odin-rdf-sparql's merge join will rely on it.
- [x] Measured and recorded in Status: rebuild time, resident size, and
      one-commit time at 4×10⁵ facts, before and after; the vision's
      Current State and the README's numbers re-read and amended where
      the seventh order moves them.
- [x] `RECORD-A-0004` **amended, not rewritten**: a dated note under the
      decision recording that the posting-list escape hatch was spent as
      one graph-first order for the `(G, P, O)` shape, on this consumer's
      request; the "no graph-first permutations" sentence stands as the
      record with the note beside it. `api.md` §5.1 and §12.2's order
      table amended the same way; the "six" in `permute.odin`'s,
      `resident.odin`'s and `snapshot.odin`'s comments corrected.
- [x] `make test` and `make check` green; both verifiers agree over the
      fault corpus (they should be untouched — the format did not move).

## Implementation Notes

### Dependencies

- None on the format or on any sibling. `RECORD-T-0026` is the measured
  cost this answers for the `(G)` shape; it stays filed as the record of
  the measurement.
- **`RECORD-T-0029` goes first** (filed the same day): `Filter.graphs`
  carries scoped-versus-unscoped in the slice's data pointer, and some
  empty slices are nil in Odin and some are not, so a consumer that
  computes an empty descendant set can read the **whole store** by
  allocation history. That is correctness rather than cost; the fix is
  a stated `Graph_Scope` like `Origin`, and this task's graph-set
  paragraph above should be written against the fixed `Filter`.

### Consumers

- odin-rdf-sparql: `SPARQL-T-0044` (the application's graph set on
  `query_init`) needs nothing from this task; its planner's `range_len`
  costing (`plan.odin:2115`) becomes exact per graph once this lands.
- odin-rdf-shacl: `SHACL-T-0039` (validating the union of a set) needs
  nothing from this task either; its single-graph reads become prefix
  reads for free.

## Status Updates **[REQUIRED]**

- **2026-08-26 — Filed** from the workspace design discussion with the
  owner, on the stated requirement that "which `risk:Risk` are in
  workspace W" must not scan every Risk in the store. The analysis of
  named-graph-per-workspace against entity stamping, and the sizing of
  the sibling changes, are in this task and its two siblings
  (`SPARQL-T-0044`, `SHACL-T-0039`). Not started; the owner's call on
  when.
- **2026-08-27 — Active. Plan**, before code. `permute.odin`: `Order.GPOS`,
  key `{.G, .P, .O, .S}`; the radix build already iterates `Order` and
  `order_key`, so it needs nothing. `read.odin`: `choose_order` gains
  the one G-led case (bound G, S unbound, O not bound without P) placed
  *after* the S cases and *before* the P/O ones; `pattern_component`
  returns the pattern's G as spelled so the prefix loop's "0 is unbound"
  test still holds, and `snapshot_match_as` maps `MATCH_DEFAULT_GRAPH`
  to the stored `0` as it enters `want`; the prefix widens from 3 to 4,
  since a named `GPOS` can now carry every component. `permute_test`'s
  exact corpus gets its hand-computed `GPOS` row; the order-selection
  test gets the G-led rows; a new `test_read_graph_prefix` builds a
  two-workspace corpus through the writer and replay and asserts the
  1× windows, the S-ascending walk, the default graph as a prefix, the
  unchanged S-bound and (G,O) choices, `snapshot_match_as(.POSG)`
  agreeing on the answer with a 3× window, and `Pattern.g ∩
  Filter.graphs`. Comments that state "six" as a fact about the type
  surface are corrected; `api.md` §5, §5.1 and §12.2 and `RECORD-A-0004`
  get dated notes, old text standing. Then `make test` for the scale
  numbers against yesterday's run (sort 45 ms, permutations 9.2 MB of
  21.2, commit 34.5/35.9/42.1 ms, boot 221/301 ms).
- **2026-08-27 — Done; unreleased on `main`.** Built as planned, with
  one refinement the plan named and the code needed: the prefix widens
  from three components to four, because a planner naming `GPOS` for a
  fully bound pattern now has a four-deep prefix. `make check` clean;
  80 record tests (79 + `test_read_graph_prefix`), `make test` green
  end to end, both verifiers untouched — the format did not move.

  **Measured, same machine, against yesterday's run** (`tests/scale`,
  ISMS-shaped corpus, 4×10⁵ ops):

  | | six orders (2026-08-26) | seven (2026-08-27) | delta |
  | --- | --- | --- | --- |
  | permutation sort, 340,145 facts | 45 ms | 57 ms | +12 ms |
  | boot phase "permutation sort" | 44 / 43 ms | 51 / 52 ms | +8 ms |
  | boot, bulk-loaded / hand-edited | 221 / 301 ms | 237 / 309 ms | +16 / +8 ms |
  | resident after bulk apply, 4×10⁵ facts | 21.2 MB (perms 9.2) | 22.7 MB (perms 10.7) | +1.5 MB = 4 B × facts |
  | resident at boot, 340,145 facts | 20.0 MB (perms 7.8) | 21.3 MB (perms 9.1) | +1.3 MB |
  | one commit at 4×10⁵ facts, min / mean / max | 34.5 / 35.9 / 42.1 ms | 37.6 / 41.1 / 48.0 ms | +3 / +5 / +6 ms |
  | verify / replay (log-level, unaffected) | 53 / 57 · 88 / 100 ms | 58 / 62 · 97 / 101 ms | noise |

  Every delta is the one the task priced: one more 4-byte-per-fact
  array, one more radix pass set on boot and wake, one more flat
  copy-on-write per commit until `RECORD-A-0005`'s delta structure
  lands. The G column is small dictionary ids, so its high-16-bit pass
  is skipped, which is why the seventh sort costs less than a sixth of
  the six.

  **What the consumer's shape costs now**, from `test_read_graph_prefix`
  (two workspaces of 4 and 3 facts, one default-graph fact): `{g = W,
  p = rdf:type, o = Risk}` opens a window of exactly 2 where `(P, O)`
  alone opens 6; `{g = W}` is 4; `{g = W, p}` is 3; the default graph
  as `MATCH_DEFAULT_GRAPH` is a prefix of 1; `{g = W, o}` stays `OSPG`
  with a 6-wide window filtered residually; `{s, g}` stays `SPOG`; and a
  planner naming `POSG` for the same pattern gets the same answer from
  the 3× window. `RECORD-T-0026`'s `GRAPH <g> { ?s ?p ?o }` is the
  `(G)` row of the same table and is a prefix now too.

  **Not done here, deliberately**: a tag. The seventh order is on
  `main` and unreleased; whether it is `v0.6.0` alone or waits for
  `SPARQL-T-0044` / `SHACL-T-0039` is the owner's call. Both engines
  call `snapshot_match`, so once either pins a release that includes
  this, their graph-bound patterns are prefix reads with no source
  change — odin-rdf-sparql's `graph` benchmark case
  (`RECORD-T-0026`'s 169,055 candidates for 4,122 answers) becomes
  4,122 for 4,122.
- **2026-08-27 — Tagged `v0.6.0` at `4bf700c` and walked, the same day.**
  odin-rdf-sparql (`SPARQL-T-0046`) and odin-rdf-shacl (`SHACL-T-0041`)
  pinned it with **no source change in either** — both call
  `snapshot_match`. The consumer-side measurement is sparql's `make
  bench`, whose `candidates` pins are asserted: **8 moved, all
  downward, every solution count identical** — `graph` from 20,617 /
  169,055 to **4,122 / 4,122**, exactly the answer at both sizes, and
  **0.064 / 0.065 ms** where it was 0.078 / 0.244 — flat across a 10×
  store as the old store was, and faster than it; `optional`, `order`
  and `order-limit` each narrower by exactly the named graph's 500
  facts, because a default-graph pattern's `(G, P, O)` window no longer
  holds the named graph's facts to filter out. sparql's
  `merge_order_for` sees the seventh order and selects it when G and P
  are ground and the join is on O — correct and narrower; the
  `(G,P,O)`-ground join on S at depth 3 is left for a measured change
  there.