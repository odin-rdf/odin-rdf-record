package record

import "core:testing"

import "rdf:rdf"

// The encoder and intern's tests (RECORD-T-0013): the encoder's bytes
// for every term shape against the vectors the codec tests and the
// golden commit already fix, an encode/decode round trip per shape,
// the inline gate's canonical rule, the intern's four answers (inline,
// published, pending, new) with datatype-first ordering, and the proof
// that its numbering is the log's — the definitions it produces commit
// through the real writer, replay, and resolve to the same ids.

@(private = "file")
it_enc :: proc(s: string) -> []byte {
	return transmute([]byte)s
}

// it_resolve is a probe's resolver: xsd:integer is 7, xsd:long 3,
// nothing else is known.
@(private = "file")
it_resolve :: proc(data: rawptr, iri: rdf.IRI) -> (id: u64, ok: bool) {
	_ = data
	switch iri {
	case rdf.XSD_INTEGER:
		return 7, true
	case rdf.IRI("http://www.w3.org/2001/XMLSchema#long"):
		return 3, true
	}
	return 0, false
}

// it_resolve_iri is the decoder's side of it_resolve.
@(private = "file")
it_resolve_iri :: proc(data: rawptr, id: u64) -> (iri: string, ok: bool) {
	_ = data
	switch id {
	case 7:
		return string(rdf.XSD_INTEGER), true
	case 3:
		return "http://www.w3.org/2001/XMLSchema#long", true
	}
	return "", false
}

// it_store publishes a store holding the given encodings as terms
// 1..n and nothing else — the empty world of epoch 0 with a
// dictionary, which is all the intern reads of a snapshot.
@(private = "file")
it_store :: proc(t: ^testing.T, s: ^Store, encs: []string) -> Snapshot {
	store_init(s)
	for e in encs {
		_, err := dict_add(&s.dict, it_enc(e), s.allocator)
		testing.expect_value(t, err, Load_Error.None)
	}
	store_build_permutations(s)
	store_build_term_index(s)
	store_publish(s)
	snap, serr := store_latest(s)
	testing.expect_value(t, serr, Snapshot_Error.None)
	return snap
}

@(private = "file")
expect_enc :: proc(t: ^testing.T, t_: rdf.Term, want: string, loc := #caller_location) {
	buf: [64]byte
	enc, err := term_encode(t_, it_resolve, nil, buf[:])
	testing.expect_value(t, err, Term_Error.None, loc = loc)
	testing.expect(t, string(enc) == want, "encoding differs from the vector", loc = loc)
	testing.expect(t, raw_data(enc) == raw_data(buf[:]), "a short encoding lands in the caller's buffer", loc = loc)
}

@(test)
test_term_encode_vectors :: proc(t: ^testing.T) {
	// The golden commit's IRIs (encode_test.odin, computed independently
	// in Python) and the codec tests' vectors for every other tag.
	expect_enc(t, rdf.IRI("http://example.org/alice"), "\x01http://example.org/alice")
	expect_enc(t, rdf.Blank_Node("b0"), "\x02b0")
	expect_enc(t, rdf.Literal{lexical = "hello", datatype = rdf.XSD_STRING}, "\x03hello")
	expect_enc(t, rdf.Literal{lexical = "hello"}, "\x03hello") // an unset datatype is xsd:string
	expect_enc(t, rdf.Literal{lexical = "Alice", datatype = rdf.RDF_LANG_STRING, language = "en"}, "\x04\x02enAlice")
	expect_enc(t, rdf.Literal{lexical = "Alice", datatype = rdf.RDF_LANG_STRING, language = "EN"}, "\x04\x02enAlice")
	expect_enc(t, rdf.Literal{lexical = "Alice", datatype = rdf.RDF_LANG_STRING, language = "en-US"}, "\x04\x05en-usAlice")
	expect_enc(t, rdf.Literal{lexical = "42", datatype = rdf.XSD_INTEGER}, "\x05\x00\x00\x00\x00\x00\x00\x00\x0742")
	expect_enc(t, rdf.Literal{lexical = "99", datatype = "http://www.w3.org/2001/XMLSchema#long"}, "\x05\x00\x00\x00\x00\x00\x00\x00\x0399")

	// An encoding longer than the buffer is allocated and owned by the caller.
	long := make([]byte, 300)
	defer delete(long)
	for i in 0 ..< len(long) {
		long[i] = 'x'
	}
	buf: [64]byte
	enc, err := term_encode(rdf.IRI(string(long)), it_resolve, nil, buf[:])
	testing.expect_value(t, err, Term_Error.None)
	testing.expect(t, raw_data(enc) != raw_data(buf[:]) && len(enc) == 301 && enc[0] == TERM_TAG_IRI, "a long encoding is allocated")
	delete(enc)

	// Refusals: the format has no tag for these, and it is frozen.
	tt := rdf.Triple{subject = rdf.IRI("http://ex/s"), predicate = rdf.IRI("http://ex/p"), object = rdf.IRI("http://ex/o")}
	_, terr := term_encode(&tt, it_resolve, nil, buf[:])
	testing.expect_value(t, terr, Term_Error.Unsupported_Term)

	dir := rdf.Literal{lexical = "x", datatype = rdf.RDF_DIR_LANG_STRING, language = "ar", direction = .RTL}
	_, derr := term_encode(dir, it_resolve, nil, buf[:])
	testing.expect_value(t, derr, Term_Error.Unsupported_Term)

	tag := make([]byte, 256)
	defer delete(tag)
	for i in 0 ..< len(tag) {
		tag[i] = 'a'
	}
	_, lerr := term_encode(rdf.Literal{lexical = "x", datatype = rdf.RDF_LANG_STRING, language = string(tag)}, it_resolve, nil, buf[:])
	testing.expect_value(t, lerr, Term_Error.Unsupported_Term)
	ok_enc, okerr := term_encode(rdf.Literal{lexical = "x", datatype = rdf.RDF_LANG_STRING, language = string(tag[:255])}, it_resolve, nil, buf[:])
	testing.expect_value(t, okerr, Term_Error.None) // 255 is the limit, not 254
	delete(ok_enc)

	// A datatype the resolver does not know is a miss, not a guess.
	_, uerr := term_encode(rdf.Literal{lexical = "1.5", datatype = "http://www.w3.org/2001/XMLSchema#decimal"}, it_resolve, nil, buf[:])
	testing.expect_value(t, uerr, Term_Error.Unknown_Datatype)

	_, nerr := term_encode(nil, it_resolve, nil, buf[:])
	testing.expect_value(t, nerr, Term_Error.Unsupported_Term)
}

@(test)
test_term_encode_decode_round_trip :: proc(t: ^testing.T) {
	shapes := [?]rdf.Term{
		rdf.IRI("http://example.org/a"),
		rdf.Blank_Node("b0"),
		rdf.Literal{lexical = "hello", datatype = rdf.XSD_STRING},
		rdf.Literal{lexical = "Alice", datatype = rdf.RDF_LANG_STRING, language = "en"},
		rdf.Literal{lexical = "42", datatype = rdf.XSD_INTEGER},
		rdf.Literal{lexical = "", datatype = rdf.XSD_STRING},
	}
	for shape in shapes {
		buf: [64]byte
		enc, err := term_encode(shape, it_resolve, nil, buf[:])
		testing.expect_value(t, err, Term_Error.None)
		back, ok := term_decode(enc, it_resolve_iri, nil)
		testing.expect(t, ok && back == shape, "encode then decode is the identity")
	}
	// Lowercasing is the one place the round trip normalizes: the
	// decoded tag is the canonical one.
	buf: [64]byte
	enc, _ := term_encode(rdf.Literal{lexical = "x", datatype = rdf.RDF_LANG_STRING, language = "De-CH"}, it_resolve, nil, buf[:])
	back, ok := term_decode(enc, it_resolve_iri, nil)
	testing.expect(t, ok && back.(rdf.Literal).language == "de-ch", "the language tag comes back lowercased")
}

@(test)
test_term_inline :: proc(t: ^testing.T) {
	buf: [INLINE_LEXICAL_MAX]byte
	inlined := [?]rdf.Literal{
		{lexical = "true", datatype = rdf.XSD_BOOLEAN},
		{lexical = "false", datatype = rdf.XSD_BOOLEAN},
		{lexical = "0", datatype = rdf.XSD_INTEGER},
		{lexical = "5", datatype = rdf.XSD_INTEGER},
		{lexical = "-5", datatype = rdf.XSD_INTEGER},
		{lexical = "134217727", datatype = rdf.XSD_INTEGER}, // INLINE_VALUE_MAX
		{lexical = "-134217728", datatype = rdf.XSD_INTEGER}, // INLINE_VALUE_MIN
		{lexical = "1970-01-01", datatype = XSD_DATE},
		{lexical = "2024-02-29", datatype = XSD_DATE},
		{lexical = "-0044-03-15", datatype = XSD_DATE},
		{lexical = "12345-06-07", datatype = XSD_DATE},
	}
	for lit in inlined {
		id, ok := term_inline(lit)
		testing.expect(t, ok && id&RES_INLINE_FLAG != 0, "a canonical literal in range inlines")
		back, bok := inline_term(res_inline_disk(id), buf[:])
		testing.expect(t, bok && back == rdf.Term(lit), "the inlined id materializes as the literal it came from")
	}
	five, _ := inline_integer(5)
	id5, _ := term_inline(rdf.Literal{lexical = "5", datatype = rdf.XSD_INTEGER})
	testing.expect_value(t, id5, resident_id(five))

	not_inlined := [?]rdf.Term{
		rdf.Literal{lexical = "01", datatype = rdf.XSD_INTEGER}, // leading zero
		rdf.Literal{lexical = "+1", datatype = rdf.XSD_INTEGER},
		rdf.Literal{lexical = "-0", datatype = rdf.XSD_INTEGER},
		rdf.Literal{lexical = "134217728", datatype = rdf.XSD_INTEGER}, // INLINE_VALUE_MAX + 1
		rdf.Literal{lexical = "1", datatype = rdf.XSD_BOOLEAN},
		rdf.Literal{lexical = "2023-02-30", datatype = XSD_DATE},
		rdf.Literal{lexical = "2023-2-3", datatype = XSD_DATE},
		rdf.Literal{lexical = "02023-01-01", datatype = XSD_DATE},
		rdf.Literal{lexical = "5", datatype = rdf.XSD_STRING},
		rdf.Literal{lexical = "5", datatype = rdf.RDF_LANG_STRING, language = "en"},
		rdf.Literal{lexical = "5", datatype = rdf.XSD_INTEGER, direction = .LTR}, // malformed, and not the gate's to accept
		rdf.IRI("5"),
	}
	for term in not_inlined {
		_, ok := term_inline(term)
		testing.expect(t, !ok, "non-canonical forms and non-literals do not inline")
	}
}

@(test)
test_intern :: proc(t: ^testing.T) {
	s: Store
	defer store_destroy(&s)
	published := [?]string{
		"\x01http://ex/alice",
		"\x01http://ex/knows",
		"\x01http://www.w3.org/2001/XMLSchema#long",
		"\x03hello",
	}
	snap := it_store(t, &s, published[:])
	defer snapshot_release(&snap)

	it: Intern
	intern_init(&it, snap)
	defer intern_destroy(&it)

	expect_id :: proc(t: ^testing.T, it: ^Intern, term: rdf.Term, want: u32, loc := #caller_location) {
		id, err := intern_term(it, term)
		testing.expect_value(t, err, Term_Error.None, loc = loc)
		testing.expect_value(t, id, want, loc = loc)
	}

	// Published terms answer from the dictionary; nothing is defined.
	expect_id(t, &it, rdf.IRI("http://ex/alice"), 1)
	expect_id(t, &it, rdf.Literal{lexical = "hello", datatype = rdf.XSD_STRING}, 4)
	expect_id(t, &it, rdf.Literal{lexical = "hello"}, 4)
	// Inlined terms touch nothing.
	five, _ := inline_integer(5)
	expect_id(t, &it, rdf.Literal{lexical = "5", datatype = rdf.XSD_INTEGER}, resident_id(five))
	testing.expect_value(t, len(intern_defs(&it)), 0)

	// New terms are pending ids from n_terms + 1, one definition each,
	// and re-interning a pending term is the pending id.
	expect_id(t, &it, rdf.IRI("http://ex/bob"), 5)
	expect_id(t, &it, rdf.IRI("http://ex/bob"), 5)
	testing.expect_value(t, len(intern_defs(&it)), 1)

	// A typed literal over a published datatype carries that id.
	expect_id(t, &it, rdf.Literal{lexical = "99", datatype = "http://www.w3.org/2001/XMLSchema#long"}, 6)
	// A typed literal over a new datatype interns the datatype first.
	expect_id(t, &it, rdf.Literal{lexical = "1.5", datatype = "http://www.w3.org/2001/XMLSchema#decimal"}, 8)
	expect_id(t, &it, rdf.IRI("http://www.w3.org/2001/XMLSchema#decimal"), 7)
	// Language tags are one term whatever their case.
	expect_id(t, &it, rdf.Literal{lexical = "Hello", datatype = rdf.RDF_LANG_STRING, language = "EN"}, 9)
	expect_id(t, &it, rdf.Literal{lexical = "Hello", datatype = rdf.RDF_LANG_STRING, language = "en"}, 9)
	// A non-canonical integer is a dictionary term, distinct from the
	// inlined canonical one, and its datatype is interned like any.
	expect_id(t, &it, rdf.Literal{lexical = "01", datatype = rdf.XSD_INTEGER}, 11)
	expect_id(t, &it, rdf.XSD_INTEGER, 10)
	// Blank nodes are interned as given.
	expect_id(t, &it, rdf.Blank_Node("b0"), 12)
	expect_id(t, &it, rdf.Blank_Node("b0"), 12)

	// Graph labels: nil is G = 0; anything else is a term.
	g0, gerr := intern_graph(&it, nil)
	testing.expect(t, gerr == .None && g0 == 0, "the default graph is 0")
	gi, gierr := intern_graph(&it, rdf.IRI("http://ex/g"))
	testing.expect(t, gierr == .None && gi == 13, "a named graph interns")
	gb, gberr := intern_graph(&it, rdf.Blank_Node("b0"))
	testing.expect(t, gberr == .None && gb == 12, "a blank-node graph label is the same node")

	// Unsupported terms are refused and leave the table untouched.
	before := len(intern_defs(&it))
	tt := rdf.Triple{subject = rdf.IRI("http://ex/s"), predicate = rdf.IRI("http://ex/p"), object = rdf.IRI("http://ex/o")}
	_, terr := intern_term(&it, &tt)
	testing.expect_value(t, terr, Term_Error.Unsupported_Term)
	_, derr := intern_term(&it, rdf.Literal{lexical = "x", datatype = rdf.RDF_DIR_LANG_STRING, language = "ar", direction = .RTL})
	testing.expect_value(t, derr, Term_Error.Unsupported_Term)
	tag := make([]byte, 256)
	defer delete(tag)
	for i in 0 ..< len(tag) {
		tag[i] = 'a'
	}
	_, lerr := intern_term(&it, rdf.Literal{lexical = "x", datatype = rdf.RDF_LANG_STRING, language = string(tag)})
	testing.expect_value(t, lerr, Term_Error.Unsupported_Term)
	testing.expect_value(t, len(intern_defs(&it)), before)

	// The definitions: contiguous from 5, first-appearance order, the
	// literal's bytes carrying its datatype's id.
	want := [?]string{
		"\x01http://ex/bob",
		"\x05\x00\x00\x00\x00\x00\x00\x00\x0399",
		"\x01http://www.w3.org/2001/XMLSchema#decimal",
		"\x05\x00\x00\x00\x00\x00\x00\x00\x071.5",
		"\x04\x02enHello",
		"\x01http://www.w3.org/2001/XMLSchema#integer",
		"\x05\x00\x00\x00\x00\x00\x00\x00\x0a01",
		"\x02b0",
		"\x01http://ex/g",
	}
	defs := intern_defs(&it)
	testing.expect_value(t, len(defs), len(want))
	for d, i in defs {
		testing.expect_value(t, d.id, u64(5 + i))
		testing.expect(t, string(d.enc) == want[i], "a definition's bytes are the canonical encoding")
	}
}

@(test)
test_intern_numbering_is_the_logs :: proc(t: ^testing.T) {
	// Intern against the empty world, commit the definitions through
	// the real writer — commit_encode refuses any id that is not the
	// next expected, so success is the proof — replay into a second
	// store, and resolve every term to the id the intern issued.
	fs: OFS
	defer ofs_destroy(&fs)
	empty: Store
	snap0 := it_store(t, &empty, nil)
	defer store_destroy(&empty)

	terms := [?]rdf.Term{
		rdf.IRI("http://ex/alice"),
		rdf.IRI("http://ex/knows"),
		rdf.Literal{lexical = "Alice", datatype = rdf.RDF_LANG_STRING, language = "EN"},
		rdf.Literal{lexical = "1.5", datatype = "http://www.w3.org/2001/XMLSchema#decimal"},
		rdf.Blank_Node("b0"),
		rdf.Literal{lexical = "hello", datatype = rdf.XSD_STRING},
		rdf.Literal{lexical = "7", datatype = rdf.XSD_INTEGER},
		rdf.Literal{lexical = "2024-02-29", datatype = XSD_DATE},
		rdf.Literal{lexical = "007", datatype = rdf.XSD_INTEGER},
	}
	ids: [len(terms)]u32
	g: u32
	{
		it: Intern
		intern_init(&it, snap0)
		defer intern_destroy(&it)
		for term, i in terms {
			id, err := intern_term(&it, term)
			testing.expect_value(t, err, Term_Error.None)
			ids[i] = id
		}
		gerr: Term_Error
		g, gerr = intern_graph(&it, rdf.IRI("http://ex/g"))
		testing.expect_value(t, gerr, Term_Error.None)

		w, werr := writer_create("store", ofs_ops(&fs), SEGMENT_TARGET_SIZE)
		defer writer_destroy(&w)
		testing.expect_value(t, werr, Writer_Error.None)
		ops := [2]Fact_Op{
			{op = .Assert, s = u64(ids[0]), p = u64(ids[1]), o = u64(ids[3]), g = u64(g)},
			{op = .Assert, s = u64(ids[4]), p = u64(ids[1]), o = res_inline_disk(ids[6]), g = 0},
		}
		testing.expect_value(
			t,
			writer_commit(&w, {epoch = 1, wall = OWALL, actor = u64(ids[0]), terms = intern_defs(&it), ops = ops[:]}),
			Writer_Error.None,
		)
	}
	snapshot_release(&snap0)

	s: Store
	store_init(&s)
	defer store_destroy(&s)
	ld: Loader
	loader_init(&ld, &s)
	defer loader_destroy(&ld)
	_, _, rerr := replay("store", ofs_ops(&fs), loader_consumer(&ld))
	testing.expect_value(t, rerr, Open_Error.None)
	testing.expect_value(t, ld.err, Load_Error.None)
	store_build_permutations(&s)
	store_build_term_index(&s)
	store_publish(&s)
	snap, serr := store_latest(&s)
	testing.expect_value(t, serr, Snapshot_Error.None)
	defer snapshot_release(&snap)

	for term, i in terms {
		id, ok := snapshot_resolve(snap, term)
		testing.expect(t, ok, "a term the intern defined resolves after replay")
		testing.expect_value(t, id, ids[i])
	}
	gid, gok := snapshot_resolve(snap, rdf.IRI("http://ex/g"))
	testing.expect(t, gok && gid == g, "the graph label resolves")

	// And against the replayed store the same terms are all published:
	// the intern answers from the dictionary and defines nothing.
	it2: Intern
	intern_init(&it2, snap)
	defer intern_destroy(&it2)
	for term, i in terms {
		id, err := intern_term(&it2, term)
		testing.expect(t, err == .None && id == ids[i], "re-interning a published term is its id")
	}
	testing.expect_value(t, len(intern_defs(&it2)), 0)
	// Ten dictionary terms were defined — alice, knows, "Alice"@en,
	// xsd:decimal, "1.5", b0, "hello", xsd:integer, "007", g — and the
	// two inlined literals defined nothing.
	testing.expect_value(t, snap.idx.n_terms, u32(10))
}
