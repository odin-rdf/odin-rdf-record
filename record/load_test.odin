package record

import "core:testing"

// The load path's tests (RECORD-T-0007): the resident build is the
// third consumer of a proven seam, so its equivalence is checked
// against the same writer state the T-0004 tests pin — counts from
// Verify_Result, contents by exact value — and its two live-quad
// refusals extend the judged/altered split one layer up: logs crafted
// to violate log.md par. 5.3's preconditions must verify clean, replay
// clean, and fail the resident build with a typed verdict.

// append_framed frames a crafted body onto a fake file, the way a
// hostile or buggy writer would.
@(private = "file")
append_framed :: proc(f: ^OFile, body: []byte) {
	buf: [dynamic]u8
	defer delete(buf)
	frame_append(&buf, body)
	append(&f.data, ..buf[:])
}

@(test)
test_load_canonical :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	_ = obuild(t, &fs)

	s: Store
	store_init(&s)
	defer store_destroy(&s)
	ld: Loader
	loader_init(&ld, &s)
	defer loader_destroy(&ld)
	r, tear, err := replay("store", ofs_ops(&fs), loader_consumer(&ld))
	testing.expect_value(t, err, Open_Error.None)
	testing.expect_value(t, tear.kind, Tear_Kind.None)
	testing.expect_value(t, ld.err, Load_Error.None)

	// Counts agree with the verified walk — the same counters the
	// writer's own state was checked against in T-0004.
	testing.expect_value(t, s.n_facts, r.fact_count)
	testing.expect_value(t, s.n_facts, u32(4))
	testing.expect_value(t, u64(s.n_epochs), r.last_epoch)
	testing.expect_value(t, u64(len(s.dict.off)), r.next_term_id-1)

	// Every fact, exact: components re-tagged, intervals resolved.
	// Epoch 2's retract closed fact 0; epoch 4's closed fact 3; facts
	// 1 and 2 are live.
	five, _ := inline_integer(5)
	rfive := resident_id(five)
	want := [4]Fact{
		{s = 1, p = 2, o = rfive, g = 1, assert = 1, retract = 2},
		{s = 2, p = 2, o = 1, g = 1, assert = 1, retract = LIVE_EPOCH},
		{s = 3, p = 2, o = 1, g = 1, assert = 2, retract = LIVE_EPOCH},
		{s = 2, p = 2, o = 3, g = 1, assert = 3, retract = 4},
	}
	for f, i in want {
		testing.expect_value(t, store_fact(&s, u32(i))^, f)
		testing.expect_value(t, store_derived(&s, u32(i)), false)
	}
	testing.expect_value(t, len(ld.live), 2)

	// The arena holds every term definition byte-for-byte, and resolves
	// both ways.
	enc := [3]string{"\x01http://example.org/a", "\x01http://example.org/b", "\x01http://example.org/c"}
	for e, i in enc {
		testing.expect_value(t, string(dict_bytes(&s.dict, u32(i+1))), e)
		id, ok := dict_find(&s.dict, transmute([]byte)e)
		testing.expect(t, ok, "an interned term resolves")
		testing.expect_value(t, id, u32(i+1))
	}

	// The epoch table: wall, actor, reason per epoch — "who" is total,
	// and obuild named nobody.
	for e in u32(1) ..= u32(4) {
		m := store_epoch_meta(&s, e)
		testing.expect_value(t, m.wall, OWALL+u64(e-1))
		testing.expect_value(t, m.actor, u32(0))
		testing.expect_value(t, m.reason, u32(0))
	}

	// The note sits after epoch 1 and stays in effect to the head.
	_, none := store_note_at(&s, 0)
	testing.expect(t, !none, "no note is in effect before the first")
	p, ok := store_note_at(&s, 1)
	testing.expect(t, ok, "the note is in effect at its boundary")
	testing.expect_value(t, string(p), `{"format":1}`)
	p4, ok4 := store_note_at(&s, 4)
	testing.expect(t, ok4, "and at the head")
	testing.expect_value(t, string(p4), `{"format":1}`)
}

@(test)
test_load_history_shapes :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	st := obuild(t, &fs)
	f3 := ofs_find(&fs, "store/000003.rlog")

	// Epoch 5, crafted (our writer never emits derived ops,
	// RECORD-A-0002, but the format defines them and the build must
	// take them): a derived assert and retract of one quad in a single
	// epoch — an empty [5,5) interval — then a plain re-assert of the
	// same quad. Two generations, disjoint intervals, distinct origins.
	ops5 := [3]Fact_Op{
		{op = .Assert_Derived, s = 1, p = 2, o = 3, g = 1},
		{op = .Retract_Derived, s = 1, p = 2, o = 3, g = 1},
		{op = .Assert, s = 1, p = 2, o = 3, g = 1},
	}
	body, e := commit_encode({epoch = 5, wall = OWALL + 4, ops = ops5[:]}, st.head, 4, st.next_term_id)
	testing.expect_value(t, e, Encode_Error.None)
	head5: [HASH_SIZE]u8
	copy(head5[:], body[len(body)-HASH_SIZE:])
	append_framed(f3, body)
	delete(body)

	// A second note after epoch 5, so "in effect at" has a boundary to
	// cross.
	nbody, ne := note_encode({last_epoch = 5, payload = transmute([]byte)string(`{"format":1,"note":2}`)}, head5)
	testing.expect_value(t, ne, Encode_Error.None)
	append_framed(f3, nbody)
	delete(nbody)

	s: Store
	store_init(&s)
	defer store_destroy(&s)
	ld: Loader
	loader_init(&ld, &s)
	defer loader_destroy(&ld)
	r, _, err := replay("store", ofs_ops(&fs), loader_consumer(&ld))
	testing.expect_value(t, err, Open_Error.None)
	testing.expect_value(t, ld.err, Load_Error.None)
	testing.expect_value(t, s.n_facts, r.fact_count)
	testing.expect_value(t, s.n_facts, u32(6))

	testing.expect_value(t, store_fact(&s, 4)^, Fact{s = 1, p = 2, o = 3, g = 1, assert = 5, retract = 5})
	testing.expect_value(t, store_derived(&s, 4), true)
	testing.expect_value(t, store_fact(&s, 5)^, Fact{s = 1, p = 2, o = 3, g = 1, assert = 5, retract = LIVE_EPOCH})
	testing.expect_value(t, store_derived(&s, 5), false)
	testing.expect_value(t, len(ld.live), 3)

	testing.expect_value(t, len(s.notes), 2)
	p4, _ := store_note_at(&s, 4)
	testing.expect_value(t, string(p4), `{"format":1}`)
	p5, _ := store_note_at(&s, 5)
	testing.expect_value(t, string(p5), `{"format":1,"note":2}`)
}

@(test)
test_load_refusals :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	st := obuild(t, &fs)
	f3 := ofs_find(&fs, "store/000003.rlog")
	original := clone_bytes(f3.data[:])
	defer delete(original)

	// Each craft is a chain-perfect epoch 5 the writer would never
	// produce. All three must verify clean AND replay clean — the seam
	// judges the format, not this store's live-quad discipline — and
	// fail the build with the typed verdict and its diagnosis.
	Craft :: struct {
		verdict: Load_Error,
		terms:   []Term_Def,
		ops:     []Fact_Op,
	}

	// (2,2,3,1) was asserted at epoch 3 and retracted at epoch 4:
	// retracting it again names a quad with no live generation.
	dead := [1]Fact_Op{{op = .Retract, s = 2, p = 2, o = 3, g = 1}}
	// (2,2,1,1) has been live since epoch 1: asserting it again would
	// create a second live generation of one quad.
	dup := [1]Fact_Op{{op = .Assert, s = 2, p = 2, o = 1, g = 1}}
	// Term 4's encoding is term 1's: two ids, one meaning.
	twice := [1]Term_Def{{id = 4, enc = transmute([]byte)string("\x01http://example.org/a")}}

	crafts := [3]Craft{
		{.Retract_Not_Live, nil, dead[:]},
		{.Duplicate_Assert, nil, dup[:]},
		{.Duplicate_Term, twice[:], nil},
	}
	for craft in crafts {
		ofs_set(f3, original)
		body, e := commit_encode(
			{epoch = 5, wall = OWALL, terms = craft.terms, ops = craft.ops},
			st.head,
			4,
			st.next_term_id,
		)
		testing.expect_value(t, e, Encode_Error.None)
		append_framed(f3, body)
		delete(body)

		_, _, verr := verify("store", ofs_ops(&fs))
		testing.expect_value(t, verr, Open_Error.None)
		_, _, rerr := replay("store", ofs_ops(&fs), Consumer{})
		testing.expect_value(t, rerr, Open_Error.None)

		s: Store
		store_init(&s)
		ld: Loader
		loader_init(&ld, &s)
		_, _, berr := replay("store", ofs_ops(&fs), loader_consumer(&ld))
		testing.expect_value(t, berr, Open_Error.Consumer_Abort)
		testing.expect_value(t, ld.err, craft.verdict)
		testing.expect_value(t, ld.epoch, u64(5))
		if len(craft.ops) > 0 {
			testing.expect_value(t, ld.op, craft.ops[0])
		}
		if len(craft.terms) > 0 {
			testing.expect_value(t, ld.term, craft.terms[0].id)
		}
		// The store holds everything before the refusal: the four
		// canonical facts, untouched.
		testing.expect_value(t, s.n_facts, u32(4))
		loader_destroy(&ld)
		store_destroy(&s)
	}
	ofs_set(f3, original)

	// The epoch ceiling (api.md par. 2.1): a commit at LIVE_EPOCH
	// cannot be represented residently. Four billion commits from the
	// design scale, so it is exercised at the procedure, not with a
	// log.
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	ld: Loader
	loader_init(&ld, &s)
	defer loader_destroy(&ld)
	testing.expect(t, !load_commit(&ld, u64(LIVE_EPOCH), 0, 0, 0), "the ceiling refuses")
	testing.expect_value(t, ld.err, Load_Error.Epoch_Overflow)
	testing.expect_value(t, s.n_epochs, u32(0))
}
