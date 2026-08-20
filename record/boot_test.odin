package record

import "core:fmt"
import "core:slice"
import "core:testing"

// Boot's tests (RECORD-T-0011). The resume path's dangerous bug is a
// chain-valid record written from slightly wrong state — a fact id off
// by one survives verification, because fact ids are not chained — so
// the defense is exact: a resumed writer's counters against the
// original writer's own state, and byte-identical files against a
// writer that never stopped. The centerpiece is the cross-restart
// sweep: the writer sweep (RECORD-T-0002) proved no acknowledged epoch
// is lost at any operation cut point; this proves the store *continues*
// from every one of those states — the composition RECORD-T-0003
// deferred until resume existed to compose with.

@(test)
test_writer_open_counters :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	st := obuild(t, &fs)

	// Resume from the verified walk: every counter equals the original
	// writer's own state at destruction — the exact-value criterion.
	r, _, verr := verify("store", ofs_ops(&fs))
	testing.expect_value(t, verr, Open_Error.None)
	w, werr := writer_open("store", ofs_ops(&fs), r)
	testing.expect_value(t, werr, Writer_Error.None)
	testing.expect(t, w.head == st.head, "the next commit chains from the pre-restart head")
	testing.expect_value(t, w.prev_epoch, st.last_epoch)
	testing.expect_value(t, w.next_term_id, st.next_term_id)
	testing.expect_value(t, w.fact_count, st.fact_count)
	testing.expect_value(t, w.seg_no, st.seg_no)
	testing.expect_value(t, w.seg_size, st.seg_size)
	testing.expect_value(t, w.epoch_records, st.epoch_records)

	// The grown log verifies clean and ends at the new head.
	ops5 := [1]Fact_Op{{op = .Assert, s = 1, p = 2, o = 3, g = 1}}
	testing.expect_value(t, writer_commit(&w, {epoch = 5, wall = OWALL + 4, ops = ops5[:]}), Writer_Error.None)
	r2, _, verr2 := verify("store", ofs_ops(&fs))
	testing.expect_value(t, verr2, Open_Error.None)
	testing.expect_value(t, r2.last_epoch, u64(5))
	testing.expect(t, r2.head == w.head, "verify follows the resumed chain")
	testing.expect_value(t, writer_destroy(&w), Writer_Error.None)

	// A tail the walk named but the filesystem lost is a typed refusal.
	empty: OFS
	defer ofs_destroy(&empty)
	missing := Verify_Result {
		segments  = 1,
		tail_size = HEADER_SIZE,
	}
	wbad, oerr := writer_open("store", ofs_ops(&empty), missing)
	testing.expect_value(t, oerr, Writer_Error.IO_Open)
	writer_destroy(&wbad)
}

@(test)
test_boot_fresh_and_note :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)

	// A fresh directory creates: an empty published store, a usable
	// writer, and the startup note as the first record after the
	// header — the log is self-describing from birth.
	s: Store
	tear, err, lerr, werr := store_open(&s, "store", ofs_ops(&fs))
	testing.expect_value(t, err, Open_Error.None)
	testing.expect_value(t, lerr, Load_Error.None)
	testing.expect_value(t, werr, Writer_Error.None)
	testing.expect_value(t, tear.kind, Tear_Kind.None)
	testing.expect_value(t, s.published, u32(0))
	testing.expect_value(t, len(s.notes), 1)
	p0, ok0 := store_note_at(&s, 0)
	testing.expect(t, ok0, "the note is in effect from epoch 0")
	testing.expect_value(t, string(p0), ENV_NOTE_V1)

	terms1 := [1]Term_Def{{id = 1, enc = transmute([]byte)string("\x01http://ex/a")}}
	ops1 := [1]Fact_Op{{op = .Assert, s = 1, p = 1, o = 1, g = 0}}
	testing.expect_value(t, writer_commit(&s.writer, {epoch = 1, wall = OWALL, terms = terms1[:], ops = ops1[:]}), Writer_Error.None)
	store_close(&s)

	// The second boot resumes: the environment is unchanged, so no
	// second note — "written at startup when any of it differs"
	// (log.md par. 7.1), and byte-equality is the differs test.
	s2: Store
	_, err2, _, werr2 := store_open(&s2, "store", ofs_ops(&fs))
	testing.expect_value(t, err2, Open_Error.None)
	testing.expect_value(t, werr2, Writer_Error.None)
	testing.expect_value(t, s2.published, u32(1))
	testing.expect_value(t, len(s2.notes), 1)
	ops2 := [1]Fact_Op{{op = .Assert, s = 1, p = 1, o = 1, g = 1}}
	testing.expect_value(t, writer_commit(&s2.writer, {epoch = 2, wall = OWALL + 1, ops = ops2[:]}), Writer_Error.None)
	store_close(&s2)

	r, _, verr := verify("store", ofs_ops(&fs))
	testing.expect_value(t, verr, Open_Error.None)
	testing.expect_value(t, r.last_epoch, u64(2))
}

@(test)
test_boot_byte_identical :: proc(t: ^testing.T) {
	// Six epochs, once through a writer that never stops, once split
	// across two boots — the files must be byte-identical, which is
	// what makes "resume writes from slightly wrong state" impossible
	// to miss.
	commit_n :: proc(t: ^testing.T, w: ^Writer, e: u64) {
		ops: [1]Fact_Op
		if e == 1 {
			terms := [2]Term_Def{
				{id = 1, enc = transmute([]byte)string("\x01http://ex/s")},
				{id = 2, enc = transmute([]byte)string("\x01http://ex/p")},
			}
			ops[0] = {op = .Assert, s = 1, p = 2, o = 1, g = 0}
			testing.expect_value(t, writer_commit(w, {epoch = 1, wall = OWALL, terms = terms[:], ops = ops[:]}), Writer_Error.None)
			return
		}
		o, _ := inline_integer(i64(e))
		ops[0] = {op = .Assert, s = 1, p = 2, o = o, g = 0}
		testing.expect_value(t, writer_commit(w, {epoch = e, wall = OWALL + u64(e) - 1, ops = ops[:]}), Writer_Error.None)
	}

	fs_a: OFS
	defer ofs_destroy(&fs_a)
	wa, aerr := writer_create("store", ofs_ops(&fs_a))
	testing.expect_value(t, aerr, Writer_Error.None)
	testing.expect_value(t, writer_note(&wa, transmute([]byte)string(ENV_NOTE_V1)), Writer_Error.None)
	for e in u64(1) ..= 6 {
		commit_n(t, &wa, e)
	}
	writer_destroy(&wa)

	fs_b: OFS
	defer ofs_destroy(&fs_b)
	sb: Store
	_, berr, _, bwerr := store_open(&sb, "store", ofs_ops(&fs_b))
	testing.expect_value(t, berr, Open_Error.None)
	testing.expect_value(t, bwerr, Writer_Error.None)
	for e in u64(1) ..= 4 {
		commit_n(t, &sb.writer, e)
	}
	store_close(&sb)
	sb2: Store
	_, berr2, _, bwerr2 := store_open(&sb2, "store", ofs_ops(&fs_b))
	testing.expect_value(t, berr2, Open_Error.None)
	testing.expect_value(t, bwerr2, Writer_Error.None)
	for e in u64(5) ..= 6 {
		commit_n(t, &sb2.writer, e)
	}
	store_close(&sb2)

	fa := ofs_find(&fs_a, "store/000001.rlog")
	fb := ofs_find(&fs_b, "store/000001.rlog")
	testing.expect(t, fa != nil && fb != nil, "both stores hold segment 1")
	testing.expect(t, slice.equal(fa.data[:], fb.data[:]), "resumed and unbroken writers produce identical bytes")
	testing.expect(t, slice.equal(fs_a.head[:], fs_b.head[:]), "and identical HEADs")
}

@(test)
test_boot_rotation_edges :: proc(t: ^testing.T) {
	// (a) A tail that ends with a seal — rotation crashed after the
	// seal, before the new file — resumes by creating the next segment.
	{
		fs: OFS
		defer ofs_destroy(&fs)
		_ = obuild(t, &fs)
		ofs_find(&fs, "store/000003.rlog").gone = true
		s: Store
		tear, err, _, werr := store_open(&s, "store", ofs_ops(&fs))
		testing.expect_value(t, err, Open_Error.None)
		testing.expect_value(t, werr, Writer_Error.None)
		testing.expect_value(t, tear.kind, Tear_Kind.None)
		testing.expect_value(t, s.published, u32(2))
		testing.expect_value(t, s.writer.seg_no, u32(3))
		ops := [1]Fact_Op{{op = .Assert, s = 1, p = 2, o = 3, g = 1}}
		testing.expect_value(t, writer_commit(&s.writer, {epoch = 3, wall = OWALL + 9, ops = ops[:]}), Writer_Error.None)
		r, _, verr := verify("store", ofs_ops(&fs))
		testing.expect_value(t, verr, Open_Error.None)
		testing.expect_value(t, r.segments, u32(3))
		testing.expect_value(t, r.last_epoch, u64(3))
		store_close(&s)
	}
	// (b) A header-only tail — rotation crashed right after the new
	// segment durably opened — resumes by appending into it.
	{
		fs: OFS
		defer ofs_destroy(&fs)
		_ = obuild(t, &fs)
		f3 := ofs_find(&fs, "store/000003.rlog")
		ofs_set(f3, f3.data[:HEADER_SIZE])
		s: Store
		tear, err, _, werr := store_open(&s, "store", ofs_ops(&fs))
		testing.expect_value(t, err, Open_Error.None)
		testing.expect_value(t, werr, Writer_Error.None)
		testing.expect_value(t, tear.kind, Tear_Kind.None)
		testing.expect_value(t, s.published, u32(2))
		testing.expect_value(t, s.writer.seg_no, u32(3))
		ops := [1]Fact_Op{{op = .Assert, s = 1, p = 2, o = 3, g = 1}}
		testing.expect_value(t, writer_commit(&s.writer, {epoch = 3, wall = OWALL + 9, ops = ops[:]}), Writer_Error.None)
		r, _, verr := verify("store", ofs_ops(&fs))
		testing.expect_value(t, verr, Open_Error.None)
		testing.expect_value(t, r.last_epoch, u64(3))
		store_close(&s)
	}
	// (c) A torn tail recovers — the event surfaced, never swallowed —
	// and resume appends at the truncation point.
	{
		fs: OFS
		defer ofs_destroy(&fs)
		_ = obuild(t, &fs)
		f3 := ofs_find(&fs, "store/000003.rlog")
		offs := record_offsets(f3.data[:])
		defer delete(offs)
		ofs_set(f3, f3.data[:offs[1]+5])
		s: Store
		tear, err, _, werr := store_open(&s, "store", ofs_ops(&fs))
		testing.expect_value(t, err, Open_Error.None)
		testing.expect_value(t, werr, Writer_Error.None)
		testing.expect_value(t, tear.kind, Tear_Kind.Tail)
		testing.expect_value(t, tear.segment, u32(3))
		testing.expect_value(t, fs.truncates, 1)
		testing.expect_value(t, s.published, u32(3)) // epoch 4 was cut
		ops := [1]Fact_Op{{op = .Assert, s = 1, p = 2, o = 3, g = 1}}
		testing.expect_value(t, writer_commit(&s.writer, {epoch = 4, wall = OWALL + 9, ops = ops[:]}), Writer_Error.None)
		r, _, verr := verify("store", ofs_ops(&fs))
		testing.expect_value(t, verr, Open_Error.None)
		testing.expect_value(t, r.last_epoch, u64(4))
		store_close(&s)
	}
	// (d) A husk tail — the segment file exists but never durably
	// opened — is removed, and resume finishes the rotation.
	{
		fs: OFS
		defer ofs_destroy(&fs)
		_ = obuild(t, &fs)
		garbage := [40]u8{0 = 'x'}
		ofs_set(ofs_find(&fs, "store/000003.rlog"), garbage[:])
		s: Store
		tear, err, _, werr := store_open(&s, "store", ofs_ops(&fs))
		testing.expect_value(t, err, Open_Error.None)
		testing.expect_value(t, werr, Writer_Error.None)
		testing.expect_value(t, tear.kind, Tear_Kind.Header)
		testing.expect_value(t, fs.removes, 1)
		testing.expect_value(t, s.published, u32(2))
		testing.expect_value(t, s.writer.seg_no, u32(3))
		ops := [1]Fact_Op{{op = .Assert, s = 1, p = 2, o = 3, g = 1}}
		testing.expect_value(t, writer_commit(&s.writer, {epoch = 3, wall = OWALL + 9, ops = ops[:]}), Writer_Error.None)
		store_close(&s)
	}
	// (e) A halting verdict passes through untouched: damage in a
	// sealed segment is evidence, and boot refuses with the walk's own
	// word for it.
	{
		fs: OFS
		defer ofs_destroy(&fs)
		_ = obuild(t, &fs)
		f1 := ofs_find(&fs, "store/000001.rlog")
		offs := record_offsets(f1.data[:])
		defer delete(offs)
		f1.data[offs[0]+FRAME_OVERHEAD+5] ~= 0x01
		s: Store
		_, err, lerr, werr := store_open(&s, "store", ofs_ops(&fs))
		testing.expect_value(t, err, Open_Error.Corrupt)
		testing.expect_value(t, lerr, Load_Error.None)
		testing.expect_value(t, werr, Writer_Error.None)
		testing.expect(t, s.writer.dir == "", "no writer on a refused boot")
		testing.expect_value(t, fs.truncates, 0)
	}
}

// sweep_script drives one writer life for the cross-restart sweep:
// four commits, a note, an explicit seal, and a small target size so
// rotation fires on its own — every operation class the writer has,
// under a budget that fails operation k+1. Returns the epochs the
// writer acknowledged before the cut.
@(private = "file")
sweep_script :: proc(fs: ^OFS) -> (acked: [dynamic]u64) {
	w, err := writer_create("store", ofs_ops(fs), 200)
	defer writer_destroy(&w)
	if err != .None {
		return
	}
	enc_buf: [32]u8
	for e in u64(1) ..= 4 {
		enc := fmt.bprintf(enc_buf[:], "\x01http://ex/t%d", e)
		terms := [1]Term_Def{{id = e, enc = transmute([]byte)enc}}
		ops := [1]Fact_Op{{op = .Assert, s = e, p = e, o = e, g = 0}}
		if writer_commit(&w, {epoch = e, wall = OWALL + e, terms = terms[:], ops = ops[:]}) != .None {
			return
		}
		append(&acked, e)
		if e == 2 {
			if writer_note(&w, transmute([]byte)string(`{"probe":1}`)) != .None {
				return
			}
		}
		if e == 3 {
			if writer_seal(&w) != .None {
				return
			}
		}
	}
	return
}

@(test)
test_boot_cross_restart_sweep :: proc(t: ^testing.T) {
	// Learn the unbudgeted operation count once; then crash at every
	// cut point, boot from the durable view, and continue.
	probe: OFS
	probe.budget = 1 << 30
	acked0 := sweep_script(&probe)
	total := probe.used
	delete(acked0)
	ofs_destroy(&probe)
	testing.expect(t, total > 20, "the script exercises a real spread of operations")

	enc_buf: [32]u8
	for half in ([2]bool{false, true}) {
		for cut in 1 ..= total {
			fs: OFS
			fs.budget = cut
			acked := sweep_script(&fs)
			defer delete(acked)

			// The durable view: what a crash at this cut leaves.
			durable: OFS
			for &f in fs.files {
				if data, ok := ofs_durable(&fs, f.name, half); ok {
					ofs_seed(&durable, f.name, data)
				}
			}
			ofs_destroy(&fs)
			defer ofs_destroy(&durable)

			// Boot. Every crash state is recoverable, no acknowledged
			// epoch is lost, and the store continues.
			s: Store
			_, err, lerr, werr := store_open(&s, "store", ofs_ops(&durable), target_size = 200)
			testing.expectf(t, err == .None, "cut %d half %v: boot err %v", cut, half, err)
			testing.expectf(t, lerr == .None && werr == .None, "cut %d half %v: %v %v", cut, half, lerr, werr)
			last := u64(0)
			if len(acked) > 0 {
				last = acked[len(acked)-1]
			}
			testing.expectf(t, u64(s.published) >= last, "cut %d half %v: acked epoch %d lost (published %d)", cut, half, last, s.published)

			// Two more epochs through the resumed writer. The bounds
			// are hoisted: writer_commit advances prev_epoch, and a
			// bound read from it inside the range would never be met.
			first := s.writer.prev_epoch + 1
			for e in first ..= first + 1 {
				enc := fmt.bprintf(enc_buf[:], "\x01http://ex/r%d", e)
				terms := [1]Term_Def{{id = s.writer.next_term_id, enc = transmute([]byte)enc}}
				ops := [1]Fact_Op{{op = .Assert, s = s.writer.next_term_id, p = s.writer.next_term_id, o = s.writer.next_term_id, g = 0}}
				cerr := writer_commit(&s.writer, {epoch = e, wall = OWALL + 100 + e, terms = terms[:], ops = ops[:]})
				testing.expectf(t, cerr == .None, "cut %d half %v: resumed commit %v", cut, half, cerr)
			}
			resumed_last := s.writer.prev_epoch
			store_close(&s)

			// The combined log verifies clean and replays to the union
			// of both runs.
			col: Collector2
			r, _, verr := replay("store", ofs_ops(&durable), col2_consumer(&col))
			testing.expectf(t, verr == .None, "cut %d half %v: combined log replay %v", cut, half, verr)
			testing.expect_value(t, r.last_epoch, resumed_last)
			testing.expect_value(t, col.commits, u64(len(acked))+2)
		}
	}
}

// Collector2 is the sweep's counting consumer — the scale test has its
// own; this one is package-test-local and minimal.
@(private = "file")
Collector2 :: struct {
	commits: u64,
}

@(private = "file")
col2_consumer :: proc(c: ^Collector2) -> Consumer {
	return {
		data = c,
		commit = proc(data: rawptr, epoch, wall, actor, reason: u64) -> bool {
			(^Collector2)(data).commits += 1
			return true
		},
	}
}
