package record

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"


// The CLI's end-to-end test (RECORD-T-0005): build a known log with
// the library's writer, run the built binary over it — `make test`
// builds `build/rdfrecord` first — and assert the exact output of every
// subcommand, exit codes included. The log covers what the formats
// must render: an inlined integer, a language literal, a named graph
// and the default graph, an attributed epoch, a retract, and a derived
// assert (which this store's writer never produces in practice,
// RECORD-A-0002, but the format defines and the tool must read).

// BIN is located from this source file rather than from the working
// directory: `make tool` builds it into this repository's build/, and
// a consumer compiling this package's tests into its own binary runs
// them from its own directory, where "build/rdfrecord" is nothing at all
// (RECORD-T-0047). When it is absent the test says so and returns —
// there is no CLI to assert, which is a missing build and not a
// failing one. DIR stays relative; it is the runner's scratch.
@(private = "file")
BIN :: #directory + "../build/rdfrecord"
@(private = "file")
DIR :: "build/tool-test"

@(private = "file")
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

	w, err := writer_create(DIR, posix_file_ops())
	defer writer_destroy(&w)
	testing.expect_value(t, err, Writer_Error.None)

	terms := [4]Term_Def{
		{id = 1, enc = transmute([]u8)string("\x01http://example.org/s")},
		{id = 2, enc = transmute([]u8)string("\x01http://example.org/p")},
		{id = 3, enc = transmute([]u8)string("\x04\x02enAlice")},
		{id = 4, enc = transmute([]u8)string("\x01http://example.org/g")},
	}
	five, _ := inline_integer(5)
	ops1 := [2]Fact_Op{
		{op = .Assert, s = 1, p = 2, o = five, g = DEFAULT_GRAPH},
		{op = .Assert, s = 1, p = 2, o = 3, g = 4},
	}
	testing.expect_value(
		t,
		writer_commit(&w, {epoch = 1, wall = WALL, terms = terms[:], ops = ops1[:]}),
		Writer_Error.None,
	)
	ops2 := [2]Fact_Op{
		{op = .Retract, s = 1, p = 2, o = five, g = DEFAULT_GRAPH},
		{op = .Assert_Derived, s = 1, p = 2, o = 4, g = DEFAULT_GRAPH},
	}
	testing.expect_value(
		t,
		writer_commit(&w, {epoch = 2, wall = WALL + 1, actor = 1, ops = ops2[:]}),
		Writer_Error.None,
	)

	hex := "0123456789abcdef"
	buf: [HASH_SIZE * 2]u8
	for b, i in w.head {
		buf[i*2] = hex[b>>4]
		buf[i*2+1] = hex[b&0xF]
	}
	return fmt.aprintf("%s", string(buf[:]))
}

@(test)
test_tool :: proc(t: ^testing.T) {
	if !os.exists(BIN) {
		log.warnf("%s is absent — `make tool` builds it; skipping the CLI test", BIN)
		return
	}

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


// stats has its own store (RECORD-T-0050), because the census is about
// vocabulary and build_store's log deliberately has none: two classes
// under two different namespaces, one of each live in a different graph,
// and a retract so that "facts" is provably the live set rather than the
// asserts. --prefix is what makes the vsuite namespace separable from
// the other one.
@(private = "file")
SDIR :: "build/tool-stats-test"

@(private = "file")
build_stats_store :: proc(t: ^testing.T) -> (head_hex: string) {
	os.make_directory(SDIR)
	os.remove(SDIR + "/000001.rlog")
	os.remove(SDIR + "/HEAD")

	w, err := writer_create(SDIR, posix_file_ops())
	defer writer_destroy(&w)
	testing.expect_value(t, err, Writer_Error.None)

	terms := [6]Term_Def{
		{id = 1, enc = transmute([]u8)string("\x01https://data/vsuite.se/r1")},
		{id = 2, enc = transmute([]u8)string("\x01http://www.w3.org/1999/02/22-rdf-syntax-ns#type")},
		{id = 3, enc = transmute([]u8)string("\x01https://data/vsuite.se/ns#Risk")},
		{id = 4, enc = transmute([]u8)string("\x01https://data/vsuite.se/r2")},
		{id = 5, enc = transmute([]u8)string("\x01http://example.org/ns#Other")},
		{id = 6, enc = transmute([]u8)string("\x01https://data/vsuite.se/g1")},
	}
	ops1 := [3]Fact_Op{
		{op = .Assert, s = 1, p = 2, o = 3, g = DEFAULT_GRAPH}, // r1 a Risk
		{op = .Assert, s = 4, p = 2, o = 3, g = 6}, // r2 a Risk, in g1
		{op = .Assert, s = 1, p = 2, o = 5, g = DEFAULT_GRAPH}, // r1 a Other
	}
	testing.expect_value(
		t,
		writer_commit(&w, {epoch = 1, wall = WALL, terms = terms[:], ops = ops1[:]}),
		Writer_Error.None,
	)
	ops2 := [1]Fact_Op{
		{op = .Retract, s = 1, p = 2, o = 3, g = DEFAULT_GRAPH},
	}
	testing.expect_value(
		t,
		writer_commit(&w, {epoch = 2, wall = WALL + 1, ops = ops2[:]}),
		Writer_Error.None,
	)

	hex := "0123456789abcdef"
	buf: [HASH_SIZE * 2]u8
	for b, i in w.head {
		buf[i*2] = hex[b>>4]
		buf[i*2+1] = hex[b&0xF]
	}
	return fmt.aprintf("%s", string(buf[:]))
}

@(test)
test_tool_stats :: proc(t: ^testing.T) {
	if !os.exists(BIN) {
		log.warnf("%s is absent — `make tool` builds it; skipping the stats test", BIN)
		return
	}

	head_hex := build_stats_store(t)
	defer delete(head_hex)

	// plain: three asserts and one retract leave two live facts, in two
	// graphs, of two classes. Both censuses sort by count descending then
	// by name ascending — here every count is 1, so the order is the
	// names', and the default graph's empty rendering sorts first.
	code, out, err_out := run(t, BIN, "stats", SDIR)
	testing.expect_value(t, code, 0)
	want_plain := fmt.tprintf(
		`head:      %s
epoch:     2
segments:  1
terms:     6
epochs:    2
asserts:   3
retracts:  1
derived:   0
facts:     2

graphs: 2
         1  (default graph)
         1  <https://data/vsuite.se/g1>

classes: 2 (rdf:type objects)
         1  <http://example.org/ns#Other>
         1  <https://data/vsuite.se/ns#Risk>
`,
		head_hex,
	)
	testing.expect_value(t, out, want_plain)
	testing.expect_value(t, err_out, "")
	delete(out)
	delete(err_out)

	// --prefix restricts the class census and says what it restricted
	// from; the graph census is untouched, and so is `facts`.
	code, out, err_out = run(t, BIN, "stats", "--prefix=https://data/vsuite.se/", SDIR)
	testing.expect_value(t, code, 0)
	testing.expect(
		t,
		strings.contains(
			out,
			`classes: 1 of 2 (rdf:type objects with prefix "https://data/vsuite.se/")
         1  <https://data/vsuite.se/ns#Risk>
`,
		),
		"the prefix filters the class census and reports the total it filtered from",
	)
	testing.expect(t, strings.contains(out, "graphs: 2\n"), "the graph census is not filtered")
	delete(out)
	delete(err_out)

	// An IRI prefix written in angle brackets is the same prefix.
	code, out, err_out = run(t, BIN, "stats", "--prefix=<https://data/vsuite.se/>", SDIR)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "classes: 1 of 2"), "a bracketed prefix is unwrapped")
	delete(out)
	delete(err_out)

	// json: one object, the same figures, graph and class names as
	// N-Triples term strings and the default graph as null.
	code, out, err_out = run(t, BIN, "stats", "--format=json", SDIR)
	testing.expect_value(t, code, 0)
	// Assembled with %s rather than written as one format string: the
	// JSON is all braces, and tprintf would read every one of them.
	want_json := fmt.tprintf(
		"%s%s%s",
		`{"head":"`,
		head_hex,
		`","epoch":2,"segments":1,"terms":6,"epochs":2,"ops":{"assert":3,"retract":1,"derived":0},"facts":2,"torn":false,"anomalies":{"duplicate_assert":0,"retract_not_live":0},"graphs":[{"graph":null,"facts":1},{"graph":"<https://data/vsuite.se/g1>","facts":1}],"classes":{"prefix":null,"distinct":2,"distinct_total":2,"counts":[{"class":"<http://example.org/ns#Other>","instances":1},{"class":"<https://data/vsuite.se/ns#Risk>","instances":1}]}}
`,
	)
	testing.expect_value(t, out, want_json)
	testing.expect_value(t, err_out, "")
	delete(out)
	delete(err_out)

	// A torn tail: the census is of the durable prefix, reported on
	// stderr with exit 2, exactly as verify and dump report it.
	f, oerr := os.open(SDIR + "/000001.rlog", {.Write})
	testing.expect(t, oerr == nil, "the segment opens for injury")
	_, _ = os.seek(f, 0, .End)
	junk := [3]u8{1, 2, 3}
	_, _ = os.write(f, junk[:])
	os.close(f)

	code, out, err_out = run(t, BIN, "stats", SDIR)
	testing.expect_value(t, code, 2)
	testing.expect(t, strings.contains(out, "torn:      yes"), "the plain output says so")
	testing.expect(t, strings.contains(out, "facts:     2"), "the durable prefix still counts")
	testing.expect(t, len(err_out) > 0, "the tear is reported")
	delete(out)
	delete(err_out)

	// A missing store, and an unknown flag: exit 1.
	code, out, err_out = run(t, BIN, "stats", "build/no-such-store")
	testing.expect_value(t, code, 1)
	delete(out)
	delete(err_out)
	code, out, err_out = run(t, BIN, "stats", "--frobnicate", SDIR)
	testing.expect_value(t, code, 1)
	delete(out)
	delete(err_out)
}
