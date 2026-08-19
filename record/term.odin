// The canonical term codec (RECORD-T-0005): architecture.md par. 3.2's
// tag-byte encoding decoded into the parser repo's data model, and
// RECORD-A-0001's inlined ids materialized as the literals they carry.
// This is library code rather than tool code on purpose: the dump tool
// is its first consumer, and the resident store's Term(id) (api.md
// par. 12.7) is its second — one term decoder in the system, matching
// the one encoder the family already has.
//
// Decoded terms borrow from the encoding they were decoded from, per
// the family's zero-copy discipline — with one exception: a split IRI
// (tag 0x06) is stored as (namespace id, local name) and must be
// joined, which is the single allocation in this file and happens only
// for that tag. Datatype and namespace references are dictionary ids
// (par. 3.2: "datatypes are stored as IDs, not IRIs"), resolved
// through a caller-supplied callback, because only the caller holds a
// dictionary.
package record

import "core:fmt"

import "rdf:rdf"

// Term encoding tags, architecture.md par. 3.2 — with 0x06 from
// par. 3.5 and 0x07 reserved for RDF 1.2 triple terms (par. 11.3).
TERM_TAG_IRI :: u8(0x01)
TERM_TAG_BLANK :: u8(0x02)
TERM_TAG_STRING :: u8(0x03)
TERM_TAG_LANG :: u8(0x04)
TERM_TAG_TYPED :: u8(0x05)
TERM_TAG_SPLIT_IRI :: u8(0x06)

// XSD_DATE is xsd:date, the datatype of inlined dates; the parser's
// vocabulary carries the datatypes its grammars need and this is not
// one of them.
XSD_DATE :: rdf.IRI(rdf.XSD_NS + "date")

// INLINE_LEXICAL_MAX bounds the lexical form of any inlined term:
// booleans are "true"/"false", integers span ±2^27, and dates span
// roughly ±367,000 years around 1970 — none needs more than 16 bytes.
INLINE_LEXICAL_MAX :: 16

// Resolve_Iri resolves a dictionary id to the IRI it defines — the
// callback term_decode needs for a typed literal's datatype and a
// split IRI's namespace. It must fail (ok = false) rather than guess
// when the id is unknown or does not name an IRI.
Resolve_Iri :: proc(data: rawptr, id: u64) -> (iri: string, ok: bool)

// term_decode decodes one canonical term encoding into the data model.
// The returned term borrows from `enc` except for a split IRI, whose
// namespace and local name are joined in one allocation from
// `allocator`. Decoding is strict: an unknown tag, a truncated
// payload, or a reference the resolver cannot answer is not ok —
// never a guess, for the same reason an unknown record kind halts.
term_decode :: proc(
	enc: []byte,
	resolve: Resolve_Iri,
	data: rawptr,
	allocator := context.allocator,
) -> (
	t: rdf.Term,
	ok: bool,
) {
	if len(enc) == 0 {
		return nil, false
	}
	payload := enc[1:]
	switch enc[0] {
	case TERM_TAG_IRI:
		return rdf.IRI(string(payload)), true
	case TERM_TAG_BLANK:
		return rdf.Blank_Node(string(payload)), true
	case TERM_TAG_STRING:
		return rdf.Literal{lexical = string(payload), datatype = rdf.XSD_STRING}, true
	case TERM_TAG_LANG:
		if len(payload) < 1 {
			return nil, false
		}
		l := int(payload[0])
		if 1+l > len(payload) {
			return nil, false
		}
		return rdf.Literal{
			lexical = string(payload[1+l:]),
			datatype = rdf.RDF_LANG_STRING,
			language = string(payload[1 : 1+l]),
		}, true
	case TERM_TAG_TYPED:
		if len(payload) < 8 {
			return nil, false
		}
		dt, dt_ok := resolve(data, get_u64(payload))
		if !dt_ok {
			return nil, false
		}
		return rdf.Literal{lexical = string(payload[8:]), datatype = rdf.IRI(dt)}, true
	case TERM_TAG_SPLIT_IRI:
		if len(payload) < 8 {
			return nil, false
		}
		ns, ns_ok := resolve(data, get_u64(payload))
		if !ns_ok {
			return nil, false
		}
		local := payload[8:]
		joined := make([]byte, len(ns)+len(local), allocator)
		copy(joined, ns)
		copy(joined[len(ns):], local)
		return rdf.IRI(string(joined)), true
	}
	return nil, false
}

// inline_term materializes an inlined id as the literal it carries,
// writing the lexical form into the caller's buffer (at least
// INLINE_LEXICAL_MAX bytes) — the term borrows from it. Only ids
// inline_ok accepts decode; everything else, the reserved tag 0
// included, is not ok.
inline_term :: proc(id: u64, buf: []byte) -> (t: rdf.Term, ok: bool) {
	if id&INLINE_FLAG == 0 || !inline_ok(id) {
		return nil, false
	}
	tag := u8(id >> INLINE_TAG_SHIFT) & 0x7F
	payload := id & INLINE_PAYLOAD_MASK
	switch tag {
	case INLINE_TAG_BOOLEAN:
		return rdf.Literal{lexical = "true" if payload == 1 else "false", datatype = rdf.XSD_BOOLEAN}, true
	case INLINE_TAG_INTEGER:
		lex := fmt.bprintf(buf, "%d", i64(payload) - i64(INLINE_BIAS))
		return rdf.Literal{lexical = lex, datatype = rdf.XSD_INTEGER}, true
	case INLINE_TAG_DATE:
		y, m, d := civil_from_days(i64(payload) - i64(INLINE_BIAS))
		lex: string
		if y < 0 {
			lex = fmt.bprintf(buf, "-%04d-%02d-%02d", -y, m, d)
		} else {
			lex = fmt.bprintf(buf, "%04d-%02d-%02d", y, m, d)
		}
		return rdf.Literal{lexical = lex, datatype = XSD_DATE}, true
	}
	return nil, false
}

// civil_from_days converts days since 1970-01-01 to a proleptic
// Gregorian date — Howard Hinnant's civil_from_days, the standard
// closed form.
@(private)
civil_from_days :: proc(days: i64) -> (y: i64, m: int, d: int) {
	z := days + 719468
	era := (z if z >= 0 else z - 146096) / 146097
	doe := z - era*146097
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365
	doy := doe - (365*yoe + yoe/4 - yoe/100)
	mp := (5*doy + 2) / 153
	d = int(doy - (153*mp+2)/5 + 1)
	m = int(mp + 3 if mp < 10 else mp - 9)
	y = yoe + era*400
	if m <= 2 {
		y += 1
	}
	return y, m, d
}
