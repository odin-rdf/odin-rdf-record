package record

import "core:testing"

// Replay's tests (RECORD-T-0004): a collecting consumer proves that
// what the writer wrote is exactly what replay delivers — order,
// counts, and payloads, across segment boundaries — and crafted
// records prove the replay-only judgements: the par. 5.2 dictionary
// self-check, the resident-boundary assertions of api.md par. 3.4, and
// the note's lastEpoch. Chain-valid nonsense must verify and refuse to
// replay; the split is asserted explicitly.

@(private = "file")
C_Commit :: struct {
	epoch, wall, actor, reason: u64,
}

@(private = "file")
C_Term :: struct {
	id:  u64,
	enc: [dynamic]u8, // cloned: the delivery borrows only for the call
}

@(private = "file")
C_Op :: struct {
	epoch: u64,
	op:    Fact_Op,
}

@(private = "file")
C_Note :: struct {
	last_epoch: u64,
	payload:    [dynamic]u8,
}

@(private = "file")
Collector :: struct {
	commits: [dynamic]C_Commit,
	terms:   [dynamic]C_Term,
	ops:     [dynamic]C_Op,
	notes:   [dynamic]C_Note,
	order:   [dynamic]u8, // 'c', 't', 'o', 'n' in delivery order
	limit:   int,         // deliveries accepted before refusing; 0 is unlimited
	count:   int,
}

@(private = "file")
col_consumer :: proc(col: ^Collector) -> Consumer {
	return {data = col, commit = col_commit, term = col_term, op = col_op, note = col_note}
}

@(private = "file")
col_destroy :: proc(col: ^Collector) {
	delete(col.commits)
	for &t in col.terms {
		delete(t.enc)
	}
	delete(col.terms)
	delete(col.ops)
	for &n in col.notes {
		delete(n.payload)
	}
	delete(col.notes)
	delete(col.order)
	col^ = {}
}

@(private = "file")
col_take :: proc(col: ^Collector) -> bool {
	col.count += 1
	return col.limit == 0 || col.count <= col.limit
}

@(private = "file")
col_commit :: proc(data: rawptr, epoch, wall, actor, reason: u64) -> bool {
	col := (^Collector)(data)
	if !col_take(col) {
		return false
	}
	append(&col.commits, C_Commit{epoch, wall, actor, reason})
	append(&col.order, 'c')
	return true
}

@(private = "file")
col_term :: proc(data: rawptr, id: u64, enc: []byte) -> bool {
	col := (^Collector)(data)
	if !col_take(col) {
		return false
	}
	t := C_Term {
		id = id,
	}
	append(&t.enc, ..enc)
	append(&col.terms, t)
	append(&col.order, 't')
	return true
}

@(private = "file")
col_op :: proc(data: rawptr, epoch: u64, op: Fact_Op) -> bool {
	col := (^Collector)(data)
	if !col_take(col) {
		return false
	}
	append(&col.ops, C_Op{epoch, op})
	append(&col.order, 'o')
	return true
}

@(private = "file")
col_note :: proc(data: rawptr, last_epoch: u64, payload: []byte) -> bool {
	col := (^Collector)(data)
	if !col_take(col) {
		return false
	}
	n := C_Note {
		last_epoch = last_epoch,
	}
	append(&n.payload, ..payload)
	append(&col.notes, n)
	append(&col.order, 'n')
	return true
}

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
test_replay_completeness :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	st := obuild(t, &fs)

	col: Collector
	defer col_destroy(&col)
	r, tear, err := replay("store", ofs_ops(&fs), col_consumer(&col))
	testing.expect_value(t, err, Open_Error.None)
	testing.expect_value(t, tear.kind, Tear_Kind.None)

	// The result carries the same resume state verify computes.
	testing.expect(t, r.head == st.head, "replay ends at the writer's head")
	testing.expect_value(t, r.last_epoch, st.last_epoch)
	testing.expect_value(t, r.segments, st.seg_no)
	testing.expect_value(t, r.next_term_id, st.next_term_id)
	testing.expect_value(t, r.fact_count, st.fact_count)

	// Delivery order is log order: commit boundary, then terms, then
	// ops; the note sits between epochs 1 and 2 where the chain holds
	// it; seals are never delivered.
	testing.expect_value(t, string(col.order[:]), "cttoonctoococo")

	// Every commit boundary, exactly as written.
	testing.expect_value(t, len(col.commits), 4)
	for c, i in col.commits {
		testing.expect_value(t, c.epoch, u64(i+1))
		testing.expect_value(t, c.wall, OWALL + u64(i))
		testing.expect_value(t, c.actor, u64(0))
		testing.expect_value(t, c.reason, u64(0))
	}

	// Every term definition, ids in first-appearance order, encodings
	// byte-for-byte.
	testing.expect_value(t, len(col.terms), 3)
	enc := [3]string{"\x01http://example.org/a", "\x01http://example.org/b", "\x01http://example.org/c"}
	for term, i in col.terms {
		testing.expect_value(t, term.id, u64(i+1))
		testing.expect_value(t, string(term.enc[:]), enc[i])
	}

	// Every fact op with its owning epoch, across all three segments.
	five, _ := inline_integer(5)
	want := [6]C_Op{
		{1, {op = .Assert, s = 1, p = 2, o = five, g = 1}},
		{1, {op = .Assert, s = 2, p = 2, o = 1, g = 1}},
		{2, {op = .Assert, s = 3, p = 2, o = 1, g = 1}},
		{2, {op = .Retract, s = 1, p = 2, o = five, g = 1}},
		{3, {op = .Assert, s = 2, p = 2, o = 3, g = 1}},
		{4, {op = .Retract, s = 2, p = 2, o = 3, g = 1}},
	}
	testing.expect_value(t, len(col.ops), len(want))
	for op, i in col.ops {
		testing.expect_value(t, op, want[i])
	}

	// The environment note, keyed by the epoch it follows.
	testing.expect_value(t, len(col.notes), 1)
	testing.expect_value(t, col.notes[0].last_epoch, u64(1))
	testing.expect_value(t, string(col.notes[0].payload[:]), `{"format":1}`)

	// A consumer of nil procedures is legal: the judgements run, the
	// deliveries are skipped.
	_, _, nerr := replay("store", ofs_ops(&fs), Consumer{})
	testing.expect_value(t, nerr, Open_Error.None)
}

@(test)
test_replay_is_verifying :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	_ = obuild(t, &fs)

	// A flipped bit in the first sealed record: replay halts with the
	// open path's verdict and has delivered nothing at or after the
	// damage.
	f1 := ofs_find(&fs, "store/000001.rlog")
	saved := clone_bytes(f1.data[:])
	defer delete(saved)
	offs1 := record_offsets(saved)
	defer delete(offs1)
	f1.data[offs1[0]+FRAME_OVERHEAD+5] ~= 0x01
	col: Collector
	defer col_destroy(&col)
	_, _, err := replay("store", ofs_ops(&fs), col_consumer(&col))
	testing.expect_value(t, err, Open_Error.Corrupt)
	testing.expect_value(t, len(col.commits), 0)
	testing.expect_value(t, len(col.ops), 0)
	ofs_set(f1, saved)

	// A torn tail: replay reports it read-only, and the stream already
	// holds exactly the durable prefix — what recovery would leave.
	f3 := ofs_find(&fs, "store/000003.rlog")
	original := clone_bytes(f3.data[:])
	defer delete(original)
	offs := record_offsets(original)
	defer delete(offs)
	cut := offs[1] + 5
	ofs_set(f3, original[:cut])

	col2: Collector
	defer col_destroy(&col2)
	r, tear, terr := replay("store", ofs_ops(&fs), col_consumer(&col2))
	testing.expect_value(t, terr, Open_Error.Torn)
	testing.expect_value(t, tear.kind, Tear_Kind.Tail)
	testing.expect_value(t, tear.segment, u32(3))
	testing.expect_value(t, tear.offset, offs[1])
	testing.expect_value(t, r.last_epoch, u64(3))
	testing.expect_value(t, len(col2.commits), 3)
	testing.expect_value(t, len(col2.ops), 5)
	testing.expect_value(t, len(f3.data), cut) // replay repaired nothing
	testing.expect_value(t, fs.truncates, 0)
	ofs_set(f3, original)
}

@(test)
test_replay_self_checks :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	st := obuild(t, &fs)

	f3 := ofs_find(&fs, "store/000003.rlog")
	original := clone_bytes(f3.data[:])
	defer delete(original)

	// Every craft below carries a perfect chain — commit_encode is fed
	// a lie about the writer's state, or the body is patched and its
	// hash recomputed — so verify must accept what replay refuses.
	// That split is this test's subject.
	Craft :: struct {
		verdict: Open_Error,
		body:    []byte,
	}
	crafts: [dynamic]Craft
	defer delete(crafts)

	// A term definition out of first-appearance order: the writer
	// claims the next id is 5 when the log has defined 3.
	oo_terms := [1]Term_Def{{id = 5, enc = transmute([]u8)string("\x01http://example.org/x")}}
	body1, e1 := commit_encode({epoch = 5, wall = OWALL, terms = oo_terms[:]}, st.head, 4, 5)
	testing.expect_value(t, e1, Encode_Error.None)
	append(&crafts, Craft{.Term_Order, body1})

	// An op naming a dictionary id nothing defined.
	bad_ops := [1]Fact_Op{{op = .Assert, s = 9, p = 1, o = 1, g = 1}}
	body2, e2 := commit_encode({epoch = 5, wall = OWALL, ops = bad_ops[:]}, st.head, 4, 10)
	testing.expect_value(t, e2, Encode_Error.None)
	append(&crafts, Craft{.Bad_Term_Id, body2})

	// An actor nothing defined.
	ok_ops := [1]Fact_Op{{op = .Assert, s = 1, p = 2, o = 3, g = 1}}
	body3, e3 := commit_encode({epoch = 5, wall = OWALL, actor = 9, ops = ok_ops[:]}, st.head, 4, 10)
	testing.expect_value(t, e3, Encode_Error.None)
	append(&crafts, Craft{.Bad_Term_Id, body3})

	// An inlined object outside the frozen range: a valid commit,
	// its object patched to inline tag 5 (unassigned) and the chain
	// hash recomputed — tamper-shaped, but chain-perfect.
	body4, e4 := commit_encode({epoch = 5, wall = OWALL, ops = ok_ops[:]}, st.head, 4, st.next_term_id)
	testing.expect_value(t, e4, Encode_Error.None)
	bad_inline := [8]u8{0x85, 0, 0, 0, 0, 0, 0, 1} // INLINE_FLAG | tag 5, payload 1
	copy(body4[58:66], bad_inline[:])
	h4 := chain_hash(body4)
	copy(body4[len(body4)-HASH_SIZE:], h4[:])
	append(&crafts, Craft{.Inline_Range, body4})

	// A zero op component, patched the same way.
	body5, e5 := commit_encode({epoch = 5, wall = OWALL, ops = ok_ops[:]}, st.head, 4, st.next_term_id)
	testing.expect_value(t, e5, Encode_Error.None)
	zero := [8]u8{}
	copy(body5[42:50], zero[:]) // the subject field
	h5 := chain_hash(body5)
	copy(body5[len(body5)-HASH_SIZE:], h5[:])
	append(&crafts, Craft{.Bad_Term_Id, body5})

	// A note whose lastEpoch is not the epoch it follows.
	body6, e6 := note_encode({last_epoch = 9, payload = transmute([]u8)string("{}")}, st.head)
	testing.expect_value(t, e6, Encode_Error.None)
	append(&crafts, Craft{.Note_Epoch, body6})

	for craft in crafts {
		ofs_set(f3, original)
		append_framed(f3, craft.body)
		delete(craft.body)

		_, _, verr := verify("store", ofs_ops(&fs))
		testing.expect_value(t, verr, Open_Error.None)

		_, _, rerr := replay("store", ofs_ops(&fs), Consumer{})
		testing.expect_value(t, rerr, craft.verdict)
	}
	ofs_set(f3, original)

	// A consumer that refuses stops replay with its own verdict.
	col: Collector
	defer col_destroy(&col)
	col.limit = 3
	_, _, aerr := replay("store", ofs_ops(&fs), col_consumer(&col))
	testing.expect_value(t, aerr, Open_Error.Consumer_Abort)
	testing.expect_value(t, col.count, 4) // the refused fourth delivery
}
