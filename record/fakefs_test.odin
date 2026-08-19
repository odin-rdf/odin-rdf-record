package record

import "base:runtime"
import "core:strings"
import "core:testing"

// The read path's shared test scaffolding, used by open_test.odin and
// replay_test.odin: a byte-level fake filesystem and the canonical log
// to injure. Fault states are made by truncating and editing file
// contents directly, which is exactly the space of states a real crash
// or a real tamperer can produce. Package-private rather than
// file-private because two test files consume it; the writer's own
// fake (writer_test.odin) stays separate — its operation budget models
// the crash, this one models the aftermath.

@(private)
OFile :: struct {
	name: string, // cloned
	data: [dynamic]u8,
	gone: bool,
}

@(private)
OFS :: struct {
	files:     [dynamic]OFile,
	head:      [dynamic]u8, // last put_file content (HEAD)
	fail_read: string,      // path whose read reports .Error; "" for none
	truncates: int,
	removes:   int,
	dir_syncs: int,
}

@(private)
ofs_ops :: proc(fs: ^OFS) -> File_Ops {
	return {
		data     = fs,
		create   = ofs_create,
		append   = ofs_append,
		sync     = ofs_sync,
		close    = ofs_close,
		sync_dir = ofs_sync_dir,
		put_file = ofs_put_file,
		read     = ofs_read,
		truncate = ofs_truncate,
		remove   = ofs_remove,
	}
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

@(private)
ofs_seed :: proc(fs: ^OFS, name: string, data: []byte) {
	f := OFile {
		name = strings.clone(name),
	}
	append(&f.data, ..data)
	append(&fs.files, f)
}

@(private)
ofs_set :: proc(f: ^OFile, data: []byte) {
	f.gone = false
	resize(&f.data, 0)
	append(&f.data, ..data)
}

@(private)
ofs_create :: proc(data: rawptr, path: string) -> (File_Handle, bool) {
	fs := (^OFS)(data)
	for f in fs.files {
		if f.name == path && !f.gone {
			return 0, false
		}
	}
	append(&fs.files, OFile{name = strings.clone(path)})
	return File_Handle(len(fs.files)), true
}

@(private)
ofs_append :: proc(data: rawptr, f: File_Handle, bytes: []byte) -> bool {
	fs := (^OFS)(data)
	append(&fs.files[int(f)-1].data, ..bytes)
	return true
}

@(private)
ofs_sync :: proc(data: rawptr, f: File_Handle) -> bool {
	_ = data
	_ = f
	return true
}

@(private)
ofs_close :: proc(data: rawptr, f: File_Handle) -> bool {
	_ = data
	_ = f
	return true
}

@(private)
ofs_sync_dir :: proc(data: rawptr, dir: string) -> bool {
	fs := (^OFS)(data)
	_ = dir
	fs.dir_syncs += 1
	return true
}

@(private)
ofs_put_file :: proc(data: rawptr, path: string, content: []byte) -> bool {
	fs := (^OFS)(data)
	_ = path
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
