// The encoding layer of the record (RECORD-T-0001): every on-disk byte
// of log.md's format as pure functions over byte slices — the segment
// header (par. 3), the record frame (par. 4), the three record bodies
// (par. 5), and the hash chain (par. 6). Nothing here touches a file:
// the writer appends what these produce, and the open path feeds what
// it reads back through the decoders.
//
// All integers are big-endian, per the format. Decoded views borrow
// from the body they were decoded from and are valid exactly as long
// as it — the family's zero-copy discipline. Encoded bodies are
// allocated from the caller's allocator and owned by the caller.
//
// Encoding refuses what the format forbids before any byte exists: a
// non-contiguous epoch, a term definition out of first-appearance
// order, an inlined component outside the range RECORD-A-0001 froze.
// Decoding is strict about structure — an unknown record kind, a bad
// length, or a trailing byte is an error, never a skip (log.md par. 4)
// — and permissive about values, which are the replay consumer's
// business.
package record

import "core:crypto/sha2"

// The fixed shape of the format (log.md par. 3, par. 4).
MAGIC :: "RDFLOG\x00\x00"
FORMAT_VERSION :: 2
HEADER_SIZE :: 64
HASH_SIZE :: 32
FRAME_OVERHEAD :: 8
MAX_RECORD_SIZE :: 64 * 1024 * 1024
OP_SIZE :: 33

// DEFAULT_GRAPH is the graph component of a fact in the default graph
// (log.md par. 5.3, amended 2026-08-19): 0, the same "none" that actor
// and reason use, because an absent graph name is the default graph.
// Valid in G and nowhere else — S, P, and O may never be 0.
DEFAULT_GRAPH :: u64(0)

// Record_Kind is a body's first byte. Kinds 0x04..0x7F are reserved;
// a reader that meets one in a sealed segment must fail, not skip.
Record_Kind :: enum u8 {
	Invalid          = 0x00,
	Epoch_Commit     = 0x01,
	Segment_Seal     = 0x02,
	Environment_Note = 0x03,
}

// Op_Kind's high nibble carries origin (log.md par. 5.3): an auditor
// must never see an inference presented as a record, so origin is part
// of the record itself. Our writer never emits the derived kinds
// (RECORD-A-0002), but the format defines them and the decoder reads
// them.
Op_Kind :: enum u8 {
	Assert          = 0x01,
	Retract         = 0x02,
	Assert_Derived  = 0x11,
	Retract_Derived = 0x12,
}

// The on-disk inline-term encoding (architecture.md par. 3.4): bit 63
// flags an inlined term, bits 62..56 tag its type, and the low 56 bits
// carry the payload — offset-binary for the ordered types, so inlined
// values sort numerically under the same big-endian order the indices
// use. The writer restricts payloads to what the 32-bit resident
// scheme can hold (RECORD-A-0001): boolean 0/1, integer and date
// within ±2^27 of the bias.
INLINE_FLAG :: u64(1) << 63
INLINE_TAG_SHIFT :: 56
INLINE_PAYLOAD_MASK :: (u64(1) << 56) - 1
INLINE_BIAS :: u64(1) << 55
INLINE_TAG_BOOLEAN :: u8(0x01)
INLINE_TAG_INTEGER :: u8(0x02)
INLINE_TAG_DATE :: u8(0x03)
INLINE_VALUE_MIN :: -(i64(1) << 27)
INLINE_VALUE_MAX :: i64(1)<<27 - 1

// Encode_Error is what commit_encode and friends refuse with. Every
// case is a caller bug, not an environmental condition: nothing here
// can fail for a reason the caller did not put in the arguments.
Encode_Error :: enum {
	None,
	Epoch_Gap,    // epoch is not prev_epoch + 1 (log.md par. 5.1)
	Term_Order,   // term ids not contiguous from next_term_id (par. 5.2)
	Bad_Term_Id,  // a zero S/P/O, an inlined definition or graph label, or an undefined dictionary id
	Inline_Range, // an inlined id outside RECORD-A-0001's frozen range
	Bad_Op,       // an op kind the format does not define
	Too_Large,    // the body would exceed MAX_RECORD_SIZE
}

// Decode_Error is what the decoders refuse with. Structure is judged
// here; values are the consumer's business.
Decode_Error :: enum {
	None,
	Truncated,    // the body ends before its own fields say it should
	Malformed,    // the body has bytes its own fields do not account for
	Bad_Magic,    // a segment header that is not one
	Bad_Version,  // a format version this reader does not speak
	Bad_Checksum, // a header CRC mismatch
	Bad_Kind,     // a record kind this reader does not know
	Bad_Op,       // an op kind the format does not define
}

// Frame_Status classifies frame_next's read, in log.md par. 7.2's
// terms. Position decides what Torn means: only the final frame of the
// open segment may be recovered by truncation — anywhere else it is
// corruption, and that judgement belongs to the open path, not here.
Frame_Status :: enum {
	Ok,
	Clean_End, // fewer than FRAME_OVERHEAD bytes remain
	Torn,      // a zero or oversized length, a short body, or a CRC mismatch
}

// Segment_Header is the fixed 64 bytes at offset 0 of every segment
// (log.md par. 3). The CRC covers bytes 0..27 only: the base hash is
// verified by equality against the previous segment's head, a stronger
// check than any checksum.
Segment_Header :: struct {
	version:       u32,
	segment:       u32,
	first_epoch:   u64,
	first_fact_id: u32,
	base_hash:     [HASH_SIZE]u8,
}

// Term_Def is one term definition inside an epoch commit (log.md
// par. 5.2). The encoding is architecture.md par. 3.2's canonical form
// carried verbatim — opaque bytes to this layer. Decoded, `enc`
// borrows from the body.
Term_Def :: struct {
	id:  u64,
	enc: []byte,
}

// Fact_Op is one fact operation (log.md par. 5.3): 33 bytes on disk,
// component order matching N-Quads. Nothing in it is 8-byte aligned,
// which is the decoder's problem and not the reader's.
Fact_Op :: struct {
	op:         Op_Kind,
	s, p, o, g: u64,
}

// Commit is an epoch commit the writer wants encoded. Actor and reason
// are term ids, 0 for none; wall is Unix nanoseconds UTC from the
// writer's clock — evidence, not proof (api.md par. 2.4).
Commit :: struct {
	epoch:  u64,
	wall:   u64,
	actor:  u64,
	reason: u64,
	terms:  []Term_Def,
	ops:    []Fact_Op,
}

// Commit_View is a decoded epoch commit. The term and op regions stay
// raw — commit_terms and commit_ops iterate them without allocating —
// and everything borrows from the decoded body.
Commit_View :: struct {
	epoch:       u64,
	wall:        u64,
	actor:       u64,
	reason:      u64,
	n_terms:     u32,
	n_ops:       u32,
	terms_bytes: []byte,
	ops_bytes:   []byte,
	prev_hash:   [HASH_SIZE]u8,
	hash:        [HASH_SIZE]u8,
}

// Note is an environment note (log.md par. 5.5): the software
// environment as UTF-8 JSON, chained like a commit but advancing no
// epoch. last_epoch is the epoch the note follows, 0 before the first.
Note :: struct {
	last_epoch: u64,
	payload:    []byte,
}

// Note_View is a decoded environment note; payload borrows.
Note_View :: struct {
	last_epoch: u64,
	payload:    []byte,
	prev_hash:  [HASH_SIZE]u8,
	hash:       [HASH_SIZE]u8,
}

// Seal is a segment seal (log.md par. 5.4): always the last record of
// a sealed segment, a summary rather than a chain link — final_hash is
// the head at seal time, and the seal's own bytes are hashed into
// nothing. sig is empty in v1 (RECORD-I-0001 non-goal); decoded, it
// borrows.
Seal :: struct {
	last_epoch:   u64,
	record_count: u64,
	last_fact_id: u32,
	final_hash:   [HASH_SIZE]u8,
	sig:          []byte,
}

// record_kind reads a body's first byte. Unknown kinds are the
// caller's error to raise — par. 4 is emphatic that skipping one
// silently changes the reconstructed graph.
record_kind :: proc(body: []byte) -> (kind: Record_Kind, ok: bool) {
	if len(body) == 0 {
		return .Invalid, false
	}
	switch body[0] {
	case u8(Record_Kind.Epoch_Commit):
		return .Epoch_Commit, true
	case u8(Record_Kind.Segment_Seal):
		return .Segment_Seal, true
	case u8(Record_Kind.Environment_Note):
		return .Environment_Note, true
	}
	return .Invalid, false
}

// header_encode fills the fixed 64 header bytes, CRC included.
header_encode :: proc(h: Segment_Header, dst: ^[HEADER_SIZE]u8) {
	copy(dst[0:8], MAGIC)
	put_u32_at(dst[8:], h.version)
	put_u32_at(dst[12:], h.segment)
	put_u64_at(dst[16:], h.first_epoch)
	put_u32_at(dst[24:], h.first_fact_id)
	put_u32_at(dst[28:], crc32c(dst[0:28]))
	base := h.base_hash
	copy(dst[32:64], base[:])
}

// header_decode validates magic, version, and the CRC over bytes
// 0..27. The base hash is returned unjudged: its check is equality
// against the previous segment's head, which only the open path holds.
header_decode :: proc(src: []byte) -> (h: Segment_Header, err: Decode_Error) {
	if len(src) < HEADER_SIZE {
		return {}, .Truncated
	}
	if string(src[0:8]) != MAGIC {
		return {}, .Bad_Magic
	}
	if get_u32(src[28:]) != crc32c(src[0:28]) {
		return {}, .Bad_Checksum
	}
	h.version = get_u32(src[8:])
	if h.version != FORMAT_VERSION {
		return {}, .Bad_Version
	}
	h.segment = get_u32(src[12:])
	h.first_epoch = get_u64(src[16:])
	h.first_fact_id = get_u32(src[24:])
	copy(h.base_hash[:], src[32:64])
	return h, .None
}

// frame_append frames one body onto buf: length, CRC-32C over the
// length bytes followed by the body, body. The caller guarantees the
// body is a legal record — commit_encode and friends already refused
// anything oversized or empty.
frame_append :: proc(buf: ^[dynamic]u8, body: []byte) {
	assert(len(body) > 0 && len(body) <= MAX_RECORD_SIZE, "frame_append: body size out of range")
	lenb: [4]u8
	put_u32_at(lenb[:], u32(len(body)))
	crc := crc32c(lenb[:], body)
	append(buf, ..lenb[:])
	put_u32(buf, crc)
	append(buf, ..body)
}

// frame_next reads one frame off data, returning the body (borrowed)
// and the remainder. Clean_End means fewer than 8 bytes remain; Torn
// means a zero or oversized length, a body the data cannot hold, or a
// CRC mismatch — log.md par. 7.2's taxonomy, position left to the
// caller.
frame_next :: proc(data: []byte) -> (body: []byte, rest: []byte, status: Frame_Status) {
	if len(data) < FRAME_OVERHEAD {
		return nil, data, .Clean_End
	}
	length := int(get_u32(data))
	if length == 0 || length > MAX_RECORD_SIZE {
		return nil, data, .Torn
	}
	if len(data)-FRAME_OVERHEAD < length {
		return nil, data, .Torn
	}
	body = data[FRAME_OVERHEAD : FRAME_OVERHEAD+length]
	if get_u32(data[4:]) != crc32c(data[0:4], body) {
		return nil, data, .Torn
	}
	return body, data[FRAME_OVERHEAD+length:], .Ok
}

// inline_ok is the writer's restriction from RECORD-A-0001: an inlined
// id must carry a tag the frozen scheme assigns and a payload the
// 32-bit resident encoding can hold. Dictionary ids pass untouched.
inline_ok :: proc(id: u64) -> bool {
	if id & INLINE_FLAG == 0 {
		return true
	}
	tag := u8(id >> INLINE_TAG_SHIFT) & 0x7F
	payload := id & INLINE_PAYLOAD_MASK
	switch tag {
	case INLINE_TAG_BOOLEAN:
		return payload <= 1
	case INLINE_TAG_INTEGER, INLINE_TAG_DATE:
		v := i64(payload) - i64(INLINE_BIAS)
		return v >= INLINE_VALUE_MIN && v <= INLINE_VALUE_MAX
	}
	return false
}

// inline_integer builds the on-disk inlined id for an xsd:integer in
// the frozen range — the one inline case the writer emits today
// (RECORD-A-0001). The caller has already refused non-canonical
// lexical forms; this is arithmetic, not judgement.
inline_integer :: proc(v: i64) -> (id: u64, ok: bool) {
	if v < INLINE_VALUE_MIN || v > INLINE_VALUE_MAX {
		return 0, false
	}
	return INLINE_FLAG | u64(INLINE_TAG_INTEGER) << INLINE_TAG_SHIFT | u64(v + i64(INLINE_BIAS)), true
}

// commit_encode encodes one epoch commit, computing its chain hash
// from prev_hash. It refuses the format's encoding-level invariants:
// the epoch must be prev_epoch + 1 (gap-free, log.md par. 5.1), term
// ids must run contiguously from next_term_id in first-appearance
// order (par. 5.2), no term definition may be inlined, and every op
// component must be a nonzero id that is either a defined dictionary
// id or an inlined value in the frozen range — except G, where 0 is
// the default graph and an inlined id is never legal (par. 5.3,
// amended: a graph label is not a literal). Live-quad preconditions
// need resident state and are Apply's business, not this layer's.
// The returned body is allocated from `allocator`; the caller owns it.
commit_encode :: proc(
	c: Commit,
	prev_hash: [HASH_SIZE]u8,
	prev_epoch: u64,
	next_term_id: u64,
	allocator := context.allocator,
) -> (
	body: []byte,
	err: Encode_Error,
) {
	if c.epoch != prev_epoch+1 {
		return nil, .Epoch_Gap
	}
	size := 41 + len(c.ops)*OP_SIZE + 2*HASH_SIZE
	next := next_term_id
	for t in c.terms {
		if t.id != next || t.id&INLINE_FLAG != 0 || t.id == 0 {
			return nil, .Term_Order
		}
		next += 1
		size += 12 + len(t.enc)
	}
	max_term := next // exclusive bound: ids defined by this or any earlier record
	for op in c.ops {
		if op.op != .Assert && op.op != .Retract && op.op != .Assert_Derived && op.op != .Retract_Derived {
			return nil, .Bad_Op
		}
		for id in ([3]u64{op.s, op.p, op.o}) {
			if id == 0 {
				return nil, .Bad_Term_Id
			}
			if id & INLINE_FLAG != 0 {
				if !inline_ok(id) {
					return nil, .Inline_Range
				}
			} else if id >= max_term {
				return nil, .Bad_Term_Id
			}
		}
		// G is the one component 0 is legal in — the default graph —
		// and the one component an inlined id never is: every inlined
		// term is a literal, and a graph label is an IRI or a blank
		// node (log.md par. 5.3, amended).
		if op.g != DEFAULT_GRAPH {
			if op.g&INLINE_FLAG != 0 || op.g >= max_term {
				return nil, .Bad_Term_Id
			}
		}
	}
	for id in ([2]u64{c.actor, c.reason}) {
		if id != 0 && (id&INLINE_FLAG != 0 || id >= max_term) {
			return nil, .Bad_Term_Id
		}
	}
	if size > MAX_RECORD_SIZE {
		return nil, .Too_Large
	}

	buf := make([dynamic]u8, 0, size, allocator)
	append(&buf, u8(Record_Kind.Epoch_Commit))
	put_u64(&buf, c.epoch)
	put_u64(&buf, c.wall)
	put_u64(&buf, c.actor)
	put_u64(&buf, c.reason)
	put_u32(&buf, u32(len(c.terms)))
	put_u32(&buf, u32(len(c.ops)))
	for t in c.terms {
		put_u64(&buf, t.id)
		put_u32(&buf, u32(len(t.enc)))
		append(&buf, ..t.enc)
	}
	for op in c.ops {
		append(&buf, u8(op.op))
		put_u64(&buf, op.s)
		put_u64(&buf, op.p)
		put_u64(&buf, op.o)
		put_u64(&buf, op.g)
	}
	prev := prev_hash
	append(&buf, ..prev[:])
	put_chain_hash(&buf)
	return buf[:], .None
}

// commit_decode validates an epoch commit's structure exactly: the
// term region must parse, the op region must hold n_ops legal kinds,
// and with the two hashes they must account for every byte. Values —
// term ids, components, the hashes themselves — are the consumer's
// and the chain walker's business.
commit_decode :: proc(body: []byte) -> (v: Commit_View, err: Decode_Error) {
	if len(body) < 41+2*HASH_SIZE {
		return {}, .Truncated
	}
	if body[0] != u8(Record_Kind.Epoch_Commit) {
		return {}, .Bad_Kind
	}
	v.epoch = get_u64(body[1:])
	v.wall = get_u64(body[9:])
	v.actor = get_u64(body[17:])
	v.reason = get_u64(body[25:])
	v.n_terms = get_u32(body[33:])
	v.n_ops = get_u32(body[37:])
	tail := len(body) - 2*HASH_SIZE
	off := 41
	for _ in 0 ..< v.n_terms {
		if off+12 > tail {
			return {}, .Truncated
		}
		l := int(get_u32(body[off+8:]))
		if off+12+l > tail {
			return {}, .Truncated
		}
		off += 12 + l
	}
	v.terms_bytes = body[41:off]
	if tail-off != int(v.n_ops)*OP_SIZE {
		return {}, .Malformed
	}
	v.ops_bytes = body[off:tail]
	for i in 0 ..< int(v.n_ops) {
		k := v.ops_bytes[i*OP_SIZE]
		if k != u8(Op_Kind.Assert) && k != u8(Op_Kind.Retract) &&
		   k != u8(Op_Kind.Assert_Derived) && k != u8(Op_Kind.Retract_Derived) {
			return {}, .Bad_Op
		}
	}
	copy(v.prev_hash[:], body[tail:])
	copy(v.hash[:], body[tail+HASH_SIZE:])
	return v, .None
}

// Term_Iter walks a decoded commit's term definitions in order,
// borrowing each encoding from the body. commit_decode validated the
// region, so iteration cannot fail.
Term_Iter :: struct {
	rest:      []byte,
	remaining: u32,
}

commit_terms :: proc(v: Commit_View) -> Term_Iter {
	return {rest = v.terms_bytes, remaining = v.n_terms}
}

term_next :: proc(it: ^Term_Iter) -> (t: Term_Def, ok: bool) {
	if it.remaining == 0 {
		return {}, false
	}
	t.id = get_u64(it.rest)
	l := int(get_u32(it.rest[8:]))
	t.enc = it.rest[12 : 12+l]
	it.rest = it.rest[12+l:]
	it.remaining -= 1
	return t, true
}

// Op_Iter walks a decoded commit's fact operations in order. The op
// bytes are unaligned by design (log.md par. 5.3); every component is
// read byte-by-byte.
Op_Iter :: struct {
	rest:      []byte,
	remaining: u32,
}

commit_ops :: proc(v: Commit_View) -> Op_Iter {
	return {rest = v.ops_bytes, remaining = v.n_ops}
}

op_next :: proc(it: ^Op_Iter) -> (op: Fact_Op, ok: bool) {
	if it.remaining == 0 {
		return {}, false
	}
	op.op = Op_Kind(it.rest[0])
	op.s = get_u64(it.rest[1:])
	op.p = get_u64(it.rest[9:])
	op.o = get_u64(it.rest[17:])
	op.g = get_u64(it.rest[25:])
	it.rest = it.rest[OP_SIZE:]
	it.remaining -= 1
	return op, true
}

// note_encode encodes an environment note, chained from prev_hash like
// a commit — the note carries the chain (log.md par. 5.5) — but
// advancing no epoch. The returned body is the caller's.
note_encode :: proc(
	n: Note,
	prev_hash: [HASH_SIZE]u8,
	allocator := context.allocator,
) -> (
	body: []byte,
	err: Encode_Error,
) {
	size := 13 + len(n.payload) + 2*HASH_SIZE
	if size > MAX_RECORD_SIZE {
		return nil, .Too_Large
	}
	buf := make([dynamic]u8, 0, size, allocator)
	append(&buf, u8(Record_Kind.Environment_Note))
	put_u64(&buf, n.last_epoch)
	put_u32(&buf, u32(len(n.payload)))
	append(&buf, ..n.payload)
	prev := prev_hash
	append(&buf, ..prev[:])
	put_chain_hash(&buf)
	return buf[:], .None
}

// note_decode validates an environment note's structure; the payload
// borrows from the body.
note_decode :: proc(body: []byte) -> (v: Note_View, err: Decode_Error) {
	if len(body) < 13+2*HASH_SIZE {
		return {}, .Truncated
	}
	if body[0] != u8(Record_Kind.Environment_Note) {
		return {}, .Bad_Kind
	}
	v.last_epoch = get_u64(body[1:])
	l := int(get_u32(body[9:]))
	if 13+l+2*HASH_SIZE > len(body) {
		return {}, .Truncated
	}
	if 13+l+2*HASH_SIZE < len(body) {
		return {}, .Malformed
	}
	v.payload = body[13 : 13+l]
	copy(v.prev_hash[:], body[13+l:])
	copy(v.hash[:], body[13+l+HASH_SIZE:])
	return v, .None
}

// seal_encode encodes a segment seal. The seal is a summary, not a
// chain link: final_hash is the head at seal time and the seal's own
// bytes are hashed into nothing (log.md par. 5.4). sig is written as
// given; v1 writers pass none.
seal_encode :: proc(s: Seal, allocator := context.allocator) -> (body: []byte, err: Encode_Error) {
	size := 57 + len(s.sig)
	if size > MAX_RECORD_SIZE {
		return nil, .Too_Large
	}
	buf := make([dynamic]u8, 0, size, allocator)
	append(&buf, u8(Record_Kind.Segment_Seal))
	put_u64(&buf, s.last_epoch)
	put_u64(&buf, s.record_count)
	put_u32(&buf, s.last_fact_id)
	final := s.final_hash
	append(&buf, ..final[:])
	put_u32(&buf, u32(len(s.sig)))
	append(&buf, ..s.sig)
	return buf[:], .None
}

// seal_decode validates a seal's structure; sig borrows from the body.
seal_decode :: proc(body: []byte) -> (s: Seal, err: Decode_Error) {
	if len(body) < 57 {
		return {}, .Truncated
	}
	if body[0] != u8(Record_Kind.Segment_Seal) {
		return {}, .Bad_Kind
	}
	s.last_epoch = get_u64(body[1:])
	s.record_count = get_u64(body[9:])
	s.last_fact_id = get_u32(body[17:])
	copy(s.final_hash[:], body[21:53])
	l := int(get_u32(body[53:]))
	if 57+l > len(body) {
		return {}, .Truncated
	}
	if 57+l < len(body) {
		return {}, .Malformed
	}
	s.sig = body[57 : 57+l]
	return s, .None
}

// chain_hash computes log.md par. 6's rule over a complete chained
// body: SHA-256 of everything but the trailing hash field itself.
// hash_ok checks a body against its own embedded hash — the local half
// of verification; the cross-record half (prev_hash equality) is the
// open path's walk.
chain_hash :: proc(body: []byte) -> (h: [HASH_SIZE]u8) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, body[:len(body)-HASH_SIZE])
	sha2.final(&ctx, h[:])
	return h
}

hash_ok :: proc(body: []byte) -> bool {
	if len(body) < 2*HASH_SIZE+1 {
		return false
	}
	h := chain_hash(body)
	embedded: [HASH_SIZE]u8
	copy(embedded[:], body[len(body)-HASH_SIZE:])
	return h == embedded
}

// put_chain_hash appends the chain hash of everything already in buf —
// the encode-side form of chain_hash, called once per chained record
// with prev_hash already appended.
@(private)
put_chain_hash :: proc(buf: ^[dynamic]u8) {
	h: [HASH_SIZE]u8
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, buf[:])
	sha2.final(&ctx, h[:])
	append(buf, ..h[:])
}

// Big-endian helpers. The format is big-endian throughout and nothing
// in it is reliably aligned, so every integer is assembled bytewise.

@(private)
put_u32 :: proc(buf: ^[dynamic]u8, v: u32) {
	append(buf, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

@(private)
put_u64 :: proc(buf: ^[dynamic]u8, v: u64) {
	append(
		buf,
		u8(v >> 56), u8(v >> 48), u8(v >> 40), u8(v >> 32),
		u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v),
	)
}

@(private)
put_u32_at :: proc(dst: []byte, v: u32) {
	dst[0] = u8(v >> 24)
	dst[1] = u8(v >> 16)
	dst[2] = u8(v >> 8)
	dst[3] = u8(v)
}

@(private)
put_u64_at :: proc(dst: []byte, v: u64) {
	dst[0] = u8(v >> 56)
	dst[1] = u8(v >> 48)
	dst[2] = u8(v >> 40)
	dst[3] = u8(v >> 32)
	dst[4] = u8(v >> 24)
	dst[5] = u8(v >> 16)
	dst[6] = u8(v >> 8)
	dst[7] = u8(v)
}

@(private)
get_u32 :: proc(b: []byte) -> u32 {
	return u32(b[0])<<24 | u32(b[1])<<16 | u32(b[2])<<8 | u32(b[3])
}

@(private)
get_u64 :: proc(b: []byte) -> u64 {
	return u64(b[0])<<56 | u64(b[1])<<48 | u64(b[2])<<40 | u64(b[3])<<32 |
	       u64(b[4])<<24 | u64(b[5])<<16 | u64(b[6])<<8 | u64(b[7])
}
