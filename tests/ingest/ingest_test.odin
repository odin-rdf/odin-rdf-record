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
live_count :: proc(s: ^rec.Store, epoch: u32) -> (n: int) {
	snap, err := rec.store_at(s, epoch)
	if err != .None {
		return -1
	}
	defer rec.snapshot_release(&snap)
	sc := rec.range_iter(rec.snapshot_match(snap, {}), {origin = .Any})
	for _ in rec.scan_next(&sc) {
		n += 1
	}
	return
}

@(private)
exists :: proc(s: ^rec.Store, epoch: u32, q: rdf.Quad) -> bool {
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
	return rec.snapshot_exists(snap, p, {origin = .Any})
}

@(private)
has_blank :: proc(ops: []rec.Op) -> bool {
	for op in ops {
		if _, b := op.subject.(rdf.Blank_Node); b {
			return true
		}
		if _, b := op.object.(rdf.Blank_Node); b {
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
sweep_suite :: proc(t: ^testing.T, su: Suite) -> (pairs, ground, syntax_ok, syntax_bad: int) {
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
		if has_blank(ops) || has_blank(rops) || len(ops) == 0 {
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
	pairs, ground, ok, bad := sweep_suite(t, {dir = W3C + "/rdf11-turtle", doc_ext = ".ttl", res_ext = ".nt", base = "https://w3c.github.io/rdf-tests/rdf/rdf11/rdf-turtle/"})
	log.infof("rdf11-turtle: %d eval pairs (%d ground, compared as sets), %d positive and %d negative syntax documents", pairs, ground, ok, bad)
	testing.expectf(t, pairs > 100 && ground > 50 && ok > 50 && bad > 50, "the suite was swept: %d eval pairs (%d ground), %d positive and %d negative syntax", pairs, ground, ok, bad)
}

@(test)
test_ingest_w3c_trig :: proc(t: ^testing.T) {
	pairs, ground, ok, bad := sweep_suite(t, {dir = W3C + "/rdf11-trig", doc_ext = ".trig", res_ext = ".nq", base = "https://w3c.github.io/rdf-tests/rdf/rdf11/rdf-trig/", quads = true})
	log.infof("rdf11-trig: %d eval pairs (%d ground, compared as sets), %d positive and %d negative syntax documents", pairs, ground, ok, bad)
	testing.expectf(t, pairs > 100 && ground > 50 && ok > 50 && bad > 50, "the suite was swept: %d eval pairs (%d ground), %d positive and %d negative syntax", pairs, ground, ok, bad)
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
test_ingest_triple_term_refused_at_apply :: proc(t: ^testing.T) {
	// RDF 1.2's triple terms parse (the format is the parser's) and the
	// op is emitted; the store refuses it — where the stance put the gap.
	fs: rec.Mem_FS
	defer rec.mem_fs_destroy(&fs)
	s: rec.Store
	open_mem(t, &s, &fs)
	defer rec.store_close(&s)
	doc := read(t, W3C + "/rdf12-turtle-eval/turtle12-eval-bnode-01.ttl")
	defer delete(doc)
	ops, err := ingest.turtle(doc, nil, context.allocator, base = "http://example/")
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
	_, _, aerr := rec.apply(&s, {ops = ops})
	testing.expect_value(t, aerr, rec.Apply_Error{.Unsupported_Term, at})
	testing.expect_value(t, s.n_epochs, u32(0))
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
		testing.expect_value(t, rec.store_fact(&b, id)^, rec.store_fact(&a2, id)^)
	}
	for id in 1 ..= u32(min(len(a2.dict.off), len(b.dict.off))) {
		testing.expect(t, string(rec.dict_bytes(&b.dict, id)) == string(rec.dict_bytes(&a2.dict, id)), "term bytes agree")
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
