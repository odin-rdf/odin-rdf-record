package record

import "base:runtime"

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

// it_component is the encoder's Resolve_Term_ID for the vector tests:
// three IRIs by name, the inlined integer 5 in its **on-disk** form
// (RECORD-A-0008 decision 3 — res_inline_disk's output, not a resident
// id), and a standing triple term at id 9 for the nesting case.
@(private = "file")
it_component :: proc(data: rawptr, t: rdf.Term) -> (id: u64, ok: bool) {
	_ = data
	if iid, inlined := term_inline(t); inlined {
		return res_inline_disk(iid), true
	}
	#partial switch v in t {
	case rdf.IRI:
		switch v {
		case "http://ex/s":
			return 1, true
		case "http://ex/p":
			return 2, true
		case "http://ex/o":
			return 3, true
		case "http://ex/a":
			return 4, true
		case "http://ex/b":
			return 5, true
		}
	case ^rdf.Triple:
		return 9, true
	}
	return 0, false
}

// it_resolve_term is it_component's inverse, the decoder's side.
@(private = "file")
it_resolve_term :: proc(data: rawptr, id: u64, allocator: runtime.Allocator) -> (t: rdf.Term, ok: bool) {
	_ = data
	if id & INLINE_FLAG != 0 {
		// An inlined literal materializes with a *static* datatype IRI,
		// so it must be cloned to be owned — otherwise destroy_term
		// would free a constant. The real resolver (RECORD-T-0024) has
		// the same obligation.
		buf: [INLINE_LEXICAL_MAX]byte
		lit, lok := inline_term(id, buf[:])
		if !lok {
			return nil, false
		}
		return rdf.clone_term(lit, allocator), true
	}
	switch id {
	case 1:
		return rdf.clone_term(rdf.IRI("http://ex/s"), allocator), true
	case 2:
		return rdf.clone_term(rdf.IRI("http://ex/p"), allocator), true
	case 3:
		return rdf.clone_term(rdf.IRI("http://ex/o"), allocator), true
	}
	return nil, false
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

@(private = "file")
expect_enc_t :: proc(t: ^testing.T, t_: rdf.Term, want: string, loc := #caller_location) {
	buf: [64]byte
	enc, err := term_encode(t_, it_resolve, nil, buf[:], it_component)
	testing.expect_value(t, err, Term_Error.None, loc = loc)
	testing.expect(t, string(enc) == want, "encoding differs from the vector", loc = loc)
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

	// RDF 1.2's two term kinds, vectors derived in
	// tests/verify/term_vectors.py from architecture.md par. 3.2 and
	// par. 11.3 and RECORD-A-0007 alone — never by running this encoder.
	tt3 := rdf.Triple{subject = rdf.IRI("http://ex/s"), predicate = rdf.IRI("http://ex/p"), object = rdf.IRI("http://ex/o")}
	expect_enc_t(
		t,
		&tt3,
		"\x07\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x03",
	)
	// A component that is an inlined literal carries par. 3.4's on-disk
	// form, bit 63 and the 2^55 bias — not the resident re-tagging.
	tti := rdf.Triple {
		subject   = rdf.IRI("http://ex/s"),
		predicate = rdf.IRI("http://ex/p"),
		object    = rdf.Literal{lexical = "5", datatype = rdf.XSD_INTEGER},
	}
	expect_enc_t(
		t,
		&tti,
		"\x07\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x02\x82\x80\x00\x00\x00\x00\x00\x05",
	)
	// Nesting, the shape construct-3.ttl carries: the inner triple term
	// is interned first and is a component id like any other.
	inner := rdf.Triple{subject = rdf.IRI("http://ex/s"), predicate = rdf.IRI("http://ex/p"), object = rdf.IRI("http://ex/o")}
	outer := rdf.Triple{subject = rdf.IRI("http://ex/a"), predicate = rdf.IRI("http://ex/b"), object = &inner}
	expect_enc_t(
		t,
		&outer,
		"\x07\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x09",
	)
	expect_enc(t, rdf.Literal{lexical = "Alice", datatype = rdf.RDF_DIR_LANG_STRING, language = "en", direction = .LTR}, "\x08\x02\x01enAlice")
	expect_enc(t, rdf.Literal{lexical = "مرحبا", datatype = rdf.RDF_DIR_LANG_STRING, language = "ar", direction = .RTL}, "\x08\x02\x02ar\xd9\x85\xd8\xb1\xd8\xad\xd8\xa8\xd8\xa7")
	// The same fold as tag 0x04, or the two tags would disagree about
	// term identity for the language half.
	expect_enc(t, rdf.Literal{lexical = "Alice", datatype = rdf.RDF_DIR_LANG_STRING, language = "EN-NZ", direction = .LTR}, "\x08\x05\x01en-nzAlice")

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
	// A nil component resolver refuses every triple term — the shape
	// this codec had before RECORD-I-0004, kept as the default so a
	// caller holding no dictionary is unchanged.
	tt := rdf.Triple{subject = rdf.IRI("http://ex/s"), predicate = rdf.IRI("http://ex/p"), object = rdf.IRI("http://ex/o")}
	_, terr := term_encode(&tt, it_resolve, nil, buf[:])
	testing.expect_value(t, terr, Term_Error.Unsupported_Term)

	// A base direction with no language is not an RDF 1.2 term and gets
	// no bytes rather than an invented encoding (RECORD-A-0007): the
	// mirror of the decoder's langlen != 0 refusal, and what keeps
	// tag 0x08 from spelling what tag 0x04 already spells.
	_, derr := term_encode(rdf.Literal{lexical = "x", datatype = rdf.RDF_DIR_LANG_STRING, direction = .RTL}, it_resolve, nil, buf[:])
	testing.expect_value(t, derr, Term_Error.Unsupported_Term)

	// A component the resolver does not know is a miss, not a guess —
	// Unknown_Datatype's twin one tag over.
	unknown := rdf.Triple{subject = rdf.IRI("http://ex/nope"), predicate = rdf.IRI("http://ex/p"), object = rdf.IRI("http://ex/o")}
	_, cerr := term_encode(&unknown, it_resolve, nil, buf[:], it_component)
	testing.expect_value(t, cerr, Term_Error.Unknown_Component)

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

	expect_id :: proc(t: ^testing.T, it: ^Intern, term: rdf.Term, want: Term_ID, loc := #caller_location) {
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

	// Unsupported terms are refused and leave the table untouched —
	// including the components a recursion had already defined, which is
	// what the intern's mark is for (RECORD-T-0023). This triple term's
	// third component is a language tag over 255 bytes, so its first two
	// components intern and are then rolled back.
	before := len(intern_defs(&it))
	tag := make([]byte, 256)
	defer delete(tag)
	for i in 0 ..< len(tag) {
		tag[i] = 'a'
	}
	partial := rdf.Triple {
		subject   = rdf.IRI("http://ex/only-in-a-refused-term"),
		predicate = rdf.IRI("http://ex/also-only-here"),
		object    = rdf.Literal{lexical = "x", datatype = rdf.RDF_LANG_STRING, language = string(tag)},
	}
	_, terr := intern_term(&it, &partial)
	testing.expect_value(t, terr, Term_Error.Unsupported_Term)
	testing.expect_value(t, len(intern_defs(&it)), before)
	// And the rollback is exact rather than approximate: re-interning
	// one of those components gets a fresh id, not the one the refused
	// recursion handed out.
	rid, rerr := intern_term(&it, rdf.IRI("http://ex/only-in-a-refused-term"))
	testing.expect(t, rerr == .None && rid == Term_ID(it.snap.idx.n_terms+u32(before)+1), "a rolled-back component leaves no pending id behind")
	intern_rollback(&it, before)

	// A direction with no language is still not a term.
	_, derr := intern_term(&it, rdf.Literal{lexical = "x", datatype = rdf.RDF_DIR_LANG_STRING, direction = .RTL})
	testing.expect_value(t, derr, Term_Error.Unsupported_Term)
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
	ids: [len(terms)]Term_ID
	g: Term_ID
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


@(test)
test_term_rdf12_round_trip :: proc(t: ^testing.T) {
	buf: [64]byte

	// A triple term round-trips through three component ids, and the
	// decoded tree is wholly owned: destroy_term frees every component
	// and the node (RECORD-A-0008 decision 2).
	tt := rdf.Triple{subject = rdf.IRI("http://ex/s"), predicate = rdf.IRI("http://ex/p"), object = rdf.IRI("http://ex/o")}
	enc, err := term_encode(&tt, it_resolve, nil, buf[:], it_component)
	testing.expect_value(t, err, Term_Error.None)
	back, ok := term_decode(enc, it_resolve_iri, nil, it_resolve_term)
	testing.expect_value(t, ok, true)
	tr, is_triple := back.(^rdf.Triple)
	testing.expect(t, is_triple, "tag 0x07 decodes to a triple term")
	testing.expect(t, tr^ == tt, "encode then decode is the identity for a triple term")
	rdf.destroy_term(back)

	// An inlined component survives the disk/resident boundary: it
	// encodes in par. 3.4's on-disk form and materializes as the
	// literal it names.
	tti := rdf.Triple {
		subject   = rdf.IRI("http://ex/s"),
		predicate = rdf.IRI("http://ex/p"),
		object    = rdf.Literal{lexical = "5", datatype = rdf.XSD_INTEGER},
	}
	ienc, ierr := term_encode(&tti, it_resolve, nil, buf[:], it_component)
	testing.expect_value(t, ierr, Term_Error.None)
	iback, iok := term_decode(ienc, it_resolve_iri, nil, it_resolve_term)
	testing.expect_value(t, iok, true)
	testing.expect(t, iback.(^rdf.Triple)^ == tti, "an inlined component round-trips")
	rdf.destroy_term(iback)

	// Base direction round-trips, direction and all.
	dirs := [2]rdf.Direction{.LTR, .RTL}
	for dir in dirs {
		lit := rdf.Literal{lexical = "Alice", datatype = rdf.RDF_DIR_LANG_STRING, language = "en", direction = dir}
		denc, derr := term_encode(lit, it_resolve, nil, buf[:])
		testing.expect_value(t, derr, Term_Error.None)
		dback, dok := term_decode(denc, it_resolve_iri, nil)
		testing.expect(t, dok && dback == rdf.Term(lit), "a base-direction literal round-trips")
	}
}

@(test)
test_term_rdf12_refusals :: proc(t: ^testing.T) {
	// Tag 0x07 decode: a nil resolver, a payload that is not exactly 24
	// bytes (a tolerated tail would be a second encoding of one term),
	// a zero component, and a component the resolver cannot answer.
	full :: "\x07\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x03"
	full_enc: string = full
	_, nok := term_decode(transmute([]u8)full_enc, it_resolve_iri, nil)
	testing.expect(t, !nok, "a nil term resolver refuses a triple term")
	refused_triple := [4]string{
		full[:len(full) - 1], // 23 bytes of payload
		full + "x", // 25 bytes of payload
		"\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x03", // s = 0
		"\x07\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x63", // o unknown
	}
	for enc in refused_triple {
		_, ok := term_decode(transmute([]u8)enc, it_resolve_iri, nil, it_resolve_term)
		testing.expect(t, !ok, "a malformed or unresolvable triple term is refused")
	}

	// Tag 0x08 decode: the three refusals injectivity needs
	// (RECORD-A-0007's amendment). A .None direction and a zero language
	// length are both shapes tag 0x04 already spells; a direction byte
	// outside rdf.Direction is not a direction.
	refused_dir := [5]string{
		"\x08", // no room for langlen and dir
		"\x08\x02", // no dir byte
		"\x08\x00\x01Alice", // langlen 0
		"\x08\x02\x00enAlice", // direction .None — tag 0x04's job
		"\x08\x02\x03enAlice", // 3 is not an rdf.Direction
	}
	for enc in refused_dir {
		_, ok := term_decode(transmute([]u8)enc, it_resolve_iri, nil, it_resolve_term)
		testing.expect(t, !ok, "a base-direction encoding outside the format is refused")
	}
	// The truncation that is not a refusal: langlen exactly spanning the
	// payload is an empty lexical form, which is a term.
	short_enc := "\x08\x02\x01en"
	empty, eok := term_decode(transmute([]u8)short_enc, it_resolve_iri, nil)
	testing.expect(t, eok && empty.(rdf.Literal).lexical == "", "an empty lexical form is a term")
}

@(test)
test_term_rdf12_injectivity :: proc(t: ^testing.T) {
	// par. 3.2's property in both directions. Forward: distinct terms
	// encode distinctly — a distinct tag byte with a fixed-length
	// payload cannot collide with any other encoding.
	buf: [64]byte
	seen: map[string]bool
	defer {
		for k in seen {
			delete(k)
		}
		delete(seen)
	}
	a := rdf.Triple{subject = rdf.IRI("http://ex/s"), predicate = rdf.IRI("http://ex/p"), object = rdf.IRI("http://ex/o")}
	b := rdf.Triple{subject = rdf.IRI("http://ex/a"), predicate = rdf.IRI("http://ex/b"), object = rdf.IRI("http://ex/o")}
	distinct_terms := [?]rdf.Term {
		rdf.IRI("http://ex/s"),
		rdf.Blank_Node("b0"),
		rdf.Literal{lexical = "Alice", datatype = rdf.XSD_STRING},
		rdf.Literal{lexical = "Alice", datatype = rdf.RDF_LANG_STRING, language = "en"},
		rdf.Literal{lexical = "Alice", datatype = rdf.RDF_DIR_LANG_STRING, language = "en", direction = .LTR},
		rdf.Literal{lexical = "Alice", datatype = rdf.RDF_DIR_LANG_STRING, language = "en", direction = .RTL},
		rdf.Literal{lexical = "42", datatype = rdf.XSD_INTEGER},
		&a,
		&b,
	}
	for term in distinct_terms {
		enc, err := term_encode(term, it_resolve, nil, buf[:], it_component)
		testing.expect_value(t, err, Term_Error.None)
		testing.expect(t, !(string(enc) in seen), "two distinct terms share an encoding")
		seen[strings_clone_local(string(enc))] = true
	}

	// The converse, the half RECORD-T-0021's re-check found sharper:
	// one term never encodes two ways. A language tag differing only in
	// case is one term under both tags that carry a language, and a
	// directional literal never falls back to tag 0x04.
	folds := [?][2]rdf.Term {
		{
			rdf.Literal{lexical = "Alice", datatype = rdf.RDF_LANG_STRING, language = "EN"},
			rdf.Literal{lexical = "Alice", datatype = rdf.RDF_LANG_STRING, language = "en"},
		},
		{
			rdf.Literal{lexical = "Alice", datatype = rdf.RDF_DIR_LANG_STRING, language = "EN", direction = .LTR},
			rdf.Literal{lexical = "Alice", datatype = rdf.RDF_DIR_LANG_STRING, language = "en", direction = .LTR},
		},
	}
	for pair in folds {
		one, _ := term_encode(pair[0], it_resolve, nil, buf[:])
		two_buf: [64]byte
		two, _ := term_encode(pair[1], it_resolve, nil, two_buf[:])
		testing.expect(t, string(one) == string(two), "a case-differing language tag is one term, one encoding")
	}

	// And the gate that keeps a triple term's components canonical:
	// an inlineable literal is an inlined id and never a dictionary
	// term, so it reaches a component slot exactly one way.
	inlineable, inl_ok := term_inline(rdf.Literal{lexical = "5", datatype = rdf.XSD_INTEGER})
	testing.expect(t, inl_ok && inlineable & RES_INLINE_FLAG != 0, "a canonical integer inlines")

	// term_inline is untouched by this initiative and refuses both new
	// kinds: three ids do not fit in 28 bits, and RECORD-A-0001 is frozen.
	_, t_inl := term_inline(&a)
	testing.expect(t, !t_inl, "a triple term does not inline")
	_, d_inl := term_inline(rdf.Literal{lexical = "x", datatype = rdf.RDF_DIR_LANG_STRING, language = "en", direction = .LTR})
	testing.expect(t, !d_inl, "a base-direction literal does not inline")
}

@(private = "file")
strings_clone_local :: proc(s: string) -> string {
	b := make([]byte, len(s))
	copy(b, s)
	return string(b)
}
