package record

import "base:runtime"
import "core:strings"
import "core:testing"

// The shared test scaffolding: a byte-level fake filesystem, the
// canonical log to injure, and — since RECORD-T-0011 — the crash model
// the cross-restart sweep needs in one fake: an operation budget (the
// writer_test.odin Fake_FS model), synced/linked durability tracking,
// and the read side, so a crashed writer's durable view can be
// re-seeded and booted in the same test. Fault states are made two
// ways, both real: editing file contents directly (the tamperer's
// space), and exhausting the budget then taking ofs_durable's view
// (the crash's space). Package-private because several test files
// consume it; writer_test.odin's Fake_FS predates the composition and
// stays for the writer's own sweep.

@(private)
OFile :: struct {
	name:   string, // cloned
	data:   [dynamic]u8,
	gone:   bool,
	synced: int,  // bytes made durable by the last sync
	linked: bool, // the directory entry is durable (sync_dir since creation)
}

@(private)
OFS :: struct {
	files:     [dynamic]OFile,
	head:      [dynamic]u8, // last put_file content (HEAD)
	fail_read: string,      // path whose read reports .Error; "" for none
	truncates: int,
	removes:   int,
	dir_syncs: int,
	budget:    int, // write-side operations before failure; 0 is unlimited
	used:      int,
}

@(private)
ofs_ops :: proc(fs: ^OFS) -> File_Ops {
	return {
		data        = fs,
		create      = ofs_create,
		open_append = ofs_open_append,
		append      = ofs_append,
		sync        = ofs_sync,
		close       = ofs_close,
		sync_dir    = ofs_sync_dir,
		put_file    = ofs_put_file,
		read        = ofs_read,
		truncate    = ofs_truncate,
		remove      = ofs_remove,
	}
}

// ofs_take spends one write-side operation of the budget — the crash
// model: operation k+1 fails, everything before it succeeded.
@(private)
ofs_take :: proc(fs: ^OFS) -> bool {
	if fs.budget == 0 {
		return true
	}
	fs.used += 1
	return fs.used <= fs.budget
}

// ofs_durable is the post-crash view of one file (the Fake_FS
// semantics, composed in): nothing if its directory entry never became
// durable, otherwise the synced bytes — plus, when `half` says so,
// half of the unsynced tail, the partial-page shape a real crash
// leaves.
@(private)
ofs_durable :: proc(fs: ^OFS, name: string, half: bool) -> (data: []byte, ok: bool) {
	f := ofs_find(fs, name)
	if f == nil || f.gone || !f.linked {
		return nil, false
	}
	n := f.synced
	if half {
		n += (len(f.data) - f.synced) / 2
	}
	return f.data[:n], true
}

@(private)
ofs_destroy :: proc(fs: ^OFS) {
	for &f in fs.files {
		delete(f.name)
		delete(f.data)
	}
	delete(fs.files)
	delete(fs.head)
	fs^ = {}
}

// ofs_find returns the file whatever its `gone` flag says, so a test
// can restore what recovery removed.
@(private)
ofs_find :: proc(fs: ^OFS, name: string) -> ^OFile {
	for &f in fs.files {
		if f.name == name {
			return &f
		}
	}
	return nil
}

// ofs_seed plants a file as if fully durable — the injured-log tests'
// entry point, where durability is not the subject.
@(private)
ofs_seed :: proc(fs: ^OFS, name: string, data: []byte) {
	f := OFile {
		name   = strings.clone(name),
		linked = true,
	}
	append(&f.data, ..data)
	f.synced = len(f.data)
	append(&fs.files, f)
}

@(private)
ofs_set :: proc(f: ^OFile, data: []byte) {
	f.gone = false
	f.linked = true
	resize(&f.data, 0)
	append(&f.data, ..data)
	f.synced = len(f.data)
}

@(private)
ofs_create :: proc(data: rawptr, path: string) -> (File_Handle, bool) {
	fs := (^OFS)(data)
	if !ofs_take(fs) {
		return 0, false
	}
	for &f, i in fs.files {
		if f.name != path {
			continue
		}
		if !f.gone {
			return 0, false // create refuses an existing path
		}
		// A removed file's slot is reused: a fresh file, not durable
		// in the directory until the next sync_dir.
		f.gone = false
		f.linked = false
		f.synced = 0
		resize(&f.data, 0)
		return File_Handle(i + 1), true
	}
	append(&fs.files, OFile{name = strings.clone(path)})
	return File_Handle(len(fs.files)), true
}

@(private)
ofs_open_append :: proc(data: rawptr, path: string) -> (File_Handle, bool) {
	fs := (^OFS)(data)
	if !ofs_take(fs) {
		return 0, false
	}
	for &f, i in fs.files {
		if f.name == path && !f.gone {
			return File_Handle(i + 1), true
		}
	}
	return 0, false // open_append refuses an absent path
}

@(private)
ofs_append :: proc(data: rawptr, f: File_Handle, bytes: []byte) -> bool {
	fs := (^OFS)(data)
	if !ofs_take(fs) {
		return false
	}
	append(&fs.files[int(f)-1].data, ..bytes)
	return true
}

@(private)
ofs_sync :: proc(data: rawptr, f: File_Handle) -> bool {
	fs := (^OFS)(data)
	if !ofs_take(fs) {
		return false
	}
	file := &fs.files[int(f)-1]
	file.synced = len(file.data)
	return true
}

@(private)
ofs_close :: proc(data: rawptr, f: File_Handle) -> bool {
	fs := (^OFS)(data)
	_ = f
	return ofs_take(fs)
}

@(private)
ofs_sync_dir :: proc(data: rawptr, dir: string) -> bool {
	fs := (^OFS)(data)
	_ = dir
	if !ofs_take(fs) {
		return false
	}
	fs.dir_syncs += 1
	for &f in fs.files {
		if !f.gone {
			f.linked = true
		}
	}
	return true
}

@(private)
ofs_put_file :: proc(data: rawptr, path: string, content: []byte) -> bool {
	fs := (^OFS)(data)
	_ = path
	if !ofs_take(fs) {
		return false
	}
	clear(&fs.head)
	append(&fs.head, ..content)
	return true
}

@(private)
ofs_read :: proc(data: rawptr, path: string, allocator: runtime.Allocator) -> (contents: []byte, status: Read_Status) {
	fs := (^OFS)(data)
	if fs.fail_read == path {
		return nil, .Error
	}
	for &f in fs.files {
		if f.name == path && !f.gone {
			contents = make([]byte, len(f.data), allocator)
			copy(contents, f.data[:])
			return contents, .Ok
		}
	}
	return nil, .Absent
}

@(private)
ofs_truncate :: proc(data: rawptr, path: string, size: int) -> bool {
	fs := (^OFS)(data)
	for &f in fs.files {
		if f.name == path && !f.gone {
			if size > len(f.data) {
				return false
			}
			resize(&f.data, size)
			f.synced = size // the cut is made durable (fsync) by contract
			fs.truncates += 1
			return true
		}
	}
	return false
}

@(private)
ofs_remove :: proc(data: rawptr, path: string) -> bool {
	fs := (^OFS)(data)
	for &f in fs.files {
		if f.name == path && !f.gone {
			f.gone = true
			fs.removes += 1
			return true
		}
	}
	return false
}

@(private)
OWALL :: u64(1_700_000_000_000_000_000)

// OState is the writer's own view at the end of obuild, which
// Verify_Result must reproduce exactly — the open path is what hands a
// resuming writer its state back (RECORD-T-0004).
@(private)
OState :: struct {
	head:          [HASH_SIZE]u8,
	last_epoch:    u64,
	seg_no:        u32,
	seg_size:      int,
	next_term_id:  u64,
	fact_count:    u32,
	epoch_records: u64,
}

// obuild produces the canonical log to injure and replay: sealed
// segment 1 (commit, note, seal), sealed segment 2 (commit, seal), and
// an open segment 3 holding two commits — epochs 1..4, three terms,
// four asserts.
@(private)
obuild :: proc(t: ^testing.T, fs: ^OFS) -> (st: OState) {
	w, err := writer_create("store", ofs_ops(fs), SEGMENT_TARGET_SIZE)
	defer writer_destroy(&w)
	testing.expect_value(t, err, Writer_Error.None)

	terms1 := [2]Term_Def{
		{id = 1, enc = transmute([]u8)string("\x01http://example.org/a")},
		{id = 2, enc = transmute([]u8)string("\x01http://example.org/b")},
	}
	five, _ := inline_integer(5)
	ops1 := [2]Fact_Op{
		{op = .Assert, s = 1, p = 2, o = five, g = 1},
		{op = .Assert, s = 2, p = 2, o = 1, g = 1},
	}
	testing.expect_value(t, writer_commit(&w, {epoch = 1, wall = OWALL, terms = terms1[:], ops = ops1[:]}), Writer_Error.None)
	testing.expect_value(t, writer_note(&w, transmute([]u8)string(`{"format":1}`)), Writer_Error.None)
	testing.expect_value(t, writer_seal(&w), Writer_Error.None)

	terms2 := [1]Term_Def{{id = 3, enc = transmute([]u8)string("\x01http://example.org/c")}}
	ops2 := [2]Fact_Op{
		{op = .Assert, s = 3, p = 2, o = 1, g = 1},
		{op = .Retract, s = 1, p = 2, o = five, g = 1},
	}
	testing.expect_value(t, writer_commit(&w, {epoch = 2, wall = OWALL + 1, terms = terms2[:], ops = ops2[:]}), Writer_Error.None)
	testing.expect_value(t, writer_seal(&w), Writer_Error.None)

	ops3 := [1]Fact_Op{{op = .Assert, s = 2, p = 2, o = 3, g = 1}}
	testing.expect_value(t, writer_commit(&w, {epoch = 3, wall = OWALL + 2, ops = ops3[:]}), Writer_Error.None)
	ops4 := [1]Fact_Op{{op = .Retract, s = 2, p = 2, o = 3, g = 1}}
	testing.expect_value(t, writer_commit(&w, {epoch = 4, wall = OWALL + 3, ops = ops4[:]}), Writer_Error.None)

	return OState{
		head          = w.head,
		last_epoch    = w.prev_epoch,
		seg_no        = w.seg_no,
		seg_size      = w.seg_size,
		next_term_id  = w.next_term_id,
		fact_count    = w.fact_count,
		epoch_records = w.epoch_records,
	}
}

// record_offsets scans one segment's frames and returns each record's
// start offset.
@(private)
record_offsets :: proc(data: []byte) -> (offs: [dynamic]int) {
	offset := HEADER_SIZE
	rest := data[HEADER_SIZE:]
	for {
		body, next_rest, status := frame_next(rest)
		if status != .Ok {
			return
		}
		append(&offs, offset)
		offset += FRAME_OVERHEAD + len(body)
		rest = next_rest
	}
}

@(private)
clone_bytes :: proc(data: []byte) -> []byte {
	out := make([]byte, len(data))
	copy(out, data)
	return out
}
