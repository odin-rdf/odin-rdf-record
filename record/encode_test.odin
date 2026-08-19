package record

import "core:encoding/hex"
import "core:testing"

// The golden constants below were computed by an independent Python
// script (struct + hashlib + a reference CRC-32C) from log.md's field
// layouts alone — the encoders must reproduce them byte for byte, so a
// disagreement is a format bug, not a test bug. RECORD-T-0001.

@(private = "file")
GOLDEN_HEADER :: "5244464c4f4700000000000100000001000000000000000100000001dc6def980000000000000000000000000000000000000000000000000000000000000000"

@(private = "file")
GOLDEN_COMMIT :: "01000000000000000117979cfe362a000000000000000000000000000000000000000000020000000200000000000000010000001901687474703a2f2f6578616d706c652e6f72672f616c69636500000000000000020000001901687474703a2f2f6578616d706c652e6f72672f6b6e6f777301000000000000000100000000000000028280000000000022000000000000000101000000000000000200000000000000020000000000000001000000000000000100000000000000000000000000000000000000000000000000000000000000005cc2324816808c16e27086a2771f5965de13f4c18d7b7e6fc756bfe5c9af00c5"

@(private = "file")
GOLDEN_WALL :: u64(1_700_000_000_000_000_000)

@(private = "file")
GOLDEN_FRAME_CRC :: u32(0xF833_26E3)

// golden_commit fills caller-owned arrays and returns a Commit slicing
// them — the slices must not outlive storage this proc owns.
@(private = "file")
golden_commit :: proc(terms: ^[2]Term_Def, ops: ^[2]Fact_Op) -> Commit {
	inline_34, ok := inline_integer(34)
	assert(ok)
	terms^ = {
		{id = 1, enc = transmute([]u8)string("\x01http://example.org/alice")},
		{id = 2, enc = transmute([]u8)string("\x01http://example.org/knows")},
	}
	ops^ = {
		{op = .Assert, s = 1, p = 2, o = inline_34, g = 1},
		{op = .Assert, s = 2, p = 2, o = 1, g = 1},
	}
	return Commit{epoch = 1, wall = GOLDEN_WALL, terms = terms[:], ops = ops[:]}
}

@(test)
test_crc32c_check_value :: proc(t: ^testing.T) {
	// The published CRC-32C check value.
	testing.expect_value(t, crc32c(transmute([]u8)string("123456789")), u32(0xE306_9283))
	// Chunked and contiguous agree.
	testing.expect_value(
		t,
		crc32c(transmute([]u8)string("1234"), transmute([]u8)string("56789")),
		u32(0xE306_9283),
	)
}

@(test)
test_header_golden_and_round_trip :: proc(t: ^testing.T) {
	want, wok := hex.decode(transmute([]u8)string(GOLDEN_HEADER))
	testing.expect(t, wok, "golden header hex decodes")
	defer delete(want)

	h := Segment_Header{version = 1, segment = 1, first_epoch = 1, first_fact_id = 1}
	dst: [HEADER_SIZE]u8
	header_encode(h, &dst)
	testing.expect(t, string(dst[:]) == string(want), "header bytes match the independent encoding")

	got, err := header_decode(dst[:])
	testing.expect_value(t, err, Decode_Error.None)
	testing.expect_value(t, got.version, u32(1))
	testing.expect_value(t, got.segment, u32(1))
	testing.expect_value(t, got.first_epoch, u64(1))
	testing.expect_value(t, got.first_fact_id, u32(1))
	testing.expect(t, got.base_hash == h.base_hash, "base hash round-trips")
}

@(test)
test_header_refusals :: proc(t: ^testing.T) {
	h := Segment_Header{version = 1, segment = 3, first_epoch = 9, first_fact_id = 4}
	dst: [HEADER_SIZE]u8
	header_encode(h, &dst)

	_, err := header_decode(dst[:HEADER_SIZE-1])
	testing.expect_value(t, err, Decode_Error.Truncated)

	bad := dst
	bad[0] = 'X'
	_, err = header_decode(bad[:])
	testing.expect_value(t, err, Decode_Error.Bad_Magic)

	bad = dst
	bad[20] ~= 0xFF // inside the CRC-covered range
	_, err = header_decode(bad[:])
	testing.expect_value(t, err, Decode_Error.Bad_Checksum)

	// A wrong version with a valid CRC: re-encode with version 2.
	header_encode(Segment_Header{version = 2, segment = 3, first_epoch = 9, first_fact_id = 4}, &dst)
	_, err = header_decode(dst[:])
	testing.expect_value(t, err, Decode_Error.Bad_Version)

	// A corrupted base hash is NOT the header CRC's business: the check
	// is equality against the previous head, made by the open path.
	header_encode(h, &dst)
	dst[40] ~= 0xFF
	_, err = header_decode(dst[:])
	testing.expect_value(t, err, Decode_Error.None)
}

@(test)
test_commit_golden :: proc(t: ^testing.T) {
	want, wok := hex.decode(transmute([]u8)string(GOLDEN_COMMIT))
	testing.expect(t, wok, "golden commit hex decodes")
	defer delete(want)

	terms: [2]Term_Def
	ops: [2]Fact_Op
	c := golden_commit(&terms, &ops)
	body, err := commit_encode(c, {}, 0, 1)
	testing.expect_value(t, err, Encode_Error.None)
	defer delete(body)

	testing.expect(t, string(body) == string(want), "commit bytes match the independent encoding")
	testing.expect(t, hash_ok(body), "embedded hash matches the chain rule")

	buf: [dynamic]u8
	defer delete(buf)
	frame_append(&buf, body)
	testing.expect_value(t, get_u32_test(buf[4:8]), GOLDEN_FRAME_CRC)
}

@(test)
test_commit_decode_and_iterate :: proc(t: ^testing.T) {
	terms: [2]Term_Def
	ops: [2]Fact_Op
	c := golden_commit(&terms, &ops)
	body, err := commit_encode(c, {}, 0, 1)
	testing.expect_value(t, err, Encode_Error.None)
	defer delete(body)

	v, derr := commit_decode(body)
	testing.expect_value(t, derr, Decode_Error.None)
	testing.expect_value(t, v.epoch, u64(1))
	testing.expect_value(t, v.wall, GOLDEN_WALL)
	testing.expect_value(t, v.actor, u64(0))
	testing.expect_value(t, v.reason, u64(0))
	testing.expect_value(t, v.n_terms, u32(2))
	testing.expect_value(t, v.n_ops, u32(2))
	testing.expect(t, v.prev_hash == [HASH_SIZE]u8{}, "first record chains from zero")

	ti := commit_terms(v)
	for want_term in terms {
		got, ok := term_next(&ti)
		testing.expect(t, ok, "term iterator yields")
		testing.expect_value(t, got.id, want_term.id)
		testing.expect(t, string(got.enc) == string(want_term.enc), "term encoding survives verbatim")
	}
	_, more := term_next(&ti)
	testing.expect(t, !more, "term iterator ends")

	oi := commit_ops(v)
	for want_op in ops {
		got, ok := op_next(&oi)
		testing.expect(t, ok, "op iterator yields")
		testing.expect_value(t, got, want_op)
	}
	_, more = op_next(&oi)
	testing.expect(t, !more, "op iterator ends")
}

@(test)
test_commit_structural_refusals :: proc(t: ^testing.T) {
	terms: [2]Term_Def
	ops: [2]Fact_Op
	c := golden_commit(&terms, &ops)
	body, err := commit_encode(c, {}, 0, 1)
	testing.expect_value(t, err, Encode_Error.None)
	defer delete(body)

	// A trailing byte the fields do not account for.
	extra := make([]byte, len(body)+1)
	defer delete(extra)
	copy(extra, body)
	_, derr := commit_decode(extra)
	testing.expect_value(t, derr, Decode_Error.Malformed)

	// A body cut inside the term region.
	_, derr = commit_decode(body[:60])
	testing.expect_value(t, derr, Decode_Error.Truncated)

	// A flipped bit breaks the embedded hash.
	flipped := make([]byte, len(body))
	defer delete(flipped)
	copy(flipped, body)
	flipped[45] ~= 0x01
	testing.expect(t, !hash_ok(flipped), "a flipped bit fails the chain rule")

	// An op kind the format does not define, patched into valid bytes.
	bad := make([]byte, len(body))
	defer delete(bad)
	copy(bad, body)
	bad[len(bad)-2*HASH_SIZE-2*OP_SIZE] = 0x05
	_, derr = commit_decode(bad)
	testing.expect_value(t, derr, Decode_Error.Bad_Op)
}

@(test)
test_commit_encode_refusals :: proc(t: ^testing.T) {
	terms: [2]Term_Def
	ops: [2]Fact_Op
	c := golden_commit(&terms, &ops)

	// Epoch gaps are impossible to write (log.md par. 5.1).
	_, err := commit_encode(c, {}, 3, 1)
	testing.expect_value(t, err, Encode_Error.Epoch_Gap)

	// Term ids run in first-appearance order from next_term_id.
	_, err = commit_encode(c, {}, 0, 7)
	testing.expect_value(t, err, Encode_Error.Term_Order)

	// An op naming a dictionary id nothing has defined.
	ops_bad := [1]Fact_Op{{op = .Assert, s = 99, p = 2, o = 1, g = 1}}
	c2 := c
	c2.ops = ops_bad[:]
	_, err = commit_encode(c2, {}, 0, 1)
	testing.expect_value(t, err, Encode_Error.Bad_Term_Id)

	// A zero component: the graph is mandatory, and 0 is "unbound".
	ops_bad[0] = {op = .Assert, s = 1, p = 2, o = 1, g = 0}
	_, err = commit_encode(c2, {}, 0, 1)
	testing.expect_value(t, err, Encode_Error.Bad_Term_Id)

	// An inlined integer outside RECORD-A-0001's frozen range, encoded
	// under the 64-bit on-disk scheme the writer must not use.
	huge := INLINE_FLAG | u64(INLINE_TAG_INTEGER) << INLINE_TAG_SHIFT | (INLINE_BIAS + u64(1) << 30)
	ops_bad[0] = {op = .Assert, s = 1, p = 2, o = huge, g = 1}
	_, err = commit_encode(c2, {}, 0, 1)
	testing.expect_value(t, err, Encode_Error.Inline_Range)

	// An op kind the format does not define.
	ops_bad[0] = {op = Op_Kind(0x05), s = 1, p = 2, o = 1, g = 1}
	_, err = commit_encode(c2, {}, 0, 1)
	testing.expect_value(t, err, Encode_Error.Bad_Op)

	// An inlined actor: actor and reason are dictionary terms or none.
	c3 := c
	c3.actor, _ = inline_integer(1)
	_, err = commit_encode(c3, {}, 0, 1)
	testing.expect_value(t, err, Encode_Error.Bad_Term_Id)
}

@(test)
test_frame_taxonomy :: proc(t: ^testing.T) {
	body := transmute([]u8)string("\x03payload-bytes")
	buf: [dynamic]u8
	defer delete(buf)
	frame_append(&buf, body)
	frame_append(&buf, body)

	got, rest, status := frame_next(buf[:])
	testing.expect_value(t, status, Frame_Status.Ok)
	testing.expect(t, string(got) == string(body), "frame round-trips the body")
	got, rest, status = frame_next(rest)
	testing.expect_value(t, status, Frame_Status.Ok)
	_, _, status = frame_next(rest)
	testing.expect_value(t, status, Frame_Status.Clean_End)

	// Fewer than 8 bytes is a clean end, whatever the bytes are.
	_, _, status = frame_next(buf[:7])
	testing.expect_value(t, status, Frame_Status.Clean_End)

	// A zero length is not a legal record — a zero-filled block after a
	// crash must not read as a valid empty record (log.md par. 4).
	zeros: [16]u8
	_, _, status = frame_next(zeros[:])
	testing.expect_value(t, status, Frame_Status.Torn)

	// A length past MAX_RECORD_SIZE.
	over: [16]u8
	put_u32_test(over[:], u32(MAX_RECORD_SIZE)+1)
	_, _, status = frame_next(over[:])
	testing.expect_value(t, status, Frame_Status.Torn)

	// A body the remaining bytes cannot hold.
	_, _, status = frame_next(buf[:len(body)+FRAME_OVERHEAD-1])
	testing.expect_value(t, status, Frame_Status.Torn)

	// A CRC mismatch.
	buf[5] ~= 0xFF
	_, _, status = frame_next(buf[:])
	testing.expect_value(t, status, Frame_Status.Torn)
}

@(test)
test_note_round_trip :: proc(t: ^testing.T) {
	prev: [HASH_SIZE]u8
	prev[0] = 0xAB
	payload := transmute([]u8)string(`{"format":1,"derived":"materialized"}`)
	body, err := note_encode(Note{last_epoch = 4, payload = payload}, prev)
	testing.expect_value(t, err, Encode_Error.None)
	defer delete(body)
	testing.expect(t, hash_ok(body), "note carries the chain")

	v, derr := note_decode(body)
	testing.expect_value(t, derr, Decode_Error.None)
	testing.expect_value(t, v.last_epoch, u64(4))
	testing.expect(t, string(v.payload) == string(payload), "payload borrows intact")
	testing.expect(t, v.prev_hash == prev, "prev hash round-trips")

	extra := make([]byte, len(body)+1)
	defer delete(extra)
	copy(extra, body)
	_, derr = note_decode(extra)
	testing.expect_value(t, derr, Decode_Error.Malformed)

	_, derr = note_decode(body[:20])
	testing.expect_value(t, derr, Decode_Error.Truncated)
}

@(test)
test_seal_round_trip :: proc(t: ^testing.T) {
	final: [HASH_SIZE]u8
	final[31] = 0x7F
	s := Seal{last_epoch = 42, record_count = 17, last_fact_id = 400, final_hash = final}
	body, err := seal_encode(s)
	testing.expect_value(t, err, Encode_Error.None)
	defer delete(body)

	got, derr := seal_decode(body)
	testing.expect_value(t, derr, Decode_Error.None)
	testing.expect_value(t, got.last_epoch, u64(42))
	testing.expect_value(t, got.record_count, u64(17))
	testing.expect_value(t, got.last_fact_id, u32(400))
	testing.expect(t, got.final_hash == final, "final hash round-trips")
	testing.expect_value(t, len(got.sig), 0)

	// A signature survives the trip, borrowed.
	s.sig = transmute([]u8)string("not-a-real-signature")
	signed, serr := seal_encode(s)
	testing.expect_value(t, serr, Encode_Error.None)
	defer delete(signed)
	got, derr = seal_decode(signed)
	testing.expect_value(t, derr, Decode_Error.None)
	testing.expect(t, string(got.sig) == "not-a-real-signature", "sig borrows intact")

	extra := make([]byte, len(body)+1)
	defer delete(extra)
	copy(extra, body)
	_, derr = seal_decode(extra)
	testing.expect_value(t, derr, Decode_Error.Malformed)
}

@(test)
test_inline_encoding :: proc(t: ^testing.T) {
	// The golden op's object: 34 under flag | tag 2 | bias + 34.
	id, ok := inline_integer(34)
	testing.expect(t, ok, "34 inlines")
	testing.expect_value(t, id, u64(1)<<63 | u64(2)<<56 | (u64(1)<<55 + 34))
	testing.expect(t, inline_ok(id), "the frozen range accepts it")

	// The frozen boundaries (RECORD-A-0001): ±2^27.
	lo, lok := inline_integer(INLINE_VALUE_MIN)
	testing.expect(t, lok && inline_ok(lo), "the low boundary inlines")
	hi, hok := inline_integer(INLINE_VALUE_MAX)
	testing.expect(t, hok && inline_ok(hi), "the high boundary inlines")
	_, ok = inline_integer(INLINE_VALUE_MAX + 1)
	testing.expect(t, !ok, "past the ceiling falls back to the dictionary")
	_, ok = inline_integer(INLINE_VALUE_MIN - 1)
	testing.expect(t, !ok, "past the floor falls back to the dictionary")

	// Tag 0 is reserved and rejected: 0x8000000000000000 must never
	// decode as a plausible term.
	testing.expect(t, !inline_ok(INLINE_FLAG), "tag 0 is invalid")
	// An unassigned tag.
	testing.expect(t, !inline_ok(INLINE_FLAG | u64(4)<<INLINE_TAG_SHIFT), "tag 4 is unassigned")
	// Boolean payloads are 0 or 1 and nothing else.
	testing.expect(t, inline_ok(INLINE_FLAG | u64(1)<<INLINE_TAG_SHIFT | 1), "boolean true")
	testing.expect(t, !inline_ok(INLINE_FLAG | u64(1)<<INLINE_TAG_SHIFT | 2), "boolean payload 2 is invalid")
}

@(test)
test_record_kind :: proc(t: ^testing.T) {
	kind, ok := record_kind([]byte{0x01})
	testing.expect(t, ok && kind == .Epoch_Commit, "commit kind")
	kind, ok = record_kind([]byte{0x02})
	testing.expect(t, ok && kind == .Segment_Seal, "seal kind")
	kind, ok = record_kind([]byte{0x03})
	testing.expect(t, ok && kind == .Environment_Note, "note kind")
	_, ok = record_kind([]byte{0x04})
	testing.expect(t, !ok, "reserved kinds fail rather than skip")
	_, ok = record_kind(nil)
	testing.expect(t, !ok, "an empty body has no kind")
}

// Test-side big-endian helpers: the package's own are private to keep
// the surface honest, and the tests must not depend on them anyway —
// a golden comparison through the same helpers would prove nothing.

@(private = "file")
get_u32_test :: proc(b: []byte) -> u32 {
	return u32(b[0])<<24 | u32(b[1])<<16 | u32(b[2])<<8 | u32(b[3])
}

@(private = "file")
put_u32_test :: proc(dst: []byte, v: u32) {
	dst[0] = u8(v >> 24)
	dst[1] = u8(v >> 16)
	dst[2] = u8(v >> 8)
	dst[3] = u8(v)
}
