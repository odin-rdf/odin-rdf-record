// The resident structures (RECORD-T-0007): what a store *is while
// running*, per api.md par. 2-4 — a pointer-free fact table, a chunked
// dictionary arena, an epoch table, and the environment notes — plus
// the 64->32-bit id re-tag that connects them to the log's encoding.
// Everything here is a disposable projection rebuilt by replay
// (load.odin); nothing in this file is durable, reads the filesystem,
// or knows the log format beyond the inline-id scheme it shares with
// encode.odin.
//
// The layout rule every structure follows, from api.md par. 2.3 and
// par. 4: **chunks never move.** Growth appends a chunk and never
// relocates one, so a pointer or a zero-copy view handed out earlier
// stays valid for the life of the store. That is the single sentence
// the snapshot design (RECORD-A-0005) hangs from, and it is why the
// fact table is [dynamic][]Fact rather than one growing slice.
package record

import "base:runtime"

// LIVE_EPOCH is the retract field of a fact that is still live
// (api.md par. 2.1): visibility at epoch e is
// `assert <= e && e < retract` with no special case. Real epochs are
// therefore bounded one below it — the load path refuses a log that
// reaches it, four billion commits away from the design scale.
LIVE_EPOCH :: u32(0xFFFF_FFFF)

// The resident inline-term encoding (api.md par. 3): bit 31 flags an
// inlined term, bits 30..28 tag its type with the same tag values the
// on-disk scheme uses (encode.odin), and the low 28 bits carry the
// payload — raw 0/1 for booleans, offset-binary for the ordered types
// so inlined values still sort numerically. Tag 0 is reserved so that
// 0x8000_0000 decodes as invalid rather than as a plausible term.
// RECORD-A-0001 froze both schemes together; resident_id is the bridge.
RES_INLINE_FLAG :: u32(1) << 31
RES_INLINE_TAG_SHIFT :: 28
RES_INLINE_PAYLOAD_MASK :: (u32(1) << 28) - 1
RES_INLINE_BIAS :: u32(1) << 27

// resident_id re-tags one on-disk term id (u64) as a resident id
// (u32): dictionary ids pass through unchanged, and inlined ids move
// the flag from bit 63 to bit 31, the tag from bits 62..56 to bits
// 30..28, and rebias the payload from 2^55 to 2^27. A pure function,
// total on any id replay delivers — replay has already refused
// dictionary ids at or above RESIDENT_ID_LIMIT (.Term_Overflow) and
// inlined ids outside RECORD-A-0001's frozen range (.Inline_Range) —
// and the asserts state that precondition rather than widen the
// contract.
resident_id :: proc(id: u64) -> u32 {
	if id & INLINE_FLAG == 0 {
		assert(id < RESIDENT_ID_LIMIT, "resident_id: a dictionary id past the resident scheme")
		return u32(id)
	}
	tag := u8(id >> INLINE_TAG_SHIFT) & 0x7F
	payload := id & INLINE_PAYLOAD_MASK
	switch tag {
	case INLINE_TAG_BOOLEAN:
		assert(payload <= 1, "resident_id: a boolean payload past one")
		return RES_INLINE_FLAG | u32(tag) << RES_INLINE_TAG_SHIFT | u32(payload)
	case INLINE_TAG_INTEGER, INLINE_TAG_DATE:
		v := i64(payload) - i64(INLINE_BIAS)
		assert(v >= INLINE_VALUE_MIN && v <= INLINE_VALUE_MAX, "resident_id: a payload outside the frozen range")
		return RES_INLINE_FLAG | u32(tag) << RES_INLINE_TAG_SHIFT | u32(v + i64(RES_INLINE_BIAS))
	}
	panic("resident_id: an inline tag outside RECORD-A-0001's frozen scheme")
}

// Fact is the single canonical resident record (api.md par. 2): one
// generation of one quad, 24 bytes, no pointer fields, no padding.
// `assert` is immutable after construction; `retract` is the only
// field ever written later — LIVE_EPOCH while live, the retracting
// epoch after. Origin is deliberately not here: it lives in the
// store's derived bitset (api.md par. 2.2), keeping the visibility
// test's cache lines free of a field it never reads.
Fact :: struct {
	s, p, o, g: u32, // resident term ids
	assert:     u32, // the epoch that asserted this generation
	retract:    u32, // the epoch that retracted it; LIVE_EPOCH while live
}

// Quad is a resident quad value — the four components of a Fact
// without its interval. The load path keys its transient live map on
// it, and the read API's pattern type will share its shape.
Quad :: struct {
	s, p, o, g: u32,
}

// The fact table's chunking (api.md par. 2.3): 8192 facts per chunk,
// 192 KB, a power of two so locating a fact is a shift and a mask.
FACT_CHUNK_BITS :: 13
FACT_CHUNK_SIZE :: 1 << FACT_CHUNK_BITS
FACT_CHUNK_MASK :: FACT_CHUNK_SIZE - 1

// Epoch_Meta is one entry per committed epoch (api.md par. 2.4): the
// wall clock, and who and why as term ids — 0 meaning none, exactly as
// the log records it. Per-epoch rather than per-fact: every op in one
// commit shares one actor.
Epoch_Meta :: struct {
	wall:   u64, // Unix nanoseconds UTC; advisory (log.md par. 5.1)
	actor:  u32, // dictionary id, 0 if none
	reason: u32, // dictionary id, 0 if none
}

// The epoch table's chunking: same discipline as the fact table, 8192
// entries (128 KB) per chunk.
EPOCH_CHUNK_BITS :: 13
EPOCH_CHUNK_SIZE :: 1 << EPOCH_CHUNK_BITS
EPOCH_CHUNK_MASK :: EPOCH_CHUNK_SIZE - 1

// Env_Note is one environment note, keyed by the epoch it follows
// (log.md par. 5.5), payload cloned and owned by the store. Resident
// so that a derived fact's epoch can resolve to the note in effect at
// the time (api.md par. 12.6) — a few hundred entries at most.
Env_Note :: struct {
	last_epoch: u32,
	payload:    []byte,
}

// The dictionary arena's chunking (api.md par. 4): 1 MB chunks, and a
// term id locates its bytes through one packed u32 — chunk index in
// the high 12 bits, byte offset in the low 20 — so the ceiling is 4096
// chunks and 4 GB of term bytes, three orders of magnitude over the
// ~5 MB design scale. An encoding larger than a chunk gets a dedicated
// chunk of its exact size at offset 0, so no term ever spans two.
DICT_CHUNK_BITS :: 20
DICT_CHUNK_SIZE :: 1 << DICT_CHUNK_BITS
DICT_CHUNK_MASK :: u32(DICT_CHUNK_SIZE - 1)
DICT_MAX_CHUNKS :: 1 << (32 - DICT_CHUNK_BITS)

// Dict is the dictionary arena (api.md par. 4): every term's canonical
// encoding verbatim, back to back in chunks that never move, so the
// arena is a near-literal copy of the log's term definitions. `off[i]`
// locates term i+1 (ids are 1-based; 0 is "none") and dict_bytes
// recovers its length from the next term's offset — two loads, no
// pointer chase. `by_term` maps an encoding back to its id for the
// resolve path; its keys are zero-copy views into the chunks, which is
// what the never-move invariant buys.
Dict :: struct {
	chunks:  [dynamic][]byte,
	used:    [dynamic]u32, // bytes filled in each chunk; final once a chunk is left
	off:     [dynamic]u32, // packed (chunk << DICT_CHUNK_BITS | offset), one per term
	by_term: map[string]u32,
}

// Store is the memory-resident projection of one log (api.md): built
// by replay through the load path's Loader, read through snapshots
// once those exist (RECORD-T-0009). Fields are read-only to consumers;
// the Loader is the only writer today. The permutations, the
// published-epoch discipline, and the read API land in this struct as
// their tasks do.
Store :: struct {
	facts:     [dynamic][]Fact, // FACT_CHUNK_SIZE-fact chunks; never relocated
	n_facts:   u32, // facts appended — the fact-id high-water mark
	derived:   [dynamic]u64, // origin bitset, one bit per fact id (api.md par. 2.2)
	dict:      Dict,
	epochs:    [dynamic][]Epoch_Meta, // EPOCH_CHUNK_SIZE-entry chunks, indexed by epoch-1
	n_epochs:  u32, // committed epochs; equals the last epoch, since epochs are contiguous from 1
	notes:     [dynamic]Env_Note, // in log order; last_epoch is non-decreasing
	ord:       [Order][]u32, // the six sorted FactID permutations (permute.odin); moved into an Index_Set on publish
	idx:       ^Index_Set, // the published index set (snapshot.odin); atomic, nil until the first publish
	published: u32, // the published epoch (log.md par. 7.1 step 5); atomic, stored after idx
	allocator: runtime.Allocator,
}

// store_init readies an empty store. Everything the store allocates —
// chunks, note payloads, the map — comes from this allocator and is
// returned by store_destroy.
store_init :: proc(s: ^Store, allocator := context.allocator) {
	s.allocator = allocator
	s.facts = make([dynamic][]Fact, allocator)
	s.derived = make([dynamic]u64, allocator)
	s.epochs = make([dynamic][]Epoch_Meta, allocator)
	s.notes = make([dynamic]Env_Note, allocator)
	s.dict.chunks = make([dynamic][]byte, allocator)
	s.dict.used = make([dynamic]u32, allocator)
	s.dict.off = make([dynamic]u32, allocator)
	s.dict.by_term = make(map[string]u32, allocator)
}

// store_destroy frees everything the store owns. Views handed out by
// dict_bytes and pointers from store_fact die with it. Every snapshot
// must have been released first — the store's publish reference must
// be the published set's last, which is RECORD-A-0005's close
// assertion making a leaked snapshot loud.
store_destroy :: proc(s: ^Store) {
	if s.idx != nil {
		assert(s.idx.refs == 1, "store_destroy: a snapshot is still holding the published set")
		release_set(s, s.idx)
	}
	for c in s.facts {
		delete(c, s.allocator)
	}
	delete(s.facts)
	delete(s.derived)
	for c in s.epochs {
		delete(c, s.allocator)
	}
	delete(s.epochs)
	for n in s.notes {
		delete(n.payload, s.allocator)
	}
	delete(s.notes)
	for o in Order {
		delete(s.ord[o], s.allocator)
	}
	for c in s.dict.chunks {
		delete(c, s.allocator)
	}
	delete(s.dict.chunks)
	delete(s.dict.used)
	delete(s.dict.off)
	delete(s.dict.by_term)
	s^ = {}
}

// store_fact returns fact `id` in place — a shift, a mask, and a load
// (api.md par. 2.3). The pointer stays valid for the life of the
// store: chunks never move. Callers read; the load path is the only
// writer.
store_fact :: proc(s: ^Store, id: u32) -> ^Fact {
	assert(id < s.n_facts, "store_fact: a fact id past the table")
	return &s.facts[id >> FACT_CHUNK_BITS][id & FACT_CHUNK_MASK]
}

// store_derived reports fact `id`'s origin from the parallel bitset
// (api.md par. 2.2): true if the fact was inferred rather than
// recorded — the distinction architecture.md A.5 requires an auditor
// to always see.
store_derived :: proc(s: ^Store, id: u32) -> bool {
	assert(id < s.n_facts, "store_derived: a fact id past the table")
	return s.derived[id >> 6] & (u64(1) << (id & 63)) != 0
}

// store_epoch_meta returns the wall/actor/reason of one committed
// epoch (api.md par. 2.4). Epochs are contiguous from 1, so the table
// is dense and the epoch number is the index.
store_epoch_meta :: proc(s: ^Store, epoch: u32) -> Epoch_Meta {
	assert(epoch >= 1 && epoch <= s.n_epochs, "store_epoch_meta: an epoch never committed")
	i := epoch - 1
	return s.epochs[i >> EPOCH_CHUNK_BITS][i & EPOCH_CHUNK_MASK]
}

// store_note_at returns the environment note in effect *at* an epoch
// (api.md par. 12.6): the last note whose last_epoch is at or before
// it, or ok=false if no note precedes it. The payload borrows from the
// store. Notes arrive in log order with non-decreasing last_epoch, so
// this is one binary search; of several notes at the same boundary the
// latest wins, being the one in effect.
store_note_at :: proc(s: ^Store, epoch: u32) -> (payload: []byte, ok: bool) {
	lo, hi := 0, len(s.notes)
	for lo < hi {
		mid := int(uint(lo+hi) >> 1)
		if s.notes[mid].last_epoch <= epoch {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {
		return nil, false
	}
	return s.notes[lo-1].payload, true
}

// dict_bytes returns term `id`'s canonical encoding as a view into the
// arena — no copy, valid for the life of the store (api.md par. 12.7).
// Two loads: the term's packed offset, and the next term's — or the
// chunk's fill where the next term opened a new chunk, which is final
// the moment a chunk stops being the last.
dict_bytes :: proc(d: ^Dict, id: u32) -> []byte {
	assert(id != 0 && id & RES_INLINE_FLAG == 0, "dict_bytes: not a dictionary id")
	assert(int(id) <= len(d.off), "dict_bytes: an id past the dictionary")
	packed := d.off[id-1]
	c := int(packed >> DICT_CHUNK_BITS)
	at := packed & DICT_CHUNK_MASK
	end := d.used[c]
	if int(id) < len(d.off) {
		next := d.off[id]
		if int(next >> DICT_CHUNK_BITS) == c {
			end = next & DICT_CHUNK_MASK
		}
	}
	return d.chunks[c][at:end]
}

// dict_find resolves a canonical encoding to its dictionary id —
// ok=false for a term this store has never seen, which api.md
// par. 12.2 insists is an ordinary case costing one hash probe.
dict_find :: proc(d: ^Dict, enc: []byte) -> (id: u32, ok: bool) {
	return d.by_term[string(enc)]
}

// dict_add interns one canonical encoding as the next dictionary id,
// copying it into the arena and keying by_term with a view over the
// copy. Refuses an encoding already interned (.Duplicate_Term — the
// arena cannot represent two ids with one meaning without breaking
// architecture.md par. 3.2's injectivity) and an arena past its u32
// addressing (.Dict_Overflow). The load path is the only caller today;
// Apply will be the second.
@(private)
dict_add :: proc(d: ^Dict, enc: []byte, allocator: runtime.Allocator) -> (id: u32, err: Load_Error) {
	if string(enc) in d.by_term {
		return 0, .Duplicate_Term
	}
	need := len(enc)
	if len(d.chunks) == 0 || int(d.used[len(d.used)-1])+need > len(d.chunks[len(d.chunks)-1]) {
		if len(d.chunks) >= DICT_MAX_CHUNKS {
			return 0, .Dict_Overflow
		}
		size := max(need, DICT_CHUNK_SIZE)
		append(&d.chunks, make([]byte, size, allocator))
		append(&d.used, 0)
	}
	c := len(d.chunks) - 1
	at := d.used[c]
	copy(d.chunks[c][at:], enc)
	d.used[c] += u32(need)
	append(&d.off, u32(c) << DICT_CHUNK_BITS | at)
	id = u32(len(d.off))
	d.by_term[string(d.chunks[c][int(at):int(at)+need])] = id
	return id, .None
}

// fact_append appends one fact and its origin bit, growing a chunk
// when the last is full — never relocating one. Returns the fact's
// positional id (log.md par. 5.3's rule, applied residently).
@(private)
fact_append :: proc(s: ^Store, f: Fact, is_derived: bool) -> (id: u32) {
	id = s.n_facts
	if id & FACT_CHUNK_MASK == 0 {
		append(&s.facts, make([]Fact, FACT_CHUNK_SIZE, s.allocator))
	}
	s.facts[id >> FACT_CHUNK_BITS][id & FACT_CHUNK_MASK] = f
	if int(id >> 6) >= len(s.derived) {
		append(&s.derived, 0)
	}
	if is_derived {
		s.derived[id >> 6] |= u64(1) << (id & 63)
	}
	s.n_facts += 1
	return id
}

// epoch_append records one committed epoch's metadata, same chunk
// discipline as the facts.
@(private)
epoch_append :: proc(s: ^Store, m: Epoch_Meta) {
	i := s.n_epochs
	if i & EPOCH_CHUNK_MASK == 0 {
		append(&s.epochs, make([]Epoch_Meta, EPOCH_CHUNK_SIZE, s.allocator))
	}
	s.epochs[i >> EPOCH_CHUNK_BITS][i & EPOCH_CHUNK_MASK] = m
	s.n_epochs += 1
}
