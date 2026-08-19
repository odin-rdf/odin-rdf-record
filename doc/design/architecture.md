# A simple, efficient RDF triplestore on bbolt

**Status:** research note. Not a specification, not a commitment. The purpose is to
pin down the decisions that are expensive to reverse — key formats, the index set,
the transaction model — and to argue each one well enough that we can disagree with
it on the merits later.

**Decisions taken as input to this document** (from the design conversation):

| Question | Choice |
|---|---|
| Data model | Triples now; quads sketched in §9 so the key format can absorb them |
| Term storage | Dictionary-encoded — terms are interned to integer IDs |
| Query surface | ~~Pattern matching + joins, not a full SPARQL algebra~~ — **revised to SPARQL**, see [Appendix A.7](#a7-the-query-surface-decision-revisited) |
| Depth areas | Transactions/MVCC, typed range queries, cardinality stats, unlanded research |

Bulk loading is deliberately *not* a deep section; it comes up only where it
constrains the on-disk layout (§4.2).

### The workload premise

Two properties of the intended application were established after the first draft
and are load-bearing enough that several recommendations below were **reversed** to
account for them:

- **Append-only with epoch versioning.** ISO/IEC audit obligations mean data is
  never deleted. A retraction is a new record carrying a monotonically increasing
  epoch, not an erasure. History is immutable by policy.
- **≈99:1 read-to-write.** Writes are ~1% of the work the system does.

- **10,000–20,000 entities**, with edges and properties. Call it 10⁵–10⁶ triples.
- **RDF was chosen for the ontologies**, not for the graph model: ISO/IEC standards
  are expressible as ontologies, and ontologies are what make the data tractable to
  AI systems. The triplestore exists to serve that, not the other way round.

The first two premises are unusually favourable for bbolt. The third invalidates
about a third of this document, and pretending otherwise would be dishonest, so it
is dealt with first. The fourth relocates where the difficulty actually lives, and
is developed in **[Appendix A](#appendix-a--the-ontology-reasoning-and-ai-layer)**,
which by this point is arguably the most important part of the document.

### Scale, and what it invalidates

At 20,000 entities and, say, twenty statements each, the store holds ~4×10⁵ triples.
The consequences are not incremental:

| Quantity | Value at 4×10⁵ triples |
|---|---|
| All six index permutations, in RAM, as sorted fact-ID slices | **~10 MB** |
| The fact table itself, versioned (S, P, O, assert, retract) | **~13 MB** |
| Dictionary, ~10⁵ distinct terms averaging 40 bytes | **~6 MB** |
| **Whole store, everything, in memory** | **~30 MB** |
| Full scan of one index at ~1 GB/s | **~10 ms** |

Everything in §4.2 about page arithmetic, B+tree fanout, `FillPercent`, and cache
residency assumed 10⁷–10⁹ triples. At 4×10⁵ the entire working set is smaller than
a single modern CPU's L3-plus-a-bit and is resident in RAM permanently. **The
B+tree is no longer buying anything on the read path**, because there is no read
path — there is a slice.

So the recommendation changes shape. Not "bbolt with careful key formats", but:

> **bbolt is the durable, hash-chained, append-only log of record. The indices are
> derived in-memory state, rebuilt from that log at startup.**

This honours the audit obligation better than the original design did — the log
*is* the system of record, and every index is a disposable projection of it, which
is precisely the property an auditor wants to hear. It also deletes whole
categories of difficulty: no mmap aliasing rules (§6.2), no transaction lifetime
constraints on iterators, no long-reader file inflation, no `FillPercent` tuning,
no page-fill compaction, no cardinality estimation worth the name.

```go
// Fact is the single canonical record. Facts are appended and never reordered
// or removed, so a fact's slice offset is a stable, permanent, citable
// identifier — which is itself an audit-friendly property.
type Fact struct {
	S, P, O ID
	Assert  uint64 // epoch at which this became true
	Retract uint64 // epoch at which it stopped; maxEpoch while live
}

type FactID uint32

// Store holds one fact table and six sort orders over it. Each order is a
// permutation of fact IDs, so a retraction is a single field write in facts[]
// that is instantly visible through all six orders with no index maintenance.
type Store struct {
	facts []Fact
	perm  [6][]FactID // SPO, SOP, PSO, POS, OSP, OPS
	terms *Dict
}
```

The struct above is the shape, not the concurrency-safe form. `facts` should be
chunked and the six orders should be published as immutable snapshots rather than
mutated in place; §6.5–6.6 and B.5 give the reasons and the corrections. Neither
changes the sizing or the interface.

Six orders cost `4 bytes × 4×10⁵ × 6 ≈ 10 MB`. At 10⁸ triples the choice between
three and six permutations was a real budget decision (§4.1); here it is not a
decision at all — **take all six**, get every sort order for merge joins and every
variable order for worst-case-optimal joins (§7.4), and stop thinking about it.

Insertion into a sorted `[]FactID` is an O(n) memmove, which at 4×10⁵ elements is a
1.6 MB copy — on the order of 100 µs, six times, at a 1% write rate. It is fine.
If it ever stops being fine, batch and re-sort rather than reaching for a tree.

Startup replays the log in epoch order. 4×10⁵ records read sequentially out of
bbolt is well under a second, and it is the only recovery path there is, which
means it is exercised on every single start — the most reliable kind of recovery
code.

**What survives from the rest of this document at this scale:**

| Section | Status |
|---|---|
| §3 dictionary encoding | Keep. Fixed-width IDs make facts comparable in one instruction. Now a `map[string]ID` + `[]Term`, mirrored into bbolt. |
| §3.4 inlined terms | Keep — cheap and it still gives ordered integers (§5.1). |
| §6.4–6.7 epochs, retraction, audit log | **The core of the design.** Read these first. |
| §7 joins | Keep, simplified: sorted slices, `sort.Search` as the leapfrog seek. |
| §5.2 side value index | Skip. At 4×10⁵ facts, scan and filter. |
| §8 cardinality statistics | Mostly skip. A bad join order costs milliseconds. Keep only per-predicate counts, which are one `map[ID]int`. |
| §4.2 page arithmetic, §4.3 layouts | Reference only. Applies if this ever reaches 10⁷+. |
| §9 quads | Still a live modelling question; the storage cost argument is now irrelevant. |
| §10.2 succinct cold tier, §10.3 order-preserving dicts, §10.4 FSST | Reference only. These solve problems you do not have. |
| §10.1 worst-case optimal joins, §10.5 sampling estimation | §10.1 gets *easier* (six orders are free). §10.5 becomes unnecessary. |

The rest of the document is retained as written, because a design note that only
covers the case you have is worth less than one that shows where the boundaries
are — and because "what would change at 100× scale" is a question that gets asked
eventually.

### Consequences of append-only and 99:1 read

Independently of scale:

| Consequence | Where |
|---|---|
| Term garbage collection becomes a non-problem, not a deferred one | §3.6 |
| Long-running queries cannot inflate the file — the epoch gives a snapshot that outlives any transaction, so §6.2's worst operational edge disappears entirely | §6.6 |
| Query results become **permanently cacheable** keyed by `(query, epoch)`, because history cannot change | §6.5 |
| Retraction becomes a field write, not an index operation | §6.4 |
| Materialized inference gets dramatically simpler: only the *addition* direction is ever needed | §10.7 |
| A hash-chained log gives tamper evidence essentially for free | §6.4 |

One caution against over-reading the append-only premise: **"never delete" does not
mean "never compact".** `bolt.Compact` exists to restore *page fill factor*, not to
reclaim deleted rows. An append-only store written in random key order still
degrades to 50–70% page occupancy, because B+tree splits leave half-empty pages
regardless of whether anything was ever removed. §6.7 develops this — though under
the log-of-record design above it applies only to the log bucket, which is written
in ascending key order and therefore packs perfectly anyway.

Language is Go. The key/value store is
[bbolt](https://github.com/etcd-io/bbolt), etcd's maintained fork of Ben Johnson's
Bolt, which is itself a Go re-imagining of Howard Chu's LMDB.

---

## Table of contents

1. [What bbolt gives us, and what it withholds](#1-what-bbolt-gives-us-and-what-it-withholds)
2. [Data model and running example](#2-data-model-and-running-example)
3. [The term dictionary](#3-the-term-dictionary)
4. [Index design](#4-index-design)
5. [Ordering and typed range queries](#5-ordering-and-typed-range-queries)
6. [Transactions, MVCC, versioning, and iterator lifetime](#6-transactions-mvcc-versioning-and-iterator-lifetime)
7. [Query evaluation](#7-query-evaluation)
8. [Cardinality statistics](#8-cardinality-statistics)
9. [Extending to quads](#9-extending-to-quads)
10. [Promising research that has not landed in products](#10-promising-research-that-has-not-landed-in-products)
11. [Open questions](#11-open-questions)
12. [Bibliography](#12-bibliography)
- [Appendix A — The ontology, reasoning, and AI layer](#appendix-a--the-ontology-reasoning-and-ai-layer)
- [Appendix B — The application layer](#appendix-b--the-application-layer)

> **Reading order.** Sections 1–10 were written before the workload was known and
> assume a much larger store. If you are reading this to build the actual system,
> read the premise block above, then §6.4–6.7, then Appendices A and B. The
> numbered sections are the reference material behind those conclusions.

---

## 1. What bbolt gives us, and what it withholds

Every decision downstream is a consequence of bbolt's shape, so it is worth being
precise about it before designing anything.

**What we get.**

- A single memory-mapped file containing a **B+tree**, ordered by unsigned
  lexicographic byte comparison (`bytes.Compare`) over keys. Order is the whole
  product; it is why a K/V store can host an RDF index at all.
- **Buckets**: named, independent B+trees inside the one file, nestable.
- **Cursors** with `First`, `Last`, `Seek`, `Next`, `Prev`. `Seek(k)` positions at
  the smallest key `≥ k`. That single primitive is what makes prefix scans, range
  scans, and (§7.4) worst-case-optimal joins possible.
- **MVCC via copy-on-write**: one writer at a time, unbounded concurrent readers,
  each reader pinned to a consistent snapshot. Transactions are serializable, and
  a committed transaction is durable after one `fsync` of the meta page.
- `Bucket.NextSequence()` — a monotone `uint64` counter per bucket, incremented
  transactionally. It is exactly the dictionary ID allocator we need, and it
  starts at 1, leaving **ID 0 free to mean "unbound"** in query patterns.

**What it withholds — and this is the interesting half.**

- **No key prefix compression.** Every key is stored in full in the leaf page.
  RocksDB, LMDB (partially), and most LSM engines do some form of prefix or delta
  encoding; bbolt does not. Key size therefore translates *linearly* into page
  count, and page count translates into cache misses. This is the single
  strongest argument for dictionary encoding, quantified in §4.2.
- **No subtree cardinality on inner nodes.** There is no `rank(key)` and no
  O(log n) "how many keys are between A and B". `Bucket.Stats()` exists but walks
  every page. Any cardinality estimate must be *maintained* or *sampled*; it
  cannot be *read* (§8).
- **No compression, no column encoding, no bloom/range filters.** What we write
  is what lands on disk.
- **Single writer.** Ingest throughput is bounded by one goroutine plus one fsync
  per commit. Batching is not an optimization, it is the only mode of operation
  for bulk writes.
- **Monotonic file growth.** Freed pages are reused but the file does not shrink;
  reclaiming space needs `bolt.Compact` into a fresh file. Worse, pages visible
  to any *open read transaction* cannot be reused, so a long-running query in the
  presence of a busy writer inflates the file (§6).
- **Hard limits.** `MaxKeySize` is 32768 bytes; `MaxValueSize` is `(1<<31)-2`.
  RDF literals can exceed the key limit, which forces a design decision in §3.2.

The honest summary: bbolt is a well-behaved ordered map with excellent read
concurrency, a mediocre write path, and no built-in space efficiency. A triplestore
on top of it must therefore (a) make keys small and fixed-width, (b) keep the index
count low, and (c) never rely on the engine to tell it anything about data
distribution.

---

## 2. Data model and running example

An RDF triple is a subject, predicate, object. Subjects are IRIs or blank nodes;
predicates are IRIs; objects are IRIs, blank nodes, or literals. A literal is a
lexical form plus *either* a language tag *or* a datatype IRI.

The running example, in Turtle:

```turtle
@prefix ex:   <http://example.org/> .
@prefix foaf: <http://xmlns.com/foaf/0.1/> .
@prefix xsd:  <http://www.w3.org/2001/XMLSchema#> .

ex:alice a foaf:Person ;
    foaf:name  "Alice"@en ;
    foaf:age   34 ;
    foaf:knows ex:bob, ex:carol .

ex:bob a foaf:Person ;
    foaf:name  "Bob"@en ;
    foaf:age   41 ;
    foaf:knows ex:carol .

ex:carol a foaf:Person ;
    foaf:name  "Carol"@en ;
    foaf:age   29 ;
    foaf:knows ex:alice .
```

Two properties of the RDF model matter enormously for storage and are easy to get
wrong:

**A graph is a set, not a bag.** Asserting a triple twice is asserting it once.
This is a gift: `Bucket.Put` is idempotent, so insertion needs no read-check and
no duplicate handling. It also means we never store a multiplicity — unless we
later add inference, where derivation counts become necessary (§10.7).

**Literal identity is lexical, not semantic.** `"34"^^xsd:integer` and
`"034"^^xsd:integer` denote the same *value* but are different *terms*. Two graphs
containing one each are not equal graphs. Any value-based optimization — inlining
integers into IDs (§3.4), order-preserving encodings (§5) — must not silently
conflate them. The mitigation used throughout this document is to apply
value-based tricks **only to canonical lexical forms** and route everything else
through the ordinary dictionary path.

In Go:

```go
type Kind uint8

const (
	KindIRI Kind = iota + 1
	KindBlank
	KindLiteral
)

// Term is the in-memory form of an RDF term. It is a value type on purpose:
// terms are compared, hashed, and copied constantly, and pointer-chasing here
// shows up immediately in profiles.
type Term struct {
	Kind     Kind
	Value    string // IRI text, blank-node label, or literal lexical form
	Lang     string // literals only; "" if absent
	Datatype string // literals only; "" is read as xsd:string
}

type ID uint64 // 0 means "unbound" / "no term"

type Triple struct{ S, P, O ID }
```

---

## 3. The term dictionary

### 3.1 Why dictionary-encode at all

The alternative — writing the lexical form of each term directly into every index
key — is simpler and avoids a lookup hop. It is also, on bbolt specifically, a
serious mistake.

Consider `<http://xmlns.com/foaf/0.1/knows>`: 34 bytes. A typical DBpedia or
Wikidata IRI runs 30–60 bytes. An inline-lexical triple key averages perhaps 120
bytes, and it appears in *three* indices, so each triple costs ~360 bytes of key
material before page overhead. Because bbolt does no prefix compression, the fact
that a million triples share the same predicate IRI buys nothing — that IRI is
written out a million times per index.

Dictionary encoding stores each distinct term once and reduces every index key to
a fixed 24 bytes. The measured consequence is in §4.2: roughly a 3.4× improvement
in entries per page, which is 3.4× fewer page faults on a scan and 3.4× more of
the working set resident in the OS page cache.

This is also what essentially every serious triplestore does — Jena TDB's `NodeId`,
Virtuoso's `IRI_ID`, RDF4J's native store, RDF-3X's ID triples (Neumann & Weikum,
VLDB 2008), Oxigraph's `EncodedTerm`. Hexastore (Weiss et al., VLDB 2008) assumes
it as a precondition. The design space is well-trodden; the interesting choices are
in the details below.

The cost is real and should be stated: every result tuple needs an ID→term
resolution before it reaches the user, and that is a random B+tree probe per term.
Mitigations are batching (§7.2), inlining (§3.4), and caching hot IDs in an
in-process LRU.

### 3.2 The two buckets and their key formats

```go
var (
	bMeta  = []byte("m")   // format version, counters, configuration
	bT2I   = []byte("t2i") // canonical term bytes -> ID
	bI2T   = []byte("i2t") // ID (8B BE) -> canonical term bytes
	bSPO   = []byte("spo")
	bPOS   = []byte("pos")
	bOSP   = []byte("osp")
	bStats = []byte("st")
)
```

**`i2t` key:** 8-byte big-endian ID. Big-endian is not cosmetic — it makes
lexicographic byte order equal numeric order, which keeps the dictionary scannable
in ID order and, more importantly, is the same property the index keys rely on.

**`i2t` value:** the canonical term encoding, defined below.

**`t2i` key:** the canonical term encoding. **`t2i` value:** the 8-byte ID.

The canonical encoding is a tag byte followed by a payload. It must be injective —
two distinct RDF terms must never encode identically — because `t2i` uses it as a
key.

```
0x01  IRI          | UTF-8 IRI
0x02  blank node   | UTF-8 local label
0x03  xsd:string   | UTF-8 lexical form
0x04  lang literal | len(tag) u8 | lowercased BCP-47 tag | UTF-8 lexical form
0x05  typed lit.   | datatype ID (8B BE)                 | UTF-8 lexical form
```

```go
const (
	tagIRI    byte = 0x01
	tagBlank  byte = 0x02
	tagString byte = 0x03
	tagLang   byte = 0x04
	tagTyped  byte = 0x05

	xsdString = "http://www.w3.org/2001/XMLSchema#string"
)

// encodeTerm appends the canonical encoding of t to dst.
// dtID must be the dictionary ID of t.Datatype when t is a typed literal.
func encodeTerm(dst []byte, t Term, dtID ID) []byte {
	switch t.Kind {
	case KindIRI:
		return append(append(dst, tagIRI), t.Value...)
	case KindBlank:
		return append(append(dst, tagBlank), t.Value...)
	case KindLiteral:
		switch {
		case t.Lang != "":
			dst = append(dst, tagLang, byte(len(t.Lang)))
			dst = append(dst, strings.ToLower(t.Lang)...)
			return append(dst, t.Value...)
		case t.Datatype == "" || t.Datatype == xsdString:
			return append(append(dst, tagString), t.Value...)
		default:
			dst = append(dst, tagTyped)
			dst = binary.BigEndian.AppendUint64(dst, uint64(dtID))
			return append(dst, t.Value...)
		}
	}
	panic("encodeTerm: invalid kind")
}
```

Three details worth defending.

**Language tags are length-prefixed and lowercased.** Length-prefixed because a
tag and a lexical form concatenated without a delimiter is ambiguous
(`"en"` + `"US"` vs `"enUS"` + `""`). Lowercased because RDF 1.1 defines language
tags to be compared case-insensitively — `"Alice"@EN` and `"Alice"@en` are the
*same term*, and the dictionary must not admit both. A single length byte caps
tags at 255 bytes, which is far above the ~35 bytes BCP-47 permits in practice;
the encoder should reject longer tags rather than truncate.

**Datatypes are stored as IDs, not IRIs.** `xsd:integer` appears in every numeric
literal in the store. Interning it recursively means each typed literal pays 8
bytes instead of ~40, and the recursion terminates because a datatype is always an
IRI. It does introduce an ordering constraint on writes: the datatype IRI must be
interned before any literal using it.

**`xsd:string` gets its own tag rather than a datatype ID.** RDF 1.1 abolished
the plain/typed literal distinction — `"Alice"` *is* `"Alice"^^xsd:string`. Giving
it tag `0x03` makes the common case one byte instead of nine and, critically,
makes the two spellings encode identically, which is exactly the term identity RDF
demands.

**The 32 KB key limit.** A literal longer than ~32 KB cannot be a `t2i` key. This
is not hypothetical — RDF is routinely used to carry document bodies. The fix:

```go
// t2iKey returns the lookup key for a canonical term encoding.
// Short terms are keyed by their own bytes; long terms are keyed by a
// 0x00-tagged strong hash, which cannot collide with any canonical
// encoding because those all start with a tag byte >= 0x01.
func t2iKey(enc []byte) []byte {
	if len(enc) <= maxInlineTermKey { // 512 bytes
		return enc
	}
	h := sha256.Sum256(enc)
	return append([]byte{0x00}, h[:16]...)
}
```

Hashed entries need collision handling: the value becomes a list of candidate IDs,
and the lookup verifies each against `i2t`. With a 128-bit hash a collision is not
going to happen, but "not going to happen" is not the same as "handled", and a
silent term merge would corrupt the graph. The verification costs one extra probe
on a path that is already rare.

The 512-byte threshold is chosen not by the key limit but by B+tree fanout: a 4 KB
page holding 512-byte keys fits eight entries, and a dictionary with tree height 8
is a bad dictionary. Everything above the threshold gets fixed 17-byte keys and
excellent fanout, at the cost of losing prefix-scan ability over long terms — which
nothing needs.

### 3.3 ID allocation

```go
func (w *writer) intern(t Term) (ID, error) {
	if id, ok := inlineEncode(t); ok { // §3.4
		return id, nil
	}
	var dt ID
	if t.Kind == KindLiteral && t.Datatype != "" && t.Datatype != xsdString {
		var err error
		if dt, err = w.intern(Term{Kind: KindIRI, Value: t.Datatype}); err != nil {
			return 0, err
		}
	}

	enc := encodeTerm(w.scratch[:0], t, dt)
	key := t2iKey(enc)

	t2i := w.tx.Bucket(bT2I)
	if v := t2i.Get(key); v != nil {
		return ID(binary.BigEndian.Uint64(v)), nil // hash case: verify first
	}

	seq, err := t2i.NextSequence()
	if err != nil {
		return 0, err
	}
	id := ID(seq)

	var idb [8]byte
	binary.BigEndian.PutUint64(idb[:], uint64(id))
	if err := t2i.Put(key, idb[:]); err != nil {
		return 0, err
	}
	if err := w.tx.Bucket(bI2T).Put(idb[:], enc); err != nil {
		return 0, err
	}
	return id, nil
}
```

IDs are dense, sequential, and assigned in first-appearance order. Density matters
more than it looks: it keeps the `i2t` B+tree perfectly packed, it keeps IDs small
enough that a variable-width encoding would pay off (§4.2), and it makes random ID
sampling meaningful (§8.3).

`NextSequence` lives on the `t2i` bucket, so the allocator participates in the
write transaction automatically — a rolled-back transaction does not burn IDs
permanently in a way that matters, and two writers cannot race because there are
never two writers.

**Why not hash-derived IDs?** Using a truncated hash of the term as its ID removes
`t2i` entirely and makes interning a pure function, which is genuinely attractive
for parallel bulk loading (workers can encode independently with no coordination).
It costs: 128 bits of ID instead of 64 (so 48-byte index keys), permanently random
insertion order into every index (destroying B+tree locality), and the loss of any
correlation between ID order and anything useful. Sequential IDs at least cluster
co-occurring terms, because RDF is typically loaded in subject order. This is a
real fork in the road and worth revisiting if parallel ingest becomes the dominant
requirement.

### 3.4 Inlined terms

Many terms are small values that do not deserve a dictionary entry. `34`, `true`,
`2026-08-17` — interning them costs two B+tree writes on insert and a random probe
on every read, to store 2 bytes of information.

Reserve the high bit of the ID space:

```
bit 63     = 1  -> inlined term, no dictionary entry exists
bits 62-56 = inline type tag (0..127)
bits 55-0  = payload
```

```go
const (
	inlineFlag = uint64(1) << 63
	inlineBool = uint64(0x01) << 56
	inlineInt  = uint64(0x02) << 56 // xsd:integer, |v| < 2^55
	inlineDate = uint64(0x03) << 56 // xsd:date as days since epoch
)

// inlineEncode returns an inlined ID for terms that qualify.
// It refuses non-canonical lexical forms so that "034"^^xsd:integer keeps a
// distinct identity from "34"^^xsd:integer, as RDF requires.
func inlineEncode(t Term) (ID, bool) {
	if t.Kind != KindLiteral || t.Lang != "" {
		return 0, false
	}
	switch t.Datatype {
	case xsdInteger:
		v, err := strconv.ParseInt(t.Value, 10, 64)
		if err != nil || v < minInlineInt || v > maxInlineInt {
			return 0, false
		}
		if strconv.FormatInt(v, 10) != t.Value { // "034", "+34", " 34"
			return 0, false
		}
		// Offset-binary so that inlined integers sort numerically among
		// themselves under the same big-endian byte order the index uses.
		return ID(inlineFlag | inlineInt | (uint64(v) + inlineIntBias)), true
	}
	return 0, false
}
```

The consequence that makes this more than a space optimization: because the flag
and tag bits are constant within a type class and the payload is offset-binary,
**inlined integers sort numerically inside the index itself**. A SPARQL
`FILTER(?age > 30)` against a pattern `?s foaf:age ?age` becomes a range scan on
the POS index rather than a scan-and-filter. §5 develops this.

The 56-bit payload covers ±2^55 ≈ ±3.6×10^16, which comfortably holds every
integer anyone puts in a knowledge graph, with graceful fallback to the dictionary
beyond it. `xsd:decimal` and `xsd:double` do not fit and stay dictionary-resident
(§5 gives them a side index instead).

Precedent: Jena TDB inlines small values into its 64-bit `NodeId`; Virtuoso
inlines into `IRI_ID`; Oxigraph inlines small terms into `EncodedTerm`. The
order-preserving property, as far as I can determine, is *not* generally exploited
by these systems for range predicates — see §10.3.

### 3.5 Factoring IRI namespaces

Every IRI in the example shares one of two prefixes. Since bbolt does not prefix-
compress, `t2i` and `i2t` pay for those bytes repeatedly.

An optional third layer splits an IRI at its last `/` or `#` into a namespace and a
local name, interns namespaces in their own tiny bucket, and stores IRIs as
`(nsID, localName)`:

```
0x06  split IRI | namespace ID (8B BE) | UTF-8 local name
```

For DBpedia-shaped data this is a large win in dictionary size — often 3–5× on the
IRI portion — and it costs one extra lookup per IRI decode plus a split heuristic
that must be *deterministic* (otherwise the same IRI could encode two ways and
break injectivity). HDT (Fernández et al., JWS 2013) builds this idea into its
dictionary; Virtuoso uses a prefix table for the same reason.

**Recommendation: build it behind a format flag, off by default.** The dictionary
is not where the bytes are — §4.2 shows the indices dominate by an order of
magnitude — and correctness bugs in a term encoder are the worst kind of bug to
have. §10.4 discusses a strictly better answer (FSST) that arrived after most
triplestores were written.

### 3.6 Term garbage collection

Deleting a triple does not delete its terms; other triples may reference them.
Three options:

1. **Never collect.** Dictionary grows monotonically. Simplest, and for
   append-mostly knowledge graphs it is correct enough forever.
2. **Reference counting.** Store a count alongside each `i2t` entry. Costs three
   read-modify-writes per triple mutation, and the counts for common predicates
   become write hotspots. With a single writer there is no contention, but the
   write amplification is real — and reference counts are notoriously easy to get
   wrong under partial failure.
3. **Mark-and-sweep during compaction.** Since `bolt.Compact` already rewrites the
   file, piggyback on it: scan the three indices marking live IDs into a bitmap
   (dense IDs make this a plain bitset, ~12 MB per 100 M terms), then copy only
   live dictionary entries. IDs are *not* renumbered, so no index rewrite is
   needed.

**Recommendation: (1), unconditionally.** The append-only premise makes this not a
trade-off but a requirement — a term referenced by a retracted fact must remain
resolvable forever, or the audit log becomes unreadable. Options 2 and 3 are
retained above only to document why they are wrong here. Note the consequence: the
dictionary is part of the permanent record and must be included in whatever backup
and integrity regime covers the log.

---

## 4. Index design

### 4.1 Which permutations, and why three suffice

A triple pattern binds some subset of `{S, P, O}` — eight cases. An index over a
component order can answer a pattern by prefix scan iff the bound components form
a *prefix* of that order.

Three cyclic rotations cover all eight:

| Pattern | Turtle-ish shape | Index | Prefix |
|---|---|---|---|
| `???` | `?s ?p ?o` | SPO | — (full scan) |
| `S??` | `ex:alice ?p ?o` | SPO | S |
| `SP?` | `ex:alice foaf:knows ?o` | SPO | S,P |
| `SPO` | `ex:alice foaf:knows ex:bob` | SPO | S,P,O |
| `?P?` | `?s foaf:knows ?o` | POS | P |
| `?PO` | `?s foaf:knows ex:bob` | POS | P,O |
| `??O` | `?s ?p ex:bob` | OSP | O |
| `S?O` | `ex:alice ?p ex:bob` | OSP | O,S |

This is the standard result and the standard choice: Jena TDB/TDB2 defaults to
exactly SPO, POS, OSP; RDF4J's native store is configurable but ships something
equivalent. Hexastore (Weiss et al., VLDB 2008) argued for all six; RDF-3X
(Neumann & Weikum, VLDB 2008) went further with six full plus six aggregated plus
three fully-aggregated indices.

**The argument for three.** Every additional permutation is another full copy of
the triple set: +33% space and +33% write amplification per index, and writes are
already the constrained resource under a single-writer engine. Three is the
minimum that answers every pattern by prefix scan, and it is therefore the point
where you stop paying for coverage and start paying for *sort orders*.

**The argument against three, stated fairly.** The three rotations do not give
every useful sort order. Pattern `S??` yields results ordered by (P, O). If a
merge join needs those results ordered by O, you must sort. More concretely:

```sparql
SELECT ?s WHERE { ?s foaf:age 34 . ?s foaf:name ?n }
```

The driving pattern `?s foaf:age 34` is `?PO` → POS gives subjects in S order,
good. But for a star join across two predicates where both sides are selective,
what you want is each predicate's subjects in S order — that is **PSO**, which is
not in the set. POS gives (O, S) order, so subjects arrive grouped by object, not
sorted globally.

**Recommendation as originally written:** ship SPO, POS, OSP, with the index set a
configuration list rather than a constant, and PSO the first candidate for a
fourth.

> **Revised, given the actual workload: take all six.** The argument for three was
> entirely about write amplification and space. At a 99:1 read ratio, write cost is
> 1% of the budget; at 4×10⁵ triples with fact-ID permutations, all six orders cost
> ~10 MB total. Both halves of the argument evaporate. Six orders give the join
> planner every sort order for merge joins and every variable order for
> worst-case-optimal joins (§7.4), and remove an entire class of planning
> compromise for a rounding error in memory. The three-index analysis above is
> retained because it is the correct analysis at 10⁷+ triples.

```go
type IndexKind uint8

const (
	IdxSPO IndexKind = iota
	IdxPOS
	IdxOSP
)

// order[k] gives the component order stored by index k, as offsets into a
// Triple laid out {S, P, O}.
var order = [3][3]uint8{
	IdxSPO: {0, 1, 2},
	IdxPOS: {1, 2, 0},
	IdxOSP: {2, 0, 1},
}

func chooseIndex(p Pattern) (IndexKind, int) {
	s, pr, o := p.S != 0, p.P != 0, p.O != 0
	switch {
	case s && pr && o:
		return IdxSPO, 3
	case s && pr:
		return IdxSPO, 2
	case pr && o:
		return IdxPOS, 2
	case s && o:
		return IdxOSP, 2
	case s:
		return IdxSPO, 1
	case pr:
		return IdxPOS, 1
	case o:
		return IdxOSP, 1
	default:
		return IdxSPO, 0
	}
}
```

### 4.2 Key format and the page arithmetic

Index keys are three fixed-width big-endian IDs, in the index's component order.
Values are empty.

```go
// encodeKey writes the 24-byte key for t in index kind k into dst[:24].
func encodeKey(dst []byte, k IndexKind, t Triple) []byte {
	c := [3]ID{t.S, t.P, t.O}
	o := order[k]
	binary.BigEndian.PutUint64(dst[0:8], uint64(c[o[0]]))
	binary.BigEndian.PutUint64(dst[8:16], uint64(c[o[1]]))
	binary.BigEndian.PutUint64(dst[16:24], uint64(c[o[2]]))
	return dst[:24]
}
```

`ex:alice foaf:knows ex:bob` with IDs 1, 5, 2 becomes:

```
spo -> 00000000 00000001 | 00000000 00000005 | 00000000 00000002
pos -> 00000000 00000005 | 00000000 00000002 | 00000000 00000001
osp -> 00000000 00000002 | 00000000 00000001 | 00000000 00000005
```

**Fixed-width big-endian, not varint.** LEB128-style varints do not sort
lexicographically, which would destroy the index. Order-preserving variable-length
encodings exist (the length-in-high-bits scheme UTF-8 uses, or SQLite4's varint),
and with dense IDs most values fit in 2–4 bytes, so a 24-byte key could plausibly
become 9–12. That is a genuine ~2× space win. It costs branchy decode on every
cursor step, variable-length prefix construction, and a subtle bug class where
prefix comparisons must respect element boundaries. **Recommendation: fixed-width
now, revisit with a benchmark.** Note that inlined IDs (§3.4) all have bit 63 set
and so always occupy the full 8 bytes — a varint scheme would need a separate
inline representation to avoid negating its own benefit.

**Page arithmetic.** A bbolt page is `os.Getpagesize()`, normally 4096 bytes. The
page header is 16 bytes; each leaf element carries a 16-byte descriptor
(`flags, pos, ksize, vsize`) plus its key and value bytes.

| Layout | Bytes/entry | Entries per 4 KB page |
|---|---|---|
| Dictionary-encoded, 24-byte key, empty value | 16 + 24 = **40** | **~102** |
| Inline lexical terms, ~120-byte key | 16 + 120 = **136** | **~30** |

That 3.4× is the whole case for §3, expressed in the currency that matters — how
much of the index fits in the page cache.

At 100 M triples: 100e6 × 40 × 3 indices = **12 GB** at perfect packing. Which
brings us to the one bulk-load fact that constrains the format:

**`FillPercent`.** bbolt splits a leaf when it exceeds `FillPercent` (default 0.5)
and offers no rebalancing on delete. Random-order insertion therefore lands you
near 50–60% occupancy — that 12 GB becomes ~22 GB. Setting
`bucket.FillPercent = 0.95` when keys arrive in ascending order recovers nearly all
of it. Since the SPO index receives keys in ascending order iff triples are sorted
by (S, P, O), the loader should sort each batch per index before writing. Three
sorted passes, one per index, is the entire bulk-load story as it touches this
document.

**The empty value slot.** A zero-length value costs nothing beyond the descriptor
that is there anyway; an 8-byte value costs 8 more bytes (a 20% key-space
increase). It is free real estate worth remembering — candidates are an insertion
epoch for change-data-capture, or a derivation count for incremental
materialization (§10.7). It should stay empty until one of those is actually
wanted.

### 4.3 Alternatives considered and rejected

**A bucket per predicate (vertical partitioning).** Abadi et al. (VLDB 2007)
showed that splitting a triple table into one two-column table per predicate is a
large win in column stores. In bbolt, `?P?` and `?PO` patterns would become
whole-bucket scans, per-predicate statistics become nearly free, and you get both
SO and OS orders per predicate cheaply.

Rejected because: the POS index *already is* vertical partitioning — a
predicate-prefixed key range is precisely a per-predicate partition, in one B+tree
rather than thousands. Real vocabularies have long tails of rare predicates, and a
bbolt bucket has a minimum footprint of one page; ten thousand predicates with
three triples each would waste tens of megabytes and produce ten thousand
tree-height-1 B+trees. Worse, a `?p?` pattern would have to fan out over every
bucket. The prefix formulation gets the same locality with none of that.

**Adjacency lists in the value.** Key on `(S, P)`, store the sorted object IDs as
a delta-varint blob or a Roaring bitmap (Chambi et al., SPE 2016) in the value.
For `ex:alice foaf:knows ex:bob, ex:carol` this is one entry rather than two, and
the per-entry 16-byte descriptor amortizes across the whole list. On high-fanout
predicates (`rdf:type`, `owl:sameAs`) the space win is substantial, and set
intersection on Roaring bitmaps is very fast — attractive for joins.

Rejected as the primary layout because updates become read-modify-write of an
entire list under a copy-on-write engine: adding one object to a 100 K-element
list rewrites the whole blob and every page it spans. It is the right layout for
an immutable, compacted tier, and §10.2 proposes exactly that.

**All six permutations.** See §4.1. Deferred, not dismissed.

---

## 5. Ordering and typed range queries

Dictionary IDs are assigned in first-appearance order, so **ID order carries no
semantic meaning**. `"Alice"` may sort before or after `"Bob"` depending on load
order. Consequently:

```sparql
SELECT ?s ?age WHERE { ?s foaf:age ?age . FILTER(?age > 30) }
```

against a plain dictionary is a full scan of the `foaf:age` predicate range with a
post-filter. On a graph where `foaf:age` has 10 M triples and three match, that is
a bad plan and there is no index to fix it.

Three ways out.

### 5.1 Order-preserving inlining (recommended, partial)

For the types that fit in 56 bits — `xsd:integer`, `xsd:boolean`, `xsd:date`,
`xsd:gYear`, and with care `xsd:dateTime` at second resolution — §3.4 already
gives us IDs that sort in value order within their type class. The filter becomes
a bounded scan:

```go
// RangeByObject scans index POS over predicate p for objects in [lo, hi].
// Correct only when lo and hi are inlined IDs of the same inline type tag,
// because only then does ID order coincide with value order.
func (tx *Tx) RangeByObject(p ID, lo, hi ID) *Iter {
	c := tx.b(IdxPOS).Cursor()
	start := key3(p, lo, 0)
	stop := key3(p, hi, ^ID(0))
	return &Iter{c: c, start: start, stop: stop, kind: IdxPOS}
}
```

The encoding must be offset-binary (add `2^55` to signed values) so that negative
numbers sort below positive ones under unsigned byte comparison. The same trick,
applied to IEEE-754, handles floats — flip the sign bit for positives, flip all
bits for negatives:

```go
func orderPreservingFloat(f float64) uint64 {
	u := math.Float64bits(f)
	if u&(1<<63) != 0 {
		return ^u // negative: reverse the magnitude ordering
	}
	return u | 1<<63 // positive: sort above all negatives
}
```

though doubles cannot be inlined in 56 bits without losing precision, so they need
§5.2. NaN sorts above `+Inf` under this encoding, which is arguably as good an
answer as any given that SPARQL leaves NaN comparisons undefined.

**This covers integers and dates, which in practice is most of what people filter
on.** It costs nothing extra: no index, no bytes, no maintenance.

### 5.2 A side value index (recommended for the rest)

For decimals, doubles, and strings — and for collation-aware string ordering,
which no ID scheme can give you — add a fourth bucket:

```
ord: | class (1B) | order-preserving value bytes | term ID (8B BE) | -> (empty)
```

`class` groups comparable types (all numerics in one class so `xsd:decimal` and
`xsd:integer` interleave correctly, per SPARQL's numeric type promotion; strings
in another). A range predicate scans `ord` to produce a stream of candidate term
IDs, which then drive a POS lookup per ID.

The term ID suffix makes keys unique when two distinct terms share a value —
`"34"^^xsd:integer` and `"34.0"^^xsd:decimal` both encode to the same numeric
bytes but are different terms, and both must survive in the index.

The cost is a fourth write per literal insertion and a two-level lookup at query
time. It is only worth building for types §5.1 cannot inline, and only when
profiling says filters are the bottleneck. **Recommendation: design the bucket
now, build it later.**

### 5.3 Order-preserving dictionary (rejected here, interesting in §10.3)

Assign IDs *in value order*, so the dictionary itself is sorted and every range
filter is an ID range. Binnig, Hildenbrand & Färber (SIGMOD 2009) showed how to do
this in main-memory column stores using gapped ID allocation with periodic
renumbering.

Rejected for this design because renumbering an ID invalidates it in all three
indices, and under copy-on-write a renumbering pass rewrites the whole store.
Gapped allocation defers the problem but does not remove it, and RDF's mixed-type
object column means there is no single order to preserve anyway. §10.3 revisits
whether a *per-type* order-preserving subspace could get most of the benefit.

---

## 6. Transactions, MVCC, versioning, and iterator lifetime

### 6.1 The model

bbolt's concurrency model is the same as LMDB's: a single write transaction at a
time, serialized by a mutex, and any number of concurrent read transactions, each
seeing an immutable snapshot fixed at the moment it opened. Writers copy pages
rather than modifying them, so readers never block writers and writers never block
readers. Commit writes new pages, then fsyncs, then atomically swaps the meta
page.

This maps onto RDF semantics with unusual cleanliness. A `Store.Update` is one
`db.Update`; a query is one `db.View`. Isolation is **serializable** — stronger
than most triplestores offer, and free.

> **Read this as describing the bbolt-resident store.** Queries there read through
> bbolt and inherit its isolation. Once the indices move into memory, bbolt is off
> the read path entirely and supplies only atomicity and durability of a commit —
> so isolation has to be re-derived from the epoch. §6.5 and §6.6 do that, and find
> that serializability survives for a different reason.

```go
func (s *Store) Update(fn func(*Tx) error) error {
	return s.db.Update(func(btx *bolt.Tx) error { return fn(&Tx{bolt: btx}) })
}

func (s *Store) View(fn func(*Tx) error) error {
	return s.db.View(func(btx *bolt.Tx) error { return fn(&Tx{bolt: btx}) })
}
```

Inserting a triple is three `Put`s plus interning:

```go
func (tx *Tx) Insert(s, p, o Term) error {
	sid, err := tx.intern(s)
	if err != nil {
		return err
	}
	pid, err := tx.intern(p)
	if err != nil {
		return err
	}
	oid, err := tx.intern(o)
	if err != nil {
		return err
	}

	t := Triple{sid, pid, oid}
	var buf [24]byte
	for _, k := range [...]IndexKind{IdxSPO, IdxPOS, IdxOSP} {
		if err := tx.b(k).Put(encodeKey(buf[:], k, t), nil); err != nil {
			return err
		}
	}
	return tx.bumpStats(t) // §8
}
```

Because a graph is a set (§2), `Put` over an existing key is a no-op in effect,
and `Insert` needs no existence check. Delete is the mirror image, minus the
dictionary (§3.6).

### 6.2 The three lifetime rules that will bite

**(1) Bytes returned by `Get` and cursors are mmap'd and valid only inside the
transaction.** They point into the memory map. After the transaction closes, the
map may be remapped or the pages reused, and the slice becomes a segfault waiting
for a busy afternoon. Any term or key that outlives the transaction must be
copied:

```go
func (tx *Tx) Lookup(id ID) (Term, error) {
	var k [8]byte
	binary.BigEndian.PutUint64(k[:], uint64(id))
	v := tx.bolt.Bucket(bI2T).Get(k[:])
	if v == nil {
		return Term{}, ErrNoSuchTerm
	}
	// decodeTerm must copy: Term holds strings, and a string built from v
	// without copying aliases the mmap.
	return decodeTerm(v)
}
```

The API should therefore never hand a caller anything derived from the map without
copying, and it should never return an iterator that outlives its transaction.
The natural Go shape is callback-scoped:

```go
func (s *Store) Query(fn func(*Tx) error) error // the tx never escapes fn
```

Returning a `chan Triple` from a query is tempting and wrong unless the
transaction is explicitly kept open for the channel's lifetime — which leads
directly to rule (3).

**(2) Inside a write transaction, values from `Get` are invalidated by the next
mutation.** A read-modify-write on a stats counter must copy before it writes.

**(3) Long read transactions inflate the file.** bbolt cannot reuse a freed page
while any open read transaction might still see it. A query holding a read
transaction for ten minutes while a loader commits continuously forces every page
the loader touches to be freshly allocated, and the file grows by roughly the
write volume over that window. This is the sharpest operational edge in the whole
design.

Mitigations, in order of preference: bound query duration and fail loudly past the
bound; materialize large result sets into caller memory rather than streaming
lazily from a held transaction; run analytical workloads against a snapshot copy
(`bolt.Compact` to a second file, or a filesystem snapshot). Monitoring
`db.Stats().FreePageN` versus `db.Stats().TxStats` gives early warning.

### 6.3 Write throughput

Each `db.Update` ends in an fsync. That caps commit rate at the device's sync
rate — order 10^2/s on spinning media, 10^3–10^4/s on NVMe. Inserting triples one
per transaction is therefore fatally slow, and the fix is structural rather than
incidental:

- **Batch explicitly.** Accumulate N triples (10^4–10^5) and insert them in one
  `db.Update`. Sort per index first, per §4.2.
- **`db.Batch`** coalesces concurrent `Update` calls from many goroutines into
  shared transactions. Note its contract: **the function may be called more than
  once** if a peer in the batch fails, so it must be idempotent. Triple insertion
  is naturally idempotent — dictionary interning is not, since `NextSequence` would
  advance twice. In practice a re-run re-reads `t2i` and finds the existing entry,
  so the outcome is correct with a burnt ID. Worth an explicit test.
- **`db.NoSync = true`** for initial bulk loads where the whole file can be
  rebuilt on crash. An order of magnitude, and no safety cost *if* the recovery
  story is "load it again".

At a 99:1 read ratio and 10⁵–10⁶ triples, none of this is a constraint in practice.
It is documented because the log write path is the one place where durability is
not negotiable.

### 6.4 Epochs, retraction, and the audit log

The audit obligation is not a feature bolted onto the store; it is the store's
primary structure. The design below makes the log the system of record and
everything else a disposable projection of it.

**The epoch is the transaction sequence number.** One epoch per committed write
transaction, not per statement. This is the right granularity because a
transaction is the atomic unit of change, so an auditor asking "what changed, and
together with what?" gets a coherent answer. bbolt serializes writers, so epochs
are totally ordered and gap-free by construction — no coordination needed.

Three buckets carry the record:

```
txn: | epoch (8B BE)              -> | wall (8B) | actor (8B) | reason (8B)
                                     | n (4B) | prevHash (32B) | hash (32B) |

log: | epoch (8B BE) | seq (4B BE) -> | op (1B) | S (8B) | P (8B) | O (8B) |

ret: | factID (4B BE)              -> | epoch (8B BE) |
```

`op` distinguishes assert from retract, and — see [A.5](#a5-justifications-an-auditor-must-never-see-an-inference-presented-as-a-record) —
asserted from derived. `actor` and `reason` are term IDs, so the *why* of a change
is itself RDF and can be queried like anything else.

Both `txn` and `log` keys ascend monotonically. bbolt has a fast path for ascending
insertion that leaves the left page full on split, so the log packs at nearly 100%
occupancy with `FillPercent = 1.0` and writes sequentially. This is the ideal case
for a B+tree and it is what an append-only log naturally produces.

**Tamper evidence comes almost free.** `hash = H(prevHash ‖ epoch ‖ wall ‖ actor ‖
reason ‖ records)` makes the log a hash chain: altering any historical record
invalidates every subsequent hash. Verification is one sequential scan — at 4×10⁵
records, well under a second, so it can run at every startup rather than as a
scheduled job. Publishing the head hash externally (or countersigning it) upgrades
this from tamper-*evident* to tamper-*evident-and-attributable*, which is usually
what a certification auditor is after. This is a genuinely cheap thing to get right
at the start and a genuinely expensive thing to retrofit.

**Bitemporality.** `wall` (when we recorded it) and any domain-level validity date
(when it was true) are different, and audit regimes generally care about both. The
epoch chain gives transaction time rigorously. Valid time is domain modelling and
belongs in the ontology, not the storage layer — do not conflate them.

**Retraction is a field write.** Under the in-memory fact table from the scale
section, retracting a fact sets `facts[id].Retract = epoch`. That single write is
immediately visible through all six sort orders, because every order stores fact
IDs rather than copies. There is no index maintenance on retraction at all — which
is a direct payoff of the one-fact-table-many-orders layout, and the reason to
prefer it over six independent key sets.

### 6.5 Querying as of an epoch

```go
// visible reports whether f is part of the graph as of epoch e.
func (f *Fact) visible(e uint64) bool {
	return f.Assert <= e && e < atomic.LoadUint64(&f.Retract)
}

// Snapshot returns the epoch a new read should run at: the highest epoch that is
// both durable on disk and fully applied to memory. A query fixes this once, at
// the start, and passes it down the whole plan.
func (s *Store) Snapshot() uint64 { return atomic.LoadUint64(&s.published) }
```

**There is no `Now` constant, and an earlier draft of this section was wrong to
have one.** It defined `Now = ^uint64(0)` and read current state at that epoch,
which fails twice over. The small failure is an off-by-one: live facts carry
`Retract == maxEpoch`, so `e < f.Retract` at `e == maxEpoch` is false and every
live fact is invisible. The real failure is that a write transaction asserting ten
facts applies them to memory one at a time, so a reader pinned to "the latest
possible epoch" observes the transaction half-applied — no amount of fixing the
comparison repairs that.

Reading at a *published* epoch fixes both, and it is the whole of the isolation
mechanism:

- The writer applies every fact for epoch E to the fact table and the sort orders,
  and only then publishes E with `atomic.StoreUint64(&s.published, E)`.
- Facts from an in-flight epoch carry `Assert = E > e` and are rejected by the
  predicate that was already there. Retractions from an in-flight epoch carry
  `Retract = E > e` and likewise leave the fact visible. Partial transactions are
  invisible for free; there is no separate commit barrier to maintain.
- Publication must trail durability. Publish only after the commit has been
  fsynced, or a reader can observe an epoch that a crash then unmakes.

Nothing about the query path changes: current-state reads pass `Snapshot()`,
as-of-past reads pass any smaller epoch, and both run the same iterator with the
same one-comparison filter. **Versioning still costs the common path one predicate
and no I/O.**

As-of-past queries are less selective — you scan the present and reject facts
asserted later — but they are rare, and at 4×10⁵ facts a full rejecting scan is
~10 ms.

The property worth designing around: **history is immutable, so any result computed
as of epoch E is correct as of epoch E forever.** Cache keyed by `(query, E)` never
needs invalidation. At a 99:1 read ratio with a small working set, this is close to
a free order of magnitude, and it is available only because of the append-only
premise.

### 6.6 Snapshots that outlive a transaction

§6.2's third rule — long read transactions inflate the file — was the sharpest
operational edge in the original design. The epoch removes it structurally rather
than mitigating it.

A logical snapshot is a number, not a transaction. A long-running analytical query
fixes `e` once, then opens and closes as many short bbolt read transactions as it
likes; every one of them yields the same answer, because nothing at or below `e`
can ever change. bbolt's freelist is never pinned for more than microseconds, so
the file does not grow.

**The isolation this buys, stated precisely.** §6.1 called the model serializable
and credited bbolt for it. With the indices in memory, bbolt is not on the read
path at all, so the property has to be re-argued from the epoch — and it survives.
Writes are totally ordered by the single writer; each write transaction reads the
state its predecessor produced; a read-only transaction at epoch `e` is equivalent
to executing immediately after epoch `e` committed. That schedule is serial. This
is stronger than the snapshot isolation the mechanism superficially resembles,
because write skew requires two concurrent writers and there are never two.

**What the epoch does not remove, and this is what an earlier draft missed.**
Immutability is a property of the *fact table*, not automatically of the structures
built over it. Two of those are mutated in place and each needs its own argument.

*Retraction is safe.* A retraction recorded after `e` was fixed always carries
`Retract > e`, so `visible(e)` still returns true for it. A monotonically growing
retraction set is therefore safe to read without synchronization against any fixed
`e` — a reader can never observe a retraction that should have been invisible to
it. `Fact.Retract` should still be written and read atomically
(`atomic.StoreUint64` / `atomic.LoadUint64`) to avoid a data race in the Go memory
model sense, but no lock is required.

*The six sort orders are not safe.* Insertion into a sorted `[]FactID` is an O(n)
memmove over elements a reader may be mid-walk through, and that reader sees
skipped or duplicated entries. This is the one structure in the design that
genuinely needs synchronization, and B.5 develops the answer: make each permutation
an immutable object that the writer replaces by pointer swap, so a reader takes a
snapshot of the slice header and needs no lock at all. Reaching for an `RWMutex`
instead would reintroduce the exact problem this section claims to have removed —
Go's `RWMutex` blocks new readers once a writer is queued, so one long analytical
scan holding the read lock stalls the writer and then everything behind it.

*The fact table wants chunking* — `[][]Fact` with fixed-size chunks rather than one
growing slice. A plain `append` can reallocate the backing array and leave a reader
holding a stale copy. That case is in fact benign, because a retraction the reader
misses always carries `Retract > e` and `visible(e)` is unchanged either way — but
it is benign for reasons that take a paragraph to establish and one careless later
change to invalidate. Chunks never move, so the argument collapses to "nothing is
ever rewritten" and stays true without maintenance.

### 6.7 What "never delete" does not save you from

Worth stating plainly because the intuition is natural and wrong: **`bolt.Compact`
is about page fill factor, not about garbage.** A B+tree splits a full page into
two half-full pages. Insert 4×10⁵ keys in random order and you converge to roughly
50–70% occupancy whether or not you ever delete anything. Never deleting prevents
*fragmentation from deletion*; it does not prevent *fragmentation from insertion*.

Under the log-of-record design this is close to moot — the log is written in
ascending key order and so packs near 100%, and the indices are in memory where
the concept does not apply. It matters only if the bbolt-resident index buckets of
§4 are built, in which case a periodic offline rebuild in ascending key order
recovers 30–50% of the file. Which, at 30 MB, nobody will ever care about.

---

## 7. Query evaluation

### 7.1 The pattern interface

```go
// Pattern is a triple pattern; a zero component is an unbound variable.
type Pattern struct{ S, P, O ID }

// Iter yields triples matching a pattern, in the sort order of whichever
// index was chosen. It is valid only within its transaction.
type Iter struct {
	c      *bolt.Cursor
	kind   IndexKind
	prefix []byte
	k, v   []byte
	begun  bool
}

func (tx *Tx) Match(p Pattern) *Iter {
	kind, n := chooseIndex(p)
	return &Iter{
		c:      tx.b(kind).Cursor(),
		kind:   kind,
		prefix: prefixFor(kind, p, n), // n*8 bytes
	}
}

func (it *Iter) Next() bool {
	if !it.begun {
		it.k, it.v = it.c.Seek(it.prefix)
		it.begun = true
	} else {
		it.k, it.v = it.c.Next()
	}
	return it.k != nil && bytes.HasPrefix(it.k, it.prefix)
}

func (it *Iter) Triple() Triple { return decodeKey(it.kind, it.k) }
```

The whole matching layer is `Seek` to a prefix and walk while the prefix holds.
That is the entire benefit of putting the bound components first, and it is why
§4.1's covering argument was worth making carefully.

**Sort order is a first-class output.** `Match` should expose which index it used
so the join planner knows the order it is receiving:

```go
// SortOrder reports the component order in which this iterator yields triples.
func (it *Iter) SortOrder() [3]uint8 { return order[it.kind] }
```

A planner that does not know its inputs' sort orders cannot choose merge joins,
and merge joins are the reason RDF stores keep multiple index permutations at all.

**Batching.** Tuple-at-a-time iteration in Go pays an interface dispatch and a
bounds check per triple. Yielding `[]Triple` in chunks of 256–1024 amortizes both
and vectorizes downstream filters. This is the Volcano→vectorized transition that
MonetDB/X100 (Boncz et al., CIDR 2005) made for relational engines and which most
open-source RDF stores never made. It costs nothing but an awkward API and is
probably the single highest-value micro-decision in the execution layer.

### 7.2 Materializing results

A basic graph pattern binds variables, so evaluation produces `map[Var]ID` rows,
not triples. Resolving IDs to terms is a random probe into `i2t` per distinct ID —
which, on a 10^6-row result, dominates everything else.

Two mitigations, both cheap: resolve **once per distinct ID** (collect the distinct
set from the whole result page, sort it, then probe in ascending ID order so the
`i2t` cursor moves forward through the tree instead of jumping), and keep an
in-process LRU of hot IDs, since predicate and class IRIs recur in essentially
every row. Sorted batch resolution alone typically turns a random-probe pattern
into a near-sequential scan.

### 7.3 Joining

For a BGP like

```sparql
SELECT ?name WHERE {
  ?s foaf:knows ex:carol .
  ?s foaf:name  ?name .
}
```

three join strategies are relevant, and the storage layer determines which are
available.

**Index nested-loop (bind join).** Evaluate the most selective pattern, and for
each binding substitute into the next pattern and re-`Match`. Each inner iteration
is a `Seek` — a B+tree descent, ~3–4 page touches. This is the default for RDF and
usually the right answer, because triple patterns after substitution are highly
selective. Its weakness is the classic one: cost is `|outer| × log|inner|` and the
outer cardinality is exactly what we cannot estimate well (§8).

**Merge join.** If both inputs are sorted on the join variable, walk them in
lockstep in linear time with no random I/O. This is where the index set pays for
itself — and where the missing PSO index (§4.1) hurts, since the star join above
gets subjects in (O, S) order from POS rather than pure S order.

**Hash join.** Build a hash table on the smaller side. Needs memory proportional to
the build side and destroys sort order for downstream operators, but it is the
robust fallback when neither side is usefully sorted.

**Sideways information passing.** RDF-3X (Neumann & Weikum, SIGMOD 2009) observed
that once one pattern has been evaluated, the set of bound values can be pushed
into *sibling* scans as a filter, not just downstream. In our setting: after
scanning `?s foaf:knows ex:carol` and learning the subjects lie in ID range
[1000, 1200], the `?s foaf:name ?name` scan can seek within that range instead of
scanning the predicate wholesale. With dense sequential IDs this is unusually
effective, and it is a small amount of code: propagate min/max plus an optional
Bloom filter of the bound IDs into the sibling iterator. Few open-source
triplestores implement it.

### 7.4 Worst-case optimal joins

Binary join plans are provably bad on cyclic patterns. The canonical case is the
triangle:

```sparql
SELECT ?a ?b ?c WHERE {
  ?a foaf:knows ?b .
  ?b foaf:knows ?c .
  ?c foaf:knows ?a .
}
```

Any plan that joins two patterns first materializes a two-path set of size up to
`N²` even when the number of triangles is `O(N^1.5)`. The AGM bound (Atserias,
Grohe & Marx, FOCS 2008) says `N^1.5` is the true worst-case output size; NPRR
(Ngo, Porat, Ré & Rudra, PODS 2012) gave the first algorithm matching it, and
Veldhuizen's **Leapfrog Triejoin** (ICDT 2014) is the practical form.

LFTJ needs exactly two operations per relation: *iterate the values of the current
variable in sorted order*, and *seek forward to the first value ≥ x*. A bbolt
cursor over a sorted index provides both, natively. The fit is close to perfect:

```go
// varIter exposes one triple pattern as a sorted stream of values for the
// current join variable, at a fixed prefix depth.
type varIter interface {
	Key() ID          // current value
	Next() bool       // advance one value
	Seek(v ID) bool   // advance to first value >= v
	AtEnd() bool
}

// leapfrogSearch advances all iterators to their least common value.
// Per Veldhuizen (ICDT 2014): keep iterators in a ring ordered by current key;
// repeatedly seek the smallest to the largest until all agree.
func leapfrogSearch(its []varIter) (ID, bool) {
	sort.Slice(its, func(i, j int) bool { return its[i].Key() < its[j].Key() })
	p, max := 0, its[len(its)-1].Key()
	for {
		min := its[p].Key()
		if min == max {
			return max, true // all iterators agree
		}
		if !its[p].Seek(max) {
			return 0, false // this relation is exhausted
		}
		max = its[p].Key()
		p = (p + 1) % len(its)
	}
}
```

**The catch, and it is the interesting part.** LFTJ fixes a global variable order
— say `a, b, c` — and requires each pattern to be iterable as a *trie* in that
order. Pattern `?b foaf:knows ?c` under variable order `a, b, c` must yield `b`
values then, for each, `c` values: that is the PSO order, which §4.1 declined to
build. Some variable orders need SOP or OPS.

So worst-case-optimal join is a concrete, principled argument for materializing
**all six permutations** — which is what Hexastore proposed in 2008 for reasons
that were less sharp than this one. The trade is +100% index space (six copies
instead of three) and +100% write amplification, in exchange for provably bounded
behaviour on cyclic queries.

**Recommendation: build the three-index store first with the index set
configurable, implement LFTJ against the interface above, and measure on
triangle-heavy workloads before committing to six.** §10.1 and §10.2 describe two
research directions that would change this calculus substantially.

---

## 8. Cardinality statistics

Everything in §7 depends on estimating "how many triples match this pattern".
§1 established that bbolt cannot answer this — there is no rank operation, and
`Bucket.Stats()` walks every page. So statistics must be maintained or sampled.

### 8.1 Maintained counters

The cheapest useful statistics, updated in the same write transaction as the
triple:

```
st | 0x01                        -> total triple count      (u64)
st | 0x02 | predID (8B)          -> triples with predicate  (u64)
st | 0x03 | predID (8B)          -> HLL sketch: distinct subjects for predicate
st | 0x04 | predID (8B)          -> HLL sketch: distinct objects for predicate
st | 0x05 | classID (8B)         -> instances of an rdf:type
```

Exact counts for `?P?` cost one read-modify-write per insert on a key that is hot
but uncontended (single writer). Distinct-value counts cannot be maintained
exactly without a second index, so **HyperLogLog** (Flajolet et al., 2007;
HLL++ per Heule et al., EDBT 2013) is the standard answer: a 2 KB sketch gives
~2% relative error, merges associatively, and updates in O(1).

From these, textbook estimation:

- `?P?` → exact.
- `SP?` → `count(P) / distinctSubjects(P)` — the average fanout.
- `?PO` → `count(P) / distinctObjects(P)`.
- `S??`, `??O` → needs per-subject/per-object counts, which are too numerous to
  maintain. Fall back to `total / distinctSubjects` globally, or sample (§8.3).

### 8.2 Characteristic sets

Independence assumptions fail badly on RDF. Estimating
`{?s a foaf:Person . ?s foaf:age ?a . ?s foaf:knows ?b}` by multiplying three
independent selectivities is off by orders of magnitude, because subjects that have
`foaf:age` overwhelmingly also have `rdf:type foaf:Person`. RDF is *implicitly
structured* — entities come in a modest number of shapes.

**Characteristic sets** (Neumann & Moerkotte, ICDE 2011) capture this: for each
subject, record the *set* of predicates it carries; count how many subjects share
each set. Real graphs have surprisingly few distinct characteristic sets — often a
few thousand for hundreds of millions of triples. A star-shaped join's cardinality
is then read almost exactly off the table by summing over the sets that contain all
the queried predicates.

```
st | 0x06 | hash(sorted predicate ID list) -> | count (u64) | predicate IDs... |
```

Maintaining these incrementally on every insert is awkward (a subject's
characteristic set changes as predicates are added, requiring a decrement of the
old set and an increment of the new). **Recommendation: compute them by scanning
the SPO index during an offline `ANALYZE`, not incrementally.** SPO groups all of a
subject's predicates contiguously, so the scan is sequential and single-pass.

This technique is over a decade old, is well-validated, and remains absent from
most open-source triplestores. It is probably the highest value-per-line-of-code
item in this document.

### 8.3 Sampling

The G-CARE benchmark study (Park et al., SIGMOD 2020) found that for subgraph
cardinality estimation, **sampling-based estimators generally beat summary-based
ones** — a result that cuts against a decade of summary research and deserves
attention here.

bbolt's cursors permit a crude but useful form. Because IDs are dense in `[1, N]`
(§3.3), seeking to a *random 24-byte key* and taking the entry that follows gives
a sample of the index. The sample is biased — it is uniform over the key *space*,
not over stored keys, so it over-samples entries that follow large gaps — but the
bias is measurable and, for order-of-magnitude join-order decisions, tolerable.

```go
// estimateRange approximates the number of index entries under prefix by
// probing k random points and measuring local key density. Biased; use for
// plan selection, never for anything user-visible.
func estimateRange(c *bolt.Cursor, prefix []byte, k int, rnd *rand.Rand) float64 {
	// ... seek to random keys within [prefix, prefix+1), measure the gap
	// between consecutive stored keys, and invert the mean gap.
}
```

A more principled version is **Wander Join** (Li et al., SIGMOD 2016): perform
random walks through the join graph and weight each walk by the inverse of its
sampling probability to get an unbiased estimator of the join size. Each walk step
is "pick a random neighbour", which over an index means "seek to a random position
in this prefix range" — the same primitive. It gives confidence intervals, not just
a point estimate, which a planner can use to decide when to re-plan.

**Recommendation: maintained counters (§8.1) plus offline characteristic sets
(§8.2) as the baseline; treat sampling as the fallback for the patterns those two
cannot cover, and as the interesting research direction (§10.5).**

---

## 9. Extending to quads

Adding a graph component turns 8 patterns into 16. The extension is mechanical if
the key format is designed with it in mind, which is the reason for sketching it
now rather than later.

Keys become 32 bytes: four IDs. Two families of index are needed.

**Graph-last (`SPOG`, `POSG`, `OSPG`)** answers the 8 patterns where the graph is
unbound — that is, "find this triple in any graph" — by the same prefix argument
as §4.1, with G trailing as a disambiguator.

**Graph-first (`GSPO`, `GPOS`, `GOSP`)** answers the 8 patterns where the graph is
bound, since G becomes the leading prefix and the remaining three components
reproduce §4.1's rotation argument inside each graph.

Six indices, sixteen patterns, complete coverage:

| Graph | Pattern | Index | Prefix |
|---|---|---|---|
| bound | `G???` … `GSPO` | GSPO / GPOS / GOSP | as §4.1, offset by one |
| unbound | `???` … `SPO?` | SPOG / POSG / OSPG | as §4.1 |

Oxigraph's RocksDB backend uses very close to this arrangement (plus a separate
family for the default graph), which is good evidence the shape is sound.

Three semantic decisions come along with the extension, and each is a genuine fork:

- **Is the default graph a graph?** RDF datasets have a default graph plus named
  graphs. Reserving a sentinel ID (say 1) for it keeps one code path; giving it
  dedicated buckets keeps default-graph queries from paying the G prefix. The
  sentinel is simpler and its cost is one wasted 8-byte column on default-graph
  keys.
- **Does `?s ?p ?o` with no `GRAPH` clause search the default graph or the union
  of all graphs?** SPARQL says the default graph; almost every user expects the
  union. Whichever is chosen, it must be chosen explicitly and documented, and the
  storage layer should support both — union is the graph-last indices scanned
  whole, default is a graph-first prefix.
- **Is a quad's identity `(s,p,o,g)` or `(s,p,o)` with graph as an attribute?**
  This determines whether the same triple in two graphs is one row or two. RDF
  datasets say two. It matters for delete semantics and for how `count()` behaves.

Space cost: 32-byte keys, 6 indices. Per triple: 6 × (16 + 32) = 288 bytes, versus
120 for the three-index triple store — **2.4×**. Not free, and worth deciding
deliberately rather than by default.

---

## 10. Promising research that has not landed in products

This section is speculative by construction. Each item is something I believe is
genuinely under-exploited by shipping triplestores, with a note on why it has not
landed and what adopting it here would cost. Treat the citations as pointers to
verify, not as settled fact.

### 10.1 Worst-case optimal joins as the default, not the exception

§7.4 covered the mechanics. The research position — that binary join plans are
asymptotically wrong for cyclic queries and that WCOJ fixes it — has been settled
since 2012, and yet almost no RDF store evaluates BGPs this way. RDFox and
Kùzu (property graphs) are the notable adopters; Jena, RDF4J, Virtuoso, Blazegraph,
and Oxigraph are all binary-join engines.

**Why it hasn't landed:** WCOJ needs tries in arbitrary variable orders, which
means all six permutations, which doubles storage — and the benefit only appears
on cyclic queries, which are a minority of production workloads. It is a bad trade
if you optimize for the average query and a great one if you care about the tail.

**The 2023 development that changes the calculus:** *Free Join* (Wang, Willsey &
Suciu, SIGMOD 2023) unifies binary joins and WCOJ into one plan space, so an
optimizer can choose the WCOJ strategy per-variable rather than per-query. That
removes the all-or-nothing character of the decision. Combined with the observation
that a bbolt cursor already *is* a leapfrog iterator, this looks like a
disproportionately good fit for the architecture in this document.

**What it would cost here:** the `varIter` interface from §7.4, a variable-order
chooser, and the three extra permutations behind a config flag.

### 10.2 Succinct self-indexes as a compacted cold tier

The **Ring** (Arroyuelo, Gómez-Brandón, Hogan, Navarro, Reutter, Rojas-Ledesma &
Soto, SIGMOD 2021) stores a graph in a Burrows–Wheeler-based structure that
supports **all six permutations in roughly the space of a single one**, and
supports the seek/next primitives LFTJ needs directly on the compressed
representation. Related: k²-triples (Álvarez-García et al., KAIS 2015), qdags, and
HDT's compressed dictionary+triples format.

**Why it hasn't landed:** these structures are essentially immutable. Rebuilding
one is a bulk operation, so they suit publication and archival (HDT's actual niche)
rather than a read-write store.

**The idea worth spawning:** an LSM-shaped hybrid. bbolt holds the hot, mutable
tier exactly as designed above; periodically, a background job compacts it into an
immutable succinct tier stored as opaque blobs in a bbolt bucket, with a tombstone
set for deletions. Queries evaluate against both and union. This gets six
permutations for the cold majority of the data at the price of one, which
simultaneously resolves §7.4's storage objection to WCOJ.

This is a substantial engineering project and belongs in a version 2 conversation,
but the key format above is compatible with it, which is the point of mentioning it
now: nothing here forecloses it.

### 10.3 Order-preserving dictionaries, done per-type

§5.3 rejected a globally order-preserving dictionary because renumbering is fatal
under copy-on-write. But the problem may be over-stated. Binnig, Hildenbrand &
Färber (SIGMOD 2009) use gapped allocation with amortized renumbering; Dietz &
Sleator's order-maintenance structure (1987) supports arbitrary insertion into a
total order in O(1) amortized.

**The unexplored variant:** partition the ID space by *type class* and make each
class internally order-preserving with generous gaps. §3.4 already does this for
inlined integers — the observation is that the same trick generalizes to
dictionary-resident strings if each class gets its own ID subspace and gap policy.
A collation-ordered string subspace would make `ORDER BY ?name` and
`FILTER(?name > "M")` index-supported, which no triplestore I know of offers.

**Why it hasn't landed:** RDF's object column is heterogeneous, so a single order
is meaningless, and per-class subspaces complicate ID allocation considerably.
Renumbering, though rarer with gaps, is still catastrophic when it happens.

**Honest assessment:** interesting, risky, and the §5.2 side index gets most of the
benefit for a fraction of the danger. Worth prototyping, not worth shipping first.

### 10.4 Modern string compression in the dictionary

§3.5 proposed namespace factoring, which is a 1990s answer. **FSST** (Boncz,
Neumann & Leis, VLDB 2020) is a symbol-table compressor giving ~2× on short strings
with random access and decompression at GB/s — it compresses each string
independently against a shared learned symbol table, so `i2t` entries stay
individually decodable. DuckDB and other analytical systems adopted it; I am not
aware of any triplestore that has.

Related: **CoCo-trie** (Boffa, Ferragina & Vinciguerra, 2022–23) and the broader
compressed-string-dictionary literature (Martínez-Prieto et al.) offer trie
structures that compress IRI sets far better than prefix factoring while retaining
lookup.

**Why it hasn't landed:** most triplestores were designed before FSST existed, and
dictionary size is rarely the reported bottleneck (§4.2 shows indices dominate).

**Where it would actually matter here:** literal-heavy graphs — product catalogues,
document annotations, anything with real text — where the dictionary *does*
dominate. A per-store decision, not a universal one. It composes cleanly with §3.2
because it changes only the `i2t` value encoding.

### 10.5 Sampling-based and learned cardinality estimation

§8.3 already argued this. The specific under-exploited results: G-CARE's finding
that sampling beats summaries (SIGMOD 2020), Wander Join's unbiased estimator with
confidence intervals (SIGMOD 2016), and the emergent-schema line of work (Pham,
Passing, Erling & Boncz, WWW 2015) which shows that RDF graphs have a discoverable
relational schema hiding inside them — usable both for estimation and for physical
layout.

**Why it hasn't landed:** query optimizers are the least modular part of a database
and the hardest to validate; replacing an estimator risks regressing plans that
currently work. Learned estimators additionally need training infrastructure that
nobody wants inside a storage engine.

**The cheap version worth trying here:** confidence intervals rather than point
estimates, plus **re-planning at materialization boundaries** when the actual
cardinality falls outside the predicted interval. That is adaptive query processing
with a very small blast radius, and dense IDs (§3.3) make the sampling primitive
unusually cheap.

### 10.6 Factorised result representations

Olteanu & Závodný (TODS 2015) showed that query results can be kept in a
*factorised* form — a circuit of unions and Cartesian products — that is
exponentially smaller than the flat tuple set, with many aggregates computable
directly on the factorised form.

RDF is an unusually good fit, because star-shaped patterns are the dominant query
shape and stars are exactly what factorises well. A query asking for a person's
five properties currently materializes the Cartesian product of five independent
attribute sets; factorised, it stays a product of five small sets until the
consumer forces it.

**Why it hasn't landed:** SPARQL's result format is flat, so the factorisation has
to be expanded at the boundary anyway — the win only exists for aggregates,
`COUNT`, and further joins. Kùzu implements a related idea (factorized
intermediate results) for property graphs.

**Relevance here:** modest but real, and it costs nothing in the storage layer —
it is purely an execution-engine representation. Worth knowing exists before the
iterator API in §7.1 hardens, since a batch-of-tuples interface and a
factorised-representation interface are hard to reconcile after the fact.

### 10.7 Incremental materialization — no longer speculative

This was written as a hypothetical. Given that ontologies are the *reason* for
choosing RDF, it is a core requirement instead, and it has moved to
[Appendix A.4](#a4-reasoning-strategy). The short version: the hard part of
incremental materialization is deletion, Motik, Nenov, Piro & Horrocks (AAAI 2015)
give the good algorithm for it — and at 4×10⁵ triples you get to not need it,
because full re-materialization is a seconds-long operation and retraction is rare.
Scale buys simplicity here in a way that is worth taking.

---

## 11. Open questions

**Answered during the design conversation** — retained so the reasoning above can
be traced to its premises:

1. ~~**Read/write mix.**~~ ≈99:1 read. This favours bbolt strongly and is what
   makes six index permutations and eager materialization (A.4) affordable.
2. ~~**Target scale.**~~ 10,000–20,000 entities, so 10⁵–10⁶ triples. This is the
   premise that invalidated most of §4, §5.2, §8, and §10.2–10.5; see the
   [Scale section](#scale-and-what-it-invalidates). Note the original text below
   guessed the arguments "implicitly assume 10⁷–10⁹" — that guess was two to three
   orders of magnitude high, which is why so much was revised.
3. ~~**Deletion volume.**~~ Nothing is ever deleted; retraction is an epoch mark
   (§6.4). §3.6 becomes "never collect", unconditionally.
4. ~~**Is serializable isolation wanted?**~~ Moot. Single-writer serializability is
   free, and human-paced CRUD is three orders of magnitude below the ceiling (B.5).

**Still open, in the storage layer.** The larger open questions have moved to
[A.8](#a8-open-questions-for-this-layer) (ontology and AI) and
[B.7](#b7-additional-open-questions) (application), which is itself the finding:
almost nothing that remains unresolved is about storage.

1. **Query shapes.** Star-shaped entity lookup is clearly dominant given the CRUD
   application, and six permutations serve it. Still worth knowing whether
   reporting produces cyclic patterns, since that is §7.4's whole argument — though
   at 4×10⁵ facts even a poor plan is fast.
2. **Full-text and geospatial.** Both are extremely common asks for RDF stores and
   neither fits the design above — full-text needs an inverted index over literals,
   geospatial needs an R-tree or a space-filling curve. Both can be additional
   buckets, but the query layer needs to know they exist. Are they in scope at all?
   Full-text is the more likely of the two: a compliance UI with a search box over
   policy text is a normal request, and at 4×10⁵ facts an in-memory inverted index
   over literals is a few megabytes and a couple of hundred lines.
3. **RDF 1.2 triple terms.** The RDF 1.2 work (successor to RDF-star) allows a
   triple to be a term. That makes the dictionary recursive: a triple term's ID
   references three other IDs. The encoding in §3.2 extends naturally
   (`0x07 | sID | pID | oID`), but the semantics — particularly what it means to
   assert versus mention — are still moving. A.6 recommends named graphs instead
   for now, so the only decision needed today is whether to **reserve the tag
   byte**, which costs nothing and preserves the option.
4. **Blank node identity across transactions.** Blank node labels are scoped to a
   document, not a graph. Two loads of the same ontology file must not merge their
   blank nodes — and note that SHACL shapes and OWL restrictions (A.3) are written
   almost entirely with blank nodes, so an ontology-centric system hits this
   immediately rather than eventually. Skolemizing on ingest (minting a fresh IRI
   per document-scoped label) is the clean answer, makes every node individually
   citable in the audit log, and is probably right here despite changing the data.
5. **Blank nodes versus the audit log, specifically.** A retraction identifies a
   fact by ID, which is fine, but a human reading the log needs to understand what
   was retracted. A fact whose object is `_:b17` is not self-describing.
   Skolemization largely solves this too, which strengthens the case for it.

---

## 12. Bibliography

Storage and indexing:

- Weiss, Karras & Bernstein. *Hexastore: Sextuple Indexing for Semantic Web Data
  Management.* VLDB 2008.
- Neumann & Weikum. *RDF-3X: a RISC-style Engine for RDF.* VLDB 2008; and
  *The RDF-3X Engine for Scalable Management of RDF Data.* VLDB Journal 2010.
- Neumann & Weikum. *Scalable Join Processing on Very Large RDF Graphs.*
  SIGMOD 2009. (Sideways information passing.)
- Abadi, Marcus, Madden & Hollenbach. *Scalable Semantic Web Data Management Using
  Vertical Partitioning.* VLDB 2007.
- Fernández, Martínez-Prieto, Gutiérrez, Polleres & Arias. *Binary RDF
  Representation for Publication and Exchange (HDT).* Journal of Web Semantics 2013.
- Álvarez-García, Brisaboa, Fernández, Martínez-Prieto & Navarro. *Compressed
  Vertical Partitioning for Efficient RDF Management.* KAIS 2015.
- Urbani & Jacobs. *Adaptive Low-level Storage of Very Large Knowledge Graphs
  (Trident).* WWW 2020.
- Chu. *MDB: A Memory-Mapped Database and Backend for OpenLDAP.* 2011. (LMDB, the
  design bbolt descends from.)

Joins:

- Atserias, Grohe & Marx. *Size Bounds and Query Plans for Relational Joins.*
  FOCS 2008. (The AGM bound.)
- Ngo, Porat, Ré & Rudra. *Worst-case Optimal Join Algorithms.* PODS 2012.
- Veldhuizen. *Leapfrog Triejoin: A Simple, Worst-Case Optimal Join Algorithm.*
  ICDT 2014.
- Aberger, Tu, Olukotun & Ré. *EmptyHeaded: A Relational Engine for Graph
  Processing.* TODS 2017.
- Arroyuelo, Gómez-Brandón, Hogan, Navarro, Reutter, Rojas-Ledesma & Soto.
  *Worst-Case Optimal Graph Joins in Almost No Space.* SIGMOD 2021. (The Ring.)
- Wang, Willsey & Suciu. *Free Join: Unifying Worst-Case Optimal and Traditional
  Joins.* SIGMOD 2023.
- Olteanu & Závodný. *Size Bounds for Factorised Representations of Query
  Results.* TODS 2015.

Statistics and estimation:

- Neumann & Moerkotte. *Characteristic Sets: Accurate Cardinality Estimation for
  RDF Queries with Multiple Joins.* ICDE 2011.
- Park, Ko, Bhowmick, Kim, Hong & Han. *G-CARE: A Framework for Performance
  Benchmarking of Cardinality Estimation Techniques for Subgraph Matching.*
  SIGMOD 2020.
- Li, Wu, Yi & Zhao. *Wander Join: Online Aggregation via Random Walks.*
  SIGMOD 2016.
- Flajolet, Fusy, Gandouet & Meunier. *HyperLogLog.* AofA 2007; Heule, Nunkesser &
  Hall. *HyperLogLog in Practice.* EDBT 2013.
- Pham, Passing, Erling & Boncz. *Deriving an Emergent Relational Schema from RDF
  Data.* WWW 2015.

Compression and encoding:

- Binnig, Hildenbrand & Färber. *Dictionary-based Order-preserving String
  Compression for Main Memory Column Stores.* SIGMOD 2009.
- Boncz, Neumann & Leis. *FSST: Fast Random Access String Compression.* VLDB 2020.
- Boffa, Ferragina & Vinciguerra. *CoCo-trie: Data-aware Compression and Indexing
  of Strings.* Information Systems 2023.
- Chambi, Lemire, Kaser & Godin. *Better Bitmap Performance with Roaring Bitmaps.*
  Software: Practice and Experience 2016.
- Dietz & Sleator. *Two Algorithms for Maintaining Order in a List.* STOC 1987.

Execution and reasoning:

- Boncz, Zukowski & Nes. *MonetDB/X100: Hyper-Pipelining Query Execution.*
  CIDR 2005.
- Motik, Nenov, Piro & Horrocks. *Incremental Update of Datalog Materialisation:
  the Backward/Forward Algorithm.* AAAI 2015.

Implementations referenced: bbolt (etcd-io), Apache Jena TDB2, Eclipse RDF4J,
Oxigraph, Virtuoso, RDFox, terminusdb-store, Kùzu.

---

## Appendix A — The ontology, reasoning, and AI layer

RDF was chosen here for ontologies, their fit with AI systems, and the fact that
ISO/IEC standards express well as ontologies. That reorders the whole document's
priorities, so this appendix states the consequences.

### A.1 The storage layer is not where the difficulty is

At 4×10⁵ triples the store fits in ~30 MB of RAM and a full index scan takes ~10 ms.
There is no storage problem to solve. Every hard question in this system is a
*modelling* question: how faithfully the ontology captures a standard, whether an
inference is justified, whether an AI-produced assertion can be trusted, and
whether an auditor can be shown why the system concluded what it concluded.

The engineering budget should follow. Sections 4, 5, 8, and most of 10 describe
work that would be valuable at 10⁸ triples and is close to wasted here. This
appendix describes work that is load-bearing at any scale.

### A.2 TBox and ABox separation — what finally justifies quads

Section 9 treated named graphs as an optional extension whose cost was 2.4× storage.
That framing is now wrong in both directions: the storage cost is irrelevant, and
the capability is required.

An ontology derived from an ISO/IEC standard is a body of axioms with an identity,
a version, a publication date, and a provenance chain back to a normative document.
That metadata attaches to a *set of statements*, which is exactly what a named
graph is. Instance data belongs in different graphs again, and AI-extracted
assertions in yet another.

```turtle
@prefix ex:   <http://example.org/> .
@prefix dct:  <http://purl.org/dc/terms/> .
@prefix prov: <http://www.w3.org/ns/prov#> .
@prefix xsd:  <http://www.w3.org/2001/XMLSchema#> .

# All IRIs here are illustrative placeholders.

ex:graph/std/27001-2022 a ex:OntologyVersion ;
    dct:title    "Information security controls, as an ontology" ;
    dct:issued   "2022-10-25"^^xsd:date ;
    ex:supersedes ex:graph/std/27001-2013 ;
    ex:assertedAtEpoch 41 .

ex:graph/extraction/run-17 a ex:ExtractionRun ;
    prov:wasAssociatedWith ex:model/claude ;
    prov:startedAtTime "2026-08-18T09:14:00Z"^^xsd:dateTime ;
    ex:reviewStatus ex:AwaitingHumanReview .
```

Three capabilities fall out of this that are hard to get any other way:

- **Which standard, and which version of it, justified a conclusion.** Standards get
  revised; conclusions drawn under the 2013 edition are not automatically valid
  under the 2022 one. A named graph per ontology version makes this queryable
  instead of tribal knowledge.
- **Quarantining machine-generated assertions.** Extracted triples land in their own
  graph and are simply not in the union graph the compliance queries read until a
  human promotes them. This is a one-line change in query scope rather than a
  workflow engine.
- **Retiring a whole source atomically.** One epoch, one graph, done.

The graph identity should be versioned by the epoch model of §6.4 like everything
else, so "the ontology as it stood at epoch E" is answerable. Note that this is the
one place where the §9 quad key format genuinely matters — and under the in-memory
design it is one extra `ID` field in `Fact`, not a 2.4× storage multiplier.

### A.3 OWL and SHACL do different jobs — and the ISO use case mostly wants SHACL

This is the single most consequential modelling decision in the system, and it is
the one most often got wrong.

**OWL is open-world.** Absence of information is not information. Given an axiom
that every control has an owner, and a control with no recorded owner, an OWL
reasoner does *not* report a problem — it concludes that an owner exists and is
simply unknown, possibly inventing an anonymous individual for it.

```turtle
@prefix owl:  <http://www.w3.org/2002/07/owl#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix ex:   <http://example.org/> .

ex:Control rdfs:subClassOf [
    a owl:Restriction ;
    owl:onProperty    ex:hasOwner ;
    owl:minCardinality 1
] .

ex:control-A5-1 a ex:Control .   # no owner recorded
```

An OWL reasoner reports this as **consistent**. For a compliance system, that is
precisely the wrong answer.

**SHACL is closed-world and validation-shaped.** It reports the violation, with a
message you chose:

```turtle
@prefix sh:  <http://www.w3.org/ns/shacl#> .
@prefix ex:  <http://example.org/> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

ex:ControlShape a sh:NodeShape ;
    sh:targetClass ex:Control ;
    sh:property [
        sh:path     ex:hasOwner ;
        sh:minCount 1 ;
        sh:class    ex:Person ;
        sh:severity sh:Violation ;
        sh:message  "Every control requires a named accountable owner."
    ] ;
    sh:property [
        sh:path     ex:lastReviewed ;
        sh:datatype xsd:date ;
        sh:minCount 1 ;
        sh:message  "Every control requires a recorded review date."
    ] .
```

**Most requirements in a management-system standard are constraints, not
entailments.** "Shall be documented", "shall be reviewed at planned intervals",
"shall have an assigned owner" — these are conformance checks over what is
recorded, which is SHACL's job. Use OWL for the genuinely inferential parts:
class hierarchies, property characteristics like transitivity, equivalences
between the vocabulary of one standard and another.

That last one is worth calling out, because it is where OWL earns its place in this
system: when two standards impose overlapping requirements, expressing the overlap
as OWL axioms (`owl:equivalentClass`, `rdfs:subPropertyOf`) lets one piece of
evidence satisfy both, and lets the reasoner rather than a human maintain the
mapping. That is a real and recurring pain in multi-standard compliance work, and
it is the best argument for ontologies here.

**Recommendation:** SHACL shapes as the conformance layer, an OWL 2 RL ontology as
the semantic layer, and a clear rule that a shape violation is a finding while an
OWL inconsistency is a modelling bug.

### A.4 Reasoning strategy

At this scale the choice is easy, and it is worth appreciating how unusual that is.

**Materialize forward, eagerly, on write.** Compute the OWL 2 RL closure at commit
and store derived facts alongside asserted ones. Writes are 1% of the workload, so
paying at write time to make reads trivial is exactly the right trade. Reads then
never invoke a reasoner, which also means query latency is predictable — worth a
lot in a system somebody has to certify.

**Retraction: recompute everything.** The genuinely hard problem in materialized
reasoning is deletion — determining whether a derived fact remains derivable by
some other route. Motik et al.'s Backward/Forward algorithm (AAAI 2015) solves it
properly and is real work to implement. At 4×10⁵ triples with an OWL 2 RL rule set,
a full re-materialization from scratch runs in seconds. Retractions are audit
corrections and therefore rare. **Just recompute.** Mark the old derived facts
retracted at the new epoch and re-derive; the epoch model makes this an ordinary
append, and the audit trail even records the re-derivation as an event, which is
a bonus rather than a cost.

This is scale buying simplicity, and it should be taken deliberately — with a
comment in the code recording the assumption, so that whoever hits 10⁷ triples in
2031 knows exactly which stone to turn over.

**Profile choice is a modelling decision, not a performance one.** OWL 2 RL is the
usual recommendation because it is rule-expressible and forward-chainable, and its
rule set is small enough (on the order of thirty rules) to implement directly with
semi-naive evaluation in a few hundred lines of Go. But at this data scale even a
tableau reasoner over OWL 2 DL is tractable, so pick the profile that expresses the
standards faithfully and check performance afterwards rather than the reverse.

### A.5 Justifications: an auditor must never see an inference presented as a record

If derived facts are stored next to asserted ones, two things become mandatory.

**Facts must be labelled by origin.** `op` in the log record (§6.4) distinguishes
asserted from derived. A query that reports compliance evidence must be able to say
which facts a human recorded and which the system concluded. Blurring that line is
the sort of thing that ends an audit badly.

**Derived facts must be explainable.** "Why does the system believe this control is
compliant?" must have a mechanical answer. Because fact IDs are stable, permanent
offsets into an append-only table (§Scale), a justification is just a rule
identifier and a list of premise IDs:

```
just: | derivedFactID (4B BE) -> | ruleID (2B) | premiseFactID (4B) * n |
```

That is ~10 bytes per derived fact, and it reconstructs a full proof tree by
recursive lookup. Rendering that tree is the "show your working" answer to an
auditor, and — see A.6 — it is also the highest-value thing you can put in front
of a language model, because it converts a claim into a checkable chain.

Getting this for nearly free is a direct consequence of two earlier decisions: the
append-only fact table with stable IDs, and never garbage-collecting the dictionary.
Neither was made with justifications in mind, which is a good sign about both.

### A.6 The AI layer

**Embeddings do not belong in the graph.** Vectors are derived, non-logical,
model-version-dependent artifacts. Putting 20,000 × 768 float32 embeddings into the
RDF graph as literals would add ~61 MB of noise to a log of record whose value
comes from being small, readable, and verifiable. Keep them in a separate bbolt
bucket keyed by term ID, tagged with the model version, and treat them as a cache
that can be rebuilt. **The log of record holds assertions about the world; it does
not hold derived numerical artifacts.**

**No vector index is needed.** 20,000 vectors at 768 dimensions is 15.4M
multiply-accumulates per query — a few milliseconds brute force, under a
millisecond with int8 quantization. ANN structures like HNSW or IVF typically start
paying for themselves somewhere around 10⁵–10⁶ vectors; below that they cost a
dependency, an index to keep in sync, and recall loss, in exchange for latency you
cannot perceive. Scan the array.

**The ontology is what makes the AI layer trustworthy, and that is the actual
synergy.** Concretely, in descending order of value:

1. **SHACL as the gate on model output.** An LLM extracting assertions from a
   document produces candidate triples; those land in an extraction graph (A.2) and
   are validated against the shapes before promotion. The ontology becomes a
   machine-checkable contract on generated content — which is a far stronger
   guarantee than prompt discipline, and it is auditable.
2. **The proof tree from A.5 as context.** Handing a model a justification chain
   rather than a bare conclusion lets it explain, check, and challenge the
   conclusion. This is the difference between a system that sounds authoritative
   and one that can be verified.
3. **Ontology-guided retrieval.** Embedding search finds candidate entities;
   graph traversal over typed edges expands to a precise, bounded neighbourhood;
   that subgraph — not a pile of text chunks — becomes the context. The typed edges
   are what make the expansion principled rather than arbitrary.
4. **The vocabulary as a controlled generation target.** Class and property IRIs
   constrain what a model is allowed to say, which collapses a large class of
   plausible-sounding errors.

**Provenance for machine-generated assertions.** Named graphs per extraction run
(A.2) handle this today with no exotic features. RDF-star / RDF 1.2 triple terms
would let confidence attach to individual statements:

```turtle
# RDF-star syntax; note that RDF 1.2's triple-term syntax is still settling,
# so prefer the named-graph approach until it stabilizes.
<< ex:alice ex:accountableFor ex:control-A5-1 >>
    ex:confidence 0.82 ;
    prov:wasGeneratedBy ex:graph/extraction/run-17 .
```

**Recommendation: use named graphs now.** Per-run granularity is sufficient for
review workflow, it works in every tool today, and it avoids betting the data model
on a specification still in motion. Reserve the encoding tag (§11.6) so the option
stays open.

### A.7 The query surface decision, revisited

The original brief said pattern matching and joins, not a full SPARQL algebra. With
ontologies and AI as the motivation, **that is the wrong call** and I'd reverse it.

- **Language models write SPARQL.** There is a large public corpus of it. There is
  no corpus of your bespoke Go pattern API, and no amount of prompting fixes that.
  If AI systems are meant to query this store, the query language is a product
  decision, not an implementation detail.
- **SPARQL is the interoperability contract** for the ontology toolchain — Protégé,
  validators, external systems, standards-body deliverables. An ontology-centric
  system that cannot speak SPARQL is isolated from the ecosystem that motivated
  choosing RDF.
- **At this scale you do not need the hard parts.** The reason to fear SPARQL is
  the optimizer, and §8 already concluded that cardinality estimation is
  unnecessary here. Naive left-to-right evaluation of BGPs over six in-memory sort
  orders will answer essentially any query over 4×10⁵ triples in milliseconds.

**The uncomfortable part, stated plainly:** the pure-Go ecosystem for SPARQL,
OWL reasoning, and SHACL is thin. The JVM stack (Jena, RDF4J) and Rust
(Oxigraph) give you all three off the shelf; Go does not. So the realistic options
are:

| Option | Cost |
|---|---|
| **Implement a SPARQL 1.1 subset** over the in-memory indices — BGP, FILTER, OPTIONAL, UNION, aggregates, property paths | Substantial but bounded, and tractable precisely because no optimizer is needed. Plus OWL 2 RL forward chaining (~30 rules) and SHACL Core validation, each a few hundred lines. |
| **Run Oxigraph or Jena as a sidecar**, keeping bbolt as the hash-chained log of record and the RDF engine as a rebuildable projection | Adds a runtime dependency and a language boundary, but the log-of-record design already treats indices as disposable — so the sidecar is *exactly* the derived-state role the architecture defines. |
| **Move the whole system to the JVM or Rust** | Loses Go; gains a mature stack. |

The second looks attractive in isolation: the log stays yours, small, verifiable,
and hash-chained in Go, while the parts with the most surface area to get wrong —
SPARQL semantics, OWL entailment, SHACL — come from implementations that many
people have already found the bugs in. For a system that has to survive an audit,
"we did not write our own OWL reasoner" is a defensible sentence.

**But see [Appendix B.6](#b6-what-crud-does-to-the-sidecar-option): a CRUD
application weakens the sidecar considerably**, because a form-based UI needs
read-your-own-writes and a split log/projection architecture does not give it
cheaply. That pushes the decision toward either implementing in Go or moving the
whole stack, rather than splitting the difference.

This is a genuine strategic fork and I do not think it should be settled from a
research note. It is question 1 below.

### A.8 Open questions for this layer

1. **Go, or the best RDF stack?** Per A.7. This is now the largest open decision in
   the project and it is more a team and risk question than a technical one.
2. **How much of the standards do the ontologies actually cover?** Modelling a
   management-system standard faithfully is months of domain work, and the store
   is not the bottleneck. Is there an existing ontology to start from, or is this
   greenfield modelling?
3. **Who is the auditor, and what do they need to see?** The justification and log
   design above is my best guess at "show your working". If there is a concrete
   evidentiary format required by the certification process, it should drive the
   log record schema rather than be adapted to it afterwards.
4. **Are AI-generated assertions ever promoted to the record without human review?**
   The A.2 quarantine design assumes not. If they can be, the provenance and
   confidence requirements get considerably stricter.
5. **Do inferred facts count as records for audit purposes?** This is a compliance
   question with a direct storage consequence: whether derived facts must be
   retained in the hash-chained log or may be recomputed. A.4's "just recompute"
   strategy assumes they may be regenerated; if the closure at every historical
   epoch must be preserved verbatim, the log grows substantially and
   re-materialization is no longer free.

### A.9 Additional references

- Motik, Nenov, Piro & Horrocks. *Incremental Update of Datalog Materialisation:
  the Backward/Forward Algorithm.* AAAI 2015.
- W3C. *OWL 2 Web Ontology Language Profiles* (2nd ed., 2012) — the RL profile and
  its rule set.
- W3C. *Shapes Constraint Language (SHACL).* Recommendation, 2017.
- W3C. *RDF 1.1 Concepts and Abstract Syntax*, 2014; and the RDF 1.2 working
  drafts for triple terms.
- Knublauch & Kontokostas, and the SHACL Advanced Features note, for rules
  expressed as shapes — an alternative to OWL RL worth evaluating.
- Malyshev, Krötzsch, González, Gonsior & Bielefeldt. *Getting the Most out of
  Wikidata: Semantic Technology Usage in Wikipedia's Knowledge Graph.* ISWC 2018 —
  a well-documented account of running a real ontology-backed store at scale.

---

## Appendix B — The application layer

A conventional application sits on top: CRUD forms, graph visualization, data
tables, and reporting. This is where RDF is *least* comfortable, so it deserves
explicit design rather than being left to the ORM-shaped hole where an ORM would
normally go.

### B.1 CRUD over an append-only graph

**Update is retract-plus-assert in one epoch.** There is no in-place mutation, and
that is the correct semantics for an audit system — but it must be a first-class
primitive, not something each call site reimplements. The unit the UI works in is
"this property of this entity now has exactly these values":

```go
// SetProperty makes the values of (subject, predicate) exactly `values` as of a
// new epoch: everything currently asserted and not in values is retracted,
// everything in values and not currently asserted is added. Both halves share
// one epoch, so the audit log shows a single coherent change.
func (w *Writer) SetProperty(subject, predicate ID, values []ID, meta ChangeMeta) (Epoch, error)
```

Functional properties (`owl:FunctionalProperty`, or `sh:maxCount 1`) collapse this
to the familiar single-value form-field case, and the ontology already tells you
which properties those are — so the API can be generated rather than hand-written
(B.2).

**The epoch is your ETag.** Optimistic concurrency in a form-based UI is otherwise
fiddly; here it is nearly free. A form loads the entity at epoch E and sends E back
on save; the writer rejects the write if any fact about that entity changed in
between. Because facts carry assert and retract epochs, "did anything about
subject S change after E" is a scan of S's SPO range checking
`Assert > E || (Retract != max && Retract > E)`. At a few dozen facts per entity
this is free.

Do the check per-entity rather than globally: a global epoch check would make every
concurrent edit anywhere in the system conflict, which is the classic way this
pattern gets abandoned as unusable.

**Delete is retract.** The UI says "delete"; the store retracts. Anything reading
current state stops seeing it; the audit log retains it forever. This is exactly
what the ISO obligation wants, and it is worth making sure the UI language reflects
it — "archived" or "withdrawn" rather than "deleted", because a user who believes
data was erased and later learns it was not is a compliance incident in itself.

### B.2 The impedance mismatch, and generating the app layer from the ontology

Applications think in entities; RDF thinks in triples. Every RDF-backed application
solves this, most of them badly, usually with hand-written mapping code that drifts
from the ontology.

The better move here: **the ontology and its SHACL shapes already contain the
schema, so generate the Go layer from them.** Classes become structs, properties
become fields, `sh:datatype` becomes the Go type, `sh:maxCount 1` decides slice
versus scalar, `sh:message` and `sh:name` become form labels and validation text.

```turtle
ex:ControlShape a sh:NodeShape ;
    sh:targetClass ex:Control ;
    sh:property [ sh:path ex:hasOwner ;     sh:class ex:Person ; sh:maxCount 1 ; sh:minCount 1 ] ;
    sh:property [ sh:path ex:lastReviewed ; sh:datatype xsd:date ; sh:maxCount 1 ] ;
    sh:property [ sh:path ex:mitigates ;    sh:class ex:Risk ] .
```

```go
// Code generated from ex:ControlShape. DO NOT EDIT.
type Control struct {
	Subject      ID
	Owner        ID    `rdf:"ex:hasOwner"     shacl:"required"`
	LastReviewed *Date `rdf:"ex:lastReviewed"`
	Mitigates    []ID  `rdf:"ex:mitigates"`
}
```

This is the highest-leverage thing in the whole application layer. It makes the
ontology load-bearing rather than decorative — a change to a shape propagates to
the API, the forms, and the validation in one step — and it removes the drift that
otherwise makes people quietly stop maintaining the ontology after six months. It
also means the typed CRUD API and SPARQL (A.7) coexist without duplication: the
typed layer is generated, SPARQL is for reporting and AI.

Entity loading itself is an SPO prefix scan — a handful of facts, microseconds.
There is no N+1 problem to engineer around at this scale.

### B.3 Tables and reporting

**Two things I marked "skip" earlier are back, for a different reason.** §8.2
characteristic sets and §10.5 emergent schema were dismissed because cardinality
estimation is unnecessary at 4×10⁵ triples. But their *other* output — the implicit
table structure hiding in the graph — is exactly what a data-table UI needs, and
what tells you which columns actually exist for a given class rather than which
ones the ontology permits. Reinstate them as a UI-generation tool, not an optimizer
input.

**Materialize projections in memory.** A report or table view is a row set over a
class. Build them as derived state next to the indices:

```go
// View is a row-oriented projection of one class, rebuilt when the epoch
// advances past its watermark. At 20k entities a full rebuild is milliseconds,
// so incremental maintenance is not worth its own bug surface.
type View struct {
	Class    ID
	AsOf     Epoch
	Columns  []ID // predicates
	Rows     [][]ID
}
```

Epoch-keyed caching (§6.5) makes invalidation trivial: a view is valid for its
epoch forever, so the only question is whether to serve a slightly stale one.

**Sorting needs real collation.** A table sorted by name must use
`golang.org/x/text/collate`, not `bytes.Compare` — "Örjan" sorting after "Zebra" is
the kind of thing that gets noticed immediately in a Swedish-language UI. This is
the point §10.3 was gesturing at, and in memory it is simply a sort comparator
rather than an index design problem. Paging over a sorted in-memory slice is a
subslice.

**Point-in-time reporting is the feature to lead with.** "Show the compliance
position as of 31 December" is normally a substantial undertaking — temporal
tables, slowly-changing dimensions, or a data warehouse. Here it is `visible(e)`
with a different `e`, over data that is guaranteed immutable, with a hash-chained
log proving it was not altered after the fact. That combination is genuinely hard
to buy off the shelf, and it falls directly out of the audit requirement rather
than being built on top of it. If there is one thing in this architecture worth
building the product story around, it is this.

Reports should record the epoch they were run at, in their output. A report that
cannot be reproduced exactly is worth much less to an auditor than one that can.

### B.4 Graph visualization

The naive plan — send the graph to the browser and run a force-directed layout —
fails at this size. Force-directed layouts become visually unreadable somewhere
around a thousand nodes and computationally painful well before 20,000. The graph
is small for a database and large for a picture.

So visualization is a server-side query problem, not a rendering problem:

- **Bounded neighbourhood extraction.** Start from a focus node, expand N hops with
  a node budget, prioritizing by edge type or centrality. The six sort orders make
  both out-edges (SPO) and in-edges (OSP) equally cheap, which matters because
  users expect "what points at this?" to work as well as "what does this point to?"
- **Typed filtering before expansion.** Let the user expand along `ex:mitigates`
  but not `rdf:type`, or the neighbourhood is 90% class-membership edges and
  useless.
- **Aggregation for the overview.** Collapse instances into their classes, or
  cluster by some structural property, and let drill-down materialize detail. The
  ontology gives a principled hierarchy to aggregate along — which is a real
  advantage over an untyped graph, and worth exploiting.
- **Precomputed layout for stable views.** If there is a canonical whole-graph
  picture, compute its layout server-side once per epoch and cache it. Layout
  stability across reloads matters more to users than layout quality.

Different visual forms want different backing queries — a hierarchy view wants a
transitive closure over one property (which the OWL RL materialization of A.4 has
already computed), a matrix view wants a two-class adjacency projection, a timeline
wants the epoch dimension directly. Worth enumerating the intended visualizations
early, because each is a distinct query shape and they are cheap to serve but not
free to design.

### B.5 Concurrency

The write path is a **single writer goroutine** consuming a channel of change
requests, which matches the single-writer commit model and makes epoch allocation
trivially correct. HTTP handlers submit and await.

For the in-memory state, an earlier draft of this section recommended an
`sync.RWMutex` around the indices and dismissed the alternatives as premature
cleverness. That was the wrong call, for the reason §6.6 gives: Go's `RWMutex`
blocks new readers once a writer is queued, so a single long analytical scan
holding the read lock stalls the writer and then every reader behind it. A store
whose entire premise is that reads are 99% of the workload should not have a read
path that a write can block at all.

**Publish immutable snapshots instead.** Each permutation is an immutable
`[]FactID` behind an atomic pointer; the writer builds the next version and swaps
the pointer; readers load the pointer once and hold a slice nobody will ever
mutate. A reader that started before a write completes simply continues against
the version it loaded, which is correct rather than merely tolerable — `visible(e)`
filters the newer facts out anyway.

```go
// indexSet is the reader-visible index state. A query loads it once and keeps it
// for the query's lifetime; the writer replaces it wholesale.
type indexSet struct {
	spo, sop, pso, pos, osp, ops []FactID
}

// s.idx is an atomic.Pointer[indexSet]. This is the entire read-side protocol.
func (s *Store) index() *indexSet { return s.idx.Load() }
```

Two forms of this, in increasing order of effort:

- **Copy on write.** The writer copies all six slices, inserts, and swaps. Six
  copies of 4×10⁵ `uint32`s is ~10 MB of `memcpy` — roughly 2 ms, against a write
  rate in the single digits per second. It is about twenty lines and it is almost
  certainly where to start.
- **Sorted prefix plus append-only tail**, a miniature LSM. Readers binary search
  the immutable prefix and linearly scan a small tail; writers append to the tail
  in O(1); a background merge publishes a new prefix by the same pointer swap.
  This removes the per-write copy and the GC pressure with it. Worth building if
  write bursts — bulk import, or the full re-materialization after a retraction in
  A.4 — make the copy visible.

The fact table wants the same treatment for a different reason: chunk it as
`[][]Fact` so `append` never reallocates and no reader is left holding a stale
backing array (§6.6).

Human-driven CRUD produces write rates in the single digits per second, against an
fsync-per-commit ceiling of roughly 10³–10⁴ commits/s on NVMe — three orders of
magnitude of headroom. This is not a bottleneck and should not be designed as one.
The reason to publish snapshots is not throughput. It is that it makes the read
path lock-free and lets §6.6's isolation argument hold without qualification.

### B.6 What CRUD does to the sidecar option

A.7 offered running Oxigraph or Jena as a sidecar while bbolt holds the
hash-chained log of record. A CRUD application weakens that option significantly,
and the reason is worth being explicit about.

A form-based UI requires **read-your-own-writes**. Save, then immediately re-read,
and the change must be there. With a log in one process and the query engine as a
projection in another, every write becomes: commit to the log, propagate, wait for
the projection to catch up, then read. That is a distributed systems problem
introduced into a system whose data fits in 30 MB of RAM, and it will produce
exactly the class of intermittent bug — "sometimes my edit doesn't show up" — that
is expensive to diagnose and destroys user trust in an audit tool.

It is solvable (synchronous propagation, read-through to the log for recent epochs,
session-pinned consistency) but every solution adds machinery that the single-process
design simply does not need.

**Revised reading of A.7:** the fork is now more clearly between *implement the RDF
stack in Go* and *build the whole system on the JVM or Rust where the stack already
exists*. The hybrid is still viable if the sidecar runs in-process — Oxigraph is a
Rust library with a C ABI, so cgo makes it a linked dependency rather than a
network hop, which removes the propagation problem while keeping the mature
implementation. That specific variant is probably the most interesting unexplored
option and is worth a spike before the fork is settled.

### B.7 Additional open questions

1. **Which visualizations, concretely?** Each is a distinct query shape (B.4).
2. **Does the UI expose history, or only current state plus reports?** A UI with a
   time slider is a different application from one with a reports tab, and it
   changes how much of the epoch model surfaces in the API.
3. **How many concurrent editors?** Optimistic concurrency (B.1) is right for a
   handful of users editing mostly-disjoint entities. Many users editing the same
   entities would need something else, though at this scale that seems unlikely.
4. **Is the generated-from-ontology approach (B.2) acceptable to the team?**
   Codegen is a real workflow commitment. The alternative — hand-written mapping —
   works but historically causes the ontology to drift into decoration.
