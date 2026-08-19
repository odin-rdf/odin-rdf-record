#+build linux, darwin
package record

import "core:os"
import "core:sys/posix"
import "core:testing"

// The one test against the real filesystem: everything else runs on
// the injectable fake, and the durability *ordering* is proven there —
// what this proves is that os_file_ops actually opens, appends,
// fsyncs, and links files a reader can load back. Linux is the
// production environment; on Windows the suite simply lacks this file.

@(test)
test_os_writer_smoke :: proc(t: ^testing.T) {
	_ = posix.mkdir("build", posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH})             // may already exist
	_ = posix.mkdir("build/writer-smoke", posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH})
	_ = posix.unlink("build/writer-smoke/000001.rlog") // segments are create-exclusive
	_ = posix.unlink("build/writer-smoke/HEAD")

	w, err := writer_create("build/writer-smoke", os_file_ops())
	testing.expect_value(t, err, Writer_Error.None)

	terms := [1]Term_Def{{id = 1, enc = transmute([]u8)string("\x01http://example.org/a")}}
	ops := [1]Fact_Op{{op = .Assert, s = 1, p = 1, o = 1, g = 1}}
	testing.expect_value(
		t,
		writer_commit(&w, {epoch = 1, wall = 1_700_000_000_000_000_000, terms = terms[:], ops = ops[:]}),
		Writer_Error.None,
	)
	testing.expect_value(t, writer_note(&w, transmute([]u8)string(`{"format":1}`)), Writer_Error.None)
	head := w.head
	testing.expect_value(t, writer_destroy(&w), Writer_Error.None)

	data, rerr := os.read_entire_file_from_path("build/writer-smoke/000001.rlog", context.allocator)
	testing.expect(t, rerr == nil, "the segment reads back")
	defer delete(data)

	hdr, herr := header_decode(data)
	testing.expect_value(t, herr, Decode_Error.None)
	testing.expect_value(t, hdr.segment, u32(1))
	testing.expect_value(t, hdr.first_epoch, u64(1))
	testing.expect(t, hdr.base_hash == [HASH_SIZE]u8{}, "segment 1 chains from zero")

	running: [HASH_SIZE]u8
	records := 0
	rest := data[HEADER_SIZE:]
	for {
		body, r, status := frame_next(rest)
		rest = r
		if status != .Ok {
			testing.expect_value(t, status, Frame_Status.Clean_End)
			break
		}
		records += 1
		kind, kok := record_kind(body)
		testing.expect(t, kok, "known record kind")
		#partial switch kind {
		case .Epoch_Commit:
			v, derr := commit_decode(body)
			testing.expect_value(t, derr, Decode_Error.None)
			testing.expect_value(t, v.epoch, u64(1))
			testing.expect(t, v.prev_hash == running, "commit chains from the running head")
			running = v.hash
		case .Environment_Note:
			v, derr := note_decode(body)
			testing.expect_value(t, derr, Decode_Error.None)
			testing.expect(t, v.prev_hash == running, "note chains from the running head")
			running = v.hash
		}
	}
	testing.expect_value(t, records, 2)
	testing.expect(t, running == head, "the file's chain ends at the writer's head")

	head_data, hrerr := os.read_entire_file_from_path("build/writer-smoke/HEAD", context.allocator)
	testing.expect(t, hrerr == nil, "HEAD reads back")
	defer delete(head_data)
	testing.expect_value(t, len(head_data), 64 + len(" 1\n"))
}
