// Terms to ids (RECORD-T-0013): the package's one term encoder —
// architecture.md par. 3.2's canonical form, the inverse of term.odin's
// decoder — and the writer's intern built on it. Until this task the
// repository had a decoder and no encoder: the writer took pre-encoded
// Term_Defs, every test hand-wrote its bytes, and read.odin carried a
// file-private probe that built the encoding for Resolve alone. That
// probe is promoted here and shared, so the read side's probe and the
// write side's intern cannot disagree about a single byte.
//
// Two gates, in order, decide what a term becomes. The inline gate
// (RECORD-A-0001, frozen at first write): a canonical xsd:boolean,
// xsd:integer, or xsd:date in range is its own resident id and touches
// no dictionary. Everything else encodes, and the encoding is the
// term's identity — a dictionary id is what the arena says about those
// bytes. The encoder emits full IRIs only, never the split form
// (tag 0x06): Resolve probes the full-IRI encoding and nothing else,
// and a writer that never emits a split IRI keeps that probe correct
// by construction rather than by caveat (RECORD-T-0010).
//
// The intern is arena-free on purpose: it reads the published
// dictionary through a snapshot and records what the commit must
// define, and apply (RECORD-T-0015) appends those definitions to the
// arena as part of the candidate build — so a refused or failed apply
// rolls the dictionary back by truncation and nothing more.
package record

import "base:runtime"

import "rdf:rdf"

// Term_Error is how the encoder and the intern refuse. Both are total
// over every term the format can represent; these are the terms it
// cannot, and one the probe cannot answer.
@(private)
Term_Error :: enum u8 {
	None,
	Unsupported_Term, // a language tag over 255 bytes, a base direction with no language, a nil term — the format has no encoding for it
	Unknown_Datatype, // a typed literal whose datatype the resolver does not know — a probe's miss; the intern never returns it, because it defines what it lacks
	Unknown_Component, // a triple term whose component the resolver does not know — Unknown_Datatype's twin one tag over (RECORD-A-0008)
}

// Resolve_Datatype resolves a typed literal's datatype IRI to the
// dictionary id the encoding carries (par. 3.2: datatypes are stored
// as ids, not IRIs) — term_encode's one callback, the mirror of
// term_decode's Resolve_Iri. A probe answers from the published
// dictionary and fails on a miss; the intern answers by interning.
@(private)
Resolve_Datatype :: proc(data: rawptr, iri: rdf.IRI) -> (id: u64, ok: bool)

// Resolve_Term_ID resolves a triple term's component to the on-disk id
// the encoding carries (par. 11.3) — term_encode's second callback,
// the mirror of term_decode's Resolve_Term. **On-disk, not resident**
// (RECORD-A-0008 decision 3): the arena holds the log's term
// definitions verbatim and snapshot_resolve probes them byte for byte,
// so an inlined component must be widened through res_inline_disk
// rather than by a cast, or the two paths disagree and a term that is
// there fails to resolve.
//
// nil refuses every triple term, which is what term_encode did before
// RECORD-I-0004 and what a caller with no dictionary wants.
@(private)
Resolve_Term_ID :: proc(data: rawptr, t: rdf.Term) -> (id: u64, ok: bool)

// term_inline is the inline gate: the resident id of a literal the
// frozen scheme carries in the id itself — xsd:boolean, a canonical
// xsd:integer, a canonical xsd:date, each within RECORD-A-0001's range
// (architecture.md par. 3.4) — and not ok for every other term, which
// encodes instead. Canonical forms only: "034"^^xsd:integer interns,
// "2023-02-30"^^xsd:date interns (an ill-typed literal is still a
// term), and so does "1"^^xsd:boolean. That is RDF term identity; value
// equality across lexical forms is an engine's business. The inverse
// of inline_term.
@(private)
term_inline :: proc(t: rdf.Term) -> (id: Term_ID, ok: bool) {
	lit, is_lit := t.(rdf.Literal)
	if !is_lit || lit.language != "" || lit.direction != .None {
		return 0, false
	}
	switch lit.datatype {
	case rdf.XSD_BOOLEAN:
		switch lit.lexical {
		case "true":
			return Term_ID(RES_INLINE_FLAG | u32(INLINE_TAG_BOOLEAN) << RES_INLINE_TAG_SHIFT | 1), true
		case "false":
			return Term_ID(RES_INLINE_FLAG | u32(INLINE_TAG_BOOLEAN) << RES_INLINE_TAG_SHIFT), true
		}
	case rdf.XSD_INTEGER:
		if v, canon := canonical_integer(lit.lexical); canon {
			return Term_ID(RES_INLINE_FLAG | u32(INLINE_TAG_INTEGER) << RES_INLINE_TAG_SHIFT | u32(v + i64(RES_INLINE_BIAS))), true
		}
	case XSD_DATE:
		if days, canon := canonical_date(lit.lexical); canon {
			return Term_ID(RES_INLINE_FLAG | u32(INLINE_TAG_DATE) << RES_INLINE_TAG_SHIFT | u32(days + i64(RES_INLINE_BIAS))), true
		}
	}
	return 0, false
}

// term_encode builds a term's canonical encoding (architecture.md
// par. 3.2), tag byte included: into `buf` when it fits, else into a
// fresh allocation from `allocator` — compare raw_data against buf to
// tell, and free the latter. It is the one encoder in the system; the
// bytes it produces are what the log's term definitions carry and what
// the arena holds, verbatim. Language tags are lowercased into the
// encoding (RDF 1.1 compares them case-insensitively, so "x"@EN and
// "x"@en must be one term) and are refused over 255 bytes rather than
// truncated. A typed literal's datatype goes through `resolve` first
// and encodes as its on-disk u64 id; xsd:string never does — tag 0x03
// makes "x" and "x"^^xsd:string one term. A base direction encodes
// under tag 0x08 with the same fold on its language half; a direction
// with no language is not an RDF 1.2 term and gets no bytes rather than
// an invented encoding. A triple term encodes under tag 0x07 when
// `resolve_component` can name its parts, and is refused when it is nil.
//
// The inline gate is not consulted here: a caller that wants an id
// tries term_inline first, and the inlined types reach this encoder
// only in their non-canonical forms, which are dictionary terms. That
// ordering is what makes a triple term's components canonical, and so
// what makes par. 3.2's injectivity hold for tag 0x07: one term, one id,
// one encoding.
@(private)
term_encode :: proc(
	t: rdf.Term,
	resolve: Resolve_Datatype,
	data: rawptr,
	buf: []byte,
	resolve_component: Resolve_Term_ID = nil,
	allocator := context.allocator,
) -> (
	enc: []byte,
	err: Term_Error,
) {
	fit :: proc(buf: []byte, n: int, allocator: runtime.Allocator) -> []byte {
		return buf[:n] if n <= len(buf) else make([]byte, n, allocator)
	}
	switch v in t {
	case rdf.IRI:
		enc = fit(buf, 1+len(v), allocator)
		enc[0] = TERM_TAG_IRI
		copy(enc[1:], string(v))
		return enc, .None
	case rdf.Blank_Node:
		enc = fit(buf, 1+len(v), allocator)
		enc[0] = TERM_TAG_BLANK
		copy(enc[1:], string(v))
		return enc, .None
	case rdf.Literal:
		switch {
		case v.direction != .None:
			// RDF 1.2's rdf:dirLangString always carries a language
			// (the parser states it as a type invariant), so a
			// direction without one is refused rather than encoded —
			// admitting it would put a second spelling under one term.
			if v.language == "" || len(v.language) > 255 {
				return nil, .Unsupported_Term
			}
			enc = fit(buf, 3+len(v.language)+len(v.lexical), allocator)
			enc[0] = TERM_TAG_DIR_LANG
			enc[1] = u8(len(v.language))
			enc[2] = u8(v.direction)
			for c, i in transmute([]u8)v.language {
				enc[3+i] = c + 32 if c >= 'A' && c <= 'Z' else c
			}
			copy(enc[3+len(v.language):], v.lexical)
			return enc, .None
		case v.language != "":
			if len(v.language) > 255 {
				return nil, .Unsupported_Term
			}
			enc = fit(buf, 2+len(v.language)+len(v.lexical), allocator)
			enc[0] = TERM_TAG_LANG
			enc[1] = u8(len(v.language))
			for c, i in transmute([]u8)v.language {
				enc[2+i] = c + 32 if c >= 'A' && c <= 'Z' else c
			}
			copy(enc[2+len(v.language):], v.lexical)
			return enc, .None
		case v.datatype == "" || v.datatype == rdf.XSD_STRING:
			enc = fit(buf, 1+len(v.lexical), allocator)
			enc[0] = TERM_TAG_STRING
			copy(enc[1:], v.lexical)
			return enc, .None
		case:
			dt, dt_ok := resolve(data, v.datatype)
			if !dt_ok {
				return nil, .Unknown_Datatype
			}
			assert(dt != 0 && dt&INLINE_FLAG == 0, "term_encode: a datatype resolved to something other than a dictionary id")
			enc = fit(buf, 9+len(v.lexical), allocator)
			enc[0] = TERM_TAG_TYPED
			put_u64_at(enc[1:9], dt)
			copy(enc[9:], v.lexical)
			return enc, .None
		}
	case ^rdf.Triple:
		if resolve_component == nil {
			return nil, .Unsupported_Term
		}
		enc = fit(buf, 1+TERM_TRIPLE_PAYLOAD, allocator)
		enc[0] = TERM_TAG_TRIPLE
		components := [3]rdf.Term{v.subject, v.predicate, v.object}
		for c, i in components {
			id, id_ok := resolve_component(data, c)
			if !id_ok {
				if raw_data(enc) != raw_data(buf) {
					delete(enc, allocator)
				}
				return nil, .Unknown_Component
			}
			assert(id != 0, "term_encode: a component resolved to 0, which is not a term")
			put_u64_at(enc[1+i*8:9+i*8], id)
		}
		return enc, .None
	}
	return nil, .Unsupported_Term // a nil Term is not an RDF term
}

// --- the intern -------------------------------------------------------

// Intern is the writer's term table for one changeset: the published
// dictionary, read through the snapshot it was initialized with, plus
// the definitions this changeset adds — the commit's `terms`, in
// first-appearance order, with ids counted out from the snapshot's
// n_terms exactly as log.md par. 5.2 has a replayer count them, so the
// self-check reproduces them. It is transient: one per apply, freed
// with the call's scratch. The pending map exists because a bulk load
// defines 10^5 terms in one epoch and a linear pending list would be
// quadratic; its keys are views into the definitions' own bytes.
//
// The snapshot is borrowed, not held: the caller keeps it acquired for
// the intern's lifetime. Not safe against a concurrent intern_term on
// the same table — there is one writer, and this is its scratch.
@(private)
Intern :: struct {
	snap:      Snapshot,
	pending:   map[string]Term_ID,
	defs:      [dynamic]Term_Def,
	allocator: runtime.Allocator,
	// component_err carries why a component refused, which
	// Resolve_Term_ID's (id, ok) shape cannot. The intern never returns
	// .Unknown_Component for the same reason it never returns
	// .Unknown_Datatype — it defines what it lacks, so a component only
	// ever fails because the component itself is unsupported, and that
	// is the error the caller should see.
	component_err: Term_Error,
}

// intern_init readies an empty table over the published dictionary
// `snap` sees. Every definition's bytes and the map come from
// `allocator` and go back with intern_destroy.
@(private)
intern_init :: proc(it: ^Intern, snap: Snapshot, allocator := context.allocator) {
	assert(snap.idx != nil, "intern_init: a released snapshot")
	it.snap = snap
	it.allocator = allocator
	it.pending = make(map[string]Term_ID, allocator)
	it.defs = make([dynamic]Term_Def, allocator)
}

// intern_destroy frees the table and every definition it holds. The
// slice intern_defs returned is dead after this.
@(private)
intern_destroy :: proc(it: ^Intern) {
	for d in it.defs {
		delete(d.enc, it.allocator)
	}
	delete(it.defs)
	delete(it.pending)
	it^ = {}
}

// intern_defs is the commit's term definitions so far — ids contiguous
// from n_terms + 1, in the order the intern first saw each term, which
// is the order commit_encode requires. A view into the table, valid
// until the next intern_term or intern_destroy.
@(private)
intern_defs :: proc(it: ^Intern) -> []Term_Def {
	return it.defs[:]
}

// intern_term resolves a term to the resident id the commit will give
// it: an inlined id, touching nothing; the published dictionary's id,
// bounded by the snapshot's n_terms; the pending id of a term this
// changeset already added; or a new pending id, n_terms + 1 + k, with
// its definition recorded. A typed literal's datatype is interned
// before the literal — par. 3.2's ordering rule, which falls out of
// the encoder resolving the datatype to build the literal's bytes.
// Blank-node labels are interned as given (RECORD-I-0003 decision 4):
// identity is global within a store, and scoping a document's labels
// is the loader's job.
//
// **A triple term recurses** (RECORD-I-0004): its three components are
// interned first, each of which may recurse again, and the encoding
// carries their ids — so first-appearance numbering puts every
// component below the term naming it, which is par. 5.2's ordering rule
// made transitive and checkable by comparison. Two triple terms over
// the same components are one term and one id, which falls out of the
// pending map being keyed on bytes once the components have ids.
//
// Refuses what the encoder refuses, with nothing recorded: an
// unsupported term leaves the table as it found it, components a
// recursion had already defined included.
@(private)
intern_term :: proc(it: ^Intern, t: rdf.Term) -> (id: Term_ID, err: Term_Error) {
	if iid, inlined := term_inline(t); inlined {
		return iid, .None
	}
	// The mark makes the recursion transactional: a triple term whose
	// third component refuses must not leave the first two behind.
	mark := len(it.defs)
	buf: [256]byte
	enc, enc_err := term_encode(t, intern_datatype, it, buf[:], intern_component, it.allocator)
	if enc_err != .None {
		intern_rollback(it, mark)
		if enc_err == .Unknown_Component && it.component_err != .None {
			enc_err = it.component_err
			it.component_err = .None
		}
		return 0, enc_err
	}
	defer if raw_data(enc) != raw_data(buf[:]) {
		delete(enc, it.allocator)
	}
	if pid, found := snapshot_find(it.snap, enc); found {
		return pid, .None
	}
	if pid, found := it.pending[string(enc)]; found {
		return pid, .None
	}
	// Ids stay below the inline flag by arithmetic, not by check: a
	// dictionary of 2^31 terms needs more than the 4 GB the arena can
	// address (DICT_MAX_CHUNKS), so dict_add's .Dict_Overflow fires
	// first on any path that gets near.
	id = Term_ID(it.snap.idx.n_terms + 1 + u32(len(it.defs)))
	assert(id & RES_INLINE_FLAG == 0, "intern_term: dictionary ids exhausted")
	// par. 5.2's ordering rule, transitive since RECORD-I-0004 and
	// asserted here for the same reason par. 5.2 keeps the redundant
	// `id` field: it is one comparison, and a violation means the
	// encoder and the numbering disagree about something fundamental.
	// The replay path checks it too, where it is a refusal rather than
	// an assert, because a malformed log is data and this is code.
	assert(term_order_ok(enc, u64(id)), "intern_term: a definition references an id at or above its own")
	owned := make([]byte, len(enc), it.allocator)
	copy(owned, enc)
	append(&it.defs, Term_Def{id = u64(id), enc = owned})
	it.pending[string(owned)] = id
	return id, .None
}

// intern_graph resolves a graph label: nil is the default graph and is
// G = 0 (log.md par. 5.3, amended — the same "none" actor and reason
// use); an IRI or a blank node interns like any term. That a label is
// never a literal, and so never inlined, is the type's doing
// (rdf.Graph_Label) rather than a check here.
@(private)
intern_graph :: proc(it: ^Intern, g: rdf.Graph_Label) -> (id: Term_ID, err: Term_Error) {
	switch v in g {
	case rdf.IRI:
		return intern_term(it, v)
	case rdf.Blank_Node:
		return intern_term(it, v)
	}
	return 0, .None
}

// intern_component is the intern's Resolve_Term_ID: a triple term's
// component interns like any other term, and the id goes into the
// encoding in **on-disk** form (RECORD-A-0008 decision 3) because the
// arena holds the log's bytes verbatim. disk_id is the conversion, and
// it is the identity for a dictionary id — only an inlined component
// actually moves.
@(private = "file")
intern_component :: proc(data: rawptr, t: rdf.Term) -> (id: u64, ok: bool) {
	it := (^Intern)(data)
	rid, err := intern_term(it, t)
	if err != .None {
		it.component_err = err
		return 0, false
	}
	return disk_id(rid), true
}

// intern_rollback drops every definition added since `mark`, keys
// first because the pending map's keys are views into the bytes it
// frees. The recursion's undo: a triple term that refuses on its third
// component leaves the table exactly as it found it.
@(private)
intern_rollback :: proc(it: ^Intern, mark: int) {
	for i := len(it.defs) - 1; i >= mark; i -= 1 {
		delete_key(&it.pending, string(it.defs[i].enc))
		delete(it.defs[i].enc, it.allocator)
	}
	resize(&it.defs, mark)
}

// intern_datatype is the intern's Resolve_Datatype: a datatype is an
// IRI, an IRI always interns, so this cannot fail — which is why the
// intern never returns .Unknown_Datatype.
@(private = "file")
intern_datatype :: proc(data: rawptr, iri: rdf.IRI) -> (id: u64, ok: bool) {
	it := (^Intern)(data)
	rid, err := intern_term(it, iri)
	assert(err == .None, "intern_datatype: an IRI failed to intern")
	return u64(rid), true
}

// --- the inline gate's canonical checks ------------------------------

// canonical_integer accepts exactly the canonical xsd:integer lexical
// forms in RECORD-A-0001's range: an optional minus, no leading zeros,
// no "-0", no "+". Anything else interns instead.
@(private = "file")
canonical_integer :: proc(s: string) -> (v: i64, ok: bool) {
	d := s
	neg := false
	if len(d) > 0 && d[0] == '-' {
		neg = true
		d = d[1:]
	}
	if len(d) == 0 || len(d) > 9 || (len(d) > 1 && d[0] == '0') {
		return 0, false
	}
	for c in transmute([]u8)d {
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v*10 + i64(c-'0')
	}
	if neg {
		if v == 0 { // "-0" is not canonical
			return 0, false
		}
		v = -v
	}
	if v < INLINE_VALUE_MIN || v > INLINE_VALUE_MAX {
		return 0, false
	}
	return v, true
}

// canonical_date accepts the canonical xsd:date lexical forms the
// codec emits — [-]YYYY-MM-DD, year at least four digits and
// zero-padded to exactly four — and validates the civil date by
// round-tripping through the codec's own conversion, so "2023-02-30"
// is refused by arithmetic rather than by a table.
@(private = "file")
canonical_date :: proc(s: string) -> (days: i64, ok: bool) {
	r := s
	neg := false
	if len(r) > 0 && r[0] == '-' {
		neg = true
		r = r[1:]
	}
	// The year is everything before the first dash past it: at least
	// four digits, more only without a leading zero (the %04d shape).
	yl := 0
	for yl < len(r) && r[yl] >= '0' && r[yl] <= '9' {
		yl += 1
	}
	if yl < 4 || (yl > 4 && r[0] == '0') || len(r) != yl+6 || r[yl] != '-' || r[yl+3] != '-' {
		return 0, false
	}
	y, m, d: i64
	for c in transmute([]u8)r[:yl] {
		y = y*10 + i64(c-'0')
	}
	for i in yl + 1 ..< yl + 3 {
		if r[i] < '0' || r[i] > '9' {
			return 0, false
		}
		m = m*10 + i64(r[i]-'0')
	}
	for i in yl + 4 ..< yl + 6 {
		if r[i] < '0' || r[i] > '9' {
			return 0, false
		}
		d = d*10 + i64(r[i]-'0')
	}
	if neg {
		y = -y
	}
	if m < 1 || m > 12 || d < 1 || d > 31 {
		return 0, false
	}
	days = days_from_civil(y, int(m), int(d))
	if days < INLINE_VALUE_MIN || days > INLINE_VALUE_MAX {
		return 0, false
	}
	ry, rm, rd := civil_from_days(days)
	if ry != y || rm != int(m) || rd != int(d) {
		return 0, false
	}
	return days, true
}

// days_from_civil is civil_from_days' inverse — Howard Hinnant's
// days_from_civil, the same closed form the codec uses.
@(private = "file")
days_from_civil :: proc(y: i64, m, d: int) -> i64 {
	yy := y if m > 2 else y - 1
	era := (yy if yy >= 0 else yy-399) / 400
	yoe := yy - era*400
	doy := i64((153*(m+(-3 if m > 2 else 9)) + 2)/5 + d - 1)
	doe := yoe*365 + yoe/4 - yoe/100 + doy
	return era*146097 + doe - 719468
}
