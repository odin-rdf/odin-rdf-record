package record

import "core:testing"

// The resident structures' tests (RECORD-T-0007): the 64->32-bit
// re-tag against exact values — the place a silent off-by-one becomes
// a quietly wrong store — and the arena and chunk mechanics the load
// path builds on.

@(test)
test_resident_id_retag :: proc(t: ^testing.T) {
	// Dictionary ids pass through unchanged, 0 ("none" and the default
	// graph) included.
	testing.expect_value(t, resident_id(0), u32(0))
	testing.expect_value(t, resident_id(1), u32(1))
	testing.expect_value(t, resident_id(RESIDENT_ID_LIMIT-1), u32(RESIDENT_ID_LIMIT-1))

	// Integers: flag bit 63 -> 31, tag 2 into bits 30..28, payload
	// rebiased from 2^55 to 2^27. Exact values, hand-computed.
	cases := [5]struct {
		v:    i64,
		want: u32,
	}{
		{0, 0xA800_0000},
		{5, 0xA800_0005},
		{-1, 0xA7FF_FFFF},
		{INLINE_VALUE_MIN, 0xA000_0000},
		{INLINE_VALUE_MAX, 0xAFFF_FFFF},
	}
	for c in cases {
		id, ok := inline_integer(c.v)
		testing.expect(t, ok, "the value is in the frozen range")
		testing.expect_value(t, resident_id(id), c.want)
	}

	// The order-preserving property survives the re-tag (api.md
	// par. 3.2): inlined integers sort numerically as resident ids.
	r_min := resident_id(must_inline(t, INLINE_VALUE_MIN))
	r_neg := resident_id(must_inline(t, -1))
	r_zero := resident_id(must_inline(t, 0))
	r_five := resident_id(must_inline(t, 5))
	r_max := resident_id(must_inline(t, INLINE_VALUE_MAX))
	testing.expect(t, r_min < r_neg && r_neg < r_zero && r_zero < r_five && r_five < r_max, "integers sort numerically")

	// Booleans: raw 0/1 payload, tag 1.
	testing.expect_value(t, resident_id(INLINE_FLAG | u64(INLINE_TAG_BOOLEAN) << INLINE_TAG_SHIFT), u32(0x9000_0000))
	testing.expect_value(t, resident_id(INLINE_FLAG | u64(INLINE_TAG_BOOLEAN) << INLINE_TAG_SHIFT | 1), u32(0x9000_0001))

	// Dates: tag 3, offset-binary days since 1970.
	date_zero := INLINE_FLAG | u64(INLINE_TAG_DATE) << INLINE_TAG_SHIFT | INLINE_BIAS
	testing.expect_value(t, resident_id(date_zero), u32(0xB800_0000))
	testing.expect_value(t, resident_id(date_zero + 19_700), u32(0xB800_0000 + 19_700))
}

@(private = "file")
must_inline :: proc(t: ^testing.T, v: i64) -> u64 {
	id, ok := inline_integer(v)
	testing.expect(t, ok, "the value is in the frozen range")
	return id
}

@(test)
test_dict_arena :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	d := &s.dict

	// Interning assigns 1-based ids in call order; bytes round-trip as
	// views; lookup answers both ways.
	a := transmute([]byte)string("\x01http://example.org/a")
	bb := transmute([]byte)string("\x03some literal")
	id_a, err_a := dict_add(d, a, s.allocator)
	testing.expect_value(t, err_a, Load_Error.None)
	testing.expect_value(t, id_a, u32(1))
	id_b, err_b := dict_add(d, bb, s.allocator)
	testing.expect_value(t, err_b, Load_Error.None)
	testing.expect_value(t, id_b, u32(2))
	testing.expect_value(t, string(dict_bytes(d, 1)), string(a))
	testing.expect_value(t, string(dict_bytes(d, 2)), string(bb))
	found, ok := dict_find(d, a)
	testing.expect(t, ok, "an interned term resolves")
	testing.expect_value(t, found, u32(1))
	_, missing := dict_find(d, transmute([]byte)string("\x01http://example.org/zzz"))
	testing.expect(t, !missing, "an unseen term is an ordinary miss")

	// A duplicate encoding is refused: two ids with one meaning would
	// break injectivity.
	_, err_dup := dict_add(d, a, s.allocator)
	testing.expect_value(t, err_dup, Load_Error.Duplicate_Term)
	testing.expect_value(t, len(d.off), 2)

	// An encoding larger than a chunk gets a dedicated chunk of its
	// exact size; the term before it ends at its chunk's fill, the term
	// after it opens a fresh chunk — the three boundary shapes of
	// dict_bytes's length recovery.
	big := make([]byte, DICT_CHUNK_SIZE+1)
	defer delete(big)
	big[0] = 0x03
	for i in 1 ..< len(big) {
		big[i] = u8('a' + i%26)
	}
	id_big, err_big := dict_add(d, big, s.allocator)
	testing.expect_value(t, err_big, Load_Error.None)
	testing.expect_value(t, id_big, u32(3))
	after := transmute([]byte)string("\x01http://example.org/after")
	id_after, err_after := dict_add(d, after, s.allocator)
	testing.expect_value(t, err_after, Load_Error.None)
	testing.expect_value(t, id_after, u32(4))
	testing.expect_value(t, len(d.chunks), 3)
	testing.expect_value(t, string(dict_bytes(d, 2)), string(bb))
	got_big := dict_bytes(d, 3)
	testing.expect(t, len(got_big) == len(big), "the oversized term keeps its length")
	testing.expect_value(t, string(got_big[:8]), string(big[:8]))
	testing.expect_value(t, string(dict_bytes(d, 4)), string(after))
}

@(test)
test_dict_overflow :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)

	// Rig the arena to its chunk ceiling with empty, unallocated
	// chunks; the next intern must refuse rather than pack a chunk
	// index the u32 offset cannot carry.
	nothing: []byte
	for _ in 0 ..< DICT_MAX_CHUNKS {
		append(&s.dict.chunks, nothing)
		append(&s.dict.used, 0)
	}
	_, err := dict_add(&s.dict, transmute([]byte)string("\x01http://example.org/a"), s.allocator)
	testing.expect_value(t, err, Load_Error.Dict_Overflow)
}

@(test)
test_fact_and_epoch_chunks :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)

	// Fill past one chunk boundary; every fact and origin bit reads
	// back exactly, and growth appended chunks rather than moving one.
	n := u32(FACT_CHUNK_SIZE + 2)
	for i in 0 ..< n {
		f := Fact{s = i, p = i + 1, o = i + 2, g = 0, assert = 1, retract = LIVE_EPOCH}
		id := fact_append(&s, f, i%3 == 0)
		testing.expect_value(t, id, i)
	}
	testing.expect_value(t, s.n_facts, n)
	testing.expect_value(t, len(s.facts), 2)
	first_chunk := raw_data(s.facts[0])
	for i in 0 ..< n {
		f := store_fact(&s, i)
		testing.expect_value(t, f.s, i)
		testing.expect_value(t, f.o, i+2)
		testing.expect_value(t, store_derived(&s, i), i%3 == 0)
	}
	testing.expect(t, raw_data(s.facts[0]) == first_chunk, "chunks never move")

	// The epoch table crosses its boundary the same way.
	m := u32(EPOCH_CHUNK_SIZE + 2)
	for e in 1 ..= m {
		epoch_append(&s, Epoch_Meta{wall = u64(e) * 10, actor = e, reason = 0})
	}
	testing.expect_value(t, s.n_epochs, m)
	testing.expect_value(t, len(s.epochs), 2)
	for e in 1 ..= m {
		meta := store_epoch_meta(&s, e)
		testing.expect_value(t, meta.wall, u64(e)*10)
		testing.expect_value(t, meta.actor, e)
	}
}

@(test)
test_note_at :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)

	// No note yet: nothing is in effect at any epoch.
	_, none := store_note_at(&s, 9)
	testing.expect(t, !none, "no note precedes any epoch")

	// Notes in log order; two at the same boundary — the later one is
	// the one in effect.
	note :: proc(s: ^Store, last_epoch: u32, text: string) {
		p := make([]byte, len(text), s.allocator)
		copy(p, text)
		append(&s.notes, Env_Note{last_epoch = last_epoch, payload = p})
	}
	note(&s, 2, "first")
	note(&s, 5, "second")
	note(&s, 5, "third")

	_, before := store_note_at(&s, 1)
	testing.expect(t, !before, "nothing in effect before the first note")
	p2, ok2 := store_note_at(&s, 2)
	testing.expect(t, ok2, "in effect at its own boundary")
	testing.expect_value(t, string(p2), "first")
	p4, ok4 := store_note_at(&s, 4)
	testing.expect(t, ok4, "carries forward")
	testing.expect_value(t, string(p4), "first")
	p5, ok5 := store_note_at(&s, 5)
	testing.expect(t, ok5, "the boundary takes the new note")
	testing.expect_value(t, string(p5), "third")
	p9, ok9 := store_note_at(&s, 9)
	testing.expect(t, ok9, "the last note carries to the head")
	testing.expect_value(t, string(p9), "third")
}
