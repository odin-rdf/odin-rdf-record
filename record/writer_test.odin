package record

import "core:fmt"
import "core:strings"
import "core:testing"

// The writer's tests run against a fake filesystem with an operation
// budget: after N successful operations every further one fails, which
// is the crash model — the sweep in test_writer_crash_sweep replays
// the same script at every possible cut point and checks log.md
// par. 7.1's promise from the outside: no acknowledged epoch is ever
// lost, and nothing partial is ever mistaken for a record. The
// durable view after a "crash" is what was fsynced, optionally plus
// half of what was written but never synced — a real crash can leave
// any prefix of unsynced bytes, and recovery must classify it as torn.

@(private = "file")
Fake_File :: struct {
	name:    string, // cloned
	written: [dynamic]u8,
	synced:  int,  // bytes durable as of the last sync
	linked:  bool, // directory entry durable (a sync_dir happened)
}

@(private = "file")
Fake_FS :: struct {
	files:     [dynamic]Fake_File,
	budget:    int, // successful operations remaining; < 0 is unlimited
	used:      int,
	head:      [dynamic]u8, // last put_file content (HEAD)
	fail_head: bool,        // make put_file fail without burning budget
}

@(private = "file")
fake_ops :: proc(fs: ^Fake_FS) -> File_Ops {
	return {
		data     = fs,
		create   = fake_create,
		append   = fake_append,
		sync     = fake_sync,
		close    = fake_close,
		sync_dir = fake_sync_dir,
		put_file = fake_put_file,
	}
}

@(private = "file")
fake_destroy :: proc(fs: ^Fake_FS) {
	for &f in fs.files {
		delete(f.name)
		delete(f.written)
	}
	delete(fs.files)
	delete(fs.head)
	fs^ = {}
}

@(private = "file")
fake_take :: proc(fs: ^Fake_FS) -> bool {
	if fs.budget == 0 {
		return false
	}
	if fs.budget > 0 {
		fs.budget -= 1
	}
	fs.used += 1
	return true
}

@(private = "file")
fake_create :: proc(data: rawptr, path: string) -> (File_Handle, bool) {
	fs := (^Fake_FS)(data)
	if !fake_take(fs) {
		return 0, false
	}
	for f in fs.files {
		if f.name == path {
			return 0, false // segments are never reopened
		}
	}
	append(&fs.files, Fake_File{name = strings.clone(path)})
	return File_Handle(len(fs.files)), true
}

@(private = "file")
fake_append :: proc(data: rawptr, f: File_Handle, bytes: []byte) -> bool {
	fs := (^Fake_FS)(data)
	if !fake_take(fs) {
		return false
	}
	append(&fs.files[int(f)-1].written, ..bytes)
	return true
}

@(private = "file")
fake_sync :: proc(data: rawptr, f: File_Handle) -> bool {
	fs := (^Fake_FS)(data)
	if !fake_take(fs) {
		return false
	}
	file := &fs.files[int(f)-1]
	file.synced = len(file.written)
	return true
}

@(private = "file")
fake_close :: proc(data: rawptr, f: File_Handle) -> bool {
	fs := (^Fake_FS)(data)
	_ = f
	return fake_take(fs)
}

@(private = "file")
fake_sync_dir :: proc(data: rawptr, dir: string) -> bool {
	fs := (^Fake_FS)(data)
	_ = dir
	if !fake_take(fs) {
		return false
	}
	for &f in fs.files {
		f.linked = true
	}
	return true
}

@(private = "file")
fake_put_file :: proc(data: rawptr, path: string, content: []byte) -> bool {
	fs := (^Fake_FS)(data)
	_ = path
	if fs.fail_head {
		return false
	}
	if !fake_take(fs) {
		return false
	}
	clear(&fs.head)
	append(&fs.head, ..content)
	return true
}

// fake_durable is the post-crash view of one file: nothing if its
// directory entry never became durable, otherwise the synced bytes —
// plus, under `half`, half of the unsynced tail, the way a real crash
// can leave any prefix of writes that were never fsynced.
@(private = "file")
fake_durable :: proc(fs: ^Fake_FS, name: string, half: bool) -> (data: []byte, ok: bool) {
	for &f in fs.files {
		if f.name != name {
			continue
		}
		if !f.linked {
			return nil, false
		}
		n := f.synced
		if half {
			n += (len(f.written) - f.synced) / 2
		}
		return f.written[:n], true
	}
	return nil, false
}

@(private = "file")
WALL :: u64(1_700_000_000_000_000_000)

// script runs the writer's whole exercise: four commits, a note, a
// size-triggered rotation (target 300 forces it) and an explicit one.
// It returns the epochs the writer acknowledged before any failure.
@(private = "file")
script :: proc(fs: ^Fake_FS, target: int) -> (acked: [dynamic]u64) {
	w, err := writer_create("store", fake_ops(fs), target)
	defer writer_destroy(&w)
	if err != .None {
		return
	}

	terms1 := [2]Term_Def{
		{id = 1, enc = transmute([]u8)string("\x01http://example.org/a")},
		{id = 2, enc = transmute([]u8)string("\x01http://example.org/b")},
	}
	five, _ := inline_integer(5)
	ops1 := [2]Fact_Op{
		{op = .Assert, s = 1, p = 2, o = five, g = 1},
		{op = .Assert, s = 2, p = 2, o = 1, g = 1},
	}
	if writer_commit(&w, {epoch = 1, wall = WALL, terms = terms1[:], ops = ops1[:]}) != .None {
		return
	}
	append(&acked, 1)

	if writer_note(&w, transmute([]u8)string(`{"format":1}`)) != .None {
		return
	}

	terms2 := [1]Term_Def{{id = 3, enc = transmute([]u8)string("\x01http://example.org/c")}}
	ops2 := [2]Fact_Op{
		{op = .Assert, s = 3, p = 2, o = 1, g = 1},
		{op = .Retract, s = 1, p = 2, o = five, g = 1},
	}
	if writer_commit(&w, {epoch = 2, wall = WALL + 1, terms = terms2[:], ops = ops2[:]}) != .None {
		return
	}
	append(&acked, 2)

	ops3 := [1]Fact_Op{{op = .Assert, s = 2, p = 2, o = 3, g = 1}}
	if writer_commit(&w, {epoch = 3, wall = WALL + 2, ops = ops3[:]}) != .None {
		return
	}
	append(&acked, 3)

	if writer_seal(&w) != .None {
		return
	}

	ops4 := [1]Fact_Op{{op = .Retract, s = 2, p = 2, o = 3, g = 1}}
	if writer_commit(&w, {epoch = 4, wall = WALL + 3, ops = ops4[:]}) != .None {
		return
	}
	append(&acked, 4)
	return
}

// scan_epochs is the frame-scan stand-in for the open path
// (RECORD-T-0003): walk the durable view segment by segment, stop at
// the first anomaly, and collect the epochs of every intact commit.
// Every recovered record must carry a known kind and a good hash.
@(private = "file")
scan_epochs :: proc(t: ^testing.T, fs: ^Fake_FS, half: bool) -> (epochs: [dynamic]u64) {
	for seg := u32(1); ; seg += 1 {
		name := fmt.tprintf("store/%06d.rlog", seg)
		data, ok := fake_durable(fs, name, half)
		if !ok {
			return
		}
		if _, herr := header_decode(data); herr != .None {
			return // a partial header ends the usable log
		}
		rest := data[HEADER_SIZE:]
		scan: for {
			body, r, status := frame_next(rest)
			rest = r
			if status != .Ok {
				break scan
			}
			kind, kok := record_kind(body)
			testing.expect(t, kok, "every recovered record has a known kind")
			#partial switch kind {
			case .Epoch_Commit:
				testing.expect(t, hash_ok(body), "every recovered commit passes the chain rule")
				v, derr := commit_decode(body)
				testing.expect_value(t, derr, Decode_Error.None)
				append(&epochs, v.epoch)
			case .Environment_Note:
				testing.expect(t, hash_ok(body), "every recovered note passes the chain rule")
			case .Segment_Seal:
				_, derr := seal_decode(body)
				testing.expect_value(t, derr, Decode_Error.None)
			}
		}
	}
}

@(test)
test_writer_happy_path :: proc(t: ^testing.T) {
	fs: Fake_FS
	fs.budget = -1
	defer fake_destroy(&fs)
	acked := script(&fs, 300)
	defer delete(acked)
	testing.expect_value(t, len(acked), 4)

	epochs := scan_epochs(t, &fs, false)
	defer delete(epochs)
	testing.expect_value(t, len(epochs), 4)
	for e, i in epochs {
		testing.expect_value(t, e, u64(i+1))
	}

	// The chain spans segments: walk every chained record in order and
	// check each prev_hash against the running head, and each segment
	// header's base hash and each seal's final hash against the head
	// at that boundary.
	running: [HASH_SIZE]u8
	for seg := u32(1); ; seg += 1 {
		name := fmt.tprintf("store/%06d.rlog", seg)
		data, ok := fake_durable(&fs, name, false)
		if !ok {
			break
		}
		hdr, herr := header_decode(data)
		testing.expect_value(t, herr, Decode_Error.None)
		testing.expect(t, hdr.base_hash == running, "base hash equals the previous segment's head")
		rest := data[HEADER_SIZE:]
		walk: for {
			body, r, status := frame_next(rest)
			rest = r
			if status != .Ok {
				break walk
			}
			kind, _ := record_kind(body)
			#partial switch kind {
			case .Epoch_Commit:
				v, _ := commit_decode(body)
				testing.expect(t, v.prev_hash == running, "commit chains from the running head")
				running = v.hash
			case .Environment_Note:
				v, _ := note_decode(body)
				testing.expect(t, v.prev_hash == running, "note chains from the running head")
				running = v.hash
			case .Segment_Seal:
				s, _ := seal_decode(body)
				testing.expect(t, s.final_hash == running, "seal summarizes the head, not the chain")
			}
		}
	}

	// Seal bookkeeping in segment 1: one commit before the size
	// rotation, and two facts asserted (the high-water convention).
	seg1, _ := fake_durable(&fs, "store/000001.rlog", false)
	last_body: []byte
	rest := seg1[HEADER_SIZE:]
	for {
		body, r, status := frame_next(rest)
		rest = r
		if status != .Ok {
			break
		}
		last_body = body
	}
	s, serr := seal_decode(last_body)
	testing.expect_value(t, serr, Decode_Error.None)
	testing.expect_value(t, s.last_epoch, u64(1))
	testing.expect_value(t, s.record_count, u64(1))
	testing.expect_value(t, s.last_fact_id, u32(2))

	seg2, _ := fake_durable(&fs, "store/000002.rlog", false)
	hdr2, _ := header_decode(seg2)
	testing.expect_value(t, hdr2.segment, u32(2))
	testing.expect_value(t, hdr2.first_epoch, u64(2))
	testing.expect_value(t, hdr2.first_fact_id, u32(2))
}

@(test)
test_writer_crash_sweep :: proc(t: ^testing.T) {
	// Total operations in an uncut run.
	total: int
	{
		fs: Fake_FS
		fs.budget = -1
		defer fake_destroy(&fs)
		acked := script(&fs, 300)
		defer delete(acked)
		total = fs.used
	}
	testing.expect(t, total > 20, "the script exercises a real number of operations")

	// Cut at every point; both durable views per cut.
	for budget in 0 ..< total {
		fs: Fake_FS
		fs.budget = budget
		defer fake_destroy(&fs)
		acked := script(&fs, 300)
		defer delete(acked)

		for half in ([2]bool{false, true}) {
			epochs := scan_epochs(t, &fs, half)
			defer delete(epochs)
			for e, i in epochs {
				testing.expect_value(t, e, u64(i+1)) // contiguous from 1
			}
			testing.expect(
				t,
				len(epochs) >= len(acked),
				fmt.tprintf("budget %d half %v: acked %d epochs, recovered %d — an acknowledged epoch was lost",
					budget, half, len(acked), len(epochs)),
			)
		}
	}
}

@(test)
test_writer_seal_triggers_identical_bytes :: proc(t: ^testing.T) {
	// Run A: explicit seal after epoch 1.
	fs_a: Fake_FS
	fs_a.budget = -1
	defer fake_destroy(&fs_a)
	{
		w, err := writer_create("store", fake_ops(&fs_a), SEGMENT_TARGET_SIZE)
		defer writer_destroy(&w)
		testing.expect_value(t, err, Writer_Error.None)
		terms := [1]Term_Def{{id = 1, enc = transmute([]u8)string("\x01http://example.org/a")}}
		ops := [1]Fact_Op{{op = .Assert, s = 1, p = 1, o = 1, g = 1}}
		testing.expect_value(t, writer_commit(&w, {epoch = 1, wall = WALL, terms = terms[:], ops = ops[:]}), Writer_Error.None)
		testing.expect_value(t, writer_seal(&w), Writer_Error.None)
	}

	// Run B: the size trigger seals before epoch 2's append.
	fs_b: Fake_FS
	fs_b.budget = -1
	defer fake_destroy(&fs_b)
	{
		w, err := writer_create("store", fake_ops(&fs_b), 100)
		defer writer_destroy(&w)
		testing.expect_value(t, err, Writer_Error.None)
		terms := [1]Term_Def{{id = 1, enc = transmute([]u8)string("\x01http://example.org/a")}}
		ops := [1]Fact_Op{{op = .Assert, s = 1, p = 1, o = 1, g = 1}}
		testing.expect_value(t, writer_commit(&w, {epoch = 1, wall = WALL, terms = terms[:], ops = ops[:]}), Writer_Error.None)
		ops2 := [1]Fact_Op{{op = .Retract, s = 1, p = 1, o = 1, g = 1}}
		testing.expect_value(t, writer_commit(&w, {epoch = 2, wall = WALL + 1, ops = ops2[:]}), Writer_Error.None)
	}

	a1, aok := fake_durable(&fs_a, "store/000001.rlog", false)
	b1, bok := fake_durable(&fs_b, "store/000001.rlog", false)
	testing.expect(t, aok && bok, "both runs sealed segment 1")
	testing.expect(t, string(a1) == string(b1), "explicit and size-triggered seals produce identical bytes")

	a2, _ := fake_durable(&fs_a, "store/000002.rlog", false)
	b2, _ := fake_durable(&fs_b, "store/000002.rlog", false)
	testing.expect(
		t,
		string(a2[:HEADER_SIZE]) == string(b2[:HEADER_SIZE]),
		"both rotations open segment 2 with the same header",
	)
}

@(test)
test_writer_head_is_advisory :: proc(t: ^testing.T) {
	fs: Fake_FS
	fs.budget = -1
	defer fake_destroy(&fs)

	w, err := writer_create("store", fake_ops(&fs), SEGMENT_TARGET_SIZE)
	defer writer_destroy(&w)
	testing.expect_value(t, err, Writer_Error.None)

	terms := [1]Term_Def{{id = 1, enc = transmute([]u8)string("\x01http://example.org/a")}}
	ops := [1]Fact_Op{{op = .Assert, s = 1, p = 1, o = 1, g = 1}}
	testing.expect_value(t, writer_commit(&w, {epoch = 1, wall = WALL, terms = terms[:], ops = ops[:]}), Writer_Error.None)

	// HEAD carries the head hash in hex plus the epoch.
	want: [64]u8
	for b, i in w.head {
		want[i*2] = HEX_DIGITS[b >> 4]
		want[i*2+1] = HEX_DIGITS[b & 0xF]
	}
	testing.expect(t, string(fs.head[:]) == fmt.tprintf("%s 1\n", string(want[:])), "HEAD holds hex head and epoch")

	// A HEAD failure must not fail the commit: the epoch is already
	// durable, and reporting failure for it would be a lie.
	fs.fail_head = true
	ops2 := [1]Fact_Op{{op = .Retract, s = 1, p = 1, o = 1, g = 1}}
	testing.expect_value(t, writer_commit(&w, {epoch = 2, wall = WALL + 1, ops = ops2[:]}), Writer_Error.None)
}

@(test)
test_writer_fail_stop_and_encode_pass_through :: proc(t: ^testing.T) {
	fs: Fake_FS
	fs.budget = -1
	defer fake_destroy(&fs)

	w, err := writer_create("store", fake_ops(&fs), SEGMENT_TARGET_SIZE)
	defer writer_destroy(&w)
	testing.expect_value(t, err, Writer_Error.None)

	// An encode refusal writes nothing and does not fail the writer.
	used_before := fs.used
	ops := [1]Fact_Op{{op = .Assert, s = 1, p = 1, o = 1, g = 1}}
	testing.expect_value(t, writer_commit(&w, {epoch = 5, wall = WALL, ops = ops[:]}), Writer_Error.Epoch_Gap)
	testing.expect_value(t, fs.used, used_before)
	testing.expect(t, !w.failed, "an encode refusal is the caller's, not the writer's")

	// An IO failure stops the writer for good.
	fs.budget = 0
	terms := [1]Term_Def{{id = 1, enc = transmute([]u8)string("\x01http://example.org/a")}}
	ops1 := [1]Fact_Op{{op = .Assert, s = 1, p = 1, o = 1, g = 1}}
	got := writer_commit(&w, {epoch = 1, wall = WALL, terms = terms[:], ops = ops1[:]})
	testing.expect_value(t, got, Writer_Error.IO_Write)
	fs.budget = -1
	testing.expect_value(t, writer_commit(&w, {epoch = 1, wall = WALL, terms = terms[:], ops = ops1[:]}), Writer_Error.Failed)
	testing.expect_value(t, writer_note(&w, nil), Writer_Error.Failed)
	testing.expect_value(t, writer_seal(&w), Writer_Error.Failed)
}
