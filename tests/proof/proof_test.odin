package proof_test

import "core:fmt"
import "core:os"
import "core:testing"

import rec "../../record"
import "rdf:rdf"

// The cross-implementation suite (RECORD-T-0006): the Odin verifier
// and the Python verifier — written from log.md alone, under
// tests/verify/ — must agree verdict for verdict over a shared fault
// corpus, and on the head hash and last epoch wherever there is one.
// Each corpus case carries its expected verdict too, so the two
// implementations cannot drift into agreeing on the wrong answer.
//
// Verdicts are compared as one canonical line, the Python verifier's
// output format:
//
//	clean <head-hex> <last-epoch>
//	torn-tail <segment> <offset> <head-hex> <last-epoch>
//	torn-header <segment> 0 <head-hex> <last-epoch>
//	<halting-verdict-word>

STORE :: "build/proof/store"
CASE_DIR :: "build/proof/case"
PY :: "tests/verify/rdflog_verify.py"

WALL :: u64(1_700_000_000_000_000_000)

// The clean store's state, set once by build_proof_store and read by
// the crafting cases.
@(private = "file")
proof_head: [rec.HASH_SIZE]u8
@(private = "file")
proof_epoch: u64
@(private = "file")
proof_next_term: u64

@(private = "file")
Corpus_Case :: struct {
	name:    string,
	verdict: string, // expected first token of the canonical line
	drop:    int,    // segment file omitted from the case dir; 0 for none
	mutate:  proc(segs: [][dynamic]u8),
}

// build_proof_store writes the corpus substrate through the real
// posix ops: three segments (two sealed, one open with two commits),
// a note, an inlined value, a named graph and the default graph.
@(private = "file")
build_proof_store :: proc(t: ^testing.T) {
	os.make_directory("build")
	os.make_directory("build/proof")
	os.make_directory(STORE)
	os.make_directory(CASE_DIR)
	for i in 1 ..= 8 {
		path := fmt.tprintf("%s/%06d.rlog", STORE, i)
		os.remove(path)
	}
	os.remove(STORE + "/HEAD")

	w, err := rec.writer_create(STORE, rec.posix_file_ops())
	testing.expect_value(t, err, rec.Writer_Error.None)

	terms1 := [2]rec.Term_Def{
		{id = 1, enc = transmute([]u8)string("\x01http://example.org/a")},
		{id = 2, enc = transmute([]u8)string("\x01http://example.org/b")},
	}
	five, _ := rec.inline_integer(5)
	ops1 := [2]rec.Fact_Op{
		{op = .Assert, s = 1, p = 2, o = five, g = rec.DEFAULT_GRAPH},
		{op = .Assert, s = 2, p = 2, o = 1, g = 1},
	}
	testing.expect_value(t, rec.writer_commit(&w, {epoch = 1, wall = WALL, terms = terms1[:], ops = ops1[:]}), rec.Writer_Error.None)
	testing.expect_value(t, rec.writer_note(&w, transmute([]u8)string(`{"format":1}`)), rec.Writer_Error.None)
	testing.expect_value(t, rec.writer_seal(&w), rec.Writer_Error.None)

	terms2 := [1]rec.Term_Def{{id = 3, enc = transmute([]u8)string("\x01http://example.org/c")}}
	ops2 := [2]rec.Fact_Op{
		{op = .Assert, s = 3, p = 2, o = 1, g = 1},
		{op = .Retract, s = 1, p = 2, o = five, g = rec.DEFAULT_GRAPH},
	}
	testing.expect_value(t, rec.writer_commit(&w, {epoch = 2, wall = WALL + 1, terms = terms2[:], ops = ops2[:]}), rec.Writer_Error.None)
	testing.expect_value(t, rec.writer_seal(&w), rec.Writer_Error.None)

	ops3 := [1]rec.Fact_Op{{op = .Assert, s = 2, p = 2, o = 3, g = rec.DEFAULT_GRAPH}}
	testing.expect_value(t, rec.writer_commit(&w, {epoch = 3, wall = WALL + 2, ops = ops3[:]}), rec.Writer_Error.None)
	ops4 := [1]rec.Fact_Op{{op = .Retract, s = 2, p = 2, o = 3, g = rec.DEFAULT_GRAPH}}
	testing.expect_value(t, rec.writer_commit(&w, {epoch = 4, wall = WALL + 3, ops = ops4[:]}), rec.Writer_Error.None)
	testing.expect_value(t, rec.writer_destroy(&w), rec.Writer_Error.None)

	// The corpus substrate is a resumed-and-grown store (RECORD-T-0011):
	// boot end to end through store_open — which appends the startup
	// environment note, the payload differing from the placeholder above
	// — then one more epoch through the resumed writer. Every clean and
	// injured case downstream now also proves that resume produced a
	// chain an independent implementation accepts.
	s: rec.Store
	tear, oerr, lerr, werr := rec.store_open(&s, STORE, rec.posix_file_ops())
	testing.expect_value(t, oerr, rec.Open_Error.None)
	testing.expect_value(t, lerr, rec.Load_Error.None)
	testing.expect_value(t, werr, rec.Writer_Error.None)
	testing.expect_value(t, tear.kind, rec.Tear_Kind.None)
	ops5 := [1]rec.Fact_Op{{op = .Assert, s = 3, p = 2, o = five, g = 1}}
	testing.expect_value(t, rec.writer_commit(&s.writer, {epoch = 5, wall = WALL + 4, ops = ops5[:]}), rec.Writer_Error.None)

	proof_head = s.writer.head
	proof_epoch = s.writer.prev_epoch
	proof_next_term = s.writer.next_term_id
	rec.store_close(&s)
}

@(private = "file")
offsets_of :: proc(data: []byte) -> (offs: [dynamic]int) {
	offset := rec.HEADER_SIZE
	rest := data[rec.HEADER_SIZE:]
	for {
		body, next_rest, status := rec.frame_next(rest)
		if status != .Ok {
			return
		}
		append(&offs, offset)
		offset += rec.FRAME_OVERHEAD + len(body)
		rest = next_rest
	}
}

@(private = "file")
append_framed :: proc(seg: ^[dynamic]u8, body: []byte) {
	buf: [dynamic]u8
	defer delete(buf)
	rec.frame_append(&buf, body)
	append(seg, ..buf[:])
}

@(private = "file")
hex_of :: proc(h: [rec.HASH_SIZE]u8, buf: []byte) -> string {
	hex := "0123456789abcdef"
	for b, i in h {
		buf[i*2] = hex[b>>4]
		buf[i*2+1] = hex[b&0xF]
	}
	return string(buf[:rec.HASH_SIZE*2])
}

// canon renders record.verify's answer in the Python verifier's line
// format, so agreement is one string comparison covering the verdict,
// the head hash, the epoch, and the tear location at once.
@(private = "file")
canon :: proc(r: rec.Verify_Result, tear: rec.Tear, err: rec.Open_Error) -> string {
	buf: [rec.HASH_SIZE * 2]u8
	#partial switch err {
	case .None:
		return fmt.tprintf("clean %s %d", hex_of(r.head, buf[:]), r.last_epoch)
	case .Torn:
		kind := "torn-tail" if tear.kind == .Tail else "torn-header"
		offset := tear.offset if tear.kind == .Tail else 0
		return fmt.tprintf("%s %d %d %s %d", kind, tear.segment, offset, hex_of(r.head, buf[:]), r.last_epoch)
	case .No_Store:
		return "no-store"
	case .IO_Read:
		return "io-error"
	case .Bad_Header:
		return "bad-header"
	case .Base_Hash_Mismatch:
		return "base-hash-mismatch"
	case .Corrupt:
		return "corrupt"
	case .Chain_Broken:
		return "chain-broken"
	case .Epoch_Gap:
		return "epoch-gap"
	}
	return fmt.tprintf("unexpected-%v", err)
}

// --- mutations ------------------------------------------------------

@(private = "file")
mut_none :: proc(segs: [][dynamic]u8) {}

@(private = "file")
mut_cut_mid_final :: proc(segs: [][dynamic]u8) {
	seg := &segs[len(segs)-1]
	offs := offsets_of(seg[:])
	defer delete(offs)
	resize(seg, offs[len(offs)-1]+5)
}

@(private = "file")
mut_stray_bytes :: proc(segs: [][dynamic]u8) {
	append(&segs[len(segs)-1], 0x01, 0x02, 0x03)
}

@(private = "file")
mut_cut_at_boundary :: proc(segs: [][dynamic]u8) {
	seg := &segs[len(segs)-1]
	offs := offsets_of(seg[:])
	defer delete(offs)
	resize(seg, offs[len(offs)-1])
}

@(private = "file")
mut_cut_mid_first_open :: proc(segs: [][dynamic]u8) {
	seg := &segs[len(segs)-1]
	offs := offsets_of(seg[:])
	defer delete(offs)
	resize(seg, offs[0]+9)
}

@(private = "file")
mut_zero_len_frame :: proc(segs: [][dynamic]u8) {
	append(&segs[len(segs)-1], 0, 0, 0, 0, 0xAA, 0xBB, 0xCC, 0xDD)
}

@(private = "file")
mut_oversized_len :: proc(segs: [][dynamic]u8) {
	append(&segs[len(segs)-1], 0x04, 0x00, 0x00, 0x01, 0xAA, 0xBB, 0xCC, 0xDD)
}

@(private = "file")
mut_short_body :: proc(segs: [][dynamic]u8) {
	append(&segs[len(segs)-1], 0, 0, 0, 100, 0xAA, 0xBB, 0xCC, 0xDD, 1, 2, 3, 4, 5, 6)
}

@(private = "file")
mut_unknown_kind_open :: proc(segs: [][dynamic]u8) {
	append_framed(&segs[len(segs)-1], []byte{0x7F, 0xAA})
}

@(private = "file")
mut_unknown_kind_sealed :: proc(segs: [][dynamic]u8) {
	append_framed(&segs[0], []byte{0x7F, 0xAA})
}

@(private = "file")
mut_flip_sealed_body :: proc(segs: [][dynamic]u8) {
	offs := offsets_of(segs[0][:])
	defer delete(offs)
	segs[0][offs[0]+rec.FRAME_OVERHEAD+5] ~= 0x01
}

@(private = "file")
mut_flip_sealed_seal :: proc(segs: [][dynamic]u8) {
	offs := offsets_of(segs[0][:])
	defer delete(offs)
	segs[0][offs[len(offs)-1]+rec.FRAME_OVERHEAD+5] ~= 0x01
}

@(private = "file")
mut_flip_before_tail :: proc(segs: [][dynamic]u8) {
	seg := &segs[len(segs)-1]
	offs := offsets_of(seg[:])
	defer delete(offs)
	seg[offs[0]+rec.FRAME_OVERHEAD+5] ~= 0x01
}

@(private = "file")
mut_flip_final_record :: proc(segs: [][dynamic]u8) {
	seg := &segs[len(segs)-1]
	offs := offsets_of(seg[:])
	defer delete(offs)
	seg[offs[len(offs)-1]+rec.FRAME_OVERHEAD+5] ~= 0x01
}

@(private = "file")
mut_bad_magic :: proc(segs: [][dynamic]u8) {
	segs[1][0] ~= 0x01
}

@(private = "file")
mut_bad_header_crc :: proc(segs: [][dynamic]u8) {
	segs[1][30] ~= 0x01
}

@(private = "file")
mut_bad_base_hash :: proc(segs: [][dynamic]u8) {
	segs[1][40] ~= 0x01
}

@(private = "file")
reencode_header :: proc(seg: ^[dynamic]u8, mutate: proc(h: ^rec.Segment_Header)) {
	hdr, err := rec.header_decode(seg[:])
	assert(err == .None)
	mutate(&hdr)
	enc: [rec.HEADER_SIZE]u8
	rec.header_encode(hdr, &enc)
	copy(seg[:rec.HEADER_SIZE], enc[:])
}

@(private = "file")
mut_wrong_segment_no :: proc(segs: [][dynamic]u8) {
	reencode_header(&segs[1], proc(h: ^rec.Segment_Header) {h.segment = 9})
}

@(private = "file")
mut_wrong_first_epoch :: proc(segs: [][dynamic]u8) {
	reencode_header(&segs[1], proc(h: ^rec.Segment_Header) {h.first_epoch += 1})
}

@(private = "file")
mut_wrong_first_fact :: proc(segs: [][dynamic]u8) {
	reencode_header(&segs[1], proc(h: ^rec.Segment_Header) {h.first_fact_id += 1})
}

@(private = "file")
mut_future_version :: proc(segs: [][dynamic]u8) {
	seg := &segs[len(segs)-1]
	resize(seg, rec.HEADER_SIZE)
	reencode_header(seg, proc(h: ^rec.Segment_Header) {h.version = rec.FORMAT_VERSION + 1})
}

@(private = "file")
mut_husk_empty :: proc(segs: [][dynamic]u8) {
	resize(&segs[len(segs)-1], 0)
}

@(private = "file")
mut_husk_partial :: proc(segs: [][dynamic]u8) {
	resize(&segs[len(segs)-1], 40)
}

@(private = "file")
mut_husk_garbage :: proc(segs: [][dynamic]u8) {
	seg := &segs[len(segs)-1]
	resize(seg, rec.HEADER_SIZE)
	for &b in seg[:] {
		b = 0xAA
	}
}

@(private = "file")
mut_epoch_gap :: proc(segs: [][dynamic]u8) {
	ops := [1]rec.Fact_Op{{op = .Assert, s = 1, p = 2, o = 3, g = rec.DEFAULT_GRAPH}}
	body, err := rec.commit_encode(
		{epoch = proof_epoch + 2, wall = WALL, ops = ops[:]},
		proof_head, proof_epoch + 1, proof_next_term,
	)
	assert(err == .None)
	defer delete(body)
	append_framed(&segs[len(segs)-1], body)
}

@(private = "file")
mut_chain_broken_prev :: proc(segs: [][dynamic]u8) {
	bad := proof_head
	bad[0] ~= 0x01
	ops := [1]rec.Fact_Op{{op = .Assert, s = 1, p = 2, o = 3, g = rec.DEFAULT_GRAPH}}
	body, err := rec.commit_encode({epoch = proof_epoch + 1, wall = WALL, ops = ops[:]}, bad, proof_epoch, proof_next_term)
	assert(err == .None)
	defer delete(body)
	append_framed(&segs[len(segs)-1], body)
}

@(private = "file")
mut_chain_broken_hash :: proc(segs: [][dynamic]u8) {
	ops := [1]rec.Fact_Op{{op = .Assert, s = 1, p = 2, o = 3, g = rec.DEFAULT_GRAPH}}
	body, err := rec.commit_encode({epoch = proof_epoch + 1, wall = WALL, ops = ops[:]}, proof_head, proof_epoch, proof_next_term)
	assert(err == .None)
	defer delete(body)
	body[len(body)-1] ~= 0x01
	append_framed(&segs[len(segs)-1], body)
}

@(private = "file")
mut_sealed_trailing :: proc(segs: [][dynamic]u8) {
	append(&segs[0], 0x01, 0x02, 0x03)
}

@(test)
test_cross_implementation :: proc(t: ^testing.T) {
	build_proof_store(t)

	// Load the clean segments once.
	clean: [dynamic][]byte
	defer {
		for s in clean {
			delete(s)
		}
		delete(clean)
	}
	for i := 1; ; i += 1 {
		data, rerr := os.read_entire_file_from_path(fmt.tprintf("%s/%06d.rlog", STORE, i), context.allocator)
		if rerr != nil {
			break
		}
		append(&clean, data)
	}
	testing.expect_value(t, len(clean), 3)

	cases := []Corpus_Case{
		{"clean", "clean", 0, mut_none},
		{"tail-cut-mid-final-record", "torn-tail", 0, mut_cut_mid_final},
		{"tail-stray-bytes", "torn-tail", 0, mut_stray_bytes},
		{"tail-cut-at-boundary", "clean", 0, mut_cut_at_boundary},
		{"tail-cut-mid-first-open-record", "torn-tail", 0, mut_cut_mid_first_open},
		{"tail-zero-len-frame", "torn-tail", 0, mut_zero_len_frame},
		{"tail-oversized-len", "torn-tail", 0, mut_oversized_len},
		{"tail-short-body", "torn-tail", 0, mut_short_body},
		{"open-unknown-kind", "corrupt", 0, mut_unknown_kind_open},
		{"sealed-unknown-kind", "corrupt", 0, mut_unknown_kind_sealed},
		{"sealed-bitflip-body", "corrupt", 0, mut_flip_sealed_body},
		{"sealed-bitflip-seal", "corrupt", 0, mut_flip_sealed_seal},
		{"open-bitflip-before-tail", "corrupt", 0, mut_flip_before_tail},
		{"open-bitflip-final-record", "torn-tail", 0, mut_flip_final_record},
		{"header-bad-magic", "bad-header", 0, mut_bad_magic},
		{"header-bad-crc", "bad-header", 0, mut_bad_header_crc},
		{"header-base-hash", "base-hash-mismatch", 0, mut_bad_base_hash},
		{"header-wrong-segment", "bad-header", 0, mut_wrong_segment_no},
		{"header-wrong-first-epoch", "bad-header", 0, mut_wrong_first_epoch},
		{"header-wrong-first-fact", "bad-header", 0, mut_wrong_first_fact},
		{"future-version-header", "bad-header", 0, mut_future_version},
		{"husk-empty", "torn-header", 0, mut_husk_empty},
		{"husk-partial", "torn-header", 0, mut_husk_partial},
		{"husk-garbage", "torn-header", 0, mut_husk_garbage},
		{"epoch-gap", "epoch-gap", 0, mut_epoch_gap},
		{"chain-broken-prev", "chain-broken", 0, mut_chain_broken_prev},
		{"chain-broken-hash", "chain-broken", 0, mut_chain_broken_hash},
		{"no-store", "no-store", 1, mut_none},
		{"sealed-trailing-bytes", "corrupt", 0, mut_sealed_trailing},
	}

	for c in cases {
		// Materialize the case: copies of the clean segments, mutated.
		segs := make([][dynamic]u8, len(clean))
		for s, i in clean {
			append(&segs[i], ..s)
		}
		c.mutate(segs)

		for i in 1 ..= len(clean) {
			os.remove(fmt.tprintf("%s/%06d.rlog", CASE_DIR, i))
		}
		for &seg, i in segs {
			if i+1 != c.drop {
				werr := os.write_entire_file(fmt.tprintf("%s/%06d.rlog", CASE_DIR, i+1), seg[:])
				testing.expect(t, werr == nil, "the case writes")
			}
			delete(seg)
		}
		delete(segs)

		// Both implementations, one canonical line each.
		r, tear, verr := rec.verify(CASE_DIR, rec.posix_file_ops())
		odin_line := canon(r, tear, verr)

		state, stdout, stderr, perr := os.process_exec(
			{command = {"python3", PY, CASE_DIR}},
			context.allocator,
		)
		defer delete(stdout)
		defer delete(stderr)
		testing.expect(t, perr == nil && state.exited, "the python verifier runs")
		py_line := string(stdout)
		if len(py_line) > 0 && py_line[len(py_line)-1] == '\n' {
			py_line = py_line[:len(py_line)-1]
		}

		testing.expectf(
			t,
			odin_line == py_line,
			"%s: implementations disagree — odin %q, python %q (stderr %q)",
			c.name, odin_line, py_line, string(stderr),
		)
		verdict_len := len(c.verdict)
		testing.expectf(
			t,
			len(odin_line) >= verdict_len &&
			odin_line[:verdict_len] == c.verdict &&
			(len(odin_line) == verdict_len || odin_line[verdict_len] == ' '),
			"%s: expected verdict %q, both implementations said %q",
			c.name, c.verdict, odin_line,
		)
	}
}

// --- the apply-written corpus (RECORD-T-0015) ------------------------------

APPLY_STORE :: "build/proof/apply"

// verify_both runs both implementations over a directory and returns
// their canonical lines, in the temp allocator.
@(private = "file")
verify_both :: proc(t: ^testing.T, dir: string) -> (odin_line, py_line: string) {
	r, tear, verr := rec.verify(dir, rec.posix_file_ops())
	odin_line = canon(r, tear, verr)
	state, stdout, stderr, perr := os.process_exec({command = {"python3", PY, dir}}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect(t, perr == nil && state.exited, "the python verifier runs")
	line := string(stdout)
	if len(line) > 0 && line[len(line)-1] == '\n' {
		line = line[:len(line)-1]
	}
	py_line = fmt.tprintf("%s", line)
	return
}

// test_cross_implementation_apply writes a store through apply alone —
// the startup note, six epochs of every term shape with a retract and
// a named graph, rotating twice under a small target — and puts it
// under both verifiers, clean and with its tail torn. Apply's bytes
// are commit_encode's bytes by construction; this is the check that
// construction holds all the way to an implementation that shares
// nothing with this one but log.md.
@(test)
test_cross_implementation_apply :: proc(t: ^testing.T) {
	os.make_directory("build")
	os.make_directory("build/proof")
	os.make_directory(APPLY_STORE)
	for i in 1 ..= 8 {
		os.remove(fmt.tprintf("%s/%06d.rlog", APPLY_STORE, i))
	}
	os.remove(APPLY_STORE + "/HEAD")

	s: rec.Store
	_, oerr, lerr, werr := rec.store_open(&s, APPLY_STORE, rec.posix_file_ops(), target_size = 600)
	testing.expect_value(t, oerr, rec.Open_Error.None)
	testing.expect_value(t, lerr, rec.Load_Error.None)
	testing.expect_value(t, werr, rec.Writer_Error.None)
	alice, knows := rdf.IRI("http://example.org/alice"), rdf.IRI("http://example.org/knows")
	g := rdf.IRI("http://example.org/g")
	quad :: proc(s, p, o: rdf.Term, g: rdf.Graph_Label = nil) -> rdf.Quad {
		return {triple = {s, p, o}, graph = g}
	}
	// One triple term nested inside another, so the log holds a
	// definition of tag 0x07 whose own component is a definition of
	// tag 0x07.
	inner := rdf.Triple{alice, knows, rdf.Literal{lexical = "5", datatype = rdf.XSD_INTEGER}}
	outer := rdf.Triple{alice, knows, &inner}
	changesets := [?][]rec.Op{
		{{.Assert, quad(alice, knows, rdf.IRI("http://example.org/bob"))}},
		{{.Assert, quad(alice, knows, rdf.Literal{lexical = "5", datatype = rdf.XSD_INTEGER}, g)}},
		{{.Assert, quad(alice, knows, rdf.Literal{lexical = "Alice", datatype = rdf.RDF_LANG_STRING, language = "en"})}},
		{{.Retract, quad(alice, knows, rdf.IRI("http://example.org/bob"))}, {.Assert, quad(rdf.Blank_Node("b0"), knows, alice, g)}},
		{{.Assert, quad(alice, knows, rdf.Literal{lexical = "1.5", datatype = "http://www.w3.org/2001/XMLSchema#decimal"})}},
		{{.Assert, quad(alice, knows, rdf.Literal{lexical = "2024-02-29", datatype = rec.XSD_DATE}, g)}},
		// RDF 1.2's two kinds (RECORD-T-0025). A triple term defines
		// several terms for one op and its encoding references three
		// ids; a base-direction literal is the format's newest tag. Both
		// are here so the cross-implementation agreement is checked over
		// a log that actually contains them — the Python verifier reads
		// a term definition as `id u64, len u32, payload` (log.md par.
		// 5.2) and never looks at the tag, and this is what turns that
		// reading from a claim into a check.
		{{.Assert, quad(alice, knows, rdf.Literal{lexical = "Wort", datatype = rdf.RDF_DIR_LANG_STRING, language = "de-CH", direction = .LTR})}},
		{{.Assert, quad(alice, knows, &outer, g)}},
	}
	for cs, i in changesets {
		e, _, aerr := rec.apply(&s, {ops = cs, actor = alice, reason = rdf.Literal{lexical = "proof", datatype = rdf.XSD_STRING}})
		testing.expect_value(t, aerr, rec.Apply_Error{})
		testing.expect_value(t, e, rec.Epoch(i+1))
	}
	testing.expect(t, s.writer.seg_no >= 2, "the log rotated under apply")
	head := s.writer.head
	testing.expect_value(t, rec.store_close(&s), rec.Writer_Error.None)

	odin_line, py_line := verify_both(t, APPLY_STORE)
	hexbuf: [64]byte
	want := fmt.tprintf("clean %s %d", hex_of(head, hexbuf[:]), len(changesets))
	testing.expectf(t, odin_line == py_line, "apply-written clean: odin %q, python %q", odin_line, py_line)
	testing.expectf(t, odin_line == want, "apply-written clean: both said %q, want %q", odin_line, want)

	// Tear the tail: cut the last segment seven bytes short. Both must
	// see the same torn tail at the same offset, with the same head.
	last := 0
	for i := 1; ; i += 1 {
		if !os.exists(fmt.tprintf("%s/%06d.rlog", APPLY_STORE, i)) {
			break
		}
		last = i
	}
	path := fmt.tprintf("%s/%06d.rlog", APPLY_STORE, last)
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	defer delete(data)
	testing.expect(t, rerr == nil, "the tail segment reads")
	werr2 := os.write_entire_file(path, data[:len(data)-7])
	testing.expect(t, werr2 == nil, "the torn tail writes")
	odin_torn, py_torn := verify_both(t, APPLY_STORE)
	testing.expectf(t, odin_torn == py_torn, "apply-written torn: odin %q, python %q", odin_torn, py_torn)
	testing.expectf(t, len(odin_torn) > 9 && odin_torn[:9] == "torn-tail", "apply-written torn: both said %q", odin_torn)
}
