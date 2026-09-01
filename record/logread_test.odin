package record

import "core:testing"
import "rdf:rdf"

@(private = "file")
I :: proc(s: string) -> rdf.Term {return rdf.IRI(s)}

@(private = "file")
Seen :: struct {
	t:       ^testing.T,
	epochs:  int,
	actor:   string,
	reason:  string,
	want:    []Op,
	n:       int,
	triples: int,
}

@(private = "file")
seen_commit :: proc(data: rawptr, epoch, wall: u64, actor, reason: rdf.Term) -> bool {
	s := (^Seen)(data)
	s.epochs += 1
	// Attribution is decoded against the dictionary as of this epoch. The
	// actor is interned AFTER the epoch's ops, so a seam that resolved it
	// at the record boundary would read an id the dictionary does not yet
	// hold -- this assertion is what pins the lazy delivery.
	if a, ok := actor.(rdf.IRI); ok {
		s.actor = string(a)
	}
	if r, ok := reason.(rdf.IRI); ok {
		s.reason = string(r)
	}
	return true
}

// seen_op compares in the callback rather than keeping the quad: a term
// handed over is valid for this call only, which is log_read's stated
// contract and the reason a dump stays flat in memory.
@(private = "file")
seen_op :: proc(data: rawptr, epoch: u64, kind: Op_Kind, q: rdf.Quad) -> bool {
	s := (^Seen)(data)
	if _, ok := q.object.(^rdf.Triple); ok {
		s.triples += 1
	}
	if s.n < len(s.want) {
		testing.expect_value(s.t, kind, s.want[s.n].kind)
		testing.expect(s.t, rdf.equal_quad(q, s.want[s.n].quad), "the quad read back is the quad applied")
	}
	s.n += 1
	return true
}

// log_read is the decoded counterpart to replay (RECORD-T-0035): it
// walks a log and hands over quads, owning the dictionary and the term
// resolution the record CLI used to do for itself. This proves the four
// things that loop has to get right -- every op delivered, terms equal
// to what was applied, attribution resolved, and a triple term's
// components chased -- against a log written by apply.
@(test)
test_log_read_decodes_what_apply_wrote :: proc(t: ^testing.T) {
	fs: Mem_FS
	defer mem_fs_destroy(&fs)

	inner := new(rdf.Triple)
	defer free(inner)
	inner^ = rdf.Triple {
		subject   = I("http://ex/alice"),
		predicate = I("http://ex/knows"),
		object    = I("http://ex/bob"),
	}

	ops := []Op {
		{kind = .Assert, quad = {triple = {I("http://ex/alice"), I("http://ex/knows"), I("http://ex/bob")}}},
		{
			kind = .Assert,
			quad = {
				triple = {I("http://ex/alice"), I("http://ex/age"), rdf.Literal{lexical = "42", datatype = rdf.IRI(rdf.XSD_NS + "integer")}},
			},
		},
		// A named graph, so the graph component is exercised too.
		{
			kind = .Assert,
			quad = {
				triple = {I("http://ex/bob"), I("http://ex/knows"), I("http://ex/carol")},
				graph = rdf.IRI("http://ex/g"),
			},
		},
		// RDF 1.2: a triple term in the object. The CLI's own resolver
		// passed no resolve_term to term_decode, so this did not decode
		// before the seam existed.
		{
			kind = .Assert,
			quad = {triple = {I("http://ex/claim"), I("http://ex/says"), inner}},
		},
	}

	s: Store
	_, oerr, lerr, werr := store_open(&s, "logread", mem_file_ops(&fs))
	testing.expect(t, oerr == .None && lerr == .None && werr == .None, "the store opens")
	_, _, aerr := apply(&s, {ops = ops, actor = rdf.IRI("http://ex/importer"), reason = rdf.IRI("http://ex/because")})
	testing.expect_value(t, aerr, Apply_Error{})
	testing.expect_value(t, store_close(&s), Writer_Error.None)

	seen := Seen {
		t    = t,
		want = ops,
	}
	_, tear, err := log_read("logread", mem_file_ops(&fs), Log_Consumer{
		data   = &seen,
		commit = seen_commit,
		op     = seen_op,
	})
	testing.expect_value(t, err, Open_Error.None)
	testing.expect_value(t, tear.kind, Tear_Kind.None)

	testing.expect_value(t, seen.epochs, 1)
	testing.expect_value(t, seen.n, len(ops))
	testing.expect_value(t, seen.actor, "http://ex/importer")
	testing.expect_value(t, seen.reason, "http://ex/because")
	testing.expect_value(t, seen.triples, 1)
}

// A consumer may bind nothing it does not want. Terms are decoded only
// for the callbacks that exist, so counting epochs costs no decoding.
@(test)
test_log_read_optional_callbacks :: proc(t: ^testing.T) {
	fs: Mem_FS
	defer mem_fs_destroy(&fs)
	s: Store
	_, oerr, _, _ := store_open(&s, "logread2", mem_file_ops(&fs))
	testing.expect_value(t, oerr, Open_Error.None)
	ops := []Op{{kind = .Assert, quad = {triple = {I("http://ex/a"), I("http://ex/b"), I("http://ex/c")}}}}
	_, _, aerr := apply(&s, {ops = ops})
	testing.expect_value(t, aerr, Apply_Error{})
	testing.expect_value(t, store_close(&s), Writer_Error.None)

	n := 0
	_, _, err := log_read("logread2", mem_file_ops(&fs), Log_Consumer{
		data = &n,
		commit = proc(data: rawptr, epoch, wall: u64, actor, reason: rdf.Term) -> bool {
			(^int)(data)^ += 1
			return true
		},
	})
	testing.expect_value(t, err, Open_Error.None)
	testing.expect_value(t, n, 1)
}
