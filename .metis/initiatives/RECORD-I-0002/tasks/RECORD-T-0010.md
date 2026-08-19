---
id: the-read-api-match-iter-resolve
level: task
title: "The read API: Match, Iter, Resolve, Bytes, Term"
short_code: "RECORD-T-0010"
created_at: 2026-08-19T20:10:43.745002+00:00
updated_at: 2026-08-19T23:29:37.114904+00:00
parent: RECORD-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: RECORD-I-0002
---

# The read API: Match, Iter, Resolve, Bytes, Term

## Parent Initiative

[[RECORD-I-0002]]

## Objective

The pattern-matching read surface of api.md §12, layers 0–2, on a
snapshot: `Match(Pattern)` choosing a permutation and answering as one
prefix range; `Iter` streaming facts through the filter set (origin,
graph set, and the snapshot's live-at-epoch predicate — `G` is always
residual, RECORD-A-0004); `Resolve(term)` with the cheap miss; and term
materialization, `Bytes(id)` as an arena view with no copy and
`Term(id)` through the codec RECORD-T-0005 built with exactly this
consumer named. This is the surface odin-rdf-sparql and odin-rdf-shacl
eventually target, so its contracts are documented at the standard the
family's match interface set.

## Acceptance Criteria

- [x] Every bound/wildcard shape of (S, P, O) selects the permutation
      api.md §12.2 prescribes and answers as one binary-searched prefix
      range; a bound `G` is always a residual comparison, never a prefix.
- [x] `Iter` streams — no result materialization — through
      `Filter{origin, graphs}` composed with the snapshot's epoch
      predicate; concrete types, so the hot path is a bounds check, a
      load, and compares (api.md's stated shape).
- [x] `Resolve(term)` interns nothing: the canonical encoding of the
      probe is built caller-side or in scratch, the miss is cheap (the
      404 fast-reject of api.md §12.2), and a hit returns the resident
      id.
- [x] `Bytes(id)` returns the arena view, zero-copy, lifetime documented
      against the snapshot; `Term(id)` materializes through
      `record/term.odin` for both dictionary and inlined ids, and the
      two agree with what the writer interned, byte for byte.
- [x] Conformance: every pattern shape × several epochs × filter
      combinations against a brute-force scan oracle over the fact
      table, on both the crafted test log (inlined components, named and
      default graphs, retracted generations) and the ISMS-scale log
      (sampled patterns).
- [x] Contract-level doc comments on every public procedure — the
      family's standard.
- [x] `make check` and `make test` green.

## Implementation Notes

### Technical Approach

Prefix ranges are two binary searches per bound prefix over one
permutation; everything after the prefix is the iterator's residual
predicate. `EntityHistory` and the attribution queries (api.md §12.6)
are deliberately NOT here — the initiative's Detailed Design leaves them
a decompose-time call, and the epoch table T-0007 builds is sufficient
for them to be added as a small follow-on task if wanted.

### Dependencies

RECORD-T-0008 (permutations) and RECORD-T-0009 (the snapshot the API
hangs off).

### Risk Considerations

The oracle is the defense against the classic prefix-range bugs
(off-by-one at range ends, a residual filter applied to the wrong
position). The oracle must share nothing with the implementation but
the fact table itself.

## Status Updates **[REQUIRED]**

### 2026-08-20 — implemented; `make check` and `make test` green; NOT committed (session instruction)

**Where the code went.** `record/read.odin` + `read_test.odin`, plus
the ISMS sampled-pattern oracle appended to
`tests/scale/scale_test.odin`. The surface: `Pattern`, `Origin` (no
zero default — api.md §12.5's rule, enforced by `range_iter`'s
assert), `Filter{origin, graphs}`, `Range` (window + order +
residual), `snapshot_match` / `snapshot_match_as` / `range_len` /
`range_iter` / `scan_next`, and `snapshot_resolve` /
`snapshot_bytes` / `snapshot_term`. Naming follows the receiver rule
throughout.

**A discovered divergence, amended into api.md §12.2.** "Pattern ID 0
is unbound" was written when the default graph's sentinel was 1; the
T-0005 amendment moved the sentinel to 0, colliding "unbound" with
"the default graph" in the G position. Resolution:
`MATCH_DEFAULT_GRAPH :: 0x8000_0000` — the bit pattern §3 reserves as
invalid in term space (inline flag, tag zero), so it can never name a
term — binds G to the default graph; 0 stays unbound everywhere, and
the zero-value Pattern matches everything. `Filter.graphs` holds
stored G components (0 = default graph, unambiguous there;
MATCH_DEFAULT_GRAPH also accepted).

**Decisions recorded:**

- **`match_as` is total**: any order answers any pattern — bound
  components leading the order's key become the prefix, everything
  else is residual — so the planner can demand any sort order without
  a capability check. The residual re-checks the full pattern (prefix
  components pass trivially; cheaper than tracking coverage).
- **G never enters a prefix** even when S, P, O, and G are all bound —
  RECORD-A-0004's rule kept absolute rather than special-cased for the
  fully-bound shape; the residual comparison there costs nothing
  measurable.
- **`Range` carries the permanently-empty `delta` field** —
  RECORD-A-0005's two-run shape promise — with `range_iter` asserting
  it empty as the tripwire for Apply's delta work.
- **Resolve's inline path implements all three frozen tags**
  (integer, boolean, date), not just the writer's integer: replay
  accepts foreign logs carrying inlined booleans/dates, so Match must
  find them. Canonical forms only (architecture.md §3.4's stance):
  "+5", "05", "-0" fall through to the dictionary; "2023-02-30" is
  refused by round-tripping through the codec's own civil-date
  conversion (days_from_civil added as its inverse), and an ill-typed
  date literal is still resolvable if interned. `res_inline_disk` is
  the resident→disk re-tag inverse, feeding the codec's inline_term.
- **Resolve probes the full-IRI encoding only** — a store interning
  split IRIs (tag 0x06; no writer today) would need the split probe
  added when interning exists (next initiative's concern).
- **Range/Scan borrow the snapshot** (no refcount of their own),
  documented; Bytes views live as long as the store.

**Tests.** The crafted log (writer → replay → Loader → permutations →
publish; every term shape, named + default graphs, derived ops, a
retract/re-assert pair): 16 pattern shapes × 5 epochs × 3 origins × 4
graph sets = 960 oracle comparisons against a brute-force fact-table
scan sharing nothing with the implementation, plus one head live-set
pinned by hand. Order selection per §12.2's table; match_as × all six
orders agreeing; range_len as generation count. Resolve: hits for
every stored shape (case-insensitive language tags), inline
fast-path exact ids, six miss shapes, and the n_terms bound (a term
interned post-publication is a miss for the snapshot). Bytes/Term:
Resolve∘Term = identity over every dictionary id and the inline
space — injectivity end to end. At ISMS scale: 32 sampled-pattern
oracle checks over 340k facts at head and mid-history epochs.
50 record tests (+4); `make check` and `make test` green.

Committed and completed after review, same session. One optimization
conversation recorded for the future: Match costs two ~19-probe binary
searches at ISMS scale (~2–4 µs); the session's decision is to wait —
the trigger is a join engine landing on this store, not before. The
levers, in payoff order: bracket the upper-bound search inside the
lower (one line, ~25%); a dense run table `start[v]` per order
directly indexed by the leading component's id (~2 MB for six orders,
and it falls out of the radix sort's histograms for free — the
counting pass's prefix sums are the run starts); key columns were
priced and rejected (~32 MB, blows api.md §10's budget).