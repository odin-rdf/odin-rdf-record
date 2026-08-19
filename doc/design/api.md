# The resident store: in-memory representation and tenant density

**Status:** first draft, third companion to [`architecture.md`](architecture.md)
and [`log.md`](log.md). Those two specify what a store *is* — the data model, the
epoch semantics, the canonical term encoding — and what it *durably is* — the
segmented, hash-chained log of record. This document specifies what a store *is
while running*: the exact layout of the resident structures, the widths of their
fields, and what a single tenant costs in RAM.

It exists because of a constraint neither of the others was written under.
`architecture.md` §Scale sizes the whole store at ~30 MB and concludes, correctly
for its premise, that nothing about the in-memory layout is worth thinking hard
about. That premise was one store on one machine. The deployment premise is
different: **many tenant processes per physical machine, each with an embedded
store, with RAM as the only resource that runs out.** Disk I/O stopped being a
bottleneck when the indices moved into memory; per-tenant RAM is what converts
directly into servers per customer.

That does not make this a memory-at-all-costs document. Two standing constraints
apply to everything below and several proposals are rejected against them: no
considerable increase in code complexity, and no considerable impact on read
performance. The gains here are worth having because they are close to free, not
because they are large enough to buy with complexity.

Section 12 specifies the pattern-matching API over that layout. Section 13 is the
first application written against it — a graph explorer — and is kept here rather
than in an application document because what it found changed the API.

---

## 1. The cost model

The unit of cost is not "a store". Idle tenants are evicted — the HTTP server
stays up to serve page and login requests, and the resident store is dropped and
rebuilt from the log on the next query, which §8 of `log.md` budgets at well under
a second. So a machine holds two populations:

```
RAM  =  (idle tenants × process floor)  +  (active tenants × (floor + store))
```

The *process floor* is a Go process running the application with no store
resident: runtime, HTTP stack, TLS, session state, goroutine stacks. Call it
15 MB pending measurement — it is the one number in this document that only the
application can supply.

Taking 500 tenants per machine, a 15 MB floor, and the two store budgets derived
in §10:

| Active fraction | Untuned (~138 MB store) | Tuned (~30 MB store) | Saving |
|---|---|---|---|
| 5% | 11.0 GB | 8.3 GB | 25% |
| 10% | 14.4 GB | 9.0 GB | 37% |
| 25% | 24.8 GB | 11.3 GB | 55% |
| 50% | 42.0 GB | 15.0 GB | 64% |

**The conclusion that should govern effort:** at a low active fraction, the idle
floor dominates. In the tuned 10% row, 6.8 of 9.0 GB — 75% — is tenants doing
nothing. Halving the store again from there would buy 12%; halving the floor
would buy 37%.

So the sequence is: tune the store until it stops being the largest term, then
stop and go measure the floor. Everything in §§2–7 is worth doing because it is
cheap. None of it is worth doing twice.

---

## 2. The fact table

`architecture.md` §Scale gives a `Fact` struct and immediately disclaims it as
"the shape, not the concurrency-safe form". It is also now stale: it predates
`log.md` §5.3, which made the graph component mandatory and added a derived-origin
flag to every operation. Adding both naively produces a 56-byte struct — four
8-byte IDs, two 8-byte epochs, and a `bool` that costs 8 bytes because of what
follows it.

The specified form is 24 bytes:

```go
type ID uint32     // term ID; bit 31 set means inlined (§3)
type FactID uint32 // index into the fact table; positional, permanent
type Epoch uint32  // liveEpoch = 0xFFFFFFFF means "still live"

// Fact is the single canonical record. Facts are appended and never reordered or
// removed, so a fact's index is a stable, permanent, citable identifier — the
// same identifier log.md §5.3 assigns positionally in the log.
type Fact struct {
	S, P, O, G ID    // 16 bytes
	Assert     Epoch //  4 bytes — never mutated after construction
	Retract    Epoch //  4 bytes — the only mutated field; see §2.3
}                    // 24 bytes, 4-byte aligned, no padding
```

```packet
caption: Fact — 24 bytes resident, one per version of one quad
row: 8
0,4:   S | term ID, u32
4,4:   P | term ID
8,4:   O | term ID
12,4:  G | term ID; graph is mandatory per log.md §5.3
16,4:  Assert | epoch; immutable
20,4:  !Retract | epoch; atomic, liveEpoch while live
```

### 2.1 Why 32-bit epochs

`u32` gives 4.3×10⁹ epochs. `log.md` §9's pessimistic case — every fact written by
a separate hand edit — is 2×10⁵, a margin of 20,000×; at a sustained ten commits
per second it is thirteen years. The design has one writer goroutine and
human-paced CRUD, so there is no mechanism by which the count runs away.

This one is free in every direction. It costs a type alias, it removes 8 bytes per
fact, and §6.6's atomicity requirement is met by `atomic.LoadUint32` exactly as
well as by the 64-bit pair.

`liveEpoch` is `0xFFFFFFFF` rather than `math.MaxUint64`. Visibility is unchanged:
`f.Assert <= e && e < f.Retract`.

### 2.2 Where the derived flag went

`log.md` §5.3 puts origin in the high nibble of the op byte, and `Replay` sets a
`Derived` field per fact. As a struct field that is one bit costing eight bytes,
because 24 is already a clean multiple of the 4-byte alignment and any added field
rounds the struct up.

It becomes a parallel bitset — `[]uint64`, one bit per `FactID`, 50 KB for the
whole table:

```go
func (s *Store) derived(id FactID) bool {
	return s.derivedBits[id>>6]&(1<<(id&63)) != 0
}
```

This is not just smaller, it is in the right place. Origin is consulted when a
result is materialized and an auditor is told where a fact came from
(`architecture.md` A.5); it is never consulted in the visibility test that runs
over every candidate in every scan. Keeping it out of `Fact` keeps the hot loop's
cache lines full of things the hot loop reads.

The alternative — stealing bit 31 of `Assert` — was rejected. It puts a mask on
the hottest comparison in the system to save 50 KB.

### 2.3 Chunking, and the one mutable field

`architecture.md` §6.6 requires the fact table to be `[][]Fact` with fixed-size
chunks rather than one growing slice, so that `append` can never relocate a record
a reader is holding. That section makes the case and does not pick a number.
**8192 facts per chunk**: 192 KB per chunk, 49 chunks at 4×10⁵ facts, and with a
power of two the decomposition is two instructions.

```go
const (
	chunkBits = 13
	chunkSize = 1 << chunkBits
	chunkMask = chunkSize - 1
)

func (s *Store) fact(id FactID) *Fact {
	return &s.chunks[id>>chunkBits][id&chunkMask]
}
```

`Retract` is the only field ever written after construction, and it is written
with `atomic.StoreUint32` and read with `atomic.LoadUint32`. §6.6 establishes why
no lock is needed: a retraction recorded after a reader fixed epoch `e` always
carries `Retract > e`, so a reader that misses it computes the same answer. The
atomic is there to keep the Go memory model happy, not to establish correctness.

### 2.4 The epoch table

A `Fact` carries two epoch numbers and nothing else. That is enough to say *when*
in the commit order something changed, and nothing at all about *who* changed it
or *why* — which is most of what a history is for (§12.6).

The information exists; it is simply not resident. `log.md` §5.1 records `wall`,
`actor`, and `reason` on every epoch commit, and `actor`/`reason` are term IDs
precisely so the why of a change is itself RDF and queryable
(`architecture.md` §6.4). Replay reads those records already and then discards
three of their fields.

```go
// EpochMeta is one entry per committed epoch, indexed by epoch number. Built
// during replay from records already being read; nothing on disk changes.
type EpochMeta struct {
	Wall   int64 // 8 — Unix nanoseconds UTC, log.md §5.1
	Actor  ID    // 4 — term; 0 if none
	Reason ID    // 4 — term; 0 if none
}                // 16 bytes
```

| Epoch count | Table |
|---|---|
| 10³, bulk-loaded | 16 KB |
| 2×10⁵, fully hand-edited (`log.md` §9) | 3.2 MB |

Pointer-free, dense, and append-only, so it is chunked and published inside the
index set for the same reason everything else is (§12.1).

Three notes that matter more than the size:

- **Attribution is per epoch, not per fact.** Every op in one commit shares one
  actor. That is usually correct — a transaction *is* one agent's action — but it
  means a bulk import cannot attribute individual corrections inside it to
  different people. Those have to be separate epochs.
- **`actor` may be 0.** The format permits an unattributed change. For a system of
  record that is a gap, and it should be closed at the writer — refuse to commit
  without an actor — rather than in the format, which is right to stay permissive.
- **`Wall` is evidence; the epoch is proof.** `log.md` §12 question 5 leaves this
  open: `wall` comes from the writer's clock, which anyone with host access can
  move, while epoch order is monotonic and hash-chained regardless. A history view
  should present them as what they are rather than as one timestamp.

---

## 3. Term IDs and inlining

Reducing `ID` from 64 to 32 bits is the only narrowing in this document with a
real cost, and it is worth being precise about where the cost is — because it is
not where it looks.

**Cardinality is not the constraint.** There are ~10⁵ distinct terms against a
`u32` ceiling of 4.3×10⁹, a margin of 40,000×. The format has already made this
bet in the more aggressive direction: `log.md` §3 and §5.4 both store *fact* IDs
as `u32` "to match `FactID`", and there are four times more facts than terms.

**Inlining is the constraint.** `architecture.md` §3.4 spends the top of the ID
space on carrying small literals without a dictionary entry: bit 63 flags inline,
bits 62–56 tag the type, and 56 bits hold the payload. Halving the ID halves that
budget.

The 32-bit scheme:

```
bit 31      = 1  -> inlined term, no dictionary entry exists
bits 30-28  = inline type tag (1..7; 0 is reserved and invalid)
bits 27-0   = payload, offset-binary within each type
```

| Tag | Type | Payload | Status |
|---|---|---|---|
| `0` | — | — | reserved; **rejected on decode** |
| `1` | `xsd:boolean` | 1 bit | declared in `architecture.md` §3.4, not implemented |
| `2` | `xsd:integer` | ±1.34×10⁸ at 28 bits | the only case `inlineEncode` implements |
| `3` | `xsd:date`, days since 1970 | ~23 bits signed, years 1–9999 | declared in `architecture.md` §3.4, not implemented |
| `4`–`7` | — | — | unassigned |

Tag `0` is reserved rather than assigned so that the bit pattern `0x80000000` —
inline flag set, tag zero, zero payload — decodes as invalid rather than as a
plausible term. It is the cheapest available check that a `u32` being treated as
an ID actually is one.

**Why the type must live in the ID at all**, since it is a recurring question: an
inlined term has no dictionary entry, so the ID is the term's entire
representation and must be self-describing. Bit 31 alone says "no dictionary entry
exists"; it does not say what the remaining 31 bits mean, and payload `1` is
`true`, `1`, and `1970-01-02` simultaneously — three distinct RDF terms collapsed
onto one ID, which breaks `architecture.md` §3.2's injectivity outright and
therefore breaks join
equality.

The type cannot be recovered from context either. RDF predicates do not constrain
their objects' datatypes; SHACL validates a graph rather than defining its
representation, and a graph that violates its shapes is exactly the graph you most
need to store faithfully; and OWL range axioms are entailments — a licence to
conclude, not a guarantee about bytes. The ontology is also *data in the store*
(`architecture.md` A.2), versioned and per-tenant, so consulting it to decode an ID
would make loading circular.

Seen correctly the tag bits are not overhead. `architecture.md` §3.2's canonical
encoding already
carries the type for a dictionary-resident literal, as a tag byte plus a full
datatype-IRI reference. **Inlining moves that encoding into the ID**, and the
three tag bits are that tag byte and that datatype reference compressed by
enumerating the handful of types worth the special case.

### 3.1 Why three tag bits and not two

Three declared types fit in two bits, and the extra bit is not free: it costs one
bit of integer payload, halving the ceiling from ±2.68×10⁸ to ±1.34×10⁸.

Three bits are taken anyway, because the pressure on this scheme runs in one
direction. Every plausible evolution *adds* a type — `xsd:dateTime` has no tag and
is the obvious next one — and adding a type past four values means widening the
tag, which narrows the payload. Per §3.3 that is the change this design cannot
absorb cheaply. Two bits leaves one spare slot; three leaves five, and buys the
freedom to never have to make the move.

### 3.2 What the narrowing actually costs

The integer ceiling drops from ±3.6×10¹⁶ to ±1.34×10⁸. Values beyond it fall back
to the dictionary, which `architecture.md` §3.4 already specifies as the graceful
path, so nothing breaks — a large integer becomes a normal interned term.
`xsd:integer` is arbitrary-precision in RDF, so a fallback path was always
required; narrowing moves the threshold rather than introducing the behaviour.

**The cost is ~48 bytes per *distinct* overflow value** — the canonical encoding
in the dictionary blob, a 4-byte offset, and a map entry — not per fact. A million
facts citing the same large integer cost one entry. 64-bit IDs cost 16 bytes per fact
more than 32-bit — 6.4 MB per tenant — so break-even is roughly **133,000
distinct integers above the ceiling**. Against 40-bit IDs, which cost 4 bytes per
fact more, it is about 33,000.

What also degrades is §5.1's order-preserving property. Because the flag and tag
bits are constant within a type class and the payload is offset-binary, inlined
integers sort numerically inside the index, and `FILTER(?age > 30)` becomes a
range scan rather than a scan-and-filter. That property survives narrowing, but it
only holds over the inlined range: a filter spanning the boundary mixes inlined
and dictionary-resident integers and cannot be answered by a range scan at all.
The same hazard exists at 56 bits; the difference is that at 2⁵⁵ it never arises
and at 2²⁷ it might.

**The reason to accept this is that `architecture.md` §Scale already discarded the
payoff.** That section skips the §5.2 side value index outright — "at 4×10⁵ facts,
scan and filter" — and prices a full index scan at ~10 ms. The 56-bit payload is
spending 16 bytes per fact to turn a 10 ms scan into a range seek. That was a good
trade at the 10⁷–10⁹ premise §Scale deleted, and it is a poor one now.

#### Monetary amounts

The obvious candidate for overflow, and it does not bind here.

**Amounts are whole currency units — `$10`, never `$10.00`.** The ceiling is
therefore 134,217,727 currency units, not the 1.34 million it would be if amounts
were stored as minor units. Nothing in the compliance domain routinely carries a
single scalar above 134 million.

Two consequences follow, and both simplify the scheme:

- **No scaled-decimal tag is needed.** A dedicated tag would not have raised the
  ceiling in any case — the payload is 28 bits whichever type owns it. Its only
  benefit would have been to let `xsd:decimal` inline at all, which
  `architecture.md` §3.4 currently forbids, and with no fractional amounts in
  the data there is nothing to inline.
- **Currency is free.** Money is not a number — €100 and $100 differ — so an
  amount is a structured node carrying a value and a currency IRI, or equivalent.
  The currency is an ordinary term interned once and shared by every amount in the
  store: one dictionary entry, permanently.

If fractional amounts ever do arrive, the trap to avoid is treating a decimal tag
as a fixed-scale integer. RDF literal identity is **lexical**:
`"1234.56"^^xsd:decimal` and `"1234.560"^^xsd:decimal` are equal in value and are
*distinct RDF terms*. An encoding that maps both to one ID breaks injectivity.
Encoding the scale alongside the significand fixes it and is ruinous — 4 bits of
scale leaves ±8.4×10⁶. The workable form is the one `architecture.md` §3.4 already
uses when it
refuses `"034"` and `"+34"`: inline only one canonical lexical shape and let every
other form intern.

A modelling note with a storage consequence: a datatype IRI per currency —
`"1234"^^ex:EUR` — cannot inline under any ID width, because the tag space
enumerates types statically in three bits. Prefer a structured node with a plain
`xsd:integer` value.

#### The gate before committing to 32 bits

Count the **distinct** `xsd:integer` terms above 1.34×10⁸ in real tenant data and
multiply by 48 bytes. Compare against 6.4 MB, which is what 64-bit IDs cost per
tenant. The check exists because §3.3 makes this decision expensive to revisit,
not because the outcome is in doubt.

Measure distinct values, not occurrences, and not existence. A single large
contract value is not a reason to widen every ID in the store.

If it ever does bind, the escalation order is: a dedicated tag for the offending
type; then a prefix code giving `xsd:integer` a 1-bit tag and 30 bits of payload
(±5.4×10⁸), which keeps `ID` a native `uint32` and costs branchier decode rather
than bytes per fact; then 64-bit IDs. 40-bit IDs are not on the list — see §9.

### 3.3 The inline predicate is frozen at first write

`log.md` §5.2 assigns dictionary IDs in first-appearance order and has the
replayer count them out, which is what makes resident dictionary ID *N* the same
as log dictionary ID *N* with no translation table. That identity holds only while
the set of terms receiving dictionary entries stays fixed — and **the inline
predicate is exactly what determines that set.**

So changing the predicate after data exists is a breaking change in either
direction. Widen the payload and a value that was interned in old epochs is
inlined in new ones; narrow it and the reverse. Either way one term ends up with
two resident IDs, live simultaneously in the same store, and every join comparing
them silently returns nothing. This is the worst class of bug this design can
produce: no error, no corruption, a quietly wrong answer.

The repair is a log-ID → resident-ID translation table, ~400 KB and not much code,
but it is precisely the complexity the standing constraints exist to keep out.

**Therefore: fix the tag assignment and the payload widths now, before the first
record is written.** Reserving an unused tag value costs nothing; claiming one
later costs the table. This is the one decision in this document that is not
freely revisable at the next restart, and it is the reason §3.2's gate is worth an
afternoon.

### 3.4 The writer's inlining range, and what replay checks

There is a trap in the layering that is easy to miss, because `log.md` §5.2 says
inlined terms "never appear here" and that is easy to read as *the inline scheme
is purely in-memory*. It is not. §5.2 is talking about term *definitions*; §5.3's
fact operations carry `S`, `P`, `O`, `G` as term IDs, and when the object is `34`
that ID **is** the inlined encoding. The inline scheme is on disk.

Two rules follow, and 32-bit resident IDs are incorrect without both:

1. **The writer restricts `inlineEncode` to what the resident scheme can hold.**
   The format permits a 56-bit inline payload; our writer must not emit one. This
   is a one-line range test, and with it replay's translation from the 64-bit
   on-disk encoding to the 32-bit resident encoding is a pure re-tag that cannot
   fail.

   Without it, a legal, spec-conforming log record can contain an inlined value
   the resident store cannot represent — and it has no term definition to fall
   back on, precisely because it was inlined. Replay would have to synthesise a
   dictionary entry for a term the log never declared, which collides with §5.2's
   `id == dict.next()` self-check and needs a separate ID region to stay clear of
   it.

2. **`Replay` asserts that every dictionary term ID fits in `u32`**, and fails
   loudly if one does not. Cheap, and it sits exactly at the boundary where the
   derived representation makes its scale assumption — which is where an
   assumption belongs.

   *Amended 2026-08-19 (RECORD-T-0004): the implemented bound is 2³¹, not 2³².
   "Fits in `u32`" was this rule's shorthand, but §3's own encoding spends
   bit 31 on the inline flag, so the space a dictionary ID may occupy is bits
   0–30 and the sharper bound is the true one. Replay refuses at 2³¹
   (`Term_Overflow`); at the design scale of ~10⁵ terms the margin is still
   four orders of magnitude.*

### 3.5 The log stays 64-bit

`log.md` §5.2 and §5.3 encode term IDs as `u64` on disk. That should not change.

The asymmetry in cost is stark. `log.md` §10 rules out in-place migration: a
format version bump means new segments, and old segments stay readable at their
own version forever. Guessing too wide costs ~6 MB in a file the document already
declares too small to compress. Guessing too narrow costs a permanent dual-format
reader, in the one component whose value proposition is that a third party can
reimplement it in an afternoon.

This asymmetry is the design's own thesis applied consistently. The log is the
record and should be conservative; memory is a disposable projection and can be
re-tuned whenever the deployment changes, without anyone's permission and without
a migration.

The one qualification is §3.3: the *inline* portion of the ID space is shared
between the two representations, so it is not freely re-tunable even though the
width around it is.

---

## 4. The dictionary

`architecture.md` §Scale prices the dictionary at ~6 MB and describes it as "a
`map[string]ID` + `[]Term`". Those are not the same number, and the gap is the
second-largest item in the budget.

Built the idiomatic way, 10⁵ terms averaging 40 bytes cost far more than 4 MB of
term bytes: each term is a separate heap allocation rounded up to the 48-byte size
class; each `string` header is 16 bytes; the `[]Term` records carry their own
fields; and Go's map costs ~27 bytes per entry in bucket overhead and load factor.
Call it ~18 MB for 4 MB of information.

The specified form is an arena:

```go
type Dict struct {
	blob   [][]byte          // chunked; canonical encodings, back to back
	off    []uint32          // off[i] .. off[i+1] locates term i within blob
	byTerm map[string]ID     // keys are zero-copy views into blob
}
```

- **`blob`** holds each term's canonical encoding from `architecture.md` §3.2
  verbatim, concatenated. The dictionary is then a near-literal copy of the term
  definitions in the log, which is the right relationship between a record and a
  projection of it.
- **`off`** is 4 bytes per term. Decoding term *i* is two loads and a slice
  expression, with no pointer chase.
- **`byTerm`** is needed only on the write path — interning happens when a term is
  first seen. Its keys are built over `blob` with `unsafe.String`, so they cost no
  allocation and add no bytes beyond the map's own structure.

Total ~7 MB against ~18 MB, for one type's worth of contained code and no custom
hash table.

**`blob` must be chunked, for the same reason the fact table is.** If it were a
single growing `[]byte`, an append that reallocates would dangle every key in
`byTerm`. Chunks never move, so the invariant is "nothing is ever rewritten"
rather than a paragraph of reasoning that one careless later change invalidates.

### 4.1 The property that matters more than the bytes

A store built this way — `[]Fact` with no pointer fields, `[]FactID`
permutations, `[]uint32` offsets, `[][]byte` chunks — contains almost no pointers
for the garbage collector to trace. Go allocates such spans as `noscan` and skips
them entirely during mark.

At one store per machine this is invisible. At several hundred processes it is a
standing CPU cost across all of them, and removing it is worth as much as the
11 MB.

---

## 5. The permutations

Unchanged, and untouched by everything above: six sorted `[]FactID` slices,
4 bytes per fact per order, 9.6 MB at 4×10⁵ facts.

`architecture.md` §Scale's argument for taking all six — every sort order for
merge joins, every variable order for §7.4's worst-case-optimal joins — was made
on the grounds that six is free. Under the density premise six is not free, and
the argument has to be re-made rather than inherited. It survives: 4.8 MB is the
smallest item on the list of things we could cut, and it is the only one with a
genuine read-performance cost. Per the standing constraint, **it is not cut.**

### 5.1 Which six, given that graphs are mandatory

This is an open seam rather than a settled decision, and it was created by
`log.md` §5.3 making `G` mandatory without anyone revisiting the index design.
There are two incompatible sets of six in the existing documents:

- **`architecture.md` §4.1's six** — SPO, SOP, PSO, POS, OSP, OPS — are triple
  orders. They give every join ordering, and with `G` appended as a final
  tiebreaker they answer all eight graph-unbound patterns. They give no
  graph-bound prefix.
- **`architecture.md` §9's six** — SPOG, POSG, OSPG graph-last plus GSPO, GPOS,
  GOSP graph-first — give complete coverage of all sixteen patterns, but only
  three join orders within each family.

§9's cost argument no longer applies and should not be carried forward: it prices
quads at "2.4×" from 32-byte keys and page overhead in a B+tree. In memory an
order is a `[]FactID` — **1.6 MB flat**, whether it orders triples or quads.
`log.md` §5.3 says the same thing from the other side. So this is not a space
tradeoff any more; it is only a question of which access patterns to privilege.

**Recommendation: §4.1's six, with `G` as the final tiebreaker, and no graph-first
indices.** Filter on graph inline. `G` is a field in the `Fact` already
dereferenced to evaluate `Assert`/`Retract`, so a graph predicate is one
comparison against a value in a cache line that is already loaded. This is the
same reasoning §Scale used to drop the §5.2 side value index, applied to the same
scale.

**What would change it:** hot `GRAPH <tbox> { ... }` queries against a TBox that
is a small fraction of the facts, where a graph-first prefix genuinely narrows.
The cheap answer there is a per-graph sorted `[]FactID` posting list, not three
more full permutations — every fact is in exactly one graph, so all the posting
lists together cost 1.6 MB, one order's worth of memory instead of three.

### 5.2 How a permutation absorbs an insert

The structure above is a sorted `[]FactID`, and `architecture.md` §6.6 requires it
to be *immutable*, replaced by pointer swap, because inserting into a slice a
reader is walking shifts elements under it. Taken literally that means every
insert allocates a fresh 1.6 MB array and copies it — six times per commit,
**9.6 MB of garbage per commit.** At the "single digits per second" write rate the
design assumes, one actively-edited tenant produces ~50 MB/s of garbage, which
defeats §7's `GOMEMLIMIT`-with-collection-off strategy on its own.

This stayed invisible because three documents were each half right. §Scale prices
the *memmove* — "a 1.6 MB copy, on the order of 100 µs, six times, at a 1% write
rate; it is fine" — and as CPU it is fine. §6.6 added the immutability requirement
without revisiting that cost. §7 of this document made the GC budget load-bearing.
The problem exists only at the intersection.

**The property that makes it fixable: permutations are insert-only.** A retraction
is a field write in `facts[]` (§2.3) and never touches an index. Nothing is ever
removed from a permutation, so there is no delete path, no merge, no underflow.

Each permutation is therefore an immutable flat main array plus a small sorted
delta, both copy-on-write:

- A commit copies the delta and inserts — a few kilobytes, not 1.6 MB.
- Readers 2-way merge the two runs. `Match` does two binary searches (~19 probes
  on the main array, ~10 on the delta), `Len()` sums two spans, `Seek` seeks both.
- When the delta passes **N ≈ 1024**, it merges into a fresh main array and
  resets.

| | Per commit, all six orders |
|---|---|
| Naive copy-on-write | 9.6 MB |
| Delta copy, average over the cycle | ~12 KB |
| Rebuild, amortised (9.6 MB ÷ 1024) | ~9.4 KB |
| **Total** | **~21 KB** |

Resident cost is 6 × 1024 × 4 B = 24 KB, which is noise. The rebuild is ~30 ms of
sorting every 1024 writes — roughly every three minutes at the assumed rate — and
it blocks the single writer, not readers, who are holding earlier snapshots and
cannot observe it.

**The rebuild is `buildPermutations()`** — the same six sorts `log.md` §8 already
runs at the end of replay. One code path rather than two, exercised on every wake
as well as every merge, which is the argument `log.md` makes for replay being the
only load path.

**Why not chunk the permutation instead**, as §2.3 chunks the fact table and §4
chunks the dictionary blob: a depth-2 chunked array with a cumulative spine costs
~81 KB per commit, four times the delta, because each insert copies a chunk *and*
the spine. It also makes every layer-1 primitive two-level — locate the chunk,
then search within it — where the delta confines the complexity to a 2-way merge
in one place. The flat main array is worth protecting: it is what keeps scan
locality, single-level binary search, and free positional rank.

Two consequences worth stating rather than discovering:

- **A long analytical query pins its index set.** If a rebuild lands during one,
  both main arrays are live and permutation memory transiently doubles — +9.6 MB
  per such query. Bounded and rare, but it belongs in §1's budget.
- **N = 1024 is derived, not measured.** It sits near the optimum of two competing
  terms — delta copy grows with N, amortised rebuild shrinks with it — but the
  optimum moves with the real write rate and fact count.
---

## 6. What is deliberately not resident

`log.md` §8 introduces `map[Quad]FactID` as replay scaffolding and then suggests
keeping it, "since the same map is what makes the writer's duplicate-assert check
cheap at runtime". **It should not be kept.** It is the single largest item in the
untuned budget — Go's map layout for a 32-byte key and a 4-byte value works out to
~47 bytes per live entry after load factor, or ~19 MB — and it is redundant.

The SPO permutation *is* a sorted index on `(S, P, O, G)`. Both operations the map
exists for are a binary search over it:

- **Duplicate-assert detection** (`log.md` §5.3 requires the writer to reject an
  assert of an already-live quad, since bbolt's idempotent `Put` is gone).
- **Retract resolution** (`log.md` §5.3 retracts by value, so replay and the
  writer both have to find the live fact with that quad).

That is ~19 probes against an O(1) map lookup, on a path `architecture.md` §6.3
and B.5 both price at single digits per second. Nineteen megabytes of permanent
residency per tenant to save nineteen probes a few times a second is a straight
loss under the density premise — and deleting it *removes* code, which is the only
item on this list that improves both constraints at once.

**Replay still needs it, transiently.** `Replay` resolves retracts before the
permutations are sorted — §8 builds them once at the end, deliberately, because
sorting six slices is tens of milliseconds against an O(n) memmove per insertion.
So the map exists during replay and is dropped after, which is what §8 already
describes.

Under the eviction model this matters more than it did, because replay is no
longer a once-per-boot event — it happens every time an idle tenant wakes.
A reload spikes ~19 MB transiently. That is acceptable for staggered wakeups and
may not be for a cold start of a whole machine. If it hurts, the fix is an
open-addressed table holding only `FactID`s, rehashing the quad from `facts[id]`
on probe rather than storing 32-byte keys: 2.3 MB instead of 19, at the cost of
~40 lines of well-understood code. **Do not write it until the spike is measured
hurting something.**

---

## 7. The runtime is half the budget

Two settings and one call, none of which are data structure work, and together
they are worth more than anything in §§2–5.

**`GOMEMLIMIT`, with `GOGC` off or low.** The default `GOGC=100` lets the heap
reach twice the live set before collecting, so every megabyte saved in §§2–6 is
worth two of RSS — and, inversely, no amount of struct tuning helps if the
collector is sitting on a 2× multiplier. A store is nearly static after replay and
has almost no steady-state allocation rate to collect, which is exactly the shape
`GOMEMLIMIT` as a soft cap with `GOGC` disabled is for.

This should be measured *first*, before any of the layout work. It is an
environment variable, and it may move the number further than a week of struct
surgery.

**`debug.FreeOSMemory()` on eviction.** Go's scavenger returns freed pages to the
OS lazily. Without forcing it, a process can drop its store and hold its RSS for
minutes. The entire eviction strategy depends on this line, and it is one line.

---

## 8. Eviction and reload

Idle tenants — hours to days is the expectation — drop their resident store and
keep serving. The HTTP server, session state, and login path stay up; a request
that needs the graph triggers a replay.

This is not a new mechanism. It is `log.md` §8's replay path, which is already the
only load path and the only recovery path, invoked more often. That is a
desirable property rather than a tolerated one: **the recovery path is now
exercised continuously, in production, by ordinary traffic.** Recovery code that
runs on every wake is recovery code that works.

Three things follow that are worth stating rather than discovering:

- **Verification runs on every wake, not every boot.** `log.md` §6 puts full chain
  verification at tens of milliseconds and concludes it should run on every start.
  Under eviction, "every start" means every wake. The cost stays small, but it is
  now on a user-facing latency path rather than a process-startup path, and the
  budget should be measured against the sub-second target rather than assumed
  into it.
- **The transient replay map is the reload peak**, per §6. Resident steady state
  is not what sizes the machine if enough tenants wake at once.
- **Eviction policy is unspecified.** Time since last query is the obvious signal;
  whether it should also respond to machine-level pressure is a real question and
  is left to §11.

---

## 9. Rejected

| Proposal | Saves | Why not |
|---|---|---|
| Six permutations → three | 4.8 MB | The only item with a genuine read-performance cost. Fails the standing constraint (§5). |
| Shared TBox dictionary across tenants | Large, if tenants matched | Tenants upgrade to new application versions independently and licensed functionality varies the TBox, so tenants do not reliably share one. The sharing would be conditional, and conditional sharing across a tenant boundary is exactly the complexity the constraint forbids. |
| Flat copy-on-write permutations | — | 9.6 MB of garbage per commit, which defeats §7's GC strategy by itself. §5.2. |
| Chunked permutations (depth-2, cumulative spine) | — | 4× the delta's allocation, and it makes every layer-1 primitive two-level. Right shape for the fact table and the dictionary, wrong one here. §5.2. |
| Inline-key B-tree (`BTreeG[Quad]`) | — | Faster `Match` — probes land in a node rather than gathering from `facts[]` — and copy-on-write snapshots from a tested library. But the key needs a generation tiebreaker, so 24 bytes, and six indices at ~70% fill is ~82 MB against 9.6 MB. Rejected on density, not merit: at one store per machine this is the better design. |
| Persistent vector / RRB trie (Immer, Clojure) | — | Solves the insert copying, but binary search becomes a 4-level pointer descent and it reintroduces ~78,000 pointers per tenant, undoing §4.1. |
| Skip list, ART, packed memory array, LSM runs, succinct self-index | — | Each fails at least one of: pointer-free, positional rank, immutable without in-place mutation, insertable without rebuild. §5.2. |
| 40-bit IDs (`[5]byte`) | 4.8 MB vs 64-bit | Alignment is fine — 28-byte `Fact`, no padding. But Go has no `uint40`, so every compare becomes byte assembly on the hot path, and the only thing 40 bits buys over 32 is inline range, which §3.2 shows costs ~48 bytes per distinct overflow value against 1.6 MB flat. |
| Stealing `Assert` bit 31 for the derived flag | 50 KB | Puts a mask on the hottest comparison in the system (§2.2). |
| Open-addressed live-quad table at runtime | — | The structure should not exist at runtime at all (§6). Reconsider only for the transient replay peak, and only if measured. |
| `mmap`-ing the dictionary blob from a derived file | Moves ~5 MB to evictable clean pages | Introduces a second on-disk representation that can disagree with the log, which is the property `log.md` §11.5 rejects checkpoints for. A rebuildable checksummed cache is a weaker thing than a checkpoint of record, but it is the same argument's territory and should be decided deliberately, not slipped in. |

---

## 10. The budget

Per active tenant, at `architecture.md`'s target of 4×10⁵ facts and ~10⁵ terms:

| Structure | Untuned | Specified | § |
|---|---|---|---|
| Fact table | 22.4 MB | 9.6 MB | 2 |
| Six permutations | 9.6 MB | 9.6 MB | 5 |
| Derived origin | in struct | 0.05 MB | 2.2 |
| Dictionary | ~18 MB | ~7 MB | 4 |
| Live-quad index | ~19 MB | 0 | 6 |
| Epoch table | not kept | 0.02–3.2 MB | 2.4 |
| **Live heap** | **~69 MB** | **~26–29 MB** | |
| GC headroom | ×2 (`GOGC=100`) | ×~1.15 (`GOMEMLIMIT`) | 7 |
| **Store contribution to RSS** | **~138 MB** | **~30–34 MB** | |

Roughly 45% of the saving is deleting the live-quad map, 30% is the 64→32 bit
narrowing, and 25% is the dictionary arena. The epoch table is the one item added
rather than removed; its range is wide because it scales with the number of
commits rather than the number of facts, which is a property of how the
application is used and not of the store.

**These are estimates and every one of them should be replaced by a measurement.**
Go's map and allocator overheads are computed from documented layouts rather than
observed, the 40-byte average term is inherited from `architecture.md` §Scale
without validation against real ontologies, and the process floor in §1 is a
placeholder. The ordering of the items is more robust than any individual figure,
and the ordering is the part that should drive the work.

---

## 11. Open questions

1. **What is the process floor?** Per §1 it is ~75% of a tuned machine's RAM at a
   10% active fraction, which makes it the most valuable number in this document
   and the only one we cannot derive. Measure an evicted process before doing any
   of the layout work.
2. **What is the active fraction, and is it stable?** The §1 table swings from 25%
   to 64% saving across plausible values. It also determines whether the transient
   replay peak (§6) is a rounding error or a sizing constraint.
3. **Does the integer inlining ceiling bind?** §3.2's gate. Monetary amounts are
   whole currency units, so the ceiling is 134,217,727 units and money is not
   expected to reach it; what is unmeasured is whether any *other* `xsd:integer`
   in real tenant data does, and how many **distinct** such terms there are.
   §3.3 makes this the one decision here that is not freely revisable later.
4. **Which six permutations?** §5.1. Unresolved since `log.md` made graphs
   mandatory. The recommendation is defensible without more information, but the
   query mix would settle it.
5. **What triggers eviction?** §8. Idle time is the obvious signal; whether to add
   machine-level memory pressure, and whether eviction should ever be refused for
   a tenant mid-transaction, is unspecified.
6. **Does anything else want to be a column?** The specified `Fact` is an array of
   structs because the dominant access pattern is a random gather from a
   permutation, which wants the whole record in one cache line. `Retract` is the
   one field that argues otherwise — it is the only field written, and isolating
   it would keep writes off cache lines that scans are reading. Not worth doing
   speculatively, but worth knowing where to look if write-side contention ever
   shows up.

---

## 12. The pattern-matching API

The interface over everything above. It is drafted against one constraint that
shapes all of it: **a SPARQL engine will eventually sit on this, and so will a
report that just wants a number.** The failure to avoid is two access paths — a
convenience API and a query API each reaching into the structures on their own
terms, drifting apart, and disagreeing about visibility or origin in some corner.

So there are three layers, and the top one is written in terms of the middle one:

| Layer | What it is | Who uses it |
|---|---|---|
| 0 | `Snapshot` — a logical instant | everything |
| 1 | pattern → range → iterator | SPARQL BGP evaluation |
| 2 | counts, distinct, existence | reports, dashboards, `?` questions |

Nothing in layer 2 touches a permutation directly. If a convenience call cannot
be expressed in layer 1, that is a signal layer 1 is missing something, not a
licence to reach past it.

### 12.1 Layer 0: the snapshot

```go
// Snapshot is a logical instant: an epoch plus the index set that was published
// at or after it. It holds headers, not locks, and stays valid indefinitely —
// architecture.md §6.6's whole point. 24 bytes, no allocation.
type Snapshot struct {
	epoch Epoch     //  4
	idx   *indexSet //  8
	dict  *Dict     //  8
}

// run is one permutation, per §5.2: an immutable sorted main array and an
// immutable sorted delta. Both are replaced wholesale, never mutated.
type run struct{ main, delta []FactID }

// indexSet is the writer's unit of publication — one atomic swap covers all six
// orders, the fact chunks, and the origin bitset, so a reader cannot observe a
// mixed-version set.
type indexSet struct {
	ord     [6]run
	chunks  [][]Fact
	derived []uint64
	epochs  [][]EpochMeta // §2.4, chunked; indexed by epoch number
	nTerms  uint32        // dictionary high-water mark; §13.8
}

func (s *Store) Latest() Snapshot {
	e := Epoch(atomic.LoadUint32(&s.published)) // epoch FIRST — see below
	return Snapshot{epoch: e, idx: s.idx.Load(), dict: s.dict}
}

func (s *Store) At(e Epoch) Snapshot

// Terms is the dictionary high-water mark as of this snapshot's publication. It
// lives in the index set rather than being read off the live Dict, whose `off`
// slice the writer appends to — see §13.8.
func (s Snapshot) Terms() ID
```

**The load order is not free choice.** `log.md` §7.1 has the writer swap indices
(step 4) and *then* publish the epoch (step 5). A reader must mirror it: read the
published epoch, then load the index pointer. That way the index is at least as
new as the epoch, and any facts it carries from later epochs are rejected by the
visibility test. Load the pointer first and a reader can pair a pre-*E* index with
epoch *E* — facts that are visible but absent from the index, which is a silently
short answer rather than an error.

`architecture.md` §6.6 says "replace each permutation by pointer swap", which read
literally means six pointers and six loads. One `atomic.Pointer[indexSet]` gives a
consistent set in a single load and costs one ~200-byte allocation per commit
instead of any per read.

Returned by value, a `Snapshot` lives on the caller's stack; methods take a
pointer receiver and escape analysis keeps it there until a query engine parks one
in an operator struct, which costs a single 24-byte allocation per query. That is
the right price.

### 12.2 Layer 1: pattern, range, order

```go
// Pattern is a quad pattern. ID 0 is unbound — the dictionary never allocates it
// and log.md §5.1 already uses 0 for "none".
type Pattern struct{ S, P, O, G ID }

// span is a half-open window into one immutable run. Nothing is copied.
type span struct {
	ids    []FactID
	lo, hi int
}

// Range is what Match returns: the two windows of §5.2's main-plus-delta, the
// order they are in, and whatever the prefix could not express.
type Range struct {
	snap     Snapshot
	main     span
	delta    span
	order    Order
	residual Pattern
}

func (r Range) Len() int   // candidate count — see §12.4
func (r Range) Order() Order
```

`Range` is a *window*, not a container — the same relationship to a run that a Go
slice has to its array. `Len()` is arithmetic on four ints.

**Order selection.** The six orders are `architecture.md` §4.1's, with `G`
appended as the final tiebreaker (§5.1). Every triple pattern is prefix-covered:

| Bound | Order | Prefix |
|---|---|---|
| `???` | SPOG | 0 |
| `S??` | SPOG | 1 |
| `?P?` | PSOG | 1 |
| `??O` | OSPG | 1 |
| `SP?` | SPOG | 2 |
| `S?O` | SOPG | 2 |
| `?PO` | POSG | 2 |
| `SPO` | SPOG | 3 |

`G` never enters the prefix, so a bound graph is always residual — one comparison
against a field in a `Fact` the walk has already loaded to evaluate
`Assert`/`Retract`. That is the §5.1 trade, showing up here concretely.

Where more than one order would serve, the *choice matters downstream*, because a
merge join needs its inputs sorted on the join variable. So the planner gets to
ask:

```go
func (s Snapshot) Match(p Pattern) Range            // chooses per the table
func (s Snapshot) MatchAs(p Pattern, o Order) Range // planner names the order
```

**Matching is four binary searches**, not two — lower and upper bound in each of
main and delta. Roughly 19 + 10 probes if the second bound is bracketed inside the
first. Each probe dereferences `facts[ids[mid]]`, so it is a random gather into
the fact table, which is why §2's 24-byte `Fact` and its cache density matter more
than their megabyte count suggests.

**Fast reject.** If `Resolve` (§12.7) fails on any bound component, the pattern
matches nothing and no index is touched. A bound term that this store has never
seen is an ordinary case, not an exotic one — a lookup by an identifier that does
not exist, a filter value with no matches, a class belonging to a module this
customer has not licensed, or application code running slightly ahead of an
ontology migration. All of them should cost a hash probe rather than a scan.

### 12.3 Iteration

Concrete types, not interfaces, so `Next` inlines to a bounds check, a load, and
the filter:

```go
type Origin uint8

const (
	_              Origin = iota // 0 is invalid — origin must be stated, §12.5
	OriginAsserted               // only what was recorded
	OriginDerived                // only what was inferred
	OriginAny                    // both
)

// Filter is everything the prefix could not express. A struct, not a func: a
// closure filter is an indirect call per fact and allocates if it captures.
type Filter struct {
	Origin Origin
	Graphs GraphSet // nil means every graph; see §12.8
}

func (r Range) Iter(f Filter) Scan
func (sc *Scan) Next() bool
func (sc *Scan) ID() FactID
func (sc *Scan) Fact() *Fact
```

`Scan` 2-way merges main and delta in the range's order, and per candidate
evaluates visibility (`f.Assert <= e && e < f.Retract`, with `Retract` read
atomically per §2.3), origin, and the residual graph. All three are predicates on
a `Fact` that is already in a register.

There is no batched variant. `architecture.md` §7.1 argued for yielding
`[]Triple` in chunks of 256–1024 to amortise an interface dispatch — but the
dispatch only exists if the iterator is boxed, and a `[]FactID` buffer is exactly
the intermediate container this API is trying not to build. Box into an interface
only at the query operator boundary, where polymorphism is the actual requirement.

**Leapfrog triejoin gets a view, not a second mechanism.** §7.4 needs precisely
two operations per relation — iterate the current variable's values in sorted
order, and seek to the first value ≥ *x*:

```go
// Vars exposes a range as sorted distinct values at one prefix depth.
func (r Range) Vars(depth int) VarIter

type VarIter struct{ /* concrete: LFTJ holds a []VarIter, unboxed */ }

func (v *VarIter) Key() ID
func (v *VarIter) Next() bool
func (v *VarIter) Seek(x ID) bool
func (v *VarIter) AtEnd() bool
```

`Seek` is `sort.Search` within the remaining span of each run — strictly cheaper
than the B+tree descent §7.4 assumed. And §7.4's recommendation to "build three
indices first and measure before committing to six" is already moot: six exist, so
every variable order is available from the start.

### 12.4 Cardinality, and what it does to §8

`architecture.md` §8 opens by observing that bbolt cannot answer "how many triples
match this pattern" — "there is no rank operation, and `Bucket.Stats()` walks every
page" — and builds maintained counters, HyperLogLog sketches, and characteristic
sets on top of that premise.

**A sorted slice's rank operation is the array index.** The premise is gone, and
most of §8 with it:

| §8.1 statistic | Now |
|---|---|
| total triple count | `len(main) + len(delta)` |
| triples with predicate P | `Match(Pattern{P: p}).Len()` — O(log n) |
| `SP?`, `?PO`, `S??`, `??O` | the same, O(log n) |
| HLL distinct subjects for P | subjects are sorted inside the P prefix — exact |

So: no counters in the write path, no sketches, no ~2% error. Two honest
primitives instead:

- **`Range.Len()`** — O(log n). An exact count of *candidates*, and therefore an
  exact upper bound on live matches. This is what a join planner wants.
- **`Count(filter)`** — O(range), exact, because visibility and origin have to be
  evaluated per fact.

The gap between them is the facts retracted before the snapshot epoch, which for a
head snapshot is small.

§8.2's characteristic sets are the only part that survives, because star-join
cardinality is not any single range — and §Scale had already recommended skipping
most of §8 anyway.

### 12.5 Layer 2: the questions people actually ask

Everything here is layer 1 with a loop around it:

```go
// The primitives are on Range, so that a sub-range — §13.6's GroupIter.Sub() —
// can be counted without a Pattern that could not express it. See §13.8.
func (r Range) Count(f Filter) int
func (r Range) CountDistinct(c Component, f Filter) int
func (r Range) Exists(f Filter) bool

// The Snapshot forms are wrappers, per this section's own rule.
func (s Snapshot) Count(p Pattern, f Filter) int
func (s Snapshot) CountDistinct(c Component, p Pattern, f Filter) int
func (s Snapshot) Exists(p Pattern, f Filter) bool
```

"How many entities of type `iso:Risk`?"

```go
risk, ok := snap.Resolve(iri(isoRisk))
if !ok {
	return 0 // the tenant's TBox does not define it — no index touched
}
n := snap.CountDistinct(CompS, Pattern{P: rdfType, O: risk},
	Filter{Origin: OriginAny})
```

Two properties make this cheap. POSG order is `(P,O,S,G)`, so within the `(P,O)`
prefix the subjects are already sorted — distinct counting is adjacent dedup, no
hash set. And successive generations of the same quad sort adjacently too, so
history does not disturb it.

**`Origin` has no default, and that is deliberate.** If
`iso:CriticalRisk rdfs:subClassOf iso:Risk` and A.4's forward materialisation has
run, critical risks carry a *derived* `rdf:type iso:Risk` fact. So
`OriginAsserted` counts what was stated and `OriginAny` counts what is entailed —
both correct answers to different questions, and `architecture.md` A.5 is emphatic
that an auditor must never see an inference presented as a record. A silent
default is exactly how that failure would happen, so `Origin(0)` is invalid and
the call will not compile into something meaningful without a choice.

### 12.6 The history of an entity

*"Pull up the history for this `iso:Risk` so I can see who changed what and
when."* A named customer requirement, and the one question this design answers
more naturally than a conventional store would — because nothing is ever removed.
Every generation of every quad is still in the fact table with its
`[Assert, Retract)` interval intact, and §5.2's permutations are insert-only, so a
retracted fact is still sitting in SPOG exactly where it was.

So the history of entity *X* is **one prefix range**. Each fact in it yields
`(P, O, G, Assert, Retract)`, which is the complete interval structure; the
epoch table (§2.4) turns each epoch number into an actor, a reason, and a
timestamp.

**The entry point is separate from `Match`, deliberately:**

```go
// History returns every generation matching the pattern, ignoring visibility.
// Origin still applies, and is still required.
func (s Snapshot) History(p Pattern, f Filter) Range
```

Every layer-1 call evaluates `f.Assert <= e && e < f.Retract`. History wants the
opposite, and expressing that as a flag on `Filter` would mean some combination of
options makes `Match` silently return retracted facts. That is the kind of thing
that produces a wrong answer in an audit years later, so it gets its own name.

Layer 2 shapes it into a timeline:

```go
type ChangeOp uint8

const (
	_         ChangeOp = iota
	Asserted
	Retracted
)

type Change struct {
	Fact    FactID
	Epoch   Epoch
	Op      ChangeOp
	Actor   ID    // from §2.4; 0 if the writer did not record one
	Reason  ID
	Wall    int64 // advisory — see §2.4
	Derived bool
}

func (s Snapshot) EntityHistory(subject ID, f Filter) []Change
```

**This one materialises, and that is correct.** It is the exception to the rule
elsewhere in this API, for a specific reason: the index is ordered by quad and the
answer must be ordered by epoch, so a sort is unavoidable — and each fact
contributes up to two entries, an assertion and possibly a retraction. The input
is one entity's statements across their generations, so this is tens of elements,
not a result set. Returning an iterator here would only move the sort somewhere
less honest.

**Three decisions the question hides**, each of which changes the answer:

- **Subject position only?** An entity is also the *object* of other entities'
  facts — `(control, iso:mitigates, risk)` is part of that risk's history but has
  `S = control`. Covering it is a second prefix range in OSPG, equally cheap, but
  "the history of X" has to mean one or the other and the API should say which.
  The default should probably be both, with the object-position entries marked as
  such, since a reviewer reading a risk's history will not expect controls
  referencing it to be missing.
- **How far does the entity extend?** If amounts, addresses, or assessments are
  structured nodes, they are separate subjects, and a complete history follows
  blank-node closure — RDF's concise bounded description. That is a small
  traversal rather than one range, and it is a policy decision about where an
  entity ends.
- **Asserted or entailed?** A derived `rdf:type` appearing in a timeline is an
  inference, not an event. `Origin` already separates them and `architecture.md`
  A.5 is emphatic that an auditor must never see an inference presented as a
  record — a history view is precisely where showing them undifferentiated would
  do the most damage.

**Attributing a derived fact is a two-step, and it is currently incomplete.** For
an inference the agent is the reasoner, and what identifies it lives in
`log.md` §5.5's environment note: engine version, rule set identifier and hash. So
a derived fact resolves to its epoch, and the epoch to the environment note in
effect at the time — which means those notes need to be resident and ordered too.
They are small, a few hundred entries at most.

This drove a change to `log.md`. Its §5.5 claimed the environment note was "hashed
into the chain like any other record" while giving the record no `prevHash`/`hash`
fields, and §6's `Verify` chained only `kindEpoch` — so the record identifying
*which reasoner produced an inference* sat outside the tamper-evidence. A small
inconsistency while it was only provenance metadata; load-bearing once agent
attribution on derived facts is a customer-visible feature. The note now carries
the chain, and a `lastEpoch` field that makes "which rule set was in effect at
this fact's epoch" a comparison rather than a positional inference.

**One asymmetry worth designing to.** "What did agent X change?" is a linear scan
of the epoch table — 2×10⁵ entries, ~1 ms, no index needed. "What did epoch *e*
change?" splits: facts are appended in log order, so `Assert` is monotonically
non-decreasing over `FactID` and everything asserted at *e* is a **contiguous
`FactID` range**, findable by binary search. Retractions are field writes
scattered across the table, so they are not.

Hence: **per-entity questions from memory, per-epoch questions from the log.** An
epoch record lists its ops explicitly and is one seek away, and the log is on disk
regardless. That division costs nothing and keeps a scan out of the audit path.

Finally, the answer is *verifiable*, not merely fast. Every epoch in a timeline is
a hash-chained record, so a resident history can be checked against the log — which
is the property the whole design is organised around, and the one that makes this
feature worth more here than the same screen in a conventional application.

### 12.7 Resolution and materialisation

```go
func (s Snapshot) Resolve(t Term) (ID, bool) // term -> ID; false if unknown
func (s Snapshot) Bytes(id ID) []byte        // canonical encoding, §3.2
func (s Snapshot) Term(id ID) Term           // decoded
```

`Resolve` tries the inline encoding first (§3), then `Dict.byTerm`. `Bytes`
returns **a view into the arena blob** — no copy, no allocation. That is a
dividend of §4's layout that was not obvious when it was specified: §7.2 worried
that resolving IDs to terms "dominates everything else" on a large result set, and
with the arena the resolve step allocates nothing at all.

The API must return `[]byte`, or a `string` built over it with `unsafe.String`.
Returning a plain `string` reintroduces the copy at the last step and gives back
the whole benefit.

§7.2's other advice — resolve once per distinct ID, in ascending order — still
applies to result materialisation, though the motivation is now cache locality
rather than B+tree cursor movement.

### 12.8 What SPARQL will want that this does not yet give

Named now rather than discovered later:

- **`ORDER BY` has no cheap path.** Dictionary IDs are in first-appearance order
  and §5.3 rejected an order-preserving dictionary, so ordering by term requires
  materialising and comparing lexical forms. Inlined numerics sort correctly by ID
  within their type (§5.1), so numeric ordering is nearly free while string
  ordering is not — an asymmetry worth knowing before someone benchmarks it.
- **Graph sets, not a graph.** `FROM` and `FROM NAMED` scope a query to a *set* of
  graphs, which `Pattern.G` cannot express. Hence `Filter.Graphs`: `nil` for the
  whole dataset, otherwise a small sorted `[]ID` scanned linearly. This is
  separate from `Pattern.G`, which is what `GRAPH ?g { ... }` binds. Note that
  `architecture.md` §9 flags "default graph or union of all graphs" as a decision
  that must be made explicitly; it still has not been.
- **Bindings should not be `map[Var]ID`.** §7.2 sketches that, and a map
  allocation per row will dominate every other cost in this document. Assign
  variable slots at plan time and make a row a `[]ID`, slab-allocated per query.
- **Layer 1 yields `FactID`s; a BGP yields bindings.** Projecting components into
  binding slots is the operator layer's job, not this one's. `FactID`s are stable
  and citable (§2), which is what makes a justification record (A.5) able to point
  at one.

### 12.9 Open questions

1. **Does `Match` return `Range` by value?** It is ~80 bytes with two spans, an
   order, a residual pattern, and a snapshot. Cheap to copy, but not free, and it
   is the single hottest call in the system.
2. **Does layer 2 need more than counting?** "Instances of a class", "all
   properties of an entity", and "count by type" cover most non-SPARQL questions,
   but that list should come from the application rather than from here.
3. **Where does the query planner live?** §12.4 gives it exact candidate counts,
   which is more than §8 ever promised. Whether that is enough to skip
   characteristic sets entirely is a measurement, not a judgement.
4. **Default graph or union?** `architecture.md` §9 raised it, this document
   inherits it, and `Filter.Graphs` makes it expressible without deciding it.

---

## 13. Exploration: the first application

§12 closes by naming what a SPARQL engine will want (§12.8) and what layer 2 might
still be missing (§12.9 question 2), with the note that the list "should come from
the application rather than from here". This section is that list, produced by
writing one application against the interface rather than by guessing at it.

The application is a graph explorer. The user starts with an empty canvas and
picks an entity type from a list of everything the store knows about; a node
appears carrying a count. Clicking the node offers every edge type into and out of
it; picking one — `<-[:Owns]-(iso:Role)` — adds a second node and an edge, and the
user reads "600 risks owned by 250 roles". And so on, to arbitrary depth.

It is a small application and it exercises this API harder than an early SPARQL
engine would, because every interaction is an aggregate over a set that the
previous interaction defined. What came out of it: one addition to layer 1
(§13.6), one new resident structure (§13.7), and two corrections to §12 (§13.8).
Everything else it needs, §12 already provides — which is the result this section
was written to test.

### 13.1 Every screen is a group-by

The class picker groups by object within `?s rdf:type ?C`. The edge dropdown
groups by predicate. The far node groups by the type of the other endpoint. There
is no screen in the application that is not "for each distinct value of one
component in this range, how many distinct values of another".

§12 has `Count`, `CountDistinct`, and `Range.Vars`. It has no way to get keys and
counts *together* in one pass, which is the only thing this application ever asks
for. That is §13.6, and it is the whole of the API gap.

**The class picker is one linear pass.** POSG is `(P,O,S,G)`, so within the
`P = rdf:type` prefix the quads are sorted by class and then by subject — every
class is a contiguous run with its subjects already sorted inside it. One walk
with adjacent dedup yields the entire picker, keys and counts, with no per-class
lookup and no hash set. The cost is the size of the `rdf:type` range, ~10⁵ quads
once OWL 2 RL materialisation has inflated it, each candidate a random gather into
`facts[]` — call it 10 ms, which is right for a click and wrong for a keystroke,
and which §13.2 memoises per epoch.

**Two sources answer different questions, and both disagreements are
information:**

| | Meaning | Show it |
|---|---|---|
| Declared `owl:Class`, zero instances | "No risks recorded yet" | Yes — an empty type is a real answer |
| Instances, no class declaration | Data quality problem | Yes, flagged — do not hide it |

**Graph scoping is not optional on this screen.** The ontology is data
(`architecture.md` A.2), so without `Filter.Graphs` restricted to the ABox, the
group-by returns `owl:Class` with 340 instances and `sh:PropertyShape` with 1,200,
and the picker offers the user "Class" as an entity type to explore. This is
§12.9 question 4 — default graph or union — arriving on the first screen of the
first feature. The answer for this application is clearly *not* union, and that is
the first concrete data point that question has had.

### 13.2 Stateless, because the deployment premise requires it

The exploration graph is assembled across many clicks over minutes. Every number
on it must come from one epoch, or the 600 on one node and the 250 on another are
from different instants, and a user who subtracts them gets a wrong answer.

The obvious implementation holds a `Snapshot` for the session. §12.1 makes that
cheap — 24 bytes, headers not locks, valid indefinitely — and at one store per
machine it would be correct.

**Under §8 it is wrong.** A held `Snapshot` pins an `*indexSet`, which is the
exact memory eviction exists to reclaim, and it cannot survive the eviction it
blocks. A browser tab left open on a Friday holds ~30 MB on a machine sized on the
assumption that idle tenants cost 15 MB. §5.2 adds a second edge: a rebuild
landing during a pinned session transiently doubles permutation memory.

So the client holds the exploration state and sends it back on every request. It
holds **structure, not data**:

```json
{ "epoch": 4182,
  "nodes": [ {"id": "n0", "class": "iso:Risk", "conds": [["iso:level", 4]]},
             {"id": "n1", "class": "iso:Role",
              "via": {"from": "n0", "pred": "iso:owns", "dir": "in"}} ],
  "expand": {"node": "n1", "pred": "iso:memberOf", "dir": "out"} }
```

That it holds no ID sets is forced rather than chosen. Member sets are internal
`u32` dictionary IDs: 400 KB per request at 10⁵ members, meaningless outside the
process, and **not stable** if the inline predicate is ever re-tuned (§3.3).
Handing them to a client is a layering violation with a live hazard attached.

**Re-evaluation is affordable because of the ceiling, not because of the
selectivity.** Each hop is a merge or a probe bounded by the permutation it walks,
and the whole store is 4×10⁵ facts — ~10 ms to scan. A six-hop exploration has a
hard ceiling of a few full scans regardless of fan-out. This is
`architecture.md` §Scale's argument for deleting the side value index — at this
size, scan — applied one level up.

**Statelessness composes with eviction rather than fighting it.** The client holds
a `uint32`. The tenant evicts freely; the next request replays and re-derives.
`At(e)` still answers an old epoch after a wake, because nothing is ever removed
and the `[Assert, Retract)` intervals are reconstructed intact — so a client can
pin epoch 4,182 for a week with no server-side session, no lease, no registry, and
no expiry. Historical epochs are free here in a way they are not in a conventional
store.

**The payoff nobody asked for.** `(epoch, canonical path)` is a citable,
reproducible identifier for an aggregate view. Paste it into a compliance report
and anyone can re-derive the same numbers; the epoch is hash-chained, so those
numbers are verifiable against the log. That is the property §12.6 gives an entity
history, extended to aggregates, and it exists only because the state is a path
and an epoch rather than a server-side handle. The epoch belongs on the screen —
"as of epoch 4,182 · 14:32" — with a refresh control, for the same reason.

Four obligations follow:

- **The request is now a query surface and must be budgeted.** A client can send a
  fifty-hop path over the highest-cardinality predicates. The pricing is free and
  comes *before* the work: every hop's candidate count is `Range.Len()`, O(log n)
  (§12.4). Cost the whole path with a handful of binary searches, reject over
  budget, then evaluate. Cost-based admission control falls out of the sorted
  slice's rank operation. Unknown IRIs cost a hash probe via §12.2's fast reject.
- **The tenant boundary comes from the session, never from the blob.**
- **Recompute every node; do not trust client-supplied counts.** The temptation is
  to have the client return the numbers it already has so only the new node is
  computed. For a system of record a displayed number must be server-derived, and
  recomputation is bounded by a few full scans. It is also self-healing: each
  response is a pure function of `(epoch, path)`, so drift is impossible by
  construction.
- **Then memoise `(epoch, path prefix) → sorted []ID` in a bounded LRU.** This
  makes a redraw nearly free without reintroducing session state, because it is a
  *cache*: losing it costs latency and never correctness. It dies with the store
  on eviction and the next request rebuilds it. The snapshot is immutable, so the
  memo never needs invalidating — which is also what makes §13.1's 10 ms class
  picker a once-per-epoch cost rather than a per-request one.

That distinction — cache versus state — is what keeps the statelessness real.

### 13.3 The call sequence

`(iso:Risk {level: 4})<-[:Owns]-(iso:Role)`, end to end:

```go
func explore(store *Store, req Request) Response {
	snap := store.At(req.Epoch)                    // §12.1; client-supplied epoch
	f := Filter{Origin: req.Origin, Graphs: req.ABox}

	// Resolve every term first. A miss means the pattern matches nothing and no
	// index is touched — §12.2's fast reject, and an ordinary case: a class in a
	// module this tenant has not licensed.
	risk,  ok1 := snap.Resolve(iri("iso:Risk"))
	level, ok2 := snap.Resolve(iri("iso:level"))
	four,  ok3 := snap.Resolve(intLit(4))          // inlined per §3 — no dict probe
	owns,  ok4 := snap.Resolve(iri("iso:owns"))
	role,  ok5 := snap.Resolve(iri("iso:Role"))
	if !(ok1 && ok2 && ok3 && ok4 && ok5) {
		return Response{} // every count is zero
	}

	// --- Node 0: (iso:Risk {level: 4})
	// Two prefix-2 ranges over POSG, intersected on the subject. Both Vars(2)
	// cursors are ascending, so this is a merge; §13.4 picks the drive side.
	byType := snap.MatchAs(Pattern{P: rdfType, O: risk}, POSG)
	byLvl  := snap.MatchAs(Pattern{P: level,   O: four}, POSG)
	frontier := intersect(byType.Vars(2), byLvl.Vars(2), f) // sorted []ID, 100 risks

	// --- Edge: <-[iso:owns]-
	// POSG is (P,O,S,G), so within P = iso:owns the quads are sorted by object —
	// the risk — which is the end the frontier binds. One cursor, seeked forward,
	// never re-Matched: §12.3's Seek searches only the remaining span, so an
	// ascending sweep degenerates to a merge.
	cur := snap.MatchAs(Pattern{P: owns}, POSG).Vars(1)
	var pairs []pair
	for _, r := range frontier {
		if !cur.Seek(r) {
			break
		}
		if cur.Key() != r {
			continue // this risk has no owner
		}
		for it := cur.Sub().Vars(2); it.Next(); { // subjects within (owns, risk)
			pairs = append(pairs, pair{risk: r, role: it.Key()})
		}
	}

	// --- Node 1: (iso:Role), plus any conditions of its own
	// S is sorted within each risk but not across them, so the frontier for the
	// next hop is built by append-sort-dedup (§13.5), not by a set.
	owners  := sortDedup(roleCol(pairs))
	byRole  := snap.MatchAs(Pattern{P: rdfType, O: role}, POSG).Vars(2)
	members := intersect(owners, byRole, f)        // 250 roles

	// --- The numbers on the edge
	pairs = keep(pairs, func(p pair) bool { return found(members, p.role) })
	return Response{
		Left:  countDistinct(riskCol(pairs)),      // NOT len(frontier)
		Edges: len(pairs),
		Right: len(members),
	}
}
```

**An edge carries three numbers and only one of them is a `Len()`:**

| Number | What it is | Cost |
|---|---|---|
| 1,400 `owns` statements | `Range.Len()` on the qualifying pairs | O(log n) |
| 250 distinct roles | distinct `S` of the join result | free — already `S`-ordered |
| 600 distinct risks | distinct `O` of the join result | needs the re-sort above |

You get one order at a time, so one endpoint count is free and the other is not.
At these sizes materialising the pairs and sorting is trivial, but the asymmetry
should be known before a UI puts cardinalities on both ends of every edge.

**The left count must be recomputed after the right-hand filter, and this is the
trap.** The 100 risks are node 0 *in isolation*. Once `(iso:Role)` carries a
condition, risks whose only owners fail it drop out of the edge entirely, so the
number displayed on the left is `distinct(risk)` over the surviving pairs — ≤ 100.
Showing the pre-filter count next to a filtered edge is a wrong answer of exactly
the kind this design exists to prevent; if both are wanted, label them
("100 risks, 87 with a qualifying owner").

Conditions at any depth are the same primitive: one prefix-2 POSG range and one
intersect against the running frontier. An N-hop path is a loop over
seek-merge, dedup, intersect.

**Test a condition with a bound object, not a fetch.** `{level: 4}` on a known
subject is `snap.Exists(Pattern{S: r, P: level, O: four}, f)` — SPOG prefix 3, one
binary search, no gather of the value. Only fetch `?level` when the condition is a
range, and note that for an *unbound* subject `level > 3` is a range scan on
POSG's `O` component, because inlined integers sort numerically within their type
(§5.1) — the order-preserving property finally earning its keep.

### 13.4 Probe or merge is a per-hop decision

The intersection in §13.3 can be done two ways, and neither is always right:

| | Cost | Wins when |
|---|---|---|
| Merge both ranges | `len(a) + len(b)` | the two sides are comparable |
| Probe from the smaller | `len(frontier) × log n` | one side is much smaller |

The difference is not marginal. `?s iso:level 4` is unrestricted — if `iso:level`
is used on 50,000 entities, the merge walks 50,000 entries to intersect with 600,
where probing costs 600 binary searches. **In exploration one side is almost
always much smaller, because every hop after the first descends from an
already-narrowed frontier.** Probing is the usual answer here; merging is the
usual answer inside a SPARQL BGP where both sides are index ranges.

`Range.Len()` is O(log n), so both plans can be priced before either is committed
to. That is a query planner, and it is worth saying so rather than growing one
accidentally: the same numbers that budget the request (§13.2) choose its plan.

**Iterate level-at-a-time, not depth-first.** The natural way to write this is
nested cursors — one per exploration node, descending recursively — and it is
expressible: `[]VarIter` unboxed is the shape §12.3 anticipated for leapfrog
triejoin. But `Seek` is only cheap because it searches the *remaining* span, which
requires monotonically ascending arguments. Depth-first visits the first risk's
owner (ID 5,000) and then the second risk's owner (ID 300), so the depth-2 cursor
runs backwards and has to restart — ~19 probes per restart, tolerable at this
scale and strictly worse. Breadth-first keeps every cursor forward-only, and it is
the same nested-iterator machinery with the recursion turned inside out.

Breadth-first also makes the dedup structural rather than a discipline: the
frontier for the next hop *is* the deduped level, so "descend once per distinct
entity" needs no visited-set and no guard that a later change can forget. The one
place a set is still needed is a cyclic exploration path, where a per-node set is
what terminates the fixpoint — it is monotone and bounded by the dictionary, so
the iteration stops when no set grew. That is the only reason a cyclic path is
safe to accept from a client.

### 13.5 What the frontier is

A frontier of 100–1,000 entity IDs, built by appending and then read in ascending
order. Three candidate representations, priced at Go 1.24+ Swiss table layout
(groups of 8 slots, 8-byte control word plus 8×4-byte keys = 40 B/group,
`struct{}` values occupy nothing, max load 7/8):

| Members | `map[uint32]struct{}` | sorted `[]uint32` | flat bitset at `nTerms` = 10⁵ |
|---|---|---|---|
| 100 | 16 groups → ~0.75 KB | **0.4 KB** | 12.5 KB |
| 1,000 | 256 groups → ~10.4 KB | **4 KB** | 12.5 KB |

1,000 lands just past a doubling — 896 members still fit 128 groups at ~5.2 KB —
so the map carries ~44% slack there. On the pre-1.24 bucket layout the figures are
~0.8 KB and ~12.3 KB, so the ordering is robust to the implementation.

**The slice wins, and it wins because §13.4 removed the membership test.** The set
existed only to answer "have I seen this, should I descend"; breadth-first makes
that question disappear, so what is actually needed is an append-sort-dedup
buffer:

```go
buf = append(buf, far)          // per qualifying pair, no membership test
...
slices.Sort(buf)                // ~10 µs at n = 1000
frontier = slices.Compact(buf)
```

- One allocation with amortised doubling and no rehash — the map doubles about
  seven times on the way from 8 to 1,000 members, rehashing everything each time.
- **Ascending by construction**, which is what §13.4's forward-only cursors
  require. A map returns no order, so it would cost the sort *as well as* the map.
- The sort is ~10 µs against the ~100 µs of random gathers that produced the
  members, so it does not appear in the profile.

The bitset is not the small option at exploration sizes — it is the largest of the
three, and its virtue is that its cost is independent of population. Keep it only
if depth-first ever becomes necessary, where O(1) `SetIfAbsent` is load-bearing
and a constant 12.5 KB buys not caring how wide a level gets. It is also not the
GC hazard §4.1 would suggest a map is: `uint32` keys and `struct{}` values are
pointer-free, so a map's group arrays are allocated `noscan` and only its few
header pointers are traced.

Whichever is used, **`id < snap.Terms()` is the whole guard** — it rejects
out-of-range IDs and inlined IDs together, since bit 31 set puts an ID far above
any dictionary count (§3, §13.8).

### 13.6 `Range.GroupBy` — the one addition to layer 1

```go
// GroupBy yields one group per distinct value at `depth`, in a single linear
// pass. The run is already sorted, so grouping is adjacent-key detection, not
// hashing. It is Vars with the span kept instead of discarded.
func (r Range) GroupBy(depth int, f Filter) GroupIter

type GroupIter struct{ /* concrete, like Scan and VarIter */ }

func (g *GroupIter) Next() bool
func (g *GroupIter) Key() ID    // the value at `depth`
func (g *GroupIter) Sub() Range // the group, for Len / CountDistinct / drilling
```

`Vars` already walks distinct values at a depth and throws the extent away; this
keeps it. That is the entire implementation cost, and it is the primitive every
screen in §13.1 wants — the class picker is `GroupBy(1)` over the `rdf:type` range
in POSG, and the edge dropdown is `GroupBy(1)` over an S- or O-prefix range.

It belongs in layer 1 rather than layer 2 because `Sub()` returns a `Range`, which
keeps §12's rule intact: layer 2 stays a loop around layer 1 and never reaches
past it. It is also the answer to §12.9 question 2, arrived at the way that
question asked for.

Deliberately **not** added: a `Range.Restrict(depth, ids)` primitive for
intersecting a range against a caller-supplied sorted set. That is what §13.3's
hop does on every line, but `VarIter` plus `Seek` already expresses it exactly,
and a second spelling of one operation is precisely the two-access-paths failure
§12 opens by warning about.

### 13.7 The shape catalogue

The edge dropdown needs, for a class, every predicate leading out of and into it,
and the type at the other end. Two sources: the shapes, which give structure in
O(shape size), and the data, which gives structure in O(instances) and gives the
numbers either way. **Structure from the shapes, numbers from the data** — the
dropdown then populates instantly for a class with a million instances, and the
diff between the two is a validation finding the explorer gets for free.

Out-edges are `sh:targetClass` → NodeShape → `sh:property` → each property shape's
`sh:path` and `sh:class`/`sh:node`. In-edges are the reason the direction works at
all: an OSPG prefix on `sh:class = iso:Risk` finds every property shape anywhere
that targets Risk, and one POSG lookup on `sh:property` walks back to its owning
NodeShape and thence its `sh:targetClass`.

**Interpreted from the triples that is ~250 µs for a simple 20-property class**,
which would be fine. It stops being fine because of the parts of SHACL people
actually use:

| Feature | Why it costs |
|---|---|
| `sh:path` as a sequence or `sh:alternativePath` | An RDF list — a blank-node chain of `rdf:first`/`rdf:rest`; dependent lookups with no parallelism |
| `sh:or`, `sh:xone` | The same, with the interesting constraint one list-hop further away |
| `sh:node` recursion | A property shape referencing another node shape: a graph walk with cycle detection |
| Five target mechanisms | `sh:targetClass`, `sh:targetSubjectsOf`, `sh:targetObjectsOf`, `sh:targetNode`, implicit class target — a union, not a lookup |
| Shape inheritance | `iso:CriticalRisk` must show `iso:Risk`'s properties; cheap only because A.4 already materialised the `rdfs:subClassOf` closure |

That is a small interpreter over blank-node structures, and single-digit
milliseconds is easy to reach. Once per click it would still be acceptable; §13.2
makes it once per node per request.

**The objection, and why it does not hold.** A compiled catalogue looks like the
second representation that `log.md` §11.5 rejects checkpoints for and that §9
above rejects `mmap`-ing the dictionary blob for. It is not the same thing: those
rejections are about a second *durable* representation, one that survives a crash
and can drift from the log. A structure built in memory during replay is the same
class of object as the six permutations, the dictionary arena, and the derived
bitset — a resident projection, rebuilt on every wake, structurally incapable of
drifting because it never outlives the process. The whole of this document is
resident derived structures.

What decides it is the second argument: **the code has to exist anyway.** If
shapes are in the store then something validates against them, and no validator
re-interprets the shape graph per focus node. The catalogue is the front half of
the validator with a second consumer, not a new component.

**In-edges force whole-catalogue compilation.** Finding every shape anywhere that
targets Risk cannot be done per class on demand without scanning every shape, so
there is no useful lazy-per-class form. That is a conclusion from the workload
rather than from taste, and it fixes the structure:

```go
// Edge is one declared property of one class, in one direction.
type Edge struct {
	Pred  ID     // 4  the predicate
	Far   ID     // 4  sh:class / sh:node target; 0 if datatype-valued
	Card  uint32 // 4  packed sh:minCount / sh:maxCount
	Flags uint16 // 2  inverse | fromShape | fromRange | observedOnly
	_     uint16 // 2
}                // 16 bytes

type Catalogue struct {
	classes []ID     // sorted; binary search
	outOff  []uint32 // outOff[i]..outOff[i+1] indexes out
	out     []Edge
	inOff   []uint32 // same class ordinals
	in      []uint32 // indices into out, grouped by Far
}
```

```packet
caption: Edge — 16 bytes, one per declared property of one class
row: 8
0,4:  Pred | predicate term ID
4,4:  Far | target class; 0 if datatype-valued
8,4:  Card | packed min/max
12,2: !Flags | provenance and direction
14,2: — | reserved
```

Offsets and flat arrays, per §4 — and pointer-free, so it stays `noscan`, which
under several hundred processes is worth more than its size. A TBox of 300 classes
averaging 20 properties is ~6,000 edges: **under 200 KB**, 0.6% of the §10 budget,
paid per tenant because §9 rejected sharing a TBox across tenants.

`Flags` carries provenance because the three sources are not equivalent. A shape
declares what must be there; `rdfs:domain`/`rdfs:range` licence a conclusion and
say nothing about what is stored — the same distinction §3 draws when it refuses
to recover a datatype from OWL range axioms; and an observed predicate is neither.
A UI that renders all three identically is making a claim it cannot support.

**Compile it lazily and key it by TBox epoch, not by index set.** This is the part
that produces a wrong answer years later if it is missed. `Snapshot.At(e)` pairs
an *old epoch* with the *current* `*indexSet`; visibility filtering is what makes
the view historical. A catalogue cached against that index set would describe
today's ontology, so an exploration pinned at epoch 4,000 would be structured by
properties that did not exist yet, each shown with a count of zero and presented
as fact.

The fix is small. The writer records the last epoch that touched a TBox graph; the
catalogue is keyed by that epoch, and a snapshot selects the catalogue whose TBox
epoch is the greatest ≤ its own. Ontology upgrades are rare, so the map holds a
handful of entries at ~200 KB each, and under eviction they are rebuilt on wake
like everything else. Compile the class-hierarchy walk with `OriginAny` — the
subclass closure is exactly the materialisation you want — and the shape
declarations themselves with `OriginAsserted`.

It degrades rather than failing: a class with no shape falls back to the
data-driven route, which is O(instances) and correct. The catalogue is an
accelerator over ABox truth, never the authority on what exists.

```go
func (s Snapshot) Shapes() *Catalogue
```

### 13.8 Two corrections to §12

**`CountDistinct` belongs on `Range`.** §12.5 offers only
`Snapshot.CountDistinct(c, p, f)`, which takes a `Pattern` and therefore cannot
express "this sub-range" — so §13.6's `GroupIter.Sub()` would have had nothing to
call. Moving it down and leaving the snapshot form as a wrapper is what §12's own
"layer 2 is layer 1 with a loop around it" implies anyway:

```go
func (r Range) Count(f Filter) int
func (r Range) CountDistinct(c Component, f Filter) int
func (r Range) Exists(f Filter) bool

func (s Snapshot) CountDistinct(c Component, p Pattern, f Filter) int {
	return s.Match(p).CountDistinct(c, f)
}
```

**The term count belongs in `indexSet`.** §12.1's `Snapshot` reaches the
dictionary through a plain `*Dict` field, and `Dict.off` is a growing `[]uint32`,
so reading `len(off)` while the writer interns is a race on the slice header.
Every other structure a reader touches — fact chunks, the derived bitset, the
epoch table — lives inside `indexSet` precisely so that one atomic load yields a
consistent set; §4 already established that `blob` must be chunked so `byTerm`
keys cannot dangle, and the count needs the same treatment. One field closes it:

```go
type indexSet struct {
	ord     [6]run
	chunks  [][]Fact
	derived []uint64
	epochs  [][]EpochMeta
	nTerms  uint32 // dictionary high-water mark at this publication; §13.8
}

func (s Snapshot) Terms() ID // = idx.nTerms
```

Correct by construction rather than by timing, and it is wanted in four places:
sizing any per-request structure indexed by ID (§13.5), the single
`id < snap.Terms()` guard, §3.4's replay assertion that every dictionary ID fits
in `u32`, and as a free monotonic metric — dictionary growth per tenant is the
cheapest available signal that a tenant is heading somewhere §10's sizing does not
cover.

The count is a high-water mark that only ever grows, because terms are never
removed (`architecture.md` §3.6, made structural by `log.md` §5.2). Combined with
`log.md` §5.2's ordering rule — a fact visible at epoch *e* can only reference
terms defined at or before *e* — a snapshot-pinned count is exactly right for
everything that snapshot can see.

One consequence worth recording while it is in view: because bit 31 discriminates
the inlined half of the ID space (§3), the dictionary ceiling is 2³¹ and not the
4.3×10⁹ §3.2 quotes. Against ~10⁵ terms that is a 21,000× margin, so it does not
bind; it is off by one bit and should read as such.

### 13.9 Open questions

1. **Is the exploration path a public query surface?** §13.2 accepts an arbitrary
   client-supplied path and validates it. The alternative is to sign the blob so
   only server-issued states return. Validating is more honest — a read-only
   traversal of a tenant's own data is not an escalation — but it means admitting
   a small query language exists and documenting its budget. Decide deliberately;
   it is easier to sign later than to un-publish a surface.
2. **What is the path budget?** §13.2 prices a request before running it, and no
   one has said what the limit is. Needs a real query mix, and it interacts with
   the active-fraction question in §11.2, since the ceiling is per concurrent
   request per tenant.
3. **Does the catalogue need `rdfs:domain`/`rdfs:range` as a second source?**
   `Flags` reserves room for it. Worth it only for tenants whose ontologies carry
   no shapes, and the UI then has to present three provenance classes without
   implying they are equivalent.
4. **How far does a node extend?** §12.6 raises this for entity history and it
   recurs identically here: if amounts and assessments are structured nodes, an
   edge to them is an edge to a blank node rather than to an entity the user
   recognises. Blank-node closure would fold them into their parent. Same policy
   decision, and it should be made once for both features.
5. **Does "some" or "all" need first-class support?** An edge showing 250 roles
   does not say whether every risk has an owner, and in a compliance product the
   number wanted is frequently the complement — the 43 risks with no owner. That
   is the frontier minus the join's distinct left column, not a number on the
   edge, and a UI that shows only the edge invites the wrong reading.
