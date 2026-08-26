package record

import "core:slice"
import "core:testing"

import "rdf:rdf"

// The read API's tests (RECORD-T-0010): a crafted log carrying every
// term shape the format has — IRIs, string/lang/typed literals, an
// inlined integer, a named and the default graph, derived ops, and a
// retracted-and-re-asserted quad — driven through the real pipe
// (writer, replay, Loader, permutations, publish), then every pattern
// shape at every epoch under every filter against a brute-force scan
// oracle that shares nothing with the implementation but the fact
// table itself.

// The crafted log's fixed points, named for the tests below. Fact ids
// are positional over asserts; intervals in comments.
@(private = "file")
RT :: struct {
	five:  Term_ID, // the inlined integer 5, resident
	terms: u64, // dictionary terms defined
}

// rt_build writes the log and loads it: epochs 1..4 over terms 1..8 —
// 1 alice, 2 knows (the predicate), 3 bob, 4 g (the named graph),
// 5 "hello", 6 "Hello"@en, 7 xsd:long, 8 "99"^^xsd:long.
//
//	f0 (1,2,3,0)    [1,2)      f4 (1,2,3,0)    [3,live)  re-assert
//	f1 (1,2,5i,0)   [1,4)      f5 (3,2,8,4)    [3,live)
//	f2 (3,2,5,4)    [1,live)   f6 (3,2,5i,4)   [3,4)     derived
//	f3 (1,2,6,0)    [2,live)
@(private = "file")
rt_build :: proc(t: ^testing.T, fs: ^OFS, s: ^Store) -> (rt: RT) {
	w, werr := writer_create("store", ofs_ops(fs), SEGMENT_TARGET_SIZE)
	defer writer_destroy(&w)
	testing.expect_value(t, werr, Writer_Error.None)

	five, _ := inline_integer(5)
	rt.five = resident_id(five)

	enc :: proc(s: string) -> []byte {
		return transmute([]byte)s
	}
	terms1 := [5]Term_Def{
		{id = 1, enc = enc("\x01http://ex/alice")},
		{id = 2, enc = enc("\x01http://ex/knows")},
		{id = 3, enc = enc("\x01http://ex/bob")},
		{id = 4, enc = enc("\x01http://ex/g")},
		{id = 5, enc = enc("\x03hello")},
	}
	ops1 := [3]Fact_Op{
		{op = .Assert, s = 1, p = 2, o = 3, g = 0},
		{op = .Assert, s = 1, p = 2, o = five, g = 0},
		{op = .Assert, s = 3, p = 2, o = 5, g = 4},
	}
	testing.expect_value(t, writer_commit(&w, {epoch = 1, wall = OWALL, terms = terms1[:], ops = ops1[:]}), Writer_Error.None)

	terms2 := [1]Term_Def{{id = 6, enc = enc("\x04\x02enHello")}}
	ops2 := [2]Fact_Op{
		{op = .Assert, s = 1, p = 2, o = 6, g = 0},
		{op = .Retract, s = 1, p = 2, o = 3, g = 0},
	}
	testing.expect_value(t, writer_commit(&w, {epoch = 2, wall = OWALL + 1, terms = terms2[:], ops = ops2[:]}), Writer_Error.None)

	terms3 := [2]Term_Def{
		{id = 7, enc = enc("\x01http://www.w3.org/2001/XMLSchema#long")},
		{id = 8, enc = enc("\x05\x00\x00\x00\x00\x00\x00\x00\x0799")},
	}
	ops3 := [3]Fact_Op{
		{op = .Assert, s = 1, p = 2, o = 3, g = 0},
		{op = .Assert, s = 3, p = 2, o = 8, g = 4},
		{op = .Assert_Derived, s = 3, p = 2, o = five, g = 4},
	}
	testing.expect_value(t, writer_commit(&w, {epoch = 3, wall = OWALL + 2, terms = terms3[:], ops = ops3[:]}), Writer_Error.None)

	ops4 := [2]Fact_Op{
		{op = .Retract, s = 1, p = 2, o = five, g = 0},
		{op = .Retract_Derived, s = 3, p = 2, o = five, g = 4},
	}
	testing.expect_value(t, writer_commit(&w, {epoch = 4, wall = OWALL + 3, ops = ops4[:]}), Writer_Error.None)
	rt.terms = w.next_term_id - 1

	ld: Loader
	loader_init(&ld, s)
	defer loader_destroy(&ld)
	_, _, err := replay("store", ofs_ops(fs), loader_consumer(&ld))
	testing.expect_value(t, err, Open_Error.None)
	testing.expect_value(t, ld.err, Load_Error.None)
	store_build_permutations(s)
	store_build_term_index(s)
	store_publish(s)
	return rt
}

// oracle_collect is the brute-force answer: every fact id, checked
// against the pattern, the epoch, and the filters directly on the
// fact table — no permutation, no binary search, no scan.
@(private = "file")
oracle_collect :: proc(snap: Snapshot, p: Pattern, f: Filter) -> (out: [dynamic]Fact_ID) {
	for id in Fact_ID(0) ..< Fact_ID(snap.idx.n_facts) {
		fact := store_fact(snap.store, id)
		if p.s != 0 && fact.s != p.s {
			continue
		}
		if p.p != 0 && fact.p != p.p {
			continue
		}
		if p.o != 0 && fact.o != p.o {
			continue
		}
		if p.g != 0 {
			want := Term_ID(0) if p.g == MATCH_DEFAULT_GRAPH else p.g
			if fact.g != want {
				continue
			}
		}
		if !(fact.assert <= snap.epoch && snap.epoch < fact.retract) {
			continue
		}
		if f.origin != .Any && store_derived(snap.store, id) != (f.origin == .Derived) {
			continue
		}
		if f.scope == .Set {
			hit := false
			for g in f.graphs {
				if fact.g == g || (fact.g == 0 && g == MATCH_DEFAULT_GRAPH) {
					hit = true
					break
				}
			}
			if !hit {
				continue
			}
		}
		append(&out, id)
	}
	return out
}

@(private = "file")
scan_collect :: proc(r: Range, f: Filter) -> (out: [dynamic]Fact_ID) {
	sc := range_iter(r, f)
	for id in scan_next(&sc) {
		append(&out, id)
	}
	slice.sort(out[:])
	return out
}

@(test)
test_read_oracle :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	rt := rt_build(t, &fs, &s)

	pats := [?]Pattern{
		{},
		{s = 1},
		{s = 3},
		{p = 2},
		{o = 3},
		{o = rt.five},
		{o = 5},
		{s = 1, p = 2},
		{s = 3, o = rt.five},
		{p = 2, o = 3},
		{s = 1, p = 2, o = 3},
		{g = MATCH_DEFAULT_GRAPH},
		{g = 4},
		{s = 3, g = 4},
		{p = 2, o = rt.five, g = MATCH_DEFAULT_GRAPH},
		{s = 9}, // a term that is never a subject
	}
	origins := [3]Origin{.Any, .Asserted, .Derived}
	g4 := [1]Term_ID{4}
	gd := [1]Term_ID{MATCH_DEFAULT_GRAPH}
	both := [2]Term_ID{MATCH_DEFAULT_GRAPH, 4}
	Scoping :: struct {
		scope:  Graph_Scope,
		graphs: []Term_ID,
	}
	graph_sets := [4]Scoping{{.All, nil}, {.Set, gd[:]}, {.Set, g4[:]}, {.Set, both[:]}}

	checked := 0
	for epoch in Epoch(0) ..= 4 {
		snap, serr := store_at(&s, epoch)
		testing.expect_value(t, serr, Snapshot_Error.None)
		for p in pats {
			r := snapshot_match(snap, p)
			for origin in origins {
				for graphs in graph_sets {
					f := Filter{origin = origin, scope = graphs.scope, graphs = graphs.graphs}
					want := oracle_collect(snap, p, f)
					got := scan_collect(r, f)
					testing.expectf(
						t,
						slice.equal(got[:], want[:]),
						"pattern %v epoch %d origin %v graphs %v: got %v, want %v",
						p, epoch, origin, graphs, got, want,
					)
					testing.expectf(
						t,
						snapshot_exists(snap, p, f) == (len(want) > 0),
						"pattern %v epoch %d origin %v graphs %v: exists disagrees with the oracle",
						p, epoch, origin, graphs,
					)
					checked += 1
					delete(want)
					delete(got)
				}
			}
		}
		snapshot_release(&snap)
	}
	testing.expect_value(t, checked, len(pats)*5*3*4)

	// One case pinned by hand so the oracle itself is answerable:
	// epoch 4, any origin, no graph filter — f2, f3, f4, f5 live.
	snap, _ := store_latest(&s)
	got := scan_collect(snapshot_match(snap, {}), {origin = .Any, scope = .All})
	want := [4]Fact_ID{2, 3, 4, 5}
	testing.expect(t, slice.equal(got[:], want[:]), "the head's live set, by hand")
	delete(got)
	snapshot_release(&snap)
}

// RECORD-T-0029: an empty graph set admits nothing, however it was
// built. Odin nils some empty slices and not others — a zero-value
// dynamic array's slice is nil; one made with a capacity hint, one
// appended to and cleared, and a stack buffer's [:0] are not — and the
// scan used to test the pointer, so the same empty set read every
// graph or nothing by allocation history. The test asserts that the
// four differ in nil-ness on purpose: that is what proves both former
// branches are covered, and it will say so if a compiler ever unifies
// them.
@(test)
test_read_graph_scope_empty :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	_ = rt_build(t, &fs, &s)
	snap, _ := store_latest(&s)
	defer snapshot_release(&snap)

	zero: [dynamic]Term_ID
	defer delete(zero)
	hinted := make([dynamic]Term_ID, 0, 8)
	defer delete(hinted)
	cleared: [dynamic]Term_ID
	defer delete(cleared)
	append(&cleared, Term_ID(4))
	clear(&cleared)
	buf: [4]Term_ID

	Empty :: struct {
		name: string,
		set:  []Term_ID,
	}
	empties := [4]Empty{
		{"zero-value dynamic array", zero[:]},
		{"dynamic array with a capacity hint", hinted[:]},
		{"dynamic array appended to and cleared", cleared[:]},
		{"stack buffer [:0]", buf[:0]},
	}

	saw_nil, saw_ptr := false, false
	for e in empties {
		if e.set == nil {
			saw_nil = true
		} else {
			saw_ptr = true
		}
		f := Filter{origin = .Any, scope = .Set, graphs = e.set}
		got := scan_collect(snapshot_match(snap, {}), f)
		testing.expectf(t, len(got) == 0, "%s: an empty set admitted %v", e.name, got)
		delete(got)
		testing.expectf(t, !snapshot_exists(snap, {}, f), "%s: exists under an empty set", e.name)
	}
	testing.expect(t, saw_nil && saw_ptr, "the four empty sets no longer differ in nil-ness: this test now covers one branch, not two")

	// The set's length is what admits: the same stack buffer with one
	// graph in it admits that graph's live facts and nothing else —
	// f2 and f5 at head, both in graph 4.
	buf[0] = 4
	f := Filter{origin = .Any, scope = .Set, graphs = buf[:1]}
	got := scan_collect(snapshot_match(snap, {}), f)
	defer delete(got)
	want := [2]Fact_ID{2, 5}
	testing.expect(t, slice.equal(got[:], want[:]), "a one-graph set admits exactly its graph")
}

@(test)
test_read_order_selection :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	rt := rt_build(t, &fs, &s)
	snap, _ := store_latest(&s)
	defer snapshot_release(&snap)

	// api.md par. 12.2's table, shape by shape; G never changes the
	// choice.
	cases := [?]struct {
		p:    Pattern,
		want: Order,
	}{
		{{}, .SPOG},
		{{s = 1}, .SPOG},
		{{p = 2}, .PSOG},
		{{o = 3}, .OSPG},
		{{s = 1, p = 2}, .SPOG},
		{{s = 1, o = 3}, .SOPG},
		{{p = 2, o = 3}, .POSG},
		{{s = 1, p = 2, o = 3}, .SPOG},
		{{p = 2, g = 4}, .PSOG},
	}
	for c in cases {
		testing.expect_value(t, snapshot_match(snap, c.p).order, c.want)
	}

	// Any order answers any pattern — the residual absorbs what the
	// prefix could not express — and a graph-bound full scan works.
	f := Filter{origin = .Any, scope = .All}
	for p in ([3]Pattern{{p = 2, o = rt.five}, {s = 3, g = 4}, {g = MATCH_DEFAULT_GRAPH}}) {
		want := scan_collect(snapshot_match(snap, p), f)
		for o in Order {
			got := scan_collect(snapshot_match_as(snap, p, o), f)
			testing.expectf(t, slice.equal(got[:], want[:]), "%v via %v", p, o)
			delete(got)
		}
		delete(want)
	}

	// range_len is the candidate count: every generation in the
	// window, retracted ones included — an upper bound on any epoch's
	// answer. (1,2,?,?) has three generations: f0, f1, f4... and f3.
	testing.expect_value(t, range_len(snapshot_match(snap, {s = 1, p = 2})), 4)
}

@(test)
test_read_resolve :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	rt := rt_build(t, &fs, &s)
	snap, _ := store_latest(&s)
	defer snapshot_release(&snap)

	// Dictionary hits, every stored shape; the language tag resolves
	// case-insensitively (RDF term identity lowercases it).
	cases := [?]struct {
		t:    rdf.Term,
		want: Term_ID,
	}{
		{rdf.IRI("http://ex/alice"), 1},
		{rdf.IRI("http://ex/knows"), 2},
		{rdf.Literal{lexical = "hello", datatype = rdf.XSD_STRING}, 5},
		{rdf.Literal{lexical = "Hello", datatype = rdf.RDF_LANG_STRING, language = "en"}, 6},
		{rdf.Literal{lexical = "Hello", datatype = rdf.RDF_LANG_STRING, language = "EN"}, 6},
		{rdf.Literal{lexical = "99", datatype = rdf.IRI("http://www.w3.org/2001/XMLSchema#long")}, 8},
	}
	for c in cases {
		id, ok := snapshot_resolve(snap, c.t)
		testing.expectf(t, ok, "%v resolves", c.t)
		testing.expect_value(t, id, c.want)
	}

	// The inline fast path: canonical forms are their own ids, no
	// dictionary probe; non-canonical forms fall through to the
	// dictionary and miss, because nothing interned them.
	five, ok5 := snapshot_resolve(snap, rdf.Literal{lexical = "5", datatype = rdf.XSD_INTEGER})
	testing.expect(t, ok5, "a canonical integer inlines")
	testing.expect_value(t, five, rt.five)
	tru, okt := snapshot_resolve(snap, rdf.Literal{lexical = "true", datatype = rdf.XSD_BOOLEAN})
	testing.expect(t, okt, "a canonical boolean inlines")
	testing.expect_value(t, tru, Term_ID(RES_INLINE_FLAG|u32(INLINE_TAG_BOOLEAN)<<RES_INLINE_TAG_SHIFT|1))
	date, okd := snapshot_resolve(snap, rdf.Literal{lexical = "1970-01-05", datatype = XSD_DATE})
	testing.expect(t, okd, "a canonical date inlines")
	testing.expect_value(t, date, Term_ID(RES_INLINE_FLAG|u32(INLINE_TAG_DATE)<<RES_INLINE_TAG_SHIFT|(RES_INLINE_BIAS+4)))

	// Misses, each an ordinary cheap case: an unseen IRI, a
	// non-canonical integer, an invalid date, a literal whose datatype
	// this store has never defined.
	misses := [?]rdf.Term{
		rdf.IRI("http://ex/nobody"),
		rdf.Literal{lexical = "+5", datatype = rdf.XSD_INTEGER},
		rdf.Literal{lexical = "05", datatype = rdf.XSD_INTEGER},
		rdf.Literal{lexical = "-0", datatype = rdf.XSD_INTEGER},
		rdf.Literal{lexical = "2023-02-30", datatype = XSD_DATE},
		rdf.Literal{lexical = "x", datatype = rdf.IRI("http://ex/undefined-dt")},
	}
	for m in misses {
		_, ok := snapshot_resolve(snap, m)
		testing.expectf(t, !ok, "%v misses", m)
	}

	// The set bound: a term interned after this snapshot's publication
	// is a miss for it — it is in no index the snapshot holds — and a
	// hit for a snapshot of the set that published it, while the older
	// snapshot still misses. The writer's steps, driven directly.
	late, aerr := dict_add(&s.dict, transmute([]byte)string("\x01http://ex/late"), s.allocator)
	testing.expect_value(t, aerr, Load_Error.None)
	_, late_ok := snapshot_resolve(snap, rdf.IRI("http://ex/late"))
	testing.expect(t, !late_ok, "a post-publication term is unknown to the snapshot")
	testing.expect_value(t, late, Term_ID(9))
	store_build_permutations(&s)
	store_merge_term_index(&s, snap.idx.terms)
	store_publish(&s)
	newer, nerr := store_latest(&s)
	testing.expect_value(t, nerr, Snapshot_Error.None)
	defer snapshot_release(&newer)
	got, got_ok := snapshot_resolve(newer, rdf.IRI("http://ex/late"))
	testing.expect(t, got_ok && got == 9, "the set that published the term resolves it")
	testing.expect_value(t, snapshot_terms(newer), u32(9))
	testing.expect_value(t, snapshot_terms(snap), u32(8))
	_, still := snapshot_resolve(snap, rdf.IRI("http://ex/late"))
	testing.expect(t, !still, "the older snapshot still misses it")
	testing.expect_value(t, string(snapshot_bytes(newer, 9)), "\x01http://ex/late")
}

@(test)
test_read_kind :: proc(t: ^testing.T) {
	// Every tag the codec knows plus every inline type, each kind
	// checked against the decoded term's own union variant.
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	encs := [?]string{
		"\x01http://ex/a", // 1 IRI
		"\x02b0", // 2 blank
		"\x03hello", // 3 string
		"\x04\x02enHello", // 4 lang
		"\x01http://www.w3.org/2001/XMLSchema#long", // 5 IRI (a datatype)
		"\x05\x00\x00\x00\x00\x00\x00\x00\x0599", // 6 typed, datatype 5
		"\x01http://ex/ns/", // 7 IRI (a namespace)
		"\x06\x00\x00\x00\x00\x00\x00\x00\x07local", // 8 split IRI over 7
	}
	for e in encs {
		_, err := dict_add(&s.dict, transmute([]byte)e, s.allocator)
		testing.expect_value(t, err, Load_Error.None)
	}
	store_build_permutations(&s)
	store_build_term_index(&s)
	store_publish(&s)
	snap, _ := store_latest(&s)
	defer snapshot_release(&snap)

	want := [?]Term_Kind{.IRI, .Blank, .Literal, .Literal, .IRI, .Literal, .IRI, .IRI}
	buf: [INLINE_LEXICAL_MAX]byte
	for k, i in want {
		id := Term_ID(i + 1)
		testing.expect_value(t, snapshot_kind(snap, id), k)
		term, ok := snapshot_term(snap, id, buf[:])
		testing.expectf(t, ok, "id %d decodes", id)
		variant: Term_Kind
		switch v in term {
		case rdf.IRI:
			variant = .IRI
			if id == 8 {
				delete(string(v)) // the split IRI's one allocation
			}
		case rdf.Blank_Node:
			variant = .Blank
		case rdf.Literal:
			variant = .Literal
		case ^rdf.Triple:
			testing.fail(t)
		}
		testing.expect_value(t, variant, k)
	}
	five, _ := inline_integer(5)
	testing.expect_value(t, snapshot_kind(snap, resident_id(five)), Term_Kind.Literal)
	tru, _ := term_inline(rdf.Literal{lexical = "true", datatype = rdf.XSD_BOOLEAN})
	testing.expect_value(t, snapshot_kind(snap, tru), Term_Kind.Literal)
	day, _ := term_inline(rdf.Literal{lexical = "2024-02-29", datatype = XSD_DATE})
	testing.expect_value(t, snapshot_kind(snap, day), Term_Kind.Literal)
}

@(test)
test_read_bytes_and_term :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	rt := rt_build(t, &fs, &s)
	snap, _ := store_latest(&s)
	defer snapshot_release(&snap)

	// Bytes: the arena view, byte for byte what the writer interned.
	testing.expect_value(t, string(snapshot_bytes(snap, 5)), "\x03hello")
	testing.expect_value(t, string(snapshot_bytes(snap, 1)), "\x01http://ex/alice")

	// Term and Resolve are inverses over every dictionary id — the
	// injectivity of the canonical encoding, exercised end to end.
	buf: [INLINE_LEXICAL_MAX]u8
	for id in Term_ID(1) ..= Term_ID(rt.terms) {
		term, ok := snapshot_term(snap, id, buf[:])
		testing.expectf(t, ok, "id %d materializes", id)
		back, rok := snapshot_resolve(snap, term)
		testing.expectf(t, rok, "id %d's term resolves", id)
		testing.expect_value(t, back, id)
	}

	// The same round trip through the inline space, no dictionary
	// involved.
	term5, ok5 := snapshot_term(snap, rt.five, buf[:])
	testing.expect(t, ok5, "the inlined id materializes")
	lit5 := term5.(rdf.Literal)
	testing.expect_value(t, lit5.lexical, "5")
	testing.expect_value(t, lit5.datatype, rdf.XSD_INTEGER)
	back5, rok5 := snapshot_resolve(snap, term5)
	testing.expect(t, rok5)
	testing.expect_value(t, back5, rt.five)

	// Spot checks on the decoded shapes.
	term6, _ := snapshot_term(snap, 6, buf[:])
	lit6 := term6.(rdf.Literal)
	testing.expect_value(t, lit6.lexical, "Hello")
	testing.expect_value(t, lit6.language, "en")
	term8, _ := snapshot_term(snap, 8, buf[:])
	lit8 := term8.(rdf.Literal)
	testing.expect_value(t, lit8.lexical, "99")
	testing.expect_value(t, lit8.datatype, rdf.IRI("http://www.w3.org/2001/XMLSchema#long"))

	// Refusals: id 0 and an id past the snapshot are not terms.
	_, z_ok := snapshot_term(snap, 0, buf[:])
	testing.expect(t, !z_ok, "id 0 is 'none', not a term")
	_, past_ok := snapshot_term(snap, Term_ID(rt.terms)+1, buf[:])
	testing.expect(t, !past_ok, "an id past the snapshot is unknown")
}

