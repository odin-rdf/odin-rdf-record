package record

import "core:testing"

// The open path's fault-injection suite (RECORD-T-0003): injure logs
// the writer produced and check the verdict. The byte-level fake
// filesystem and the canonical log live in fakefs_test.odin, shared
// with the replay tests. The writer's own crash model (the operation
// budget in writer_test.odin) already proves what reaches the disk;
// these tests prove what the open path makes of it.

@(test)
test_open_verify_clean :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	st := obuild(t, &fs)

	r, tear, err := verify("store", ofs_ops(&fs))
	testing.expect_value(t, err, Open_Error.None)
	testing.expect_value(t, tear.kind, Tear_Kind.None)

	// The result is the writer's state, recomputed from bytes alone.
	testing.expect(t, r.head == st.head, "verify returns the writer's head hash")
	testing.expect_value(t, r.last_epoch, st.last_epoch)
	testing.expect_value(t, r.segments, st.seg_no)
	testing.expect_value(t, r.next_term_id, st.next_term_id)
	testing.expect_value(t, r.fact_count, st.fact_count)
	testing.expect_value(t, r.tail_size, st.seg_size)
	testing.expect_value(t, r.tail_records, st.epoch_records)
	testing.expect_value(t, r.tail_sealed, false)

	// verify is read-only, whatever it finds.
	testing.expect_value(t, fs.truncates, 0)
	testing.expect_value(t, fs.removes, 0)
}

@(test)
test_open_tail_sweep :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	_ = obuild(t, &fs)

	f := ofs_find(&fs, "store/000003.rlog")
	original := clone_bytes(f.data[:])
	defer delete(original)
	offs := record_offsets(original)
	defer delete(offs)
	testing.expect_value(t, len(offs), 2) // commits 3 and 4

	// Truncate the open segment at every byte offset of its record
	// region and recover: the file must come back cut to exactly the
	// last durable record, and the recovered log must verify clean.
	for cut in offs[0] ..< len(original) {
		ofs_set(f, original[:cut])

		boundary := offs[0]
		epoch := u64(2)
		if cut >= offs[1] {
			boundary = offs[1]
			epoch = 3
		}

		r, tear, err := recover("store", ofs_ops(&fs))
		testing.expect_value(t, err, Open_Error.None)
		if cut == boundary {
			// The cut landed on a record boundary: a shorter but
			// complete log, nothing to repair.
			testing.expect_value(t, tear.kind, Tear_Kind.None)
		} else {
			testing.expect_value(t, tear.kind, Tear_Kind.Tail)
			testing.expect_value(t, tear.segment, u32(3))
			testing.expect_value(t, tear.offset, boundary)
			testing.expect_value(t, tear.lost, cut-boundary)
		}
		testing.expect_value(t, len(f.data), boundary)
		testing.expect_value(t, r.last_epoch, epoch)
		testing.expect_value(t, r.tail_size, boundary)

		r2, tear2, err2 := verify("store", ofs_ops(&fs))
		testing.expect_value(t, err2, Open_Error.None)
		testing.expect_value(t, tear2.kind, Tear_Kind.None)
		testing.expect_value(t, r2.last_epoch, epoch)
	}

	ofs_set(f, original)
	r, _, err := verify("store", ofs_ops(&fs))
	testing.expect_value(t, err, Open_Error.None)
	testing.expect_value(t, r.last_epoch, u64(4))
}

@(test)
test_open_sealed_bitflip :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	_ = obuild(t, &fs)

	// One flipped bit anywhere in a sealed segment halts verification
	// — never clean, never torn. The header's fixed fields fail their
	// CRC or an equality check, the base hash fails the equality that
	// replaces its CRC, and every record body — the seal included — is
	// under its frame CRC.
	f := ofs_find(&fs, "store/000001.rlog")
	for i in 0 ..< len(f.data) {
		for bit in ([2]u8{0x01, 0x80}) {
			f.data[i] ~= bit
			_, tear, err := verify("store", ofs_ops(&fs))
			testing.expect(t, err != .None && err != .Torn, "a flipped bit in a sealed segment halts")
			testing.expect_value(t, tear.kind, Tear_Kind.None)
			f.data[i] ~= bit
		}
	}

	_, _, err := verify("store", ofs_ops(&fs))
	testing.expect_value(t, err, Open_Error.None)
	testing.expect_value(t, fs.truncates, 0)
	testing.expect_value(t, fs.removes, 0)
}

@(test)
test_open_position_rule :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	_ = obuild(t, &fs)

	f := ofs_find(&fs, "store/000003.rlog")
	original := clone_bytes(f.data[:])
	defer delete(original)
	offs := record_offsets(original)
	defer delete(offs)

	// A CRC failure before the tail of the open segment is corruption,
	// not a tear: a valid record follows the damaged one, and a
	// fail-stop writer cannot have produced that. recover must halt
	// and touch nothing — truncating here would destroy evidence.
	f.data[offs[0]+FRAME_OVERHEAD+5] ~= 0x01
	_, tear, err := recover("store", ofs_ops(&fs))
	testing.expect_value(t, err, Open_Error.Corrupt)
	testing.expect_value(t, tear.kind, Tear_Kind.None)
	testing.expect_value(t, fs.truncates, 0)
	ofs_set(f, original)

	// The same damage in the final record is the torn tail: the one
	// position where truncation is recovery rather than destruction.
	f.data[offs[1]+FRAME_OVERHEAD+5] ~= 0x01
	r, tear2, err2 := recover("store", ofs_ops(&fs))
	testing.expect_value(t, err2, Open_Error.None)
	testing.expect_value(t, tear2.kind, Tear_Kind.Tail)
	testing.expect_value(t, tear2.offset, offs[1])
	testing.expect_value(t, fs.truncates, 1)
	testing.expect_value(t, len(f.data), offs[1])
	testing.expect_value(t, r.last_epoch, u64(3))
	ofs_set(f, original)

	// And in a sealed segment, the same damage to the final record is
	// still corruption: position means position in the open segment,
	// not position in a file.
	f1 := ofs_find(&fs, "store/000001.rlog")
	saved := clone_bytes(f1.data[:])
	defer delete(saved)
	offs1 := record_offsets(saved)
	defer delete(offs1)
	f1.data[offs1[len(offs1)-1]+FRAME_OVERHEAD+5] ~= 0x01
	_, _, err3 := recover("store", ofs_ops(&fs))
	testing.expect_value(t, err3, Open_Error.Corrupt)
	testing.expect_value(t, fs.truncates, 1) // unchanged
	ofs_set(f1, saved)
}

@(test)
test_open_torn_shapes :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	_ = obuild(t, &fs)

	f := ofs_find(&fs, "store/000003.rlog")
	original := clone_bytes(f.data[:])
	defer delete(original)
	end := len(original)

	// Each shape of log.md par. 7.2's taxonomy, appended to the open
	// segment: a zero length (a zero-filled block is not an empty
	// record), an oversized length, a body the file cannot hold, and a
	// partial frame header. All torn; all recover by truncation to the
	// last durable record.
	zero_len := [8]u8{0, 0, 0, 0, 0xAA, 0xBB, 0xCC, 0xDD}
	oversized := [8]u8{0x04, 0x00, 0x00, 0x01, 0xAA, 0xBB, 0xCC, 0xDD} // MAX_RECORD_SIZE + 1
	short_body := [14]u8{0, 0, 0, 100, 0xAA, 0xBB, 0xCC, 0xDD, 1, 2, 3, 4, 5, 6}
	stray := [3]u8{0x01, 0x02, 0x03}
	shapes := [4][]u8{zero_len[:], oversized[:], short_body[:], stray[:]}

	for shape in shapes {
		ofs_set(f, original)
		append(&f.data, ..shape)

		_, tear, err := verify("store", ofs_ops(&fs))
		testing.expect_value(t, err, Open_Error.Torn)
		testing.expect_value(t, tear.kind, Tear_Kind.Tail)
		testing.expect_value(t, tear.offset, end)
		testing.expect_value(t, tear.lost, len(shape))

		r, _, rerr := recover("store", ofs_ops(&fs))
		testing.expect_value(t, rerr, Open_Error.None)
		testing.expect_value(t, len(f.data), end)
		testing.expect_value(t, r.last_epoch, u64(4))
	}

	// An unknown record kind under a valid CRC is never torn: the
	// bytes were fully written, just not by our writer. It halts in
	// the open segment's final position and in a sealed segment alike.
	unknown: [dynamic]u8
	defer delete(unknown)
	frame_append(&unknown, []byte{0x7F, 0xAA, 0xBB})

	ofs_set(f, original)
	append(&f.data, ..unknown[:])
	truncates_before := fs.truncates
	_, _, err := recover("store", ofs_ops(&fs))
	testing.expect_value(t, err, Open_Error.Corrupt)
	testing.expect_value(t, fs.truncates, truncates_before)
	ofs_set(f, original)

	f1 := ofs_find(&fs, "store/000001.rlog")
	saved := clone_bytes(f1.data[:])
	defer delete(saved)
	append(&f1.data, ..unknown[:])
	_, _, err2 := verify("store", ofs_ops(&fs))
	testing.expect_value(t, err2, Open_Error.Corrupt)
	ofs_set(f1, saved)
}

@(test)
test_open_husk :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)

	head: [HASH_SIZE]u8
	{
		w, err := writer_create("store", ofs_ops(&fs), SEGMENT_TARGET_SIZE)
		defer writer_destroy(&w)
		testing.expect_value(t, err, Writer_Error.None)
		terms := [1]Term_Def{{id = 1, enc = transmute([]u8)string("\x01http://example.org/a")}}
		ops := [1]Fact_Op{{op = .Assert, s = 1, p = 1, o = 1, g = 1}}
		testing.expect_value(t, writer_commit(&w, {epoch = 1, wall = OWALL, terms = terms[:], ops = ops[:]}), Writer_Error.None)
		testing.expect_value(t, writer_seal(&w), Writer_Error.None)
		head = w.head
	}

	// Baseline: an empty open segment after a seal is a clean store.
	r0, tear0, err0 := verify("store", ofs_ops(&fs))
	testing.expect_value(t, err0, Open_Error.None)
	testing.expect_value(t, tear0.kind, Tear_Kind.None)
	testing.expect_value(t, r0.segments, u32(2))
	testing.expect_value(t, r0.tail_size, HEADER_SIZE)
	testing.expect_value(t, r0.tail_records, u64(0))
	testing.expect_value(t, r0.tail_sealed, false)
	testing.expect(t, r0.head == head, "the head crosses the rotation unchanged")

	f2 := ofs_find(&fs, "store/000002.rlog")
	original := clone_bytes(f2.data[:])
	defer delete(original)

	// The rotation-crash husk: the final segment's header never became
	// durable. A truncated prefix of the real header, or a full 64
	// bytes of garbage — recovery removes the file, and the log ends
	// at the sealed segment before it.
	garbage: [HEADER_SIZE]u8
	for &b in garbage {
		b = 0xAA
	}
	husks := [4][]u8{original[:0], original[:1], original[:63], garbage[:]}
	for husk in husks {
		ofs_set(f2, husk)

		r, tear, err := verify("store", ofs_ops(&fs))
		testing.expect_value(t, err, Open_Error.Torn)
		testing.expect_value(t, tear.kind, Tear_Kind.Header)
		testing.expect_value(t, tear.segment, u32(2))
		testing.expect_value(t, tear.lost, len(husk))
		testing.expect_value(t, r.segments, u32(1))
		testing.expect_value(t, r.tail_sealed, true)
		testing.expect_value(t, r.last_epoch, u64(1))

		removes_before := fs.removes
		r2, tear2, err2 := recover("store", ofs_ops(&fs))
		testing.expect_value(t, err2, Open_Error.None)
		testing.expect_value(t, tear2.kind, Tear_Kind.Header)
		testing.expect_value(t, fs.removes, removes_before+1)
		testing.expect_value(t, r2.segments, u32(1))

		r3, _, err3 := verify("store", ofs_ops(&fs))
		testing.expect_value(t, err3, Open_Error.None)
		testing.expect_value(t, r3.segments, u32(1))
		testing.expect_value(t, r3.tail_sealed, true)
		testing.expect_value(t, r3.last_epoch, u64(1))
	}
	ofs_set(f2, original)

	// A valid header carrying an unknown version is a future format,
	// never a husk: it halts, and recovery removes nothing.
	future: [HEADER_SIZE]u8
	header_encode(Segment_Header{version = 2, segment = 2, first_epoch = 2, first_fact_id = 1, base_hash = head}, &future)
	ofs_set(f2, future[:])
	removes_before := fs.removes
	_, tearv, errv := recover("store", ofs_ops(&fs))
	testing.expect_value(t, errv, Open_Error.Bad_Header)
	testing.expect_value(t, tearv.kind, Tear_Kind.None)
	testing.expect_value(t, fs.removes, removes_before)
	ofs_set(f2, original)

	// A husk at segment 1 is a store whose creation crashed: recovery
	// removes it and reports that no store exists.
	fs2: OFS
	defer ofs_destroy(&fs2)
	ofs_seed(&fs2, "store/000001.rlog", transmute([]u8)string("RDF"))
	_, tear1, err1 := verify("store", ofs_ops(&fs2))
	testing.expect_value(t, err1, Open_Error.Torn)
	testing.expect_value(t, tear1.kind, Tear_Kind.Header)
	testing.expect_value(t, tear1.segment, u32(1))
	_, _, err2 := recover("store", ofs_ops(&fs2))
	testing.expect_value(t, err2, Open_Error.No_Store)
	testing.expect_value(t, fs2.removes, 1)

	// And a directory with no segments at all was never a store.
	fs3: OFS
	defer ofs_destroy(&fs3)
	_, _, err3 := verify("store", ofs_ops(&fs3))
	testing.expect_value(t, err3, Open_Error.No_Store)
}

@(test)
test_open_verdicts :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	st := obuild(t, &fs)

	f2 := ofs_find(&fs, "store/000002.rlog")
	f3 := ofs_find(&fs, "store/000003.rlog")
	saved2 := clone_bytes(f2.data[:])
	defer delete(saved2)
	saved3 := clone_bytes(f3.data[:])
	defer delete(saved3)

	// An unreadable segment halts as IO, distinct from an absent one.
	fs.fail_read = "store/000002.rlog"
	_, _, err := verify("store", ofs_ops(&fs))
	testing.expect_value(t, err, Open_Error.IO_Read)
	fs.fail_read = ""

	// The base hash is checked by equality, not by CRC — flipping it
	// leaves the header CRC valid and still fails the open.
	f2.data[40] ~= 0x01
	_, _, err = verify("store", ofs_ops(&fs))
	testing.expect_value(t, err, Open_Error.Base_Hash_Mismatch)
	ofs_set(f2, saved2)

	// The header's positional fields are equality-checked against the
	// walk: a re-encoded header with a valid CRC and a wrong segment
	// number, first epoch, or first fact ID fails.
	hdr, herr := header_decode(saved2)
	testing.expect_value(t, herr, Decode_Error.None)
	tampered := [3]Segment_Header{hdr, hdr, hdr}
	tampered[0].segment = 9
	tampered[1].first_epoch = 7
	tampered[2].first_fact_id = 9
	for tam in tampered {
		enc: [HEADER_SIZE]u8
		header_encode(tam, &enc)
		copy(f2.data[:HEADER_SIZE], enc[:])
		_, _, herr2 := verify("store", ofs_ops(&fs))
		testing.expect_value(t, herr2, Open_Error.Bad_Header)
		ofs_set(f2, saved2)
	}

	// An epoch gap: a structurally valid, correctly chained commit
	// whose epoch skips one. Encoded against a lied-about prev_epoch,
	// because commit_encode itself refuses gaps.
	gap_ops := [1]Fact_Op{{op = .Assert, s = 1, p = 2, o = 3, g = 1}}
	body, eerr := commit_encode({epoch = 6, wall = OWALL, ops = gap_ops[:]}, st.head, 5, st.next_term_id)
	testing.expect_value(t, eerr, Encode_Error.None)
	framed: [dynamic]u8
	frame_append(&framed, body)
	append(&f3.data, ..framed[:])
	delete(framed)
	delete(body)
	_, _, err = verify("store", ofs_ops(&fs))
	testing.expect_value(t, err, Open_Error.Epoch_Gap)
	ofs_set(f3, saved3)

	// A chain break via prev_hash: right epoch, wrong link.
	bad_prev := st.head
	bad_prev[0] ~= 0x01
	body2, eerr2 := commit_encode({epoch = 5, wall = OWALL, ops = gap_ops[:]}, bad_prev, 4, st.next_term_id)
	testing.expect_value(t, eerr2, Encode_Error.None)
	framed2: [dynamic]u8
	frame_append(&framed2, body2)
	append(&f3.data, ..framed2[:])
	delete(framed2)
	delete(body2)
	_, _, err = verify("store", ofs_ops(&fs))
	testing.expect_value(t, err, Open_Error.Chain_Broken)
	ofs_set(f3, saved3)

	// A chain break via the hash field: prev_hash matches, but the
	// recomputed hash does not agree with the embedded one. The frame
	// is rebuilt around the tampered body so its CRC holds.
	body3, eerr3 := commit_encode({epoch = 5, wall = OWALL, ops = gap_ops[:]}, st.head, 4, st.next_term_id)
	testing.expect_value(t, eerr3, Encode_Error.None)
	body3[len(body3)-1] ~= 0x01
	framed3: [dynamic]u8
	frame_append(&framed3, body3)
	append(&f3.data, ..framed3[:])
	delete(framed3)
	delete(body3)
	_, _, err = verify("store", ofs_ops(&fs))
	testing.expect_value(t, err, Open_Error.Chain_Broken)
	ofs_set(f3, saved3)

	// Halting verdicts never mutate, through recover included.
	testing.expect_value(t, fs.truncates, 0)
	testing.expect_value(t, fs.removes, 0)

	r, _, errc := verify("store", ofs_ops(&fs))
	testing.expect_value(t, errc, Open_Error.None)
	testing.expect_value(t, r.last_epoch, u64(4))
}
