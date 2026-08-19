// The segment writer (RECORD-T-0002): log.md par. 7.1 steps 1-3 —
// encode, append, fsync, and only then acknowledge — plus rotation
// with the directory fsync, and the advisory HEAD file. Steps 4-5
// (apply, publish) belong to the resident store and are absent here.
//
// # One append shape
//
// There is no batched append, deliberately: the epoch is the batch.
// nOps makes "many entries, one fsync" a property of the format, and
// an API sharing one fsync across epochs would either acknowledge
// before durability or be group commit for concurrent committers the
// single-writer design does not have. sync(2) is never used; the
// primitives are fsync on the segment file and fsync on the directory
// at rotation.
//
// # Rotation happens before an append, never after one
//
// A segment past its target size is sealed at the START of the next
// append. Sealing after a successful append would put IO that can
// fail between the fsync and the acknowledgement, and an error there
// would report failure for an epoch that is already durable — the one
// kind of lie this layer exists to never tell. For the same reason a
// HEAD write failure is swallowed: HEAD is advisory, derived, and
// never trusted, and the commit it trails is already on disk.
//
// # The writer is single-threaded and fail-stop
//
// One writer per store, no locks (log.md par. 10) — epoch allocation,
// chaining, and fact-id assignment are trivially correct because of
// it. After any IO error the writer refuses further use: the caller's
// recovery is the open path, not a retry.
package record

import "base:runtime"
import "core:fmt"
import "core:strings"

// SEGMENT_TARGET_SIZE is the default size past which a segment is
// sealed at the next append (log.md par. 2).
SEGMENT_TARGET_SIZE :: 64 * 1024 * 1024

// File_Handle identifies an open file to a File_Ops implementation.
// Opaque here; the OS implementation stores a descriptor, a test fake
// stores an index.
File_Handle :: distinct uintptr

// File_Ops is the writer's entire view of the filesystem, injectable
// so crash tests can cut between any two operations (RECORD-T-0002).
// Path arguments are borrowed for the call — an implementation that
// retains one clones it. Every proc reports plain success; the writer
// maps failures to its own error and stops.
File_Ops :: struct {
	data:     rawptr,
	// create opens a new file for append; it must refuse a path that
	// already exists (a segment is never reopened by the writer).
	create:   proc(data: rawptr, path: string) -> (File_Handle, bool),
	// append writes all the bytes at the end of the file, or fails.
	append:   proc(data: rawptr, f: File_Handle, bytes: []byte) -> bool,
	// sync makes everything appended so far durable — the boundary of
	// log.md par. 7.1 step 3. On Linux, the production environment,
	// fsync(2) is the guarantee. On darwin (development only) fsync
	// does not flush the drive cache, so the OS implementation issues
	// F_FULLFSYNC and falls back to fsync where the filesystem refuses
	// it — dev machines must not silently hold weaker guarantees than
	// production.
	sync:     proc(data: rawptr, f: File_Handle) -> bool,
	close:    proc(data: rawptr, f: File_Handle) -> bool,
	// sync_dir makes the directory's entries durable — the rotation
	// step people forget: without it a crash can leave a segment that
	// exists in the page cache and not in the directory.
	sync_dir: proc(data: rawptr, dir: string) -> bool,
	// put_file replaces a small advisory file wholesale (HEAD). No
	// durability is promised or wanted; no read path trusts it.
	put_file: proc(data: rawptr, path: string, content: []byte) -> bool,
}

// Writer_Error is every way an append can refuse. The encoding cases
// are commit_encode's, verbatim; the IO cases name the operation that
// failed, which the crash tests cut at one by one. Failed means the
// writer saw an earlier IO error and refuses further use.
Writer_Error :: enum {
	None,
	Epoch_Gap,
	Term_Order,
	Bad_Term_Id,
	Inline_Range,
	Bad_Op,
	Too_Large,
	IO_Create,
	IO_Write,
	IO_Sync,
	IO_Close,
	Failed,
}

// Writer is the single writer of one store directory. Fields are
// read-only to callers; every mutation goes through the procs below.
// prev_epoch, next_term_id, and fact_count are the encoding-level
// state the invariants of commit_encode are checked against;
// fact_count is the fact-ID high-water mark — the id the next assert
// receives — counted per log.md par. 5.3's positional rule.
Writer :: struct {
	ops:           File_Ops,
	dir:           string, // cloned; owned by the writer
	seg:           File_Handle,
	seg_no:        u32,
	seg_size:      int, // bytes in the current segment, header included
	target_size:   int,
	head:          [HASH_SIZE]u8, // hash of the last chained record
	prev_epoch:    u64,
	next_term_id:  u64,
	fact_count:    u32,
	epoch_records: u64, // commits in the current segment (seal field)
	failed:        bool,
	allocator:     runtime.Allocator,
}

// writer_create initializes a brand-new store: segment 000001 with a
// zero base hash, synced file and directory, and an initial HEAD.
// Resuming an existing store needs the open path's verified head and
// arrives with it (RECORD-T-0003/T-0004). The caller owns the Writer
// whatever err says and releases it with writer_destroy.
writer_create :: proc(
	dir: string,
	ops: File_Ops,
	target_size := SEGMENT_TARGET_SIZE,
	allocator := context.allocator,
) -> (
	w: Writer,
	err: Writer_Error,
) {
	w.ops = ops
	w.dir = strings.clone(dir, allocator)
	w.seg_no = 1
	w.target_size = target_size
	w.prev_epoch = 0
	w.next_term_id = 1 // id 0 is "none" and is never allocated
	w.fact_count = 0
	w.allocator = allocator
	if err = open_segment(&w); err != .None {
		return w, err
	}
	write_head_file(&w)
	return w, .None
}

// writer_destroy closes the open segment — without sealing it: an
// open segment is a normal state for a store at rest — and frees what
// the writer owns. IO failure here is reported but leaves nothing to
// retry.
writer_destroy :: proc(w: ^Writer) -> Writer_Error {
	err := Writer_Error.None
	if !w.failed && w.seg != 0 {
		if !w.ops.close(w.ops.data, w.seg) {
			err = .IO_Close
		}
	}
	delete(w.dir, w.allocator)
	w^ = {}
	return err
}

// writer_commit encodes one epoch commit against the writer's state,
// appends it, fsyncs, and only then returns .None — log.md par. 7.1's
// durability boundary. On .None the epoch is durable whatever happens
// next; on any other value it is as if the call never happened.
writer_commit :: proc(w: ^Writer, c: Commit) -> Writer_Error {
	if w.failed {
		return .Failed
	}
	body, enc_err := commit_encode(c, w.head, w.prev_epoch, w.next_term_id, w.allocator)
	if enc_err != .None {
		return from_encode(enc_err)
	}
	defer delete(body, w.allocator)

	if err := append_record(w, body); err != .None {
		return err
	}

	copy(w.head[:], body[len(body)-HASH_SIZE:])
	w.prev_epoch = c.epoch
	w.next_term_id += u64(len(c.terms))
	for op in c.ops {
		if op.op == .Assert || op.op == .Assert_Derived {
			w.fact_count += 1
		}
	}
	w.epoch_records += 1
	write_head_file(w)
	return .None
}

// writer_note appends an environment note chained from the current
// head. The writer fills last_epoch itself — the note follows the
// last committed epoch by construction, so the field cannot be wrong.
writer_note :: proc(w: ^Writer, payload: []byte) -> Writer_Error {
	if w.failed {
		return .Failed
	}
	body, enc_err := note_encode(Note{last_epoch = w.prev_epoch, payload = payload}, w.head, w.allocator)
	if enc_err != .None {
		return from_encode(enc_err)
	}
	defer delete(body, w.allocator)

	if err := append_record(w, body); err != .None {
		return err
	}
	copy(w.head[:], body[len(body)-HASH_SIZE:])
	write_head_file(w)
	return .None
}

// writer_seal seals the current segment and opens the next — the
// operator form of the rotation the size trigger performs, producing
// identical bytes. The seal is a summary, not a chain link: the head
// is unchanged, and the new segment's base hash is that head.
writer_seal :: proc(w: ^Writer) -> Writer_Error {
	if w.failed {
		return .Failed
	}
	return rotate(w)
}

@(private)
from_encode :: proc(e: Encode_Error) -> Writer_Error {
	switch e {
	case .None:
		return .None
	case .Epoch_Gap:
		return .Epoch_Gap
	case .Term_Order:
		return .Term_Order
	case .Bad_Term_Id:
		return .Bad_Term_Id
	case .Inline_Range:
		return .Inline_Range
	case .Bad_Op:
		return .Bad_Op
	case .Too_Large:
		return .Too_Large
	}
	return .None
}

// append_record rotates first if the segment is past its target, then
// frames, appends, and fsyncs one record. Failure marks the writer
// failed; nothing acknowledged is ever at risk, because nothing is
// acknowledged until this returns .None.
@(private)
append_record :: proc(w: ^Writer, body: []byte) -> Writer_Error {
	if w.seg_size >= w.target_size {
		if err := rotate(w); err != .None {
			return err
		}
	}
	framed := make([dynamic]u8, 0, len(body)+FRAME_OVERHEAD, w.allocator)
	defer delete(framed)
	frame_append(&framed, body)
	if !w.ops.append(w.ops.data, w.seg, framed[:]) {
		w.failed = true
		return .IO_Write
	}
	if !w.ops.sync(w.ops.data, w.seg) {
		w.failed = true
		return .IO_Sync
	}
	w.seg_size += len(framed)
	return .None
}

// rotate writes the seal, fsyncs and closes the old segment, then
// creates, fills in, and fsyncs the new one, and finally fsyncs the
// directory — log.md par. 7.1's rotation sequence, in that order.
@(private)
rotate :: proc(w: ^Writer) -> Writer_Error {
	seal := Seal {
		last_epoch   = w.prev_epoch,
		record_count = w.epoch_records,
		last_fact_id = w.fact_count,
		final_hash   = w.head,
	}
	body, enc_err := seal_encode(seal, w.allocator)
	if enc_err != .None {
		return from_encode(enc_err)
	}
	defer delete(body, w.allocator)

	framed := make([dynamic]u8, 0, len(body)+FRAME_OVERHEAD, w.allocator)
	defer delete(framed)
	frame_append(&framed, body)
	if !w.ops.append(w.ops.data, w.seg, framed[:]) {
		w.failed = true
		return .IO_Write
	}
	if !w.ops.sync(w.ops.data, w.seg) {
		w.failed = true
		return .IO_Sync
	}
	if !w.ops.close(w.ops.data, w.seg) {
		w.failed = true
		return .IO_Close
	}
	w.seg_no += 1
	w.epoch_records = 0
	return open_segment(w)
}

// open_segment creates the current segment number, writes and fsyncs
// its header, and fsyncs the directory so the file's existence is as
// durable as its bytes.
@(private)
open_segment :: proc(w: ^Writer) -> Writer_Error {
	path_buf: [512]u8
	path := segment_path(path_buf[:], w.dir, w.seg_no)
	f, ok := w.ops.create(w.ops.data, path)
	if !ok {
		w.failed = true
		return .IO_Create
	}
	w.seg = f
	header: [HEADER_SIZE]u8
	header_encode(
		Segment_Header{
			version = FORMAT_VERSION,
			segment = w.seg_no,
			first_epoch = w.prev_epoch + 1,
			first_fact_id = w.fact_count,
			base_hash = w.head,
		},
		&header,
	)
	if !w.ops.append(w.ops.data, w.seg, header[:]) {
		w.failed = true
		return .IO_Write
	}
	if !w.ops.sync(w.ops.data, w.seg) {
		w.failed = true
		return .IO_Sync
	}
	if !w.ops.sync_dir(w.ops.data, w.dir) {
		w.failed = true
		return .IO_Sync
	}
	w.seg_size = HEADER_SIZE
	return .None
}

// write_head_file replaces HEAD with the current head hash in hex and
// the last epoch. Advisory by contract (log.md par. 2): a failure is
// swallowed, because the commit it trails is already durable and
// reporting failure for it would be a lie.
@(private)
write_head_file :: proc(w: ^Writer) {
	content: [96]u8
	for b, i in w.head {
		content[i*2] = HEX_DIGITS[b >> 4]
		content[i*2+1] = HEX_DIGITS[b & 0xF]
	}
	rest := fmt.bprintf(content[64:], " %d\n", w.prev_epoch)
	path_buf: [512]u8
	path := fmt.bprintf(path_buf[:], "%s/HEAD", w.dir)
	_ = w.ops.put_file(w.ops.data, path, content[:64+len(rest)])
}

@(private)
HEX_DIGITS := "0123456789abcdef"

@(private)
segment_path :: proc(buf: []byte, dir: string, seg_no: u32) -> string {
	return fmt.bprintf(buf, "%s/%06d.rlog", dir, seg_no)
}
