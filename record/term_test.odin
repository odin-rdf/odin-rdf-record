package record

import "core:testing"

import "rdf:rdf"

// The term codec's tests (RECORD-T-0005): every tag of architecture.md
// par. 3.2 decodes to the data-model term it encodes, every inlined id
// materializes as the literal it carries, and everything malformed or
// unresolvable is refused — never guessed at.

@(private = "file")
tt_resolve :: proc(data: rawptr, id: u64) -> (string, bool) {
	_ = data
	switch id {
	case 7:
		return "http://www.w3.org/2001/XMLSchema#integer", true
	case 8:
		return "http://example.org/ns/", true
	}
	return "", false
}

@(test)
test_term_decode :: proc(t: ^testing.T) {
	iri, ok := term_decode(transmute([]u8)string("\x01http://example.org/a"), tt_resolve, nil)
	testing.expect(t, ok && iri == rdf.Term(rdf.IRI("http://example.org/a")), "an IRI decodes")

	blank, bok := term_decode(transmute([]u8)string("\x02b0"), tt_resolve, nil)
	testing.expect(t, bok && blank == rdf.Term(rdf.Blank_Node("b0")), "a blank node decodes")

	str, sok := term_decode(transmute([]u8)string("\x03hello"), tt_resolve, nil)
	testing.expect(
		t,
		sok && str == rdf.Term(rdf.Literal{lexical = "hello", datatype = rdf.XSD_STRING}),
		"a plain string decodes with xsd:string",
	)

	lang, lok := term_decode(transmute([]u8)string("\x04\x02enAlice"), tt_resolve, nil)
	testing.expect(
		t,
		lok &&
		lang == rdf.Term(rdf.Literal{lexical = "Alice", datatype = rdf.RDF_LANG_STRING, language = "en"}),
		"a language literal decodes, tag length-prefixed",
	)

	typed, tok := term_decode(transmute([]u8)string("\x05\x00\x00\x00\x00\x00\x00\x00\x0742"), tt_resolve, nil)
	testing.expect(
		t,
		tok &&
		typed == rdf.Term(rdf.Literal{lexical = "42", datatype = rdf.IRI("http://www.w3.org/2001/XMLSchema#integer")}),
		"a typed literal resolves its datatype id",
	)

	split, pok := term_decode(transmute([]u8)string("\x06\x00\x00\x00\x00\x00\x00\x00\x08local"), tt_resolve, nil)
	testing.expect(t, pok && split == rdf.Term(rdf.IRI("http://example.org/ns/local")), "a split IRI joins")
	delete(string(split.(rdf.IRI))) // the one allocating case

	// Refusals: empty, an unassigned tag, a truncated triple term (0x07
	// is no longer reserved but its payload is a fixed 24 bytes), a
	// truncated language tag, a truncated datatype id, and a reference
	// the resolver cannot answer.
	refused := [6]string{"", "\x09x", "\x07x", "\x04\x05en", "\x05\x00\x0742", "\x05\x00\x00\x00\x00\x00\x00\x00\x6342"}
	for enc in refused {
		_, rok := term_decode(transmute([]u8)enc, tt_resolve, nil)
		testing.expect(t, !rok, "malformed or unresolvable encodings are refused")
	}
}

@(test)
test_inline_term :: proc(t: ^testing.T) {
	buf: [INLINE_LEXICAL_MAX]u8

	five, _ := inline_integer(5)
	ft, fok := inline_term(five, buf[:])
	testing.expect(
		t,
		fok && ft == rdf.Term(rdf.Literal{lexical = "5", datatype = rdf.XSD_INTEGER}),
		"an inlined integer materializes",
	)

	neg, _ := inline_integer(INLINE_VALUE_MIN)
	nt, nok := inline_term(neg, buf[:])
	testing.expect(
		t,
		nok && nt.(rdf.Literal).lexical == "-134217728",
		"the frozen range's bottom formats exactly",
	)

	bt, bok := inline_term(INLINE_FLAG | u64(INLINE_TAG_BOOLEAN)<<INLINE_TAG_SHIFT | 1, buf[:])
	testing.expect(
		t,
		bok && bt == rdf.Term(rdf.Literal{lexical = "true", datatype = rdf.XSD_BOOLEAN}),
		"an inlined boolean materializes",
	)

	// Dates across the proleptic Gregorian calendar, reference values
	// from an independent implementation.
	dates := [5]struct {
		days: i64,
		lex:  string,
	}{
		{0, "1970-01-01"},
		{11016, "2000-02-29"},
		{20684, "2026-08-19"},
		{-719162, "0001-01-01"},
		{2932896, "9999-12-31"},
	}
	for c in dates {
		id := INLINE_FLAG | u64(INLINE_TAG_DATE)<<INLINE_TAG_SHIFT | u64(c.days+i64(INLINE_BIAS))
		dt, dok := inline_term(id, buf[:])
		testing.expect_value(t, dok, true)
		testing.expect_value(t, dt.(rdf.Literal).lexical, c.lex)
		testing.expect_value(t, dt.(rdf.Literal).datatype, XSD_DATE)
	}

	// Refusals: a dictionary id, the reserved tag 0, an out-of-range
	// payload.
	_, dict_ok := inline_term(42, buf[:])
	testing.expect(t, !dict_ok, "a dictionary id does not inline")
	_, tag0_ok := inline_term(INLINE_FLAG | 1, buf[:])
	testing.expect(t, !tag0_ok, "the reserved tag 0 is rejected")
	_, range_ok := inline_term(INLINE_FLAG | u64(INLINE_TAG_INTEGER)<<INLINE_TAG_SHIFT, buf[:])
	testing.expect(t, !range_ok, "a payload outside the frozen range is rejected")
}
