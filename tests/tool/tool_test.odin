package tool_test

import "core:fmt"
import "core:os"
import "core:testing"

import rec "../../record"

// The CLI's end-to-end test (RECORD-T-0005): build a known log with
// the library's writer, run the built binary over it — `make test`
// builds `build/record` first — and assert the exact output of every
// subcommand, exit codes included. The log covers what the formats
// must render: an inlined integer, a language literal, a named graph
// and the default graph, an attributed epoch, a retract, and a derived
// assert (which this store's writer never produces in practice,
// RECORD-A-0002, but the format defines and the tool must read).

BIN :: "build/record"
DIR :: "build/tool-test"

WALL :: u64(1_700_000_000_000_000_000)

@(private)
run :: proc(t: ^testing.T, args: ..string) -> (code: int, out: string, err_out: string) {
	state, stdout, stderr, err := os.process_exec({command = args}, context.allocator)
	testing.expect(t, err == nil, "the binary runs")
	testing.expect(t, state.exited, "the binary exits")
	return state.exit_code, string(stdout), string(stderr)
}

@(private)
build_store :: proc(t: ^testing.T) -> (head_hex: string) {
	os.make_directory(DIR)
	os.remove(DIR + "/000001.rlog")
	os.remove(DIR + "/HEAD")

	w, err := rec.writer_create(DIR, rec.posix_file_ops())
	defer rec.writer_destroy(&w)
	testing.expect_value(t, err, rec.Writer_Error.None)

	terms := [4]rec.Term_Def{
		{id = 1, enc = transmute([]u8)string("\x01http://example.org/s")},
		{id = 2, enc = transmute([]u8)string("\x01http://example.org/p")},
		{id = 3, enc = transmute([]u8)string("\x04\x02enAlice")},
		{id = 4, enc = transmute([]u8)string("\x01http://example.org/g")},
	}
	five, _ := rec.inline_integer(5)
	ops1 := [2]rec.Fact_Op{
		{op = .Assert, s = 1, p = 2, o = five, g = rec.DEFAULT_GRAPH},
		{op = .Assert, s = 1, p = 2, o = 3, g = 4},
	}
	testing.expect_value(
		t,
		rec.writer_commit(&w, {epoch = 1, wall = WALL, terms = terms[:], ops = ops1[:]}),
		rec.Writer_Error.None,
	)
	ops2 := [2]rec.Fact_Op{
		{op = .Retract, s = 1, p = 2, o = five, g = rec.DEFAULT_GRAPH},
		{op = .Assert_Derived, s = 1, p = 2, o = 4, g = rec.DEFAULT_GRAPH},
	}
	testing.expect_value(
		t,
		rec.writer_commit(&w, {epoch = 2, wall = WALL + 1, actor = 1, ops = ops2[:]}),
		rec.Writer_Error.None,
	)

	hex := "0123456789abcdef"
	buf: [rec.HASH_SIZE * 2]u8
	for b, i in w.head {
		buf[i*2] = hex[b>>4]
		buf[i*2+1] = hex[b&0xF]
	}
	return fmt.aprintf("%s", string(buf[:]))
}

@(test)
test_tool :: proc(t: ^testing.T) {
	head_hex := build_store(t)
	defer delete(head_hex)

	// verify: clean store, exit 0, the derived head and last epoch.
	code, out, err_out := run(t, BIN, "verify", DIR)
	testing.expect_value(t, code, 0)
	want_verify := fmt.tprintf("head:     %s\nepoch:    2\nsegments: 1\n", head_hex)
	testing.expect_value(t, out, want_verify)
	testing.expect_value(t, err_out, "")
	delete(out)
	delete(err_out)

	// head: derived and advisory agree — no warning.
	code, out, err_out = run(t, BIN, "head", DIR)
	testing.expect_value(t, code, 0)
	testing.expect_value(t, out, fmt.tprintf("%s 2\n", head_hex))
	testing.expect_value(t, err_out, "")
	delete(out)
	delete(err_out)

	// dump nquads: asserts are plain statements; the retract and the
	// derived assert are events behind comment markers.
	code, out, err_out = run(t, BIN, "dump", DIR)
	testing.expect_value(t, code, 0)
	want_nq :=
		`<http://example.org/s> <http://example.org/p> "5"^^<http://www.w3.org/2001/XMLSchema#integer> .
<http://example.org/s> <http://example.org/p> "Alice"@en <http://example.org/g> .
# retract: <http://example.org/s> <http://example.org/p> "5"^^<http://www.w3.org/2001/XMLSchema#integer> .
# assert-derived: <http://example.org/s> <http://example.org/p> <http://example.org/g> .
`
	testing.expect_value(t, out, want_nq)
	testing.expect_value(t, err_out, "")
	delete(out)
	delete(err_out)

	// dump json: one op per line; wall as a decimal string; actor a
	// term object on the attributed epoch, null on the other.
	code, out, err_out = run(t, BIN, "dump", "--format=json", DIR)
	testing.expect_value(t, code, 0)
	want_json :=
		`{"op":"assert","epoch":1,"wall":"1700000000000000000","actor":null,"reason":null,"s":{"iri":"http://example.org/s"},"p":{"iri":"http://example.org/p"},"o":{"lit":"5","dt":"http://www.w3.org/2001/XMLSchema#integer"},"g":null}
{"op":"assert","epoch":1,"wall":"1700000000000000000","actor":null,"reason":null,"s":{"iri":"http://example.org/s"},"p":{"iri":"http://example.org/p"},"o":{"lit":"Alice","dt":"http://www.w3.org/1999/02/22-rdf-syntax-ns#langString","lang":"en"},"g":{"iri":"http://example.org/g"}}
{"op":"retract","epoch":2,"wall":"1700000000000000001","actor":{"iri":"http://example.org/s"},"reason":null,"s":{"iri":"http://example.org/s"},"p":{"iri":"http://example.org/p"},"o":{"lit":"5","dt":"http://www.w3.org/2001/XMLSchema#integer"},"g":null}
{"op":"assert-derived","epoch":2,"wall":"1700000000000000001","actor":{"iri":"http://example.org/s"},"reason":null,"s":{"iri":"http://example.org/s"},"p":{"iri":"http://example.org/p"},"o":{"iri":"http://example.org/g"},"g":null}
`
	testing.expect_value(t, out, want_json)
	testing.expect_value(t, err_out, "")
	delete(out)
	delete(err_out)

	// A torn tail: stray bytes after the last record. verify reports
	// it on stderr, exits 2, and repairs nothing — the tools are
	// read-only.
	f, oerr := os.open(DIR + "/000001.rlog", {.Write})
	testing.expect(t, oerr == nil, "the segment opens for injury")
	_, _ = os.seek(f, 0, .End)
	junk := [3]u8{1, 2, 3}
	_, _ = os.write(f, junk[:])
	os.close(f)

	code, out, err_out = run(t, BIN, "verify", DIR)
	testing.expect_value(t, code, 2)
	testing.expect_value(t, out, want_verify) // the durable head is unchanged
	testing.expect(t, len(err_out) > 0, "the tear is reported")
	delete(out)
	delete(err_out)

	code, out, err_out = run(t, BIN, "verify", DIR)
	testing.expect_value(t, code, 2)
	delete(out)
	delete(err_out)

	// An unknown subcommand or a missing store: exit 1.
	code, out, err_out = run(t, BIN, "frobnicate", DIR)
	testing.expect_value(t, code, 1)
	delete(out)
	delete(err_out)
	code, out, err_out = run(t, BIN, "verify", "build/no-such-store")
	testing.expect_value(t, code, 1)
	delete(out)
	delete(err_out)
}
