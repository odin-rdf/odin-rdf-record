# The log of record: an append-only file format

**Status:** first draft, companion to [`architecture.md`](architecture.md). This
document specifies the on-disk format for the system of record. It exists because
of a reversal: `architecture.md` designs the store around bbolt, and at the scale
and workload that eventually emerged, bbolt turned out to be the wrong container
for an append-only log. The reasoning is summarized in §11.1; the short version is
that a B+tree buys ordered random access, the log needs none, and a bbolt file
cannot be verified by an auditor without our binary.

Everything else in `architecture.md` stands. The in-memory fact table, the six
`[]FactID` permutations, the epoch model (§6.4–6.6), the dictionary encoding
(§3.2), the inlined terms (§3.4), and the whole of Appendices A and B are
unchanged. This format replaces only the `txn` / `log` / `ret` buckets and the
`t2i` / `i2t` buckets — that is, the persistence layer beneath them.

---

## 1. What the format has to do

In rough order of how much each one constrains the design:

1. **Be the record.** Every fact in the running system must be reconstructible from
   this file and nothing else. No derived state on disk that the log does not
   determine.
2. **Be tamper-evident, and provably so by a third party.** A hash chain over
   epochs, verifiable in a few dozen lines by someone who does not have our code.
3. **Be self-describing.** Term IDs are internal. A log that records `1 5 2` and
   defers the meaning of those integers to a separate mutable dictionary is not a
   record — it is half of one. Term definitions therefore live *in* the chain.
4. **Survive a crash without losing an acknowledged write, and without admitting a
   corrupt one.** Append, fsync, acknowledge, in that order; detect and truncate a
   torn tail at boot.
5. **Replay fast enough to be the only recovery path.** ~4×10⁵ facts, well under a
   second, run on every start (`architecture.md` §Scale).
6. **Archive cleanly.** Sealed segments are immutable files that can be signed,
   copied to WORM storage, and handed over.

Explicit non-goals: random access, in-place update, indexing, compaction,
concurrent writers, and compression. All six are things the log does not need and
that a storage engine would charge us for.

---

## 2. Directory layout

```
store/
  000001.rlog        sealed
  000002.rlog        sealed
  000003.rlog        open — appended to
  HEAD               last verified head hash, advisory
```

Segments are numbered from 1, monotonically, zero-padded to six digits. Exactly one
segment is open for append; all lower-numbered segments are sealed and immutable.
A segment is sealed when it exceeds a target size (64 MiB by default) or on
operator command, and sealing is itself a record (§5.5).

**Why segments rather than one file.** Three reasons, all operational rather than
technical: an immutable file can be moved to write-once storage and countersigned
as a unit; a full chain verification can be parallelized per segment given the
recorded base hashes; and a torn tail can only ever affect the open segment, so
everything sealed is known-good after one verification and never needs re-reading.
The cost is a small amount of rotation code and one extra `fsync` of the directory
per rotation.

`HEAD` holds the current head hash in hex plus its epoch. It is a convenience for
monitoring and for external publication (`architecture.md` §6.4 recommends
publishing the head hash to make the chain attributable as well as evident). It is
**advisory only** — it is derived from the segments and is never trusted during
replay.

---

## 3. Segment header

Fixed 64 bytes at offset 0 of every segment. All integers are big-endian
throughout the format, matching `architecture.md`'s convention.

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | magic, ASCII `RDFLOG\x00\x00` |
| 8 | 4 | format version, currently 1 |
| 12 | 4 | segment number |
| 16 | 8 | first epoch in this segment |
| 24 | 4 | first fact ID in this segment (§5.3), `u32` to match `FactID` |
| 28 | 4 | CRC-32C of bytes 0..27 |
| 32 | 32 | base hash — the `hash` of the last chained record of the previous segment, epoch commit or environment note (§5.5); all zero for segment 1 |

```packet
caption: Segment header — 64 bytes at offset 0
row: 8
0,8:   magic | "RDFLOG\0\0"
8,4:   version | u32
12,4:  segment number | u32
16,8:  first epoch | u64
24,4:  first fact ID | u32
28,4:  CRC-32C | over bytes 0..27
32,32: !base hash | head of previous segment
```

**The CRC covers only bytes 0..27, not the base hash.** That looks like an
oversight and is not one: the base hash is verified by *equality* against the
previous segment's actual head hash, which is a far stronger check than a
checksum — a corrupted base hash fails the chain comparison whether or not its
CRC agrees. Spending four bytes on a weaker duplicate of that check would also
push the header past 64 bytes, and a header that is exactly one cache line is
worth more than a redundant checksum.

The base hash is what makes the chain span files. A verifier processing segment *n*
in isolation can confirm its internal consistency and its claimed link to *n−1*
without reading *n−1*; confirming the whole chain still requires walking from
segment 1, but that walk is a hash comparison per segment, not per record.

The first fact ID is a replay convenience: it lets a verifier or a partial reader
assign stable fact IDs (§5.3) without counting from the beginning of time.

---

## 4. Record framing

Every record, of every kind, is framed identically:

```
u32  len     — byte length of body, 1 <= len <= MaxRecordSize (64 MiB)
u32  crc     — CRC-32C over the 4 length bytes followed by the body
body[len]
```

```packet
caption: Record framing — identical for every record kind
row: 8
0,4: len | u32
4,4: CRC-32C | over len ‖ body
8,*: body | 1 .. 64 MiB
```

CRC and hash chain do different jobs and both are needed. The CRC catches accidental
corruption — a torn write, a bad sector, a truncated copy — cheaply and locally,
and it is what lets recovery distinguish "this record was never finished" from
"this record was altered". The hash chain catches deliberate alteration, which a
CRC cannot, because anyone rewriting a record can trivially recompute its CRC.

`len == 0` is not a legal record. This matters: a filesystem that hands back a
zero-filled block after a crash must not be mistaken for a valid empty record.

The body's first byte is the record kind:

| Kind | Name | §|
|---|---|---|
| `0x01` | epoch commit | 5.1 |
| `0x02` | segment seal | 5.4 |
| `0x03` | environment note | 5.5 |

Kinds `0x04`–`0x7F` are reserved. A reader encountering an unknown kind in a
sealed segment must **fail**, not skip — skipping an unrecognized record silently
changes the reconstructed graph, which is the exact failure mode this format
exists to prevent.

---

## 5. Record bodies

### 5.1 Epoch commit

The central record. One per committed write transaction, which per
`architecture.md` §6.4 is what an epoch *is*: the atomic unit of change, so an
auditor asking "what changed, and together with what?" gets a coherent answer.

```
u8    kind = 0x01
u64   epoch          — must equal previous epoch + 1
u64   wall           — Unix nanoseconds UTC, when the writer committed
u64   actor          — term ID; 0 if none
u64   reason         — term ID; 0 if none
u32   nTerms
u32   nOps
term[nTerms]         — §5.2
op[nOps]             — §5.3
[32]  prevHash
[32]  hash           — §6
```

```packet
caption: Epoch commit — kind 0x01
row: 8
0,1:  kind | 0x01
1,8:  epoch | u64
9,8:  wall | Unix ns UTC
17,8: actor | term ID
25,8: reason | term ID
33,4: nTerms | u32
37,4: nOps | u32
41,*: term[nTerms] then op[nOps]
~64,32: !prevHash
~32,32: !hash
```

Fixed overhead is 105 bytes per epoch, of which 64 is the two hashes.

`actor` and `reason` are term IDs rather than strings, so the *why* of a change is
itself RDF and queryable like anything else — this is `architecture.md` §6.4's
design and it is preserved exactly. A term used as an actor or reason must be
defined in this record or an earlier one.

**Epochs are gap-free and strictly increasing.** A replay that sees a gap must
fail. There is no legitimate way to produce one: a transaction that does not commit
never reaches the file, because the epoch number is assigned as the record is
encoded and the record only exists once `fsync` returns (§7.1).

### 5.2 Term definition

```
u64   id             — must equal the reader's next expected dictionary ID
u32   len
byte[len]            — the canonical term encoding of architecture.md §3.2
```

```packet
caption: Term definition — repeated nTerms times inside an epoch commit
row: 8
0,8:  id | u64
8,4:  len | u32
12,*: canonical term encoding | tag byte included, §3.2
```

The payload is `architecture.md`'s canonical encoding verbatim, tag byte included:
`0x01` IRI, `0x02` blank node, `0x03` `xsd:string`, `0x04` language literal,
`0x05` typed literal, `0x06` split IRI, with `0x07` reserved for RDF 1.2 triple
terms per §11.3 of that document. Its injectivity argument carries over unchanged,
and reusing it means there is one term encoder in the system rather than two.

Four consequences worth stating:

- **The dictionary is fully derived from the log.** IDs are assigned in
  first-appearance order (`architecture.md` §3.3), so a replayer counts them out as
  it goes. The `id` field is therefore redundant — it is present as a self-check,
  because a mismatch is a cheap, loud signal that the reader and writer disagree
  about something fundamental.
- **The hash chain covers term meaning, not just term identity.** This closes a gap
  in the bbolt design, where the chain covered log records holding integer IDs while
  the dictionary sat in a separately mutable bucket: editing `i2t` entry 42 from
  `ex:alice` to `ex:bob` rewrote the meaning of every fact mentioning it, and every
  hash still verified.
- **Terms are never removed.** `architecture.md` §3.6 concluded "never collect,
  unconditionally" — a term referenced by a retracted fact must stay resolvable
  forever. Append-only storage makes that structural rather than a policy someone
  has to remember.
- **Inlined terms have no definitions.** IDs with bit 63 set carry their own value
  (§3.4) and never appear here. A replayer must not expect one.

A typed literal's datatype IRI must be defined before the literal that references
it, which is the same ordering constraint `intern` already enforces (§3.2).

The 32 KB key limit that forced §3.2's hashed-key path for long literals **does not
apply here** — a term definition is length-prefixed with a `u32`, so a document
body is stored inline like anything else. That path was a B+tree artifact and it
disappears with the B+tree. Whether large literals belong in the log at all is a
separate question, raised in §12.

### 5.3 Fact operation

```
u8    op
u64   S
u64   P
u64   O
u64   G
```

```packet
caption: Fact operation — 33 bytes, repeated nOps times
row: 8
0,1:  op | assert / retract
1,8:  S | subject
9,8:  P | predicate
17,8: O | object
25,8: G | graph
```

33 bytes. Component order matches N-Quads (`s p o g .`), which is what a dump tool
will emit and what a human will read.

The diagram makes one thing visible that the field list hides: **nothing in a
fact operation is 8-byte aligned.** The one-byte `op` tag pushes every ID across
a boundary, so a reader must not cast a slice of the record to a `[]uint64` and
must not assume aligned loads. That costs nothing on arm64 or amd64 and would be
a portability bug elsewhere; the alternative — padding `op` out to 8 bytes —
would add 7 bytes to every operation, or ~2.8 MB across the store, to buy
alignment nobody needs.

| `op` | Meaning |
|---|---|
| `0x01` | assert |
| `0x02` | retract |
| `0x11` | assert, derived |
| `0x12` | retract, derived |

The high nibble carries origin. `architecture.md` A.5 is emphatic that an auditor
must never see an inference presented as a record, so origin is part of the record
itself, not metadata attached later.

**The graph component is mandatory.** Appendix A.2 established that named graphs
are required rather than optional — TBox/ABox separation, ontology versioning,
quarantining machine-generated assertions, retiring a source atomically. §9 of
`architecture.md` costed quads at 2.4× on-disk under the B+tree design; here it is
8 bytes on an op and one extra field in `Fact`. ~~The default graph gets sentinel ID
1, per §9's recommendation.~~

**Amended 2026-08-19 (RECORD-T-0005): the default-graph sentinel is 0, not 1.**
Sentinel 1 collides with §5.2's own rule: dictionary IDs are assigned in
first-appearance order starting at 1, so the first interned term *is* ID 1, and a
G of 1 would be ambiguous between "the default graph" and "the named graph whose
label is term 1" — or the dictionary origin would have to shift to 2, disturbing
every ID in every existing vector. Zero is the natural sentinel instead: §5.1
already uses 0 as "none" for `actor` and `reason`, and an absent graph name *is*
the default graph. `G == 0` therefore means the default graph; `S`, `P`, and `O`
remain forbidden from being 0. One consequence is stated here rather than left
implicit: **an inlined ID is never a legal graph component** — every inlined term
is a literal, and a graph label is an IRI or a blank node, so a writer must refuse
an inlined `G` and a replayer must reject one.

**Fact IDs are positional.** The *n*-th assert in log order is fact *n*, counting
from the segment header's first-fact-ID field. This reproduces `architecture.md`
§Scale's "a fact's slice offset is a stable, permanent, citable identifier" without
storing it: the log determines it. Justification records (A.5) can reference fact
IDs safely because nothing ever renumbers them.

**Retraction is by value, not by fact ID.** A retract op carries the full
`(S, P, O, G)` rather than the fact ID it kills. That costs 24 redundant bytes and
buys two things: the record is self-describing to a human reading the log — which
§11.5 of `architecture.md` raises as a real audit concern — and a verifier can
check that a retraction targets a fact that was actually asserted, without
maintaining a fact-ID mapping.

Replay resolves a retract to the currently-live fact with that
`(S, P, O, G)`. This is unambiguous: a graph is a set (§2), so at most one
generation of a given quad is live at any epoch. Assert → retract → re-assert →
retract produces two distinct facts with disjoint `[Assert, Retract)` intervals,
which is the correct history. A retract naming a quad that is not currently live
is a **replay error**, not a no-op — silently ignoring it hides a bug in the writer.

An assert of a quad that is already live is likewise an error rather than an
idempotent no-op. Under bbolt, `Put` made insertion idempotent for free (§6.1);
here idempotence has to be enforced by the writer before the record is encoded,
because writing a duplicate assert would create a second live fact with the same
value and break the set semantics the retract rule depends on.

### 5.4 Segment seal

```
u8    kind = 0x02
u64   lastEpoch
u64   recordCount    — epoch records in this segment
u32   lastFactID     — u32 to match FactID, as in the segment header
[32]  finalHash      — the head hash at seal time: the hash of the last
                       chained record in this segment (§6)
u32   sigLen
byte[sigLen]         — optional signature over finalHash
```

```packet
caption: Segment seal — kind 0x02, last record of a sealed segment
row: 8
0,1:   kind | 0x02
1,8:   lastEpoch | u64
9,8:   recordCount | u64
17,4:  lastFactID | u32
21,32: !finalHash | head of this segment
53,4:  sigLen | u32
57,*:  signature | optional, over finalHash
```

Always the last record in a sealed segment. It is a summary, not a chain link: the
next segment's base hash is `finalHash`, and the seal's own bytes are not hashed
into anything. That asymmetry with the environment note (§5.5) is deliberate — a
note records state that the reconstructed graph depends on, whereas a seal records
only where a file was cut, and nothing downstream reads it.

That is a real limitation and it should be stated rather than glossed. Removing a
seal record and appending further epochs to a "sealed" segment is undetectable from
the file alone. **The protection against truncation and re-writing is the externally
published head hash, not the seal.** The seal makes archival tidy and gives a
natural place to attach a signature; it does not, by itself, make the segment
tamper-proof. Nothing in an append-only format can — a chain proves that what
remains was not altered, never that nothing was removed from the end.

### 5.5 Environment note

```
u8    kind = 0x03
u64   lastEpoch      — the epoch this note follows; 0 before the first commit
u32   len
byte[len]            — UTF-8 JSON
[32]  prevHash
[32]  hash           — §6
```

```packet
caption: Environment note — kind 0x03
row: 8
0,1:  kind | 0x03
1,8:  lastEpoch | u64
9,4:  len | u32
13,*: UTF-8 JSON | engine and rule set versions
~64,32: !prevHash
~32,32: !hash
```

Records the software environment: store format version, reasoner version, the OWL
2 RL rule set identifier and its hash, SHACL shape graph version. Written at
startup when any of it differs from the last such record.

**This record carries the chain.** It is one of two kinds that do — the other is
the epoch commit — and it does so for the same reason term definitions live inside
the chain (§5.2): a record whose meaning depends on state the chain does not cover
is half a record. An earlier draft claimed the note was "hashed into the chain like
any other record" while giving it no `prevHash` or `hash` fields, which made the
claim false and left the one record identifying *which reasoner produced an
inference* outside the tamper-evidence. It is fixed here rather than explained
away.

`lastEpoch` is the epoch this note follows, and like §5.2's `id` it is redundant —
a replayer reading records in order already knows. It is present because it makes
the record self-describing to someone reading it in isolation, and because
resolving a derived fact to the rule set that produced it means looking up the
note in effect at that fact's epoch, which is a comparison this field makes direct
rather than positional.

An environment note has no epoch number of its own. It sits *between* epochs in
the record sequence, so verification advances the chain across it but does not
advance the epoch counter (§6).

This exists because of a dependency `architecture.md` A.4 creates and does not
follow through on. The strategy there is "materialize forward eagerly, and on
retraction just recompute" — full re-materialization at 4×10⁵ triples takes
seconds, so the Backward/Forward algorithm is not needed. But re-derivation is only
reproducible if the rules are the same rules. The ontology is data and therefore
already in the log; the rule engine is code and is not. Without this record,
"re-derive the closure as of epoch 4,000" silently means "with today's reasoner",
and an auditor asking why a historical conclusion changed gets no answer from the
record. Two hundred bytes per deploy makes it answerable.

---

## 6. The hash chain

```
hash = SHA-256( body[0 : len(body)-32] )
```

where the last 32 bytes of the body are the `hash` field itself, and the 32 bytes
immediately before it are `prevHash`. Because `prevHash` is inside the hashed
range, the chain is closed: altering any historical record changes its hash, which
does not match the `prevHash` recorded by its successor.

**Two record kinds carry the chain**: epoch commits (§5.1) and environment notes
(§5.5). Both are hashed identically by the rule above; they differ only in that a
commit also advances the epoch counter and a note does not. Segment seals (§5.4)
are outside the chain, for the reason given there.

`prevHash` is redundant — it is by definition the previous record's `hash` — and it
is kept anyway so that a record can be spot-checked against its predecessor without
the verifier holding state. That redundancy costs 32 bytes per epoch, which at 10⁵
epochs is 3 MB. If the epoch count ever grows to where that matters, `prevHash` is
the first thing to drop; the chain is unaffected, since a sequential verifier
carries the previous hash anyway.

Verification is one sequential pass:

```go
// Verify walks segments in order, checking framing, CRCs, epoch contiguity, and
// the hash chain. It returns the head hash, which is what gets published.
func Verify(dir string) (head [32]byte, lastEpoch uint64, err error) {
	var prev [32]byte // zero for the first record of segment 1
	for _, seg := range segments(dir) {
		h, err := readHeader(seg)
		if err != nil {
			return head, lastEpoch, err
		}
		if h.baseHash != prev {
			return head, lastEpoch, fmt.Errorf("segment %d: base hash does not "+
				"match previous segment head", h.segNo)
		}
		for rec := range records(seg) {
			// framing and CRC are checked by records()
			if rec.kind != kindEpoch && rec.kind != kindEnvNote {
				continue // only a seal reaches here, and it is not a chain link
			}
			if rec.kind == kindEpoch && rec.epoch != lastEpoch+1 {
				return head, lastEpoch, ErrEpochGap
			}
			if rec.prevHash != prev {
				return head, lastEpoch, ErrChainBroken
			}
			sum := sha256.Sum256(rec.body[:len(rec.body)-32])
			if sum != rec.hash {
				return head, lastEpoch, ErrChainBroken
			}
			prev = rec.hash
			if rec.kind == kindEpoch {
				lastEpoch = rec.epoch // a note advances the chain, not the epoch
			}
		}
	}
	return prev, lastEpoch, nil
}
```

**Amended 2026-08-19 (RECORD-T-0003).** The implemented verifier checks three
more equalities than the sketch above, all in the spirit of the base-hash
rule — redundant header fields verified against state the walk already
carries: a header's segment number must match its position in the file
sequence, its first epoch must equal the walk's last epoch + 1, and its
first fact ID must equal the count of asserts seen so far. The header CRC
protects these fields against accident but not against an editor who
recomputes it; the walk's own counters are the stronger check, and since a
partial reader is invited to trust these fields (§3), the full verifier must
vouch for them. An independent verifier must perform the same checks to
agree with ours verdict for verdict.

At 4×10⁵ facts the log is tens of megabytes and SHA-256 runs at 1–2 GB/s on any
machine with SHA extensions, so a full verification is tens of milliseconds. It
therefore runs **on every startup**, not as a scheduled job — the same argument
`architecture.md` §Scale makes for replay being the only recovery path. Code that
runs every time is code that works.

The verifier is deliberately small and depends on nothing: framing, CRC-32C,
SHA-256, big-endian integers. Reimplementing it in Python to satisfy an auditor who
does not want to run our binary is an afternoon. That property is most of the
argument for this format over bbolt.

---

## 7. Durability and crash recovery

### 7.1 The write path

Single writer goroutine, matching `architecture.md` B.5:

1. Encode the epoch body, including `prevHash` and the computed `hash`.
2. `write` the frame and body at the current offset.
3. `fsync` the segment file.
4. Apply the change to the fact table, swap in the new index snapshots, and
   advance the in-memory head hash.
5. **Publish the epoch last** — `atomic.StoreUint64(&s.published, E)` — and only
   then return success to the caller.

An environment note (§5.5) takes steps 1–3 only: it occupies a position in the
chain, so it is encoded with `prevHash`, appended, and `fsync`ed like a commit,
but it changes no facts and publishes no epoch. It must be durable before any
epoch whose derivations it describes, which is why it is written at startup rather
than lazily.

**Two boundaries, in that order, and neither is optional.**

*Step 3 is the durability boundary.* A crash before `fsync` returns leaves a
possibly-partial record that no reader has ever seen and no caller was ever told
about; recovery discards it (§7.2) and the transaction simply did not happen. A
crash after `fsync` returns leaves a complete record, and replay reconstructs the
state the caller was told about.

*Step 5 is the visibility boundary*, and it is separate from step 4 for the reason
`architecture.md` §6.5 develops: readers run at a published epoch, so a reader that
observed E while E's facts were still being applied would see the transaction
half-written. Publishing after the apply makes partial state unobservable for
free — a fact not yet applied carries `Assert = E`, and a reader still at `E-1`
rejects it with the predicate it was already evaluating. No separate commit flag,
no lock over the apply.

Publishing must trail the fsync as well as the apply. Publish between steps 2 and
3 and a reader can observe an epoch that a crash then unmakes — the one ordering
error in this sequence that yields a *wrong* answer rather than a lost one.

Rotation: `fsync` the old segment after its seal record, create the new segment,
write and `fsync` its header, then `fsync` the directory. The directory sync is the
step people forget, and skipping it means a crash can leave a file that exists in
the page cache and not in the directory.

`architecture.md` §6.3 worried at length about batching and `db.Batch` because
bbolt fsyncs per commit. That analysis carries over unchanged in shape — one epoch
is one fsync — but the conclusion is the same as B.5's: human-paced CRUD is single
digits per second against a ceiling of 10³–10⁴, so there is nothing to optimize.
Bulk import is one epoch with many ops, which amortizes the fsync over the whole
import.

### 7.2 The torn tail

Only the open segment can have one. Recovery scans it record by record and stops at
the first of:

| Condition | Reading |
|---|---|
| fewer than 8 bytes remain | clean end |
| `len == 0` or `len > MaxRecordSize` | torn |
| fewer than `len` bytes remain | torn |
| CRC mismatch | torn |

On torn: truncate the file to the offset where the bad record started, `fsync`, and
**record the truncation operationally** — log it, alert on it, count it. In an
ordinary database a truncated tail is a routine crash artifact. In a system of
record it is an event someone should look at, even though it is by construction a
transaction nobody was told had succeeded.

A CRC mismatch is ambiguous between "torn write" and "someone edited the file", and
the two want different responses. The distinguishing evidence is position: a torn
write can only be the final record. A CRC failure anywhere before the end, or in a
sealed segment, is corruption or tampering and must **halt**, not truncate. Only a
failure in the last record of the open segment gets the truncation path.

**Amended 2026-08-19 (RECORD-T-0003), three clarifications from implementation.**
First, "fewer than 8 bytes remain" is a clean end only when *zero* bytes remain: a
remainder of 1–7 bytes is a partial frame header and reads as torn — left in place
it would sit as garbage under the writer's next append. Second, the position rule
has a sharper edge than "the final record": when a CRC-failed frame's length field
is plausible and the frame ends *before* the file does, the failure is provably not
a torn append — the writer is fail-stop and never writes past a failed one — so it
halts as corruption rather than truncating what follows, which would destroy
evidence. Third, rotation adds one recoverable artifact the table does not name: a
*final* segment whose 64 header bytes never became durable (a file shorter than a
header, or exactly one that fails its magic or CRC) is the crash window between
`create` and the header's `fsync`. Recovery removes the file — the previous segment
was sealed before this one could exist, so nothing durable is lost — and surfaces
the removal the way it surfaces a truncation. A valid header carrying an unknown
version is a future format, never this husk; and the same damage anywhere non-final
halts. Relatedly, an unknown record kind under a valid CRC is never torn, in any
position: the CRC proves the bytes were fully written, just not by our writer.

### 7.3 What is not protected

Whole-file deletion, whole-segment deletion, and truncation of committed epochs are
all invisible to the chain — a shorter valid chain is still a valid chain. The
answers are external and conventional: publish the head hash somewhere the writer
cannot reach, back up sealed segments to storage the application has no credentials
to delete from, and check the segment count and head epoch from monitoring. Worth
being blunt about, because "hash-chained" is often heard as "cannot be tampered
with", and what it actually means is "cannot be tampered with *silently, in the
middle*".

---

## 8. Replay

```go
// Replay rebuilds the entire store from the log. It is the only load path and the
// only recovery path, so it is exercised on every start.
func Replay(dir string, s *Store) error {
	for rec := range allRecords(dir) { // framing, CRC, and chain checked inline
		switch rec.kind {
		case kindEnvNote:
			// Keyed by epoch, not just latest: resolving a derived fact to the
			// rule set that produced it means finding the note in effect at that
			// fact's epoch. See api.md §12.6.
			s.env.record(rec.lastEpoch, parseEnv(rec))
		case kindSeal:
			// nothing to apply; advisory
		case kindEpoch:
			for _, t := range rec.terms {
				s.dict.define(t.id, t.enc) // must equal s.dict.next()
			}
			for _, op := range rec.ops {
				switch op.kind {
				case opAssert, opAssertDerived:
					s.appendFact(Fact{
						S: op.S, P: op.P, O: op.O, G: op.G,
						Assert:  rec.epoch,
						Retract: maxEpoch,
						Derived: op.derived(),
					})
				case opRetract, opRetractDerived:
					id, ok := s.liveFact(op.S, op.P, op.O, op.G)
					if !ok {
						return fmt.Errorf("epoch %d: retract of a quad that is "+
							"not live", rec.epoch)
					}
					s.facts[id].Retract = rec.epoch
				}
			}
			s.epoch = rec.epoch
		}
	}
	s.buildPermutations() // sort six []FactID; see architecture.md §Scale
	return nil
}
```

Two notes on cost. Facts are appended in log order, so the fact table is built by
`append` with no reordering. The six permutations are built once at the end by
sorting, not by incremental insertion — `sort.Slice` over 4×10⁵ `uint32`s six times
is tens of milliseconds, against the O(n) memmove per insertion that §Scale
budgets for the steady-state write path. *(Measured 2026-08-19, RECORD-T-0008:
true for a radix sort — 39 ms optimized for the six sorts at 3.4×10⁵ facts — and
optimistic ~18× for a comparison sort; see the api.md §5.2 amendment. The
build-by-sorting conclusion stands either way: incremental insertion would be
minutes.)*

`liveFact` needs a `map[Quad]FactID` of currently-live facts during replay. That is
transient replay scaffolding, ~20 MB at 4×10⁵ facts, and it can be dropped
afterwards — or kept, since the same map is what makes the writer's duplicate-assert
check (§5.3) cheap at runtime.

Derived facts are replayed like any other if they were logged. If the decision goes
the other way — `architecture.md` A.8.5 leaves it open whether inferred facts count
as records — then ops `0x11`/`0x12` never appear, and `Replay` ends with a
materialization pass instead. The format supports both; the choice is a compliance
question, not a storage one, and it should be recorded in the environment note
either way.

---

## 9. Sizing

At `architecture.md`'s target of ~4×10⁵ facts and ~10⁵ distinct terms:

| Component | Calculation | Size |
|---|---|---|
| Term definitions | 10⁵ × (8 + 4 + ~40) | ~5 MB |
| Fact operations | 4×10⁵ × 33 | ~13 MB |
| Epoch overhead, bulk-loaded (10³ epochs) | 10³ × 113 | ~0.1 MB |
| Epoch overhead, fully hand-edited (2×10⁵ epochs) | 2×10⁵ × 113 | ~23 MB |
| **Total** | | **18–41 MB** |

The spread is entirely in how many transactions produced the data, which is a
property of the application rather than the format. For comparison, the bbolt
design costs roughly 1.4× the op bytes in page and element overhead plus a
copy-on-write path rewrite per commit, and the in-memory store is ~30 MB either
way.

Nothing here is large enough to justify compression, and compressing a sealed
segment would break the "hexdump it" property that motivated the format. If the log
ever does grow past what is comfortable, compress *archived* segments after they
leave the live directory, where the tradeoff is different.

---

## 10. What the format deliberately does not do

- **No random access.** There is no index into the log, and there will not be one.
  Everything is reconstructed at boot; a reader that wants a fact asks the in-memory
  store. `architecture.md` question 4 established that the match path never touches
  disk at all.
- **No in-place update.** Bytes once fsynced are never rewritten. This is what makes
  the crash-safety argument small enough to trust.
- **No concurrent writers.** One goroutine, per B.5. Epoch allocation, hash
  chaining, and fact ID assignment are all trivially correct as a consequence, and
  all three would need real machinery otherwise.
- **No compression, no encryption.** Encryption at rest, if required, belongs at the
  filesystem or volume layer, where it does not interfere with a third party's
  ability to verify the chain.
- **No schema evolution beyond the version field.** A format version bump means a
  new segment, not an in-place migration. Old segments stay readable at their own
  version, which is the only migration story that is compatible with never
  rewriting history.

---

## 11. Alternatives considered

### 11.1 bbolt (what this replaces)

`architecture.md` designs the whole store on bbolt, and for the original premise —
10⁷–10⁹ triples, disk-resident indices — that was right. The revision in its §Scale
section moved every index into memory and left bbolt holding an append-only
sequence written in ascending key order, which is the one workload a B+tree is pure
overhead for. §6.4 even observes that bbolt "has a fast path for ascending insertion
that leaves the left page full on split", which is bbolt doing a passable impression
of an append-only file.

The performance costs of keeping it were real but immaterial at this scale: ~16 KB
of copy-on-write page rewrites to append a 33-byte record, ~1.4× space
amplification. The decisive arguments were different:

- **An auditor cannot read a bbolt file.** The value proposition of the record is
  independent verifiability, and a format that requires our binary plus a Go library
  to parse undercuts it.
- **Nothing else needed a key/value store.** Because IDs are dense and sequential
  (§3.3), every side store is naturally an array rather than a map — embeddings
  become a flat file at offset `id × dims × 4`, which is A.6's "scan the array"
  taken literally.
- **The dictionary was outside the chain.** Fixable in bbolt, but the fix is exactly
  §5.2 of this document, at which point bbolt's remaining job is appending.

The counter-argument, which is not nothing: bbolt's durability code is battle-tested
inside etcd and ours is not, and "we did not write our own storage engine" is the
same defensible sentence that `architecture.md` A.7 invokes for not writing our own
OWL reasoner. The reason to accept the tradeoff here and not there is surface area
— append-only, never-mutate, truncate-partial-tail is perhaps 250 lines with no
concurrency and no in-place mutation, whereas an OWL reasoner is unbounded.

### 11.2 JSON Lines

Very tempting for the audit story: every record human-readable, greppable,
diffable, parseable everywhere. Rejected on one specific ground — **canonicalization**.
A hash chain requires that the bytes hashed are exactly reproducible, and JSON does
not have a single serialization: key order, number formatting, unicode escaping, and
whitespace all vary between writers. Either you hash the literal bytes as written
(and lose the ability to reformat, pretty-print, or re-serialize the file at all) or
you adopt a canonical JSON profile, which is a specification with its own edge cases
and its own bug history.

Fixed-width big-endian binary has exactly one serialization by construction. The
readability that JSON would have bought is recovered by a dump tool (§12) that emits
N-Quads and JSON on demand, which is what a human actually wants to read anyway —
nobody wants to read 4×10⁵ raw records regardless of encoding.

### 11.3 Protobuf, CBOR, Avro

Same objection as JSON in weaker form — protobuf's encoding is not canonical
(field order and varint padding are unspecified enough to matter for hashing), and
CBOR has a canonical profile but drags in a dependency to read. Additionally, all
three make the third-party verifier bigger: the point of §6 is that the verifier is
implementable from this document in an afternoon, and "install a protobuf runtime
and obtain our `.proto` files" is a meaningfully worse starting position for someone
who is auditing us.

### 11.4 SQLite

The strongest rejected option, and worth taking seriously: it is the most widely
deployed and most thoroughly tested storage engine in existence, its file format is
published and stable, and the tooling to read it exists on every machine. A
single-table append-only log in SQLite would work.

Rejected because it inverts the same tradeoff as bbolt, less severely: a B+tree and
a query planner in exchange for durability code we would otherwise own, on a
workload that is append-and-scan. It also gives the same "needs a library to parse"
property, albeit against a much more available library. Worth revisiting if the
250 lines of framing and recovery turn out to be more troublesome than expected —
this is the fallback, not a closed door.

### 11.5 A write-ahead log plus checkpoints

The conventional answer at larger scale: periodically snapshot the in-memory state
so boot does not replay from the beginning. Rejected because replay is already tens
of milliseconds, and a checkpoint introduces a second on-disk representation that
can disagree with the log — which is precisely the property (one record, everything
else derived) that the whole design is organized around. Revisit if replay ever
exceeds a second or two, which at this scale means roughly 100× growth.

---

## 12. Open questions

1. **Do derived facts go in the log?** `architecture.md` A.8.5. Ops `0x11`/`0x12`
   exist so the answer can be either, but it changes log size materially — an OWL 2
   RL closure can be several times the asserted fact count — and it decides whether
   `Replay` ends with a materialization pass. It is a compliance question and needs
   an answer from whoever owns the audit relationship.
2. **Do large literals belong in the log?** §5.2 removes the 32 KB limit, so a
   policy document body *can* be a term definition. Whether it should be is a
   different matter: it inflates the record that must be verified on every boot, and
   it puts a large opaque blob in a file whose value is being readable. The
   alternative is a content-addressed blob store beside the log with the hash as the
   term, which keeps the log small and still chains the content. Leaning toward the
   blob store above ~64 KB, but this interacts with question 1 in
   `architecture.md`'s §Q4 discussion of memory residency and should be decided
   together with it.
3. **Signature scheme for sealed segments.** §5.4 leaves `sigLen` open. Ed25519 over
   `finalHash` is the obvious default; the real questions are key custody and
   whether the auditor wants a countersignature from outside the system, which is
   an organizational decision.
4. **Head hash publication.** §7.3's protection against truncation depends entirely
   on this, and it is currently unspecified. Options range from writing it to an
   append-only cloud log to emailing it daily to a compliance mailbox. The cheap
   version is worth building before it is needed, because retrofitting it means the
   history before publication began is unprotected against truncation forever.
5. **Is `wall` trusted?** It comes from the writer's clock, which an operator with
   host access can move. Epoch order is authoritative and monotonic regardless, but
   a timestamp that an auditor is invited to rely on and that we cannot vouch for is
   worth flagging explicitly — a note in the environment record about the time
   source, or an external timestamping authority over segment seals, depending on how
   much the certification process cares.
6. **Tooling.** A `rdflog verify`, `rdflog dump --format=nquads|json`, and
   `rdflog head` are the minimum, and `dump` in particular carries a load-bearing
   part of the readability argument in §11.2. Small, but it should be built with the
   format rather than after it.
