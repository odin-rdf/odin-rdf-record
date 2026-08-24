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

import "base:runtime"

import "core:fmt"

import "rdf:rdf"

// Term encoding tags, architecture.md par. 3.2 — with 0x06 from
// par. 3.5, and 0x07 and 0x08 for RDF 1.2's two term kinds
// (RECORD-I-0004). 0x07 is the byte par. 11.3 reserved, in the layout
// it specified; 0x08 had no reservation and is chosen in RECORD-A-0007.
TERM_TAG_IRI :: u8(0x01)
TERM_TAG_BLANK :: u8(0x02)
TERM_TAG_STRING :: u8(0x03)
TERM_TAG_LANG :: u8(0x04)
TERM_TAG_TYPED :: u8(0x05)
TERM_TAG_SPLIT_IRI :: u8(0x06)
TERM_TAG_TRIPLE :: u8(0x07)
TERM_TAG_DIR_LANG :: u8(0x08)

// TERM_TRIPLE_PAYLOAD is a triple term's payload width: three on-disk
// component ids, par. 11.3. Fixed, and checked exactly — a tolerated
// tail would be a second encoding of one term, which is par. 3.2's
// injectivity gone.
TERM_TRIPLE_PAYLOAD :: 3 * 8

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

// Resolve_Term resolves a dictionary or inlined id to the term it
// names — the callback term_decode needs for a triple term's three
// components, which are arbitrary terms and may themselves be triple
// terms (RECORD-A-0008 decision 1). Its answer must be allocated from
// `allocator` and is owned by the caller: a decoded triple term is
// wholly owned, so that the parser's rdf.destroy_term — which for a
// ^rdf.Triple deep frees every component string and then the node
// itself — is exactly right rather than catastrophic. Note the verb:
// rdf.destroy_triple takes a Triple by value and leaves the node,
// so a decoded triple term is freed with rdf.destroy_term. It must fail rather than guess on an id it does
// not know.
//
// nil is a legal resolver and refuses every triple term, which is what
// a caller holding no dictionary wants and what this codec did before
// RECORD-I-0004.
Resolve_Term :: proc(data: rawptr, id: u64, allocator: runtime.Allocator) -> (t: rdf.Term, ok: bool)

// term_decode decodes one canonical term encoding into the data model.
// The returned term borrows from `enc`, with two exceptions that own
// and must be freed: a split IRI, whose namespace and local name are
// joined in one allocation from `allocator`, and a **triple term,
// which is wholly owned** — every component owned by `allocator`, so
// rdf.destroy_term frees it exactly (RECORD-A-0008 decision 2). Decoding is strict: an
// unknown tag, a truncated payload, a payload whose fixed width is
// wrong, or a reference the resolver cannot answer is not ok — never a
// guess, for the same reason an unknown record kind halts.
term_decode :: proc(
	enc: []byte,
	resolve: Resolve_Iri,
	data: rawptr,
	resolve_term: Resolve_Term = nil,
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
	case TERM_TAG_TRIPLE:
		// par. 11.3: three on-disk component ids, fixed width, checked
		// exactly. A resolver-less caller refuses, which is what every
		// caller did before this tag existed.
		if resolve_term == nil || len(payload) != TERM_TRIPLE_PAYLOAD {
			return nil, false
		}
		parts: [3]rdf.Term
		built := 0
		for i in 0 ..< 3 {
			id := get_u64(payload[i * 8:])
			if id == 0 {
				break // 0 is "none" — the default graph, an absent actor — never a term
			}
			p, p_ok := resolve_term(data, id, allocator)
			if !p_ok {
				break
			}
			parts[i] = p
			built += 1
		}
		if built < 3 {
			for i in 0 ..< built {
				rdf.destroy_term(parts[i], allocator)
			}
			return nil, false
		}
		tr := new(rdf.Triple, allocator)
		tr^ = rdf.Triple {
			subject   = parts[0],
			predicate = parts[1],
			object    = parts[2],
		}
		return tr, true
	case TERM_TAG_DIR_LANG:
		// RECORD-A-0007: tag | langlen u8 | dir u8 | lang | lexical,
		// with three refusals that keep it injective. A zero language
		// length and a .None direction are the two shapes tag 0x04
		// already encodes; a direction byte outside rdf.Direction is
		// not a direction. All three are decoder-side because par. 3.2's
		// injectivity is the format's property, not this encoder's.
		if len(payload) < 2 {
			return nil, false
		}
		l := int(payload[0])
		if l == 0 || 2+l > len(payload) {
			return nil, false
		}
		dir: rdf.Direction
		switch payload[1] {
		case u8(rdf.Direction.LTR):
			dir = .LTR
		case u8(rdf.Direction.RTL):
			dir = .RTL
		case:
			return nil, false
		}
		return rdf.Literal{
			lexical = string(payload[2+l:]),
			datatype = rdf.RDF_DIR_LANG_STRING,
			language = string(payload[2 : 2+l]),
			direction = dir,
		}, true
	}
	return nil, false
}

// term_refs collects the dictionary ids a canonical encoding
// references: a typed literal's datatype (0x05), a split IRI's
// namespace (0x06), or a triple term's three components (0x07).
// Everything else references nothing, and an *inlined* component is
// not a dictionary id and so is not a reference — it carries its own
// value and has no definition to be ordered against (log.md par. 5.2:
// "inlined terms have no definitions").
//
// It exists for the ordering rule par. 5.2 states and RECORD-I-0004
// made transitive: a term's references must be defined before it. Ids
// are assigned in first-appearance order, so that constraint is one
// comparison — a reference is *lower* than the id referencing it —
// rather than any bookkeeping. Not ok on an encoding this codec cannot
// read at all; a caller checking order has no business guessing.
term_refs :: proc(enc: []byte) -> (refs: [3]u64, n: int, ok: bool) {
	if len(enc) == 0 {
		return refs, 0, false
	}
	payload := enc[1:]
	switch enc[0] {
	case TERM_TAG_IRI, TERM_TAG_BLANK, TERM_TAG_STRING:
		return refs, 0, true
	case TERM_TAG_LANG:
		return refs, 0, len(payload) >= 1 && 1+int(payload[0]) <= len(payload)
	case TERM_TAG_DIR_LANG:
		return refs, 0, len(payload) >= 2 && 2+int(payload[0]) <= len(payload)
	case TERM_TAG_TYPED, TERM_TAG_SPLIT_IRI:
		if len(payload) < 8 {
			return refs, 0, false
		}
		refs[0] = get_u64(payload)
		return refs, 1, true
	case TERM_TAG_TRIPLE:
		if len(payload) != TERM_TRIPLE_PAYLOAD {
			return refs, 0, false
		}
		n = 0
		for i in 0 ..< 3 {
			id := get_u64(payload[i * 8:])
			if id & INLINE_FLAG != 0 {
				continue // carries its own value; nothing to order against
			}
			refs[n] = id
			n += 1
		}
		return refs, n, true
	}
	return refs, 0, false
}

// term_order_ok is par. 5.2's ordering rule as one comparison per
// reference: every dictionary id an encoding names must already be
// defined, which under first-appearance numbering means strictly lower
// than the id being defined. 0 is not a term, so it fails too. False
// on an encoding term_refs cannot read.
term_order_ok :: proc(enc: []byte, id: u64) -> bool {
	refs, n, ok := term_refs(enc)
	if !ok {
		return false
	}
	for i in 0 ..< n {
		if refs[i] == 0 || refs[i] >= id {
			return false
		}
	}
	return true
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
