// Ingest (RECORD-T-0017, RECORD-I-0003 decision 7): the pure
// translation from a parsed RDF document to the []Op that apply
// accepts — four procedures, one per format, and nothing else. This is
// the loop every consumer would otherwise write three times (the
// application, the shacl suite, the sparql suite), provided once
// because the two policies in it — blank-node scoping, and the set
// semantics of a document — are the things each would get differently
// wrong.
//
// # A document is a set
//
// An RDF document denotes a graph, and a graph has no duplicates: a
// statement written twice is stated once. The loaders emit the set —
// a repeated statement yields one op, at its first position, order
// otherwise preserved — because apply judges every assert against the
// changeset's own earlier ops (log.md par. 5.3) and would refuse the
// second as .Already_Live, turning a valid document into one that
// cannot be loaded (RECORD-T-0019: the W3C SHACL suite's own
// shacl-shacl shapes graph lists two predicates twice in one object
// list). Identity is the quad's, graph included, after the blank
// prefix is applied; the same triple in two graphs is two ops.
//
// It is a subpackage so that the core's imports stay `rdf` alone: a
// consumer that never ingests documents links no parser. It touches no
// store state and no invariant — deleting it would change nothing in
// the store — and it is named ingest, not load, because load.odin is
// replay's Loader; this package loads nothing, it translates.
//
// # Ownership
//
// The ops own their terms. The parser repo's validity contract
// (RDF-A-0001) makes borrowing impossible here: prefix expansions,
// resolved IRIs and synthesized blank-node labels are owned by the
// parser and die with parser_destroy, and everything else in a yielded
// statement dies when the next statement is drained — so every term is
// cloned into `allocator` as it is yielded, and ops_destroy frees the
// lot. apply copies what it interns, so the ops may be destroyed the
// moment apply returns.
//
// # What is not here, on purpose
//
// No Changeset builder, no apply_turtle shortcut, no tool subcommand:
// a document supplies ops, never actor, reason or mode, and the store
// never decides "one document, one epoch" — the caller may concatenate
// documents into one changeset or split one across several. Each of
// those is one line in the consumer once these four exist.
package ingest

import "base:runtime"
import "core:strings"

import "rdf:rdf"
import "rdf:rdf/quads"
import "rdf:rdf/trig"
import "rdf:rdf/triples"
import "rdf:rdf/turtle"

import record ".."

// Error_Kind is how ingest refuses: a syntax error in the document,
// with the parser's position in Error.syntax, or an allocation failure.
Error_Kind :: enum u8 {
	None,
	Syntax,
	Allocation,
}

// Error is the refusal. `syntax` is the parser's own error — kind,
// byte offset, 1-based line and column — meaningful when kind is
// .Syntax; the four format packages share the type, and
// turtle.error_message names the violated production.
Error :: struct {
	kind:   Error_Kind,
	syntax: turtle.Error,
}

// turtle translates a Turtle document into ops over one graph — the
// caller's, because Turtle has no graphs of its own; nil is the
// default graph. `base` resolves the document's relative IRIs
// (typically its location; a document that uses relative IRIs before
// a @base with none given is a syntax error). `kind` is the op kind of
// every statement: .Retract turns a document into "unload this source",
// the only retract shape a document can express. `blank_prefix` is
// prepended to every blank-node label as written — the application
// passes its upload id, a harness its test name, so that labels are
// deterministic, predictable, and therefore nameable by a later
// retract (decision 4); two documents with _:b0 under different
// prefixes are two nodes, under the same prefix one node. The prefix
// becomes part of the label, so if the store will ever be dumped and
// re-ingested it must be made of blank-node label characters — letters,
// digits, '_' and '-' — which "upload-1_" is and "upload-1/" is not;
// the store itself accepts any bytes. (The parser synthesizes its own
// labels for a document's nodes; the prefix goes in front of those.)
// The ops are the document's *set* of statements — a repeated one is
// emitted once, at its first position (see the package doc). The ops
// own their terms; free them with ops_destroy.
turtle :: proc(
	src: []byte,
	graph: rdf.Graph_Label,
	allocator: runtime.Allocator,
	kind := record.Op_Kind.Assert,
	blank_prefix := "",
	base := "",
) -> (
	ops: []record.Op,
	err: Error,
) {
	p: turtle.Parser
	turtle.parser_init(&p, src, base, allocator)
	defer turtle.parser_destroy(&p)
	acc := make([dynamic]record.Op, allocator)
	seen: Seen
	seen_init(&seen, allocator)
	defer seen_destroy(&seen)
	for {
		t, ok := turtle.parser_next(&p)
		if !ok {
			break
		}
		if !push(&acc, &seen, kind,rdf.Quad{triple = t, graph = graph}, blank_prefix, allocator) {
			return fail(&acc, allocator, .Allocation, {})
		}
	}
	if p.err.kind != .None {
		return fail(&acc, allocator, .Syntax, p.err)
	}
	return acc[:], {}
}

// ntriples translates an N-Triples document into ops over one graph —
// turtle's line-based sibling, same contract, no base (N-Triples has
// no relative IRIs).
ntriples :: proc(
	src: []byte,
	graph: rdf.Graph_Label,
	allocator: runtime.Allocator,
	kind := record.Op_Kind.Assert,
	blank_prefix := "",
) -> (
	ops: []record.Op,
	err: Error,
) {
	p: triples.Parser
	triples.parser_init(&p, src, allocator)
	defer triples.parser_destroy(&p)
	acc := make([dynamic]record.Op, allocator)
	seen: Seen
	seen_init(&seen, allocator)
	defer seen_destroy(&seen)
	for {
		t, ok := triples.parser_next(&p)
		if !ok {
			break
		}
		if !push(&acc, &seen, kind,rdf.Quad{triple = t, graph = graph}, blank_prefix, allocator) {
			return fail(&acc, allocator, .Allocation, {})
		}
	}
	if p.err.kind != .None {
		return fail(&acc, allocator, .Syntax, p.err)
	}
	return acc[:], {}
}

// trig translates a TriG document into ops, the graphs coming from the
// document — statements outside a graph block are the default graph.
// Otherwise turtle's contract: base, kind, blank_prefix, ownership.
// A blank-node graph label is prefixed like any other label.
trig :: proc(
	src: []byte,
	allocator: runtime.Allocator,
	kind := record.Op_Kind.Assert,
	blank_prefix := "",
	base := "",
) -> (
	ops: []record.Op,
	err: Error,
) {
	p: trig.Parser
	trig.parser_init(&p, src, base, allocator)
	defer trig.parser_destroy(&p)
	acc := make([dynamic]record.Op, allocator)
	seen: Seen
	seen_init(&seen, allocator)
	defer seen_destroy(&seen)
	for {
		q, ok := trig.parser_next(&p)
		if !ok {
			break
		}
		if !push(&acc, &seen, kind,q, blank_prefix, allocator) {
			return fail(&acc, allocator, .Allocation, {})
		}
	}
	if p.err.kind != .None {
		return fail(&acc, allocator, .Syntax, p.err)
	}
	return acc[:], {}
}

// nquads translates an N-Quads document into ops, the graphs coming
// from the document — trig's line-based sibling, same contract, no
// base. The dump tool's nquads output re-ingests through this.
nquads :: proc(
	src: []byte,
	allocator: runtime.Allocator,
	kind := record.Op_Kind.Assert,
	blank_prefix := "",
) -> (
	ops: []record.Op,
	err: Error,
) {
	p: quads.Parser
	quads.parser_init(&p, src, allocator)
	defer quads.parser_destroy(&p)
	acc := make([dynamic]record.Op, allocator)
	seen: Seen
	seen_init(&seen, allocator)
	defer seen_destroy(&seen)
	for {
		q, ok := quads.parser_next(&p)
		if !ok {
			break
		}
		if !push(&acc, &seen, kind,q, blank_prefix, allocator) {
			return fail(&acc, allocator, .Allocation, {})
		}
	}
	if p.err.kind != .None {
		return fail(&acc, allocator, .Syntax, p.err)
	}
	return acc[:], {}
}

// ops_destroy frees ops returned by any of the four procedures — every
// term and the slice — with the allocator they were made from.
ops_destroy :: proc(ops: []record.Op, allocator: runtime.Allocator) {
	for op in ops {
		rdf.destroy_quad(op.quad, allocator)
	}
	delete(ops, allocator)
}

// --- internals ---------------------------------------------------------

// Seen is the set of statements one document has emitted so far: hash
// buckets over rdf.hash_quad of the owned quad, chained through `next`
// (`next[i]` is the next op index sharing op i's hash, -1 to end), so
// the whole set is two allocations per document rather than one per
// statement. Every hash hit is verified by rdf.equal_quad — a collision
// costs a comparison, never a dropped statement.
@(private = "file")
Seen :: struct {
	first: map[u64]int,
	next:  [dynamic]int,
}

@(private = "file")
seen_init :: proc(s: ^Seen, allocator: runtime.Allocator) {
	s.first = make(map[u64]int, allocator)
	s.next = make([dynamic]int, allocator)
}

@(private = "file")
seen_destroy :: proc(s: ^Seen) {
	delete(s.first)
	delete(s.next)
}

// push clones one statement into owned memory — blank-node labels
// prefixed as they are copied — and appends the op, unless the document
// already stated it, in which case the clone is freed and nothing is
// appended: the ops are the document's set. The clone comes first
// because identity is the *owned* quad's (prefix applied) and because
// the parser's terms are only promised to live until the next statement
// is drained (RDF-A-0001) — a duplicate costs one clone and destroy,
// and duplicates are rare.
@(private = "file")
push :: proc(
	acc: ^[dynamic]record.Op,
	seen: ^Seen,
	kind: record.Op_Kind,
	q: rdf.Quad,
	prefix: string,
	allocator: runtime.Allocator,
) -> bool {
	op := record.Op{kind = kind}
	ok: bool
	if op.subject, ok = clone_term(q.subject, prefix, allocator); !ok {
		return false
	}
	if op.predicate, ok = clone_term(q.predicate, prefix, allocator); !ok {
		rdf.destroy_term(op.subject, allocator)
		return false
	}
	if op.object, ok = clone_term(q.object, prefix, allocator); !ok {
		rdf.destroy_term(op.subject, allocator)
		rdf.destroy_term(op.predicate, allocator)
		return false
	}
	switch g in q.graph {
	case rdf.IRI:
		s, aerr := strings.clone(string(g), allocator)
		ok = aerr == nil
		op.graph = rdf.IRI(s)
	case rdf.Blank_Node:
		s, aerr := prefixed(string(g), prefix, allocator)
		ok = aerr == nil
		op.graph = rdf.Blank_Node(s)
	}
	if !ok {
		rdf.destroy_triple(op.triple, allocator)
		return false
	}
	h := rdf.hash_quad(op.quad)
	head, chained := seen.first[h]
	for j := head; chained && j >= 0; j = seen.next[j] {
		if rdf.equal_quad(acc[j].quad, op.quad) {
			rdf.destroy_quad(op.quad, allocator)
			return true
		}
	}
	index := len(acc)
	if _, aerr := append(acc, op); aerr != nil {
		rdf.destroy_quad(op.quad, allocator)
		return false
	}
	if _, aerr := append(&seen.next, chained ? head : -1); aerr != nil {
		pop(acc)
		rdf.destroy_quad(op.quad, allocator)
		return false
	}
	seen.first[h] = index
	return true
}

// clone_term is rdf.clone_term with the blank prefix applied and
// allocation failure reported rather than ignored. A triple term is
// cloned as is — apply refuses it (.Unsupported_Term), which is where
// the stance put the gap; ingest does not drop it silently.
@(private = "file")
clone_term :: proc(t: rdf.Term, prefix: string, allocator: runtime.Allocator) -> (out: rdf.Term, ok: bool) {
	switch v in t {
	case rdf.IRI:
		s, aerr := strings.clone(string(v), allocator)
		return rdf.IRI(s), aerr == nil
	case rdf.Blank_Node:
		s, aerr := prefixed(string(v), prefix, allocator)
		return rdf.Blank_Node(s), aerr == nil
	case rdf.Literal:
		lex, e1 := strings.clone(v.lexical, allocator)
		dt, e2 := strings.clone(string(v.datatype), allocator)
		lang, e3 := strings.clone(v.language, allocator)
		lit := rdf.Literal{lexical = lex, datatype = rdf.IRI(dt), language = lang, direction = v.direction}
		if e1 != nil || e2 != nil || e3 != nil {
			rdf.destroy_term(lit, allocator)
			return nil, false
		}
		return lit, true
	case ^rdf.Triple:
		return rdf.clone_term(t, allocator), true
	}
	return nil, false
}

@(private = "file")
prefixed :: proc(label, prefix: string, allocator: runtime.Allocator) -> (string, runtime.Allocator_Error) {
	if prefix == "" {
		return strings.clone(label, allocator)
	}
	return strings.concatenate({prefix, label}, allocator)
}

// fail frees what was built and returns the error.
@(private = "file")
fail :: proc(acc: ^[dynamic]record.Op, allocator: runtime.Allocator, kind: Error_Kind, syntax: turtle.Error) -> ([]record.Op, Error) {
	ops_destroy(acc[:], allocator)
	return nil, {kind = kind, syntax = syntax}
}
