package ingest_test

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import rec "../../record"
import ingest "../../record/ingest"
import "rdf:rdf"

// The ingest subpackage's tests (RECORD-T-0017): every procedure over
// the parser repo's vendored W3C inputs for its format — reached by
// reference through the sibling checkout, never copied (provenance:
// odin-rdf-parser/tests/w3c/README.md, w3c/rdf-tests at 767554e) — the
// blank-prefix scoping, the retract shape, a triple term refused where
// the stance put the refusal, and the dump round trip under the Python
// verifier.

W3C :: "../odin-rdf-parser/tests/w3c"

@(private)
open_mem :: proc(t: ^testing.T, s: ^rec.Store, fs: ^rec.Mem_FS, loc := #caller_location) {
	_, err, lerr, werr := rec.store_open(s, "store", rec.mem_file_ops(fs))
	testing.expect_value(t, err, rec.Open_Error.None, loc = loc)
	testing.expect_value(t, lerr, rec.Load_Error.None, loc = loc)
	testing.expect_value(t, werr, rec.Writer_Error.None, loc = loc)
}

@(private)
live_count :: proc(s: ^rec.Store, epoch: rec.Epoch) -> (n: int) {
	snap, err := rec.store_at(s, epoch)
	if err != .None {
		return -1
	}
	defer rec.snapshot_release(&snap)
	sc := rec.range_iter(rec.snapshot_match(snap, {}), {origin = .Any, scope = .All})
	for _ in rec.scan_next(&sc) {
		n += 1
	}
	return
}

@(private)
exists :: proc(s: ^rec.Store, epoch: rec.Epoch, q: rdf.Quad) -> bool {
	snap, err := rec.store_at(s, epoch)
	if err != .None {
		return false
	}
	defer rec.snapshot_release(&snap)
	p: rec.Pattern
	ok: bool
	if p.s, ok = rec.snapshot_resolve(snap, q.subject); !ok {
		return false
	}
	if p.p, ok = rec.snapshot_resolve(snap, q.predicate); !ok {
		return false
	}
	if p.o, ok = rec.snapshot_resolve(snap, q.object); !ok {
		return false
	}
	p.g = rec.MATCH_DEFAULT_GRAPH
	switch g in q.graph {
	case rdf.IRI:
		if p.g, ok = rec.snapshot_resolve(snap, g); !ok {
			return false
		}
	case rdf.Blank_Node:
		if p.g, ok = rec.snapshot_resolve(snap, g); !ok {
			return false
		}
	}
	return rec.snapshot_exists(snap, p, {origin = .Any, scope = .All})
}

// term_has_blank recurses into a triple term (RECORD-T-0024). RDF 1.2's
// reifying syntax puts blank nodes inside them, and a document whose
// only blank nodes are there would otherwise be taken for ground and
// compared label for label against a result that names them differently.
// Carried names what the rdf12 sweep counts: the two term kinds
// RECORD-I-0004 built, so the log line can say the suite exercised them
// rather than merely ran.
@(private = "file")
Carried :: enum {
	Triple,
	Dir_Lang,
}

@(private = "file")
ops_carry :: proc(ops: []rec.Op, what: Carried) -> bool {
	for op in ops {
		if term_carries(op.subject, what) || term_carries(op.object, what) {
			return true
		}
	}
	return false
}

@(private = "file")
term_carries :: proc(t: rdf.Term, what: Carried) -> bool {
	switch v in t {
	case rdf.Literal:
		return what == .Dir_Lang && v.direction != .None
	case ^rdf.Triple:
		if what == .Triple {
			return true
		}
		return term_carries(v.subject, what) || term_carries(v.predicate, what) || term_carries(v.object, what)
	case rdf.IRI, rdf.Blank_Node:
		return false
	}
	return false
}

@(private)
term_has_blank :: proc(t: rdf.Term) -> bool {
	switch v in t {
	case rdf.Blank_Node:
		return true
	case ^rdf.Triple:
		return term_has_blank(v.subject) || term_has_blank(v.predicate) || term_has_blank(v.object)
	case rdf.IRI, rdf.Literal:
		return false
	}
	return false
}

@(private)
has_blank :: proc(ops: []rec.Op) -> bool {
	for op in ops {
		if term_has_blank(op.subject) || term_has_blank(op.object) {
			return true
		}
		if _, b := op.graph.(rdf.Blank_Node); b {
			return true
		}
	}
	return false
}

@(private)
read :: proc(t: ^testing.T, path: string) -> []byte {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	testing.expectf(t, err == nil, "%s reads", path)
	return data
}

// Dataset_Ingest is the per-format entry for the suite sweep: the
// document's own procedure and its line-based result format's.
@(private)
Suite :: struct {
	dir:     string,
	doc_ext: string, // ".ttl" or ".trig"
	res_ext: string, // ".nt" or ".nq"
	base:    string,
	quads:   bool, // trig/nquads, else turtle/ntriples
}

// sweep_suite runs one eval suite: every document with a result
// sibling is a positive eval test — both ingest, they yield the same
// number of ops, and when neither uses blank nodes the same statements
// (applied into two stores, each statement of one is live in the
// other); every document without a sibling is a syntax test, positive
// unless its name says bad, in which case the error carries a position.
@(private)
sweep_suite :: proc(t: ^testing.T, su: Suite) -> (pairs, ground, syntax_ok, syntax_bad, applied, triples, dirs: int) {
	entries, derr := os.read_all_directory_by_path(su.dir, context.allocator)
	testing.expectf(t, derr == nil, "%s lists", su.dir)
	defer os.file_info_slice_delete(entries, context.allocator)
	for e in entries {
		if !strings.has_suffix(e.name, su.doc_ext) {
			continue
		}
		if e.name == "test-38.ttl" {
			// Not in manifest.ttl: a stray librdf regression file whose
			// literal is a surrogate-pair \u escape, which the parser
			// rightly refuses (UCHAR must be a scalar value). The sibling
			// heuristic below would take it for a positive eval test.
			continue
		}
		doc_path := fmt.tprintf("%s/%s", su.dir, e.name)
		res_path := fmt.tprintf("%s/%s%s", su.dir, e.name[:len(e.name)-len(su.doc_ext)], su.res_ext)
		doc := read(t, doc_path)
		defer delete(doc)
		base := fmt.tprintf("%s%s", su.base, e.name)
		ops: []rec.Op
		err: ingest.Error
		if su.quads {
			ops, err = ingest.trig(doc, context.allocator, base = base)
		} else {
			ops, err = ingest.turtle(doc, nil, context.allocator, base = base)
		}
		defer ingest.ops_destroy(ops, context.allocator)

		if !os.exists(res_path) {
			if strings.contains(e.name, "bad") {
				// The position is the parser's; its column can come out
				// negative on an unterminated long string (a parser-side
				// quirk, noted in RECORD-T-0017), so the line is what is
				// asserted here.
				testing.expectf(t, err.kind == .Syntax && err.syntax.line >= 1, "%s: a negative syntax test refuses with a position, got %v", e.name, err)
				syntax_bad += 1
			} else {
				testing.expectf(t, err.kind == .None, "%s: a positive syntax test ingests, got %v", e.name, err)
				syntax_ok += 1
			}
			continue
		}
		testing.expectf(t, err.kind == .None, "%s: the document ingests, got %v", e.name, err)
		res := read(t, res_path)
		defer delete(res)
		rops: []rec.Op
		rerr: ingest.Error
		if su.quads {
			rops, rerr = ingest.nquads(res, context.allocator)
		} else {
			rops, rerr = ingest.ntriples(res, nil, context.allocator)
		}
		defer ingest.ops_destroy(rops, context.allocator)
		testing.expectf(t, rerr.kind == .None, "%s: the result ingests, got %v", e.name, rerr)
		testing.expectf(t, len(ops) == len(rops), "%s: %d ops from the document, %d from the result", e.name, len(ops), len(rops))
		pairs += 1
		if ops_carry(ops, .Triple) {
			triples += 1
		}
		if ops_carry(ops, .Dir_Lang) {
			dirs += 1
		}
		if len(ops) == 0 {
			continue
		}
		// Every document commits, ground or not (RECORD-T-0024). The
		// ground check below needs blank-node-free documents because it
		// compares labels; *applying* one needs nothing of the sort, and
		// a triple term reaching apply is the point of the rdf12 sweep —
		// most of those documents carry a blank-node reifier, so gating
		// apply on groundness would have swept straight past the
		// capability this initiative built.
		{
			one_fs: rec.Mem_FS
			defer rec.mem_fs_destroy(&one_fs)
			one: rec.Store
			open_mem(t, &one, &one_fs)
			defer rec.store_close(&one)
			for op in ops {
				single := [1]rec.Op{op}
				_, _, aerr := rec.apply(&one, {ops = single[:]})
				testing.expectf(t, aerr.kind == .None || aerr.kind == .Already_Live, "%s: apply %v", e.name, aerr)
			}
			applied += 1
		}
		if has_blank(ops) || has_blank(rops) {
			continue
		}
		// Ground documents: the same statements, as a set. Two stores,
		// because a document may repeat a statement and the store is a
		// set — assert through apply one op at a time, tolerating
		// Already_Live for the repeats.
		a_fs, b_fs: rec.Mem_FS
		defer rec.mem_fs_destroy(&a_fs)
		defer rec.mem_fs_destroy(&b_fs)
		a, b: rec.Store
		open_mem(t, &a, &a_fs)
		open_mem(t, &b, &b_fs)
		defer rec.store_close(&a)
		defer rec.store_close(&b)
		for st, i in ([2]^rec.Store{&a, &b}) {
			src := ops if i == 0 else rops
			for op in src {
				one := [1]rec.Op{op}
				_, _, aerr := rec.apply(st, {ops = one[:]})
				testing.expectf(t, aerr.kind == .None || aerr.kind == .Already_Live, "%s: apply %v", e.name, aerr)
			}
		}
		testing.expectf(t, live_count(&a, a.published) == live_count(&b, b.published), "%s: the two graphs differ in size", e.name)
		for op in ops {
			testing.expectf(t, exists(&b, b.published, op.quad), "%s: a document statement is missing from the result", e.name)
		}
		ground += 1
	}
	return
}

@(test)
test_ingest_w3c_turtle :: proc(t: ^testing.T) {
	pairs, ground, ok, bad, _, _, _ := sweep_suite(t, {dir = W3C + "/rdf11-turtle", doc_ext = ".ttl", res_ext = ".nt", base = "https://w3c.github.io/rdf-tests/rdf/rdf11/rdf-turtle/"})
	log.infof("rdf11-turtle: %d eval pairs (%d ground, compared as sets), %d positive and %d negative syntax documents", pairs, ground, ok, bad)
	testing.expectf(t, pairs > 100 && ground > 50 && ok > 50 && bad > 50, "the suite was swept: %d eval pairs (%d ground), %d positive and %d negative syntax", pairs, ground, ok, bad)
}

@(test)
test_ingest_w3c_trig :: proc(t: ^testing.T) {
	pairs, ground, ok, bad, _, _, _ := sweep_suite(t, {dir = W3C + "/rdf11-trig", doc_ext = ".trig", res_ext = ".nq", base = "https://w3c.github.io/rdf-tests/rdf/rdf11/rdf-trig/", quads = true})
	log.infof("rdf11-trig: %d eval pairs (%d ground, compared as sets), %d positive and %d negative syntax documents", pairs, ground, ok, bad)
	testing.expectf(t, pairs > 100 && ground > 50 && ok > 50 && bad > 50, "the suite was swept: %d eval pairs (%d ground), %d positive and %d negative syntax", pairs, ground, ok, bad)
}

@(test)
test_ingest_w3c_rdf12_turtle :: proc(t: ^testing.T) {
	// RECORD-T-0024's real verdict: the same end-to-end sweep the rdf11
	// suites get — ingest, apply, read back, compare against the suite's
	// own expected result — over documents carrying RDF 1.2's triple
	// terms. No vendoring; the bases are odin-rdf-parser's own harness's
	// (tests/w3c/harness/harness_test.odin), which carry a trailing
	// eval/ the rdf11 pattern does not.
	pairs, ground, ok, bad, applied, triples, dirs := sweep_suite(t, {dir = W3C + "/rdf12-turtle-eval", doc_ext = ".ttl", res_ext = ".nt", base = "https://w3c.github.io/rdf-tests/rdf/rdf12/rdf-turtle/eval/"})
	log.infof(
		"rdf12-turtle-eval: %d eval pairs (%d ground, compared as sets), %d applied, %d carrying a triple term, %d a base direction; %d positive and %d negative syntax documents",
		pairs, ground, applied, triples, dirs, ok, bad,
	)
	// 29 is odin-rdf-parser's own harness's pinned entry count for this
	// suite, and the counts below say the sweep exercised what this
	// initiative built rather than merely walking past it.
	testing.expectf(t, pairs >= 29, "the suite was swept: %d eval pairs (%d ground), %d positive and %d negative syntax", pairs, ground, ok, bad)
	testing.expectf(t, triples > 0 && applied >= pairs, "%d of %d documents carried a triple term, %d applied", triples, pairs, applied)
}

@(test)
test_ingest_w3c_rdf12_trig :: proc(t: ^testing.T) {
	pairs, ground, ok, bad, applied, triples, dirs := sweep_suite(t, {dir = W3C + "/rdf12-trig-eval", doc_ext = ".trig", res_ext = ".nq", base = "https://w3c.github.io/rdf-tests/rdf/rdf12/rdf-trig/eval/", quads = true})
	log.infof(
		"rdf12-trig-eval: %d eval pairs (%d ground, compared as sets), %d applied, %d carrying a triple term, %d a base direction; %d positive and %d negative syntax documents",
		pairs, ground, applied, triples, dirs, ok, bad,
	)
	testing.expectf(t, pairs >= 25, "the suite was swept: %d eval pairs (%d ground), %d positive and %d negative syntax", pairs, ground, ok, bad)
	testing.expectf(t, triples > 0 && applied >= pairs, "%d of %d documents carried a triple term, %d applied", triples, pairs, applied)
}

@(test)
test_ingest_w3c_rdf12_base_direction :: proc(t: ^testing.T) {
	// Base direction has no W3C *eval* directory — it is a syntax suite
	// everywhere, which is exactly what RECORD-I-0004 said when it called
	// this half "a latent limit removed rather than an evaluation
	// directory unblocked". The rdf12 eval sweep therefore reports zero
	// base-direction documents, and that number is honest rather than a
	// gap: these eight are where the vendored suites keep them.
	//
	// Parse-only upstream; here they ingest, apply and resolve, so the
	// term kind is exercised against W3C documents rather than only
	// against this repository's own fixtures.
	Doc :: struct {
		path:  string,
		lines: bool, // an N-Triples/N-Quads document rather than turtle/trig
		quads: bool,
	}
	docs := [8]Doc {
		{W3C + "/rdf12-turtle-syntax/nt-ttl12-langdir-1.ttl", false, false},
		{W3C + "/rdf12-turtle-syntax/nt-ttl12-langdir-2.ttl", false, false},
		{W3C + "/rdf12-trig-syntax/trig12-base-1.trig", false, true},
		{W3C + "/rdf12-trig-syntax/trig12-base-2.trig", false, true},
		{W3C + "/rdf12-ntriples-syntax/ntriples-langdir-1.nt", true, false},
		{W3C + "/rdf12-ntriples-syntax/ntriples-langdir-2.nt", true, false},
		{W3C + "/rdf12-nquads-syntax/nquads-langdir-1.nq", true, true},
		{W3C + "/rdf12-nquads-syntax/nquads-langdir-2.nq", true, true},
	}
	directed := 0
	for d in docs {
		doc := read(t, d.path)
		defer delete(doc)
		ops: []rec.Op
		err: ingest.Error
		switch {
		case d.lines && d.quads:
			ops, err = ingest.nquads(doc, context.allocator)
		case d.lines:
			ops, err = ingest.ntriples(doc, nil, context.allocator)
		case d.quads:
			ops, err = ingest.trig(doc, context.allocator, base = "http://example/")
		case:
			ops, err = ingest.turtle(doc, nil, context.allocator, base = "http://example/")
		}
		defer ingest.ops_destroy(ops, context.allocator)
		testing.expectf(t, err.kind == .None, "%s: ingests, got %v", d.path, err)
		if !ops_carry(ops, .Dir_Lang) {
			continue
		}
		directed += 1

		fs: rec.Mem_FS
		defer rec.mem_fs_destroy(&fs)
		st: rec.Store
		open_mem(t, &st, &fs)
		defer rec.store_close(&st)
		for op in ops {
			one := [1]rec.Op{op}
			_, _, aerr := rec.apply(&st, {ops = one[:]})
			testing.expectf(t, aerr.kind == .None || aerr.kind == .Already_Live, "%s: apply %v", d.path, aerr)
		}
		// Every directional literal in the document is a term of the
		// store afterwards — resolvable, and a literal to snapshot_kind.
		snap, serr := rec.store_latest(&st)
		testing.expect_value(t, serr, rec.Snapshot_Error.None)
		defer rec.snapshot_release(&snap)
		for op in ops {
			lit, is_lit := op.object.(rdf.Literal)
			if !is_lit || lit.direction == .None {
				continue
			}
			id, found := rec.snapshot_resolve(snap, lit)
			testing.expectf(t, found, "%s: a directional literal resolves", d.path)
			testing.expect_value(t, rec.snapshot_kind(snap, id), rec.Term_Kind.Literal)
		}
	}
	log.infof("rdf12 base direction: %d of %d vendored documents carry a directional literal, all applied", directed, len(docs))
	testing.expectf(t, directed == len(docs), "every listed document carries one: %d of %d", directed, len(docs))
}

@(test)
test_ingest_w3c_lines :: proc(t: ^testing.T) {
	// N-Triples and N-Quads: syntax suites — positive unless bad.
	for su in ([2]Suite{{dir = W3C + "/rdf11-ntriples", doc_ext = ".nt"}, {dir = W3C + "/rdf11-nquads", doc_ext = ".nq", quads = true}}) {
		entries, derr := os.read_all_directory_by_path(su.dir, context.allocator)
		testing.expectf(t, derr == nil, "%s lists", su.dir)
		defer os.file_info_slice_delete(entries, context.allocator)
		ok_n, bad_n := 0, 0
		for e in entries {
			if !strings.has_suffix(e.name, su.doc_ext) {
				continue
			}
			doc := read(t, fmt.tprintf("%s/%s", su.dir, e.name))
			defer delete(doc)
			ops: []rec.Op
			err: ingest.Error
			if su.quads {
				ops, err = ingest.nquads(doc, context.allocator)
			} else {
				ops, err = ingest.ntriples(doc, nil, context.allocator)
			}
			defer ingest.ops_destroy(ops, context.allocator)
			if strings.contains(e.name, "bad") {
				testing.expectf(t, err.kind == .Syntax && err.syntax.line >= 1, "%s: refuses with a position, got %v", e.name, err)
				bad_n += 1
			} else {
				testing.expectf(t, err.kind == .None, "%s: ingests, got %v", e.name, err)
				ok_n += 1
			}
		}
		log.infof("%s: %d positive and %d negative syntax documents", su.dir, ok_n, bad_n)
		testing.expectf(t, ok_n > 20 && bad_n > 10, "%s swept: %d positive, %d negative", su.dir, ok_n, bad_n)
	}
}

@(test)
test_ingest_blank_prefix :: proc(t: ^testing.T) {
	fs: rec.Mem_FS
	defer rec.mem_fs_destroy(&fs)
	s: rec.Store
	open_mem(t, &s, &fs)
	defer rec.store_close(&s)

	doc := transmute([]byte)string("_:b0 <http://ex/p> <http://ex/o> .\n")
	a, aerr := ingest.ntriples(doc, nil, context.allocator, blank_prefix = "upload-1/")
	b, berr := ingest.ntriples(doc, nil, context.allocator, blank_prefix = "upload-2/")
	c, cerr := ingest.ntriples(doc, nil, context.allocator, blank_prefix = "upload-1/")
	d, derr := ingest.ntriples(doc, nil, context.allocator)
	defer ingest.ops_destroy(a, context.allocator)
	defer ingest.ops_destroy(b, context.allocator)
	defer ingest.ops_destroy(c, context.allocator)
	defer ingest.ops_destroy(d, context.allocator)
	testing.expect(t, aerr.kind == .None && berr.kind == .None && cerr.kind == .None && derr.kind == .None, "all four ingest")
	testing.expect_value(t, a[0].subject, rdf.Term(rdf.Blank_Node("upload-1/b0")))
	testing.expect_value(t, d[0].subject, rdf.Term(rdf.Blank_Node("b0")))

	// Different prefixes: two nodes. The same prefix: one node — the
	// second apply is the same quad, Already_Live.
	_, _, e1 := rec.apply(&s, {ops = a})
	_, _, e2 := rec.apply(&s, {ops = b})
	testing.expect_value(t, e1, rec.Apply_Error{})
	testing.expect_value(t, e2, rec.Apply_Error{})
	testing.expect_value(t, live_count(&s, 2), 2)
	_, _, e3 := rec.apply(&s, {ops = c})
	testing.expect_value(t, e3, rec.Apply_Error{.Already_Live, 0})
	_, _, e4 := rec.apply(&s, {ops = d})
	testing.expect_value(t, e4, rec.Apply_Error{})
	testing.expect_value(t, live_count(&s, 3), 3)
}

@(test)
test_ingest_repeated_statement_is_one_op :: proc(t: ^testing.T) {
	// RECORD-T-0019: a document denotes a graph, a graph is a set, and a
	// statement written twice is stated once — the loaders emit the set,
	// because apply would refuse the second assert as Already_Live and a
	// valid document could not be loaded. The shape is the W3C SHACL
	// suite's own: a predicate repeated inside one object list.
	fs: rec.Mem_FS
	defer rec.mem_fs_destroy(&fs)
	s: rec.Store
	open_mem(t, &s, &fs)
	defer rec.store_close(&s)

	doc := transmute([]byte)string(`
@prefix ex: <http://example.org/> .
ex:s ex:p ex:a, ex:b, ex:a ; ex:q _:n, _:n .
ex:s ex:p ex:b .
`)
	on, oerr := ingest.turtle(doc, nil, context.allocator, blank_prefix = "d_")
	defer ingest.ops_destroy(on, context.allocator)
	testing.expect_value(t, oerr.kind, ingest.Error_Kind.None)
	// Three distinct statements, each at its first position, order kept.
	testing.expect_value(t, len(on), 3)
	if len(on) == 3 {
		testing.expect_value(t, on[0].object, rdf.Term(rdf.IRI("http://example.org/a")))
		testing.expect_value(t, on[1].object, rdf.Term(rdf.IRI("http://example.org/b")))
		testing.expect_value(t, on[2].object, rdf.Term(rdf.Blank_Node("d_n")))
	}
	e1, _, a1 := rec.apply(&s, {ops = on})
	testing.expect_value(t, a1, rec.Apply_Error{})
	testing.expect_value(t, live_count(&s, e1), 3)

	// The retract form is the set too: unloading the document retracts
	// each statement once.
	off, ferr := ingest.turtle(doc, nil, context.allocator, kind = .Retract, blank_prefix = "d_")
	defer ingest.ops_destroy(off, context.allocator)
	testing.expect_value(t, ferr.kind, ingest.Error_Kind.None)
	testing.expect_value(t, len(off), 3)
	e2, _, a2 := rec.apply(&s, {ops = off})
	testing.expect_value(t, a2, rec.Apply_Error{})
	testing.expect_value(t, live_count(&s, e2), 0)

	// Identity is the quad's: the same triple in two graphs is two
	// statements, and the third line repeats the first.
	nq := transmute([]byte)string(
		"<http://ex/s> <http://ex/p> <http://ex/o> <http://ex/g1> .\n" +
		"<http://ex/s> <http://ex/p> <http://ex/o> <http://ex/g2> .\n" +
		"<http://ex/s> <http://ex/p> <http://ex/o> <http://ex/g1> .\n",
	)
	g, gerr := ingest.nquads(nq, context.allocator)
	defer ingest.ops_destroy(g, context.allocator)
	testing.expect_value(t, gerr.kind, ingest.Error_Kind.None)
	testing.expect_value(t, len(g), 2)

	// Two documents are two sets: the same statement in each is still
	// Already_Live at the second apply — dedup is per document, and the
	// changeset rule is apply's.
	again, rerr := ingest.turtle(doc, nil, context.allocator, blank_prefix = "d_")
	defer ingest.ops_destroy(again, context.allocator)
	testing.expect_value(t, rerr.kind, ingest.Error_Kind.None)
	both := make([]rec.Op, 6)
	defer delete(both)
	copy(both[:3], on)
	copy(both[3:], again)
	_, _, a3 := rec.apply(&s, {ops = both})
	testing.expect_value(t, a3, rec.Apply_Error{.Already_Live, 3})
}

@(test)
test_ingest_retract_unloads :: proc(t: ^testing.T) {
	fs: rec.Mem_FS
	defer rec.mem_fs_destroy(&fs)
	s: rec.Store
	open_mem(t, &s, &fs)
	defer rec.store_close(&s)

	doc := transmute([]byte)string(`
@prefix ex: <http://example.org/> .
ex:alice a ex:Person ; ex:name "Alice"@en ; ex:age 42 ; ex:knows [ ex:name "Bob" ] .
`)
	on, oerr := ingest.turtle(doc, rdf.IRI("http://example.org/g"), context.allocator, blank_prefix = "doc/")
	off, ferr := ingest.turtle(doc, rdf.IRI("http://example.org/g"), context.allocator, kind = .Retract, blank_prefix = "doc/")
	defer ingest.ops_destroy(on, context.allocator)
	defer ingest.ops_destroy(off, context.allocator)
	testing.expect(t, oerr.kind == .None && ferr.kind == .None, "both ingest")
	testing.expect_value(t, len(on), 5)
	testing.expect_value(t, len(off), 5)
	for op in off {
		testing.expect_value(t, op.kind, rec.Op_Kind.Retract)
	}
	e1, _, a1 := rec.apply(&s, {ops = on})
	testing.expect_value(t, a1, rec.Apply_Error{})
	testing.expect_value(t, live_count(&s, e1), 5)
	e2, _, a2 := rec.apply(&s, {ops = off})
	testing.expect_value(t, a2, rec.Apply_Error{})
	testing.expect_value(t, live_count(&s, e2), 0)
	testing.expect_value(t, live_count(&s, e1), 5)
	for op in on {
		testing.expect(t, exists(&s, e1, op.quad), "intact at the earlier epoch")
		testing.expect(t, !exists(&s, e2, op.quad), "gone at head")
	}
}

@(test)
test_ingest_triple_term_commits :: proc(t: ^testing.T) {
	// Was test_ingest_triple_term_refused_at_apply, and inverted by
	// RECORD-T-0023 rather than deleted: it is the most precise
	// statement in this repository of what the gap was, so it is now the
	// most precise statement that the gap is closed. Same document, same
	// three ops, same op carrying the triple term — and it commits.
	fs: rec.Mem_FS
	defer rec.mem_fs_destroy(&fs)
	s: rec.Store
	open_mem(t, &s, &fs)
	defer rec.store_close(&s)
	doc := read(t, W3C + "/rdf12-turtle-eval/turtle12-eval-bnode-01.ttl")
	defer delete(doc)
	ops, err := ingest.turtle(doc, nil, context.allocator, base = "http://example/", blank_prefix = "tt_")
	defer ingest.ops_destroy(ops, context.allocator)
	testing.expect_value(t, err.kind, ingest.Error_Kind.None)
	// RDF 1.2: << >> is a reifier, so the second statement expands to
	// two triples about a fresh reifier node, one of them carrying the
	// triple term as the object of rdf:reifies — three ops in all.
	testing.expect_value(t, len(ops), 3)
	at := -1
	for op, i in ops {
		if _, is_tt := op.object.(^rdf.Triple); is_tt {
			at = i
		}
	}
	testing.expect(t, at >= 0, "one op carries the triple term")
	e, _, aerr := rec.apply(&s, {ops = ops})
	testing.expect_value(t, aerr, rec.Apply_Error{})
	testing.expect_value(t, e, rec.Epoch(1))
	testing.expect_value(t, s.n_epochs, u32(1))
	testing.expect_value(t, s.n_facts, u32(3))

	// The triple term is a term: resolvable, and the fact carrying it
	// matches on its id.
	snap, serr := rec.store_latest(&s)
	testing.expect_value(t, serr, rec.Snapshot_Error.None)
	defer rec.snapshot_release(&snap)
	id, found := rec.snapshot_resolve(snap, ops[at].object)
	testing.expect(t, found && id != 0, "the triple term resolves to an id")
	testing.expect(t, rec.snapshot_exists(snap, {o = id}, {origin = .Any, scope = .All}), "a pattern binding it matches")

	// And its blank-node components carry the document's scope, which is
	// what makes two documents loadable side by side (RECORD-T-0023).
	tr := ops[at].object.(^rdf.Triple)
	if b, is_blank := tr.subject.(rdf.Blank_Node); is_blank {
		testing.expect(t, strings.has_prefix(string(b), "tt_"), "a blank node inside a triple term is scoped")
	}
}

RT_DIR :: "build/ingest/roundtrip"
BIN :: "build/record"

@(test)
test_ingest_dump_round_trip :: proc(t: ^testing.T) {
	// A store filled through ingest + apply, dumped as N-Quads by the
	// CLI, re-ingested through nquads and applied into a second store:
	// the same projection, and the Python verifier accepts the log.
	os.make_directory("build")
	os.make_directory("build/ingest")
	os.make_directory(RT_DIR)
	for i in 1 ..= 4 {
		os.remove(fmt.tprintf("%s/%06d.rlog", RT_DIR, i))
	}
	os.remove(RT_DIR + "/HEAD")

	doc := transmute([]byte)string(`
@prefix ex: <http://example.org/> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
ex:alice ex:knows ex:bob ; ex:name "Alice"@EN ; ex:age 42 ; ex:born "1990-05-04"^^xsd:date ; ex:score "01"^^xsd:integer ; ex:note "plain" .
_:b0 ex:knows ex:alice .
ex:g { ex:bob ex:knows ex:carol ; ex:weight "1.5"^^xsd:decimal . _:b1 ex:p _:b0 . }
_:g2 { ex:carol ex:knows ex:alice . }
`)
	// The prefix is made of label characters, so the dump's labels
	// re-parse (ingest's doc comment).
	ops, err := ingest.trig(doc, context.allocator, blank_prefix = "rt_")
	defer ingest.ops_destroy(ops, context.allocator)
	testing.expect_value(t, err.kind, ingest.Error_Kind.None)
	testing.expect_value(t, len(ops), 11)

	a: rec.Store
	_, oerr, lerr, werr := rec.store_open(&a, RT_DIR, rec.posix_file_ops())
	testing.expect(t, oerr == .None && lerr == .None && werr == .None, "the store opens")
	_, _, aerr := rec.apply(&a, {ops = ops, actor = rdf.IRI("http://example.org/importer")})
	testing.expect_value(t, aerr, rec.Apply_Error{})
	testing.expect_value(t, rec.store_close(&a), rec.Writer_Error.None)

	state, stdout, stderr, perr := os.process_exec({command = {BIN, "dump", "--format=nquads", RT_DIR}}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect(t, perr == nil && state.exited && state.exit_code == 0, "dump runs")
	back, berr := ingest.nquads(stdout, context.allocator)
	defer ingest.ops_destroy(back, context.allocator)
	testing.expect_value(t, berr.kind, ingest.Error_Kind.None)
	testing.expect_value(t, len(back), len(ops))

	fs: rec.Mem_FS
	defer rec.mem_fs_destroy(&fs)
	b: rec.Store
	open_mem(t, &b, &fs)
	defer rec.store_close(&b)
	// The same actor, so the dictionaries agree term for term (the actor
	// is interned after the ops, as the last definition of the epoch).
	_, _, berr2 := rec.apply(&b, {ops = back, actor = rdf.IRI("http://example.org/importer")})
	testing.expect_value(t, berr2, rec.Apply_Error{})

	a2: rec.Store
	_, oerr2, _, _ := rec.store_open(&a2, RT_DIR, rec.posix_file_ops())
	testing.expect_value(t, oerr2, rec.Open_Error.None)
	defer rec.store_close(&a2)
	testing.expect_value(t, b.n_facts, a2.n_facts)
	testing.expect_value(t, len(b.dict.off), len(a2.dict.off))
	for id in 0 ..< min(a2.n_facts, b.n_facts) {
		testing.expect_value(t, rec.store_fact(&b, rec.Fact_ID(id))^, rec.store_fact(&a2, rec.Fact_ID(id))^)
	}
	for id in 1 ..= u32(min(len(a2.dict.off), len(b.dict.off))) {
		testing.expect(t, string(rec.dict_bytes(&b.dict, rec.Term_ID(id))) == string(rec.dict_bytes(&a2.dict, rec.Term_ID(id))), "term bytes agree")
	}
	for op in ops {
		testing.expect(t, exists(&b, 1, op.quad), "every ingested statement is live in the round-tripped store")
	}

	// The Python verifier over the apply-written, ingest-fed log.
	pstate, pout, perr_out, pexec := os.process_exec({command = {"python3", "tests/verify/rdflog_verify.py", RT_DIR}}, context.allocator)
	defer delete(pout)
	defer delete(perr_out)
	testing.expect(t, pexec == nil && pstate.exited, "the python verifier runs")
	testing.expectf(t, strings.has_prefix(string(pout), "clean ") && strings.has_suffix(strings.trim_space(string(pout)), " 1"), "python: %q (%q)", string(pout), string(perr_out))
}
