// The read API (RECORD-T-0010): api.md par. 12's layer 1 and its
// resolution procedures, on the snapshot layer 0 ships — Match as one
// prefix window over one permutation tree, two rank descents wide
// (RECORD-A-0012), Iter streaming facts through the filter set,
// Resolve with the cheap miss, and term materialization over the arena
// and the codec. This is the surface
// odin-rdf-sparql and odin-rdf-shacl eventually target; nothing here
// materializes a result set, and nothing reaches past a snapshot.
//
// Lifetimes: a Range and a Scan borrow their snapshot — they take no
// reference of their own, so they are valid exactly while the caller
// holds the snapshot they were made from. Bytes returned by
// snapshot_bytes are arena views, valid for the life of the store.
package record

import "base:runtime"

import "core:sync"

import "rdf:rdf"

// MATCH_DEFAULT_GRAPH binds a pattern's G to the default graph. The
// bit pattern is the reserved-invalid resident id (api.md par. 3:
// inline flag set, tag 0 — "rejected on decode"), so it can never
// collide with a term. It exists because the natural spelling is
// taken: facts store the default graph as G = 0 (log.md par. 5.3,
// amended), and a pattern's 0 means unbound.
MATCH_DEFAULT_GRAPH :: Term_ID(0x8000_0000)

// Pattern is a quad pattern over resident ids: 0 is unbound, anything
// else must match the fact's component exactly. The zero value matches
// every fact. G takes MATCH_DEFAULT_GRAPH to bind the default graph
// (see above); S, P, and O never need it, because no fact carries 0
// there.
Pattern :: struct {
	s, p, o, g: Term_ID,
}

// Origin selects by provenance (api.md par. 12.5), and it has no
// default deliberately: asserted-only and any answer different
// questions — what was recorded versus what is entailed — and
// architecture.md A.5 forbids ever conflating them silently. The zero
// value is invalid and range_iter refuses it.
Origin :: enum u8 {
	Asserted = 1, // only what was recorded
	Derived  = 2, // only what was inferred
	Any      = 3, // both
}

// Graph_Scope says what a Filter's graph set means, and has no default
// deliberately, for the reason Origin has none: "every graph" and
// "only these" answer different questions, and a zero value picking
// one silently is how an empty set came to read the whole store —
// Odin nils some empty slices and not others, so a nil test was
// letting allocation history choose (RECORD-T-0029). The zero value
// is invalid and range_iter refuses it.
Graph_Scope :: enum u8 {
	All = 1, // every graph; `graphs` must be empty
	Set = 2, // only the graphs listed — an empty list admits nothing
}

// Filter is everything the prefix could not express, evaluated per
// candidate by the scan. `scope` and `graphs` together scope to a set
// of graphs (api.md par. 12.8's FROM/FROM NAMED shape): under .Set,
// `graphs` is a small slice scanned linearly, holding stored G
// components — 0 or MATCH_DEFAULT_GRAPH for the default graph, both
// accepted — and its length alone decides what it admits; no pointer
// is consulted. It is distinct from Pattern.g, which is what GRAPH ?g
// binds; the two intersect.
Filter :: struct {
	origin: Origin,
	scope:  Graph_Scope,
	graphs: []Term_ID, // read under .Set only
}

// Range is what Match returns: a window into one permutation as two
// ranks, the order it is in, and the pattern the prefix could not
// express — a view, not a container; nothing is copied and range_len
// is arithmetic. (RECORD-A-0005 had promised a second `delta` run here
// for a structure never built; RECORD-A-0012 replaced the structure
// instead, and no consumer had named the field.)
Range :: struct {
	snap:     Snapshot,
	order:    Order,
	lo, hi:   int,
	residual: Pattern,
}

// range_len is the candidate count: an exact count of every fact
// generation in the window, and therefore an exact upper bound on
// visible matches at any epoch — what a join planner prices with
// (api.md par. 12.4). O(1) here; the descents were paid in Match.
range_len :: proc(r: Range) -> int {
	return r.hi - r.lo
}

// Scan streams a range through the filters. Concrete, not an
// interface: the hot path is a cursor step, one gather into the fact
// table, and register compares (api.md par. 12.3's stated shape).
Scan :: struct {
	snap:    Snapshot,
	cur:     Perm_Cursor, // the unconsumed window
	origin:  Origin,
	graphs:  []Term_ID, // the set to require membership of, when scoped
	s, p, o: Term_ID, // residual component checks; 0 = not checked
	g_want:  Term_ID, // the stored G value to require when g_bound
	g_bound: bool,
	scoped:  bool, // Filter.scope == .Set: decided by length, never by pointer
}

// snapshot_match answers a pattern as one prefix range, choosing the
// permutation api.md par. 12.2 prescribes: the order whose key starts
// with the pattern's bound components. G leads exactly one order,
// GPOS, chosen only when G is bound, S is not, and O is not bound
// without P (RECORD-T-0028, on RECORD-A-0004's own review trigger);
// everywhere else a bound graph is residual — one comparison against
// a field the visibility test already loaded. Two rank descents per
// bound prefix; a pattern this snapshot's terms cannot satisfy simply
// finds an empty window.
snapshot_match :: proc(snap: Snapshot, p: Pattern) -> Range {
	order, _ := choose_order(p)
	return snapshot_match_as(snap, p, order)
}

// snapshot_match_as answers the pattern from the order the caller
// names — the planner's entry point (api.md par. 12.2): a merge join
// needs its inputs sorted on the join variable, so where several
// orders serve, the choice is the planner's. Bound components that
// lead the order's key become the prefix; every other bound component
// is checked residually by the scan, so any order answers any pattern,
// only the window width differs.
snapshot_match_as :: proc(snap: Snapshot, p: Pattern, order: Order) -> Range {
	assert(snap.idx != nil, "snapshot_match_as: a released snapshot")
	key := order_key(order)
	want: [4]Term_ID
	k := 0
	for ; k < 4; k += 1 {
		v := pattern_component(p, key[k])
		if v == 0 {
			break
		}
		// A pattern binds the default graph as MATCH_DEFAULT_GRAPH and
		// a fact stores it as 0; the prefix compares against what facts
		// store, and the bound test above needed the spelling.
		want[k] = 0 if key[k] == .G && v == MATCH_DEFAULT_GRAPH else v
	}
	set := snap.idx
	lo := perm_rank(set.leaves, set.inners, set.facts, key, set.ord[order], want, k, false)
	hi := perm_rank(set.leaves, set.inners, set.facts, key, set.ord[order], want, k, true)
	return Range{snap = snap, order = order, lo = lo, hi = hi, residual = p}
}

// range_iter binds the filter set and returns the scan. Origin and
// graph scope must be stated — the zero value of either is refused
// here, per api.md par. 12.5 and RECORD-T-0029 — and a scope of .All
// carrying a set is refused as a contradiction rather than resolved
// either way. The residual checks are the full pattern: prefix
// components pass trivially (they are equal by construction), and
// re-checking them costs register compares against tracking which were
// covered.
range_iter :: proc(r: Range, f: Filter) -> Scan {
	assert(r.snap.idx != nil, "range_iter: a released snapshot")
	assert(f.origin >= .Asserted && f.origin <= .Any, "range_iter: origin must be stated (api.md par. 12.5)")
	assert(f.scope == .All || f.scope == .Set, "range_iter: graph scope must be stated (RECORD-T-0029)")
	assert(f.scope == .Set || len(f.graphs) == 0, "range_iter: scope .All with a graph set — say .Set")
	set := r.snap.idx
	sc := Scan{
		snap   = r.snap,
		cur    = perm_cursor(set.leaves, set.inners, set.ord[r.order], r.lo, r.hi),
		origin = f.origin,
		graphs = f.graphs,
		scoped = f.scope == .Set,
		s      = r.residual.s,
		p      = r.residual.p,
		o      = r.residual.o,
	}
	if r.residual.g != 0 {
		sc.g_bound = true
		sc.g_want = 0 if r.residual.g == MATCH_DEFAULT_GRAPH else r.residual.g
	}
	return sc
}

// scan_next yields the next matching fact id, in the range's order.
// Per candidate: the visibility test (assert <= epoch < retract, with
// retract loaded atomically — the one field a live writer mutates, and
// a mutation a reader misses is invisible by monotonicity), the
// residual components, origin, and the graph set. False ends the scan.
scan_next :: proc(sc: ^Scan) -> (id: Fact_ID, ok: bool) {
	candidates: for {
		ok = false
		if id, ok = perm_next(&sc.cur); !ok {
			break
		}
		f := fact_in(sc.snap.idx.facts, id)
		retract := sync.atomic_load_explicit(&f.retract, .Relaxed)
		if !(f.assert <= sc.snap.epoch && sc.snap.epoch < retract) {
			continue
		}
		if sc.s != 0 && f.s != sc.s {
			continue
		}
		if sc.p != 0 && f.p != sc.p {
			continue
		}
		if sc.o != 0 && f.o != sc.o {
			continue
		}
		if sc.g_bound && f.g != sc.g_want {
			continue
		}
		if sc.origin != .Any && snapshot_derived(sc.snap, id) != (sc.origin == .Derived) {
			continue
		}
		if sc.scoped {
			for g in sc.graphs {
				if f.g == g || (f.g == 0 && g == MATCH_DEFAULT_GRAPH) {
					return id, true
				}
			}
			continue candidates
		}
		return id, true
	}
	return 0, false
}

// snapshot_resolve resolves a term to its resident id — the fast
// reject of api.md par. 12.2: a term this store has never seen is an
// ordinary case and costs a hash probe, never a scan. The inline gate
// is tried first (par. 12.7): a canonical xsd:integer, xsd:boolean, or
// xsd:date in RECORD-A-0001's range is its own id and touches no
// dictionary. Everything else probes the arena by its canonical
// encoding, built by the package's one encoder (intern.odin) in
// scratch and freed before returning — nothing is interned. A typed
// literal's datatype resolves recursively, and so does **each component
// of a triple term** (RECORD-I-0004) — a component this snapshot has
// never seen makes the whole term a miss, which is par. 12.2's
// fast-reject one level down. A datatype this snapshot does not know
// makes the literal a miss, as does any term the format cannot encode. The id must have been interned at or before this
// snapshot's publication: a term the writer added since is a miss
// here, by the n_terms bound.
snapshot_resolve :: proc(snap: Snapshot, t: rdf.Term, allocator := context.allocator) -> (id: Term_ID, ok: bool) {
	assert(snap.idx != nil, "snapshot_resolve: a released snapshot")
	if iid, inlined := term_inline(t); inlined {
		return iid, true
	}
	snap := snap
	buf: [256]u8
	enc, err := term_encode(t, resolve_snap_datatype, &snap, buf[:], resolve_snap_component, allocator)
	if err != .None {
		return 0, false
	}
	defer if raw_data(enc) != raw_data(buf[:]) {
		delete(enc, allocator)
	}
	return snapshot_find(snap, enc)
}

// snapshot_find is the dictionary probe behind snapshot_resolve and
// the intern: a canonical encoding to the id this snapshot knows it
// by — a binary search of the set's term index (termindex.odin), so a
// term defined after publication is a miss by construction rather
// than by a bound.
@(private)
snapshot_find :: proc(snap: Snapshot, enc: []byte) -> (id: Term_ID, ok: bool) {
	return term_index_find(snap.idx, enc)
}

// Term_Kind is what snapshot_kind answers: the kinds of RDF term this
// store can hold, with no reference to how they are encoded. Triple
// arrived with RDF 1.2 (RECORD-I-0004) and is the direct replacement
// for odin-rdf-store's id_kind(id) == .Triple.
Term_Kind :: enum u8 {
	IRI,
	Blank,
	Literal,
	Triple,
}

// snapshot_kind reports a resident id's kind without decoding it —
// what an engine reads off a tagged id in odin-rdf-store, answered
// here from the one place the information is (RECORD-I-0003
// decision 8): an inlined id is always a literal, and a dictionary
// id's kind is its encoding's tag byte, which this procedure keeps
// private to the store so no consumer depends on the tag layout.
// Allocation-free; asserts on an id this snapshot does not know, as
// snapshot_bytes does.
snapshot_kind :: proc(snap: Snapshot, id: Term_ID) -> Term_Kind {
	assert(snap.idx != nil, "snapshot_kind: a released snapshot")
	if id & RES_INLINE_FLAG != 0 {
		return .Literal
	}
	assert(id != 0 && u32(id) <= snap.idx.n_terms, "snapshot_kind: not a term of this snapshot")
	// Every tag named, and an unrecognised one panics rather than
	// answers (RECORD-T-0021 decision 8). The arm this replaces fell
	// through to .Literal, which was right for every tag that existed
	// and would have been silently wrong for 0x07 — and silently wrong
	// in the one procedure whose whole job is to keep the tag layout
	// private, so no consumer could have checked it.
	switch set_bytes(snap.idx, id)[0] {
	case TERM_TAG_IRI, TERM_TAG_SPLIT_IRI:
		return .IRI
	case TERM_TAG_BLANK:
		return .Blank
	case TERM_TAG_STRING, TERM_TAG_LANG, TERM_TAG_TYPED, TERM_TAG_DIR_LANG:
		return .Literal
	case TERM_TAG_TRIPLE:
		return .Triple
	}
	panic("snapshot_kind: a term encoding with a tag this store does not define")
}

// snapshot_triple_parts reads a triple term's three components as
// resident ids — a tag check and three reads out of the arena, with no
// allocation, no decode and no recursion (RECORD-I-0004 par. 7). This is
// the cheap path: a query engine taking a triple term apart wants the
// *ids*, and materializing the term to re-resolve its parts is what
// odin-rdf-store had to do (odin-rdf-sparql's SPARQL-T-0019). The
// components are in the encoding, so they are simply there.
//
// Published rather than left to consumers on purpose: parsing the
// encoding by hand is exactly what a published API exists to prevent.
// Not ok for an inlined id or any term that is not a triple term;
// asserts on an id this snapshot does not know, as snapshot_bytes does.
snapshot_triple_parts :: proc(snap: Snapshot, id: Term_ID) -> (parts: [3]Term_ID, ok: bool) {
	assert(snap.idx != nil, "snapshot_triple_parts: a released snapshot")
	if id & RES_INLINE_FLAG != 0 {
		return parts, false // an inlined literal is never a triple term
	}
	assert(id != 0 && u32(id) <= snap.idx.n_terms, "snapshot_triple_parts: not a term of this snapshot")
	enc := set_bytes(snap.idx, id)
	if len(enc) != 1+TERM_TRIPLE_PAYLOAD || enc[0] != TERM_TAG_TRIPLE {
		return parts, false
	}
	// The arena holds the log's bytes, so the ids in it are on-disk
	// ids; resident_id is the re-tag, and it is the identity for every
	// dictionary id (RECORD-A-0008 decision 3).
	for i in 0 ..< 3 {
		parts[i] = resident_id(get_u64(enc[1+i*8:]))
	}
	return parts, true
}

// snapshot_exists answers whether any fact matches — api.md par. 12.5's
// layer-2 existence test, which is layer 1 with a loop around it: the
// range, the scan, the first hit. It is Apply's live-quad check
// (log.md par. 5.3) made public, and a planner's emptiness probe.
snapshot_exists :: proc(snap: Snapshot, p: Pattern, f: Filter) -> bool {
	sc := range_iter(snapshot_match(snap, p), f)
	_, hit := scan_next(&sc)
	return hit
}

// snapshot_bytes returns a dictionary term's canonical encoding as a
// view into the arena — no copy, no allocation, valid for the life of
// the store (api.md par. 12.7). Dictionary ids only: an inlined id has
// no bytes anywhere, and materializes through snapshot_term.
snapshot_bytes :: proc(snap: Snapshot, id: Term_ID) -> []byte {
	assert(snap.idx != nil, "snapshot_bytes: a released snapshot")
	assert(id != 0 && id&RES_INLINE_FLAG == 0 && u32(id) <= snap.idx.n_terms, "snapshot_bytes: not a dictionary id of this snapshot")
	return set_bytes(snap.idx, id)
}

// snapshot_term materializes a resident id as a data-model term — the
// codec's second consumer, as RECORD-T-0005 named it. A dictionary id
// decodes from its arena bytes, borrowing them; an inlined id
// materializes into the caller's buffer, at least INLINE_LEXICAL_MAX
// bytes, and borrows that. Not ok for id 0, an id past the snapshot, or
// bytes the codec refuses.
//
// **Two kinds own instead of borrowing, and snapshot_term_destroy is
// how a caller frees them without having to know which** — call it on
// whatever comes back and it is a no-op for the borrowing kinds. A
// split IRI joins its namespace and local name in one allocation (it
// always has; the verb is new). A **triple term is wholly owned**,
// every component allocated from `allocator`, so nothing in it dies
// with the store and rdf.destroy_term frees it exactly
// (RECORD-A-0008 decision 2).
//
// A query engine on the hot path should not be here at all: taking a
// triple term apart is snapshot_triple_parts, which allocates nothing.
// This is the answer boundary.
snapshot_term :: proc(
	snap: Snapshot,
	id: Term_ID,
	buf: []byte,
	allocator := context.allocator,
) -> (
	t: rdf.Term,
	ok: bool,
) {
	assert(snap.idx != nil, "snapshot_term: a released snapshot")
	if id & RES_INLINE_FLAG != 0 {
		return inline_term(res_inline_disk(id), buf)
	}
	if id == 0 || u32(id) > snap.idx.n_terms {
		return nil, false
	}
	snap := snap
	return term_decode(set_bytes(snap.idx, id), resolve_snap_iri, &snap, resolve_snap_term, allocator)
}

// snapshot_term_destroy frees what snapshot_term returned, and is total
// over every kind it can return: nothing for the borrowing kinds, the
// joined string for a split IRI, the whole tree for a triple term. The
// id is a parameter because that is what says which case this is — the
// term alone cannot tell a joined IRI from one borrowed out of the
// arena, and guessing from a pointer's address would be a worse kind of
// clever.
//
// It is safe to call on anything snapshot_term produced, including the
// results it refused (a nil term frees nothing), which is what lets a
// caller pair it with every call rather than only some.
snapshot_term_destroy :: proc(snap: Snapshot, id: Term_ID, t: rdf.Term, allocator := context.allocator) {
	if t == nil || id & RES_INLINE_FLAG != 0 || id == 0 {
		return
	}
	assert(snap.idx != nil, "snapshot_term_destroy: a released snapshot")
	if u32(id) > snap.idx.n_terms {
		return
	}
	switch set_bytes(snap.idx, id)[0] {
	case TERM_TAG_SPLIT_IRI:
		delete(string(t.(rdf.IRI)), allocator)
	case TERM_TAG_TRIPLE:
		rdf.destroy_term(t, allocator)
	}
}

// --- order selection -------------------------------------------------

// choose_order is api.md par. 12.2's table: the order whose key leads
// with the bound components, longest prefix first, SPOG for the full
// scan. G enters the choice in exactly one case (RECORD-T-0028): bound,
// with S unbound and O not bound without P, it leads — GPOS answers
// "everything in this graph", "every P in it" and "instances of a
// class in it" with a window that is exactly the answer, where the
// residual compare scanned every such fact in the store. With S bound
// the SPO family is selective enough that the residual is noise, and
// (G, O) alone stays O-first for the same reason.
@(private = "file")
choose_order :: proc(p: Pattern) -> (o: Order, k: int) {
	bs, bp, bo, bg := p.s != 0, p.p != 0, p.o != 0, p.g != 0
	switch {
	case bs && bp:
		return .SPOG, 3 if bo else 2
	case bs && bo:
		return .SOPG, 2
	case bs:
		return .SPOG, 1
	case bg && bp:
		return .GPOS, 3 if bo else 2
	case bp && bo:
		return .POSG, 2
	case bp:
		return .PSOG, 1
	case bo:
		return .OSPG, 1
	case bg:
		return .GPOS, 1
	}
	return .SPOG, 0
}

// pattern_component reads one position of a pattern as spelled — for
// G that is MATCH_DEFAULT_GRAPH when the default graph is bound, which
// snapshot_match_as maps to the stored 0 as it enters the prefix.
@(private = "file")
pattern_component :: proc(p: Pattern, c: Component) -> Term_ID {
	switch c {
	case .S:
		return p.s
	case .P:
		return p.p
	case .O:
		return p.o
	case .G:
		return p.g
	}
	unreachable()
}

// --- resolution helpers ----------------------------------------------

// res_inline_disk re-tags a resident inlined id back to the on-disk
// encoding — resident_id's inverse, for handing to the codec.
@(private)
res_inline_disk :: proc(id: Term_ID) -> u64 {
	assert(id & RES_INLINE_FLAG != 0, "res_inline_disk: not an inlined id")
	tag := u64(id >> RES_INLINE_TAG_SHIFT) & 0x7
	payload := u64(id & RES_INLINE_PAYLOAD_MASK)
	if u8(tag) != INLINE_TAG_BOOLEAN {
		payload = u64(i64(payload) - i64(RES_INLINE_BIAS) + i64(INLINE_BIAS))
	}
	return INLINE_FLAG | tag << INLINE_TAG_SHIFT | payload
}

// resolve_snap_datatype is the encoder's Resolve_Datatype over a
// snapshot: the datatype IRI must already be a dictionary term this
// snapshot knows, or the literal that names it is a miss. One level
// of recursion through snapshot_resolve, which an IRI always ends.
@(private = "file")
resolve_snap_datatype :: proc(data: rawptr, iri: rdf.IRI) -> (id: u64, ok: bool) {
	snap := (^Snapshot)(data)
	rid, found := snapshot_resolve(snap^, iri)
	return u64(rid), found
}

// resolve_snap_component is the encoder's Resolve_Term_ID over a
// snapshot: a triple term's component must already be a term this
// snapshot knows, or the term naming it is a miss. The id goes into the
// encoding in on-disk form (RECORD-A-0008 decision 3), which is what
// makes the bytes built here byte-identical to the arena's — and
// therefore findable. Recursion ends because a component's id is always
// lower than the id of the term naming it.
@(private = "file")
resolve_snap_component :: proc(data: rawptr, t: rdf.Term) -> (id: u64, ok: bool) {
	snap := (^Snapshot)(data)
	rid, found := snapshot_resolve(snap^, t)
	if !found {
		return 0, false
	}
	return disk_id(rid), true
}

// resolve_snap_term is the codec's Resolve_Term over a snapshot: a
// triple term's component, materialized and **owned**, because the
// decoded tree owns everything in it. The id arrives in on-disk form,
// straight out of the encoding.
//
// The clone is what makes ownership uniform, and it is deliberate
// waste on a path api.md par. 12.7 does not put on anyone's hot loop:
// an inlined literal materializes with a *static* datatype IRI that
// must not be freed, and an arena-borrowed term must not be freed
// either, so both are copied rather than have the tree hold a mixture
// a caller could not free with one verb. A component that is itself a
// triple term is already owned and passes straight through.
@(private = "file")
resolve_snap_term :: proc(data: rawptr, id: u64, allocator: runtime.Allocator) -> (t: rdf.Term, ok: bool) {
	snap := (^Snapshot)(data)
	if id & INLINE_FLAG != 0 {
		buf: [INLINE_LEXICAL_MAX]byte
		lit, lok := inline_term(id, buf[:])
		if !lok {
			return nil, false
		}
		return rdf.clone_term(lit, allocator), true
	}
	if id == 0 || id > u64(snap.idx.n_terms) {
		return nil, false
	}
	rid := Term_ID(id)
	buf: [INLINE_LEXICAL_MAX]byte
	borrowed, bok := snapshot_term(snap^, rid, buf[:], allocator)
	if !bok {
		return nil, false
	}
	if _, is_triple := borrowed.(^rdf.Triple); is_triple {
		return borrowed, true // already wholly owned; nothing to copy
	}
	owned := rdf.clone_term(borrowed, allocator)
	snapshot_term_destroy(snap^, rid, borrowed, allocator)
	return owned, true
}

// resolve_snap_iri is the codec's Resolve_Iri over a snapshot: the id
// must be a dictionary id this snapshot knows, and its encoding must
// be a full IRI — the only shape a datatype or namespace reference may
// have.
@(private = "file")
resolve_snap_iri :: proc(data: rawptr, id: u64) -> (iri: string, ok: bool) {
	snap := (^Snapshot)(data)
	if id == 0 || id&INLINE_FLAG != 0 || id > u64(snap.idx.n_terms) {
		return "", false
	}
	enc := set_bytes(snap.idx, Term_ID(id))
	if len(enc) == 0 || enc[0] != TERM_TAG_IRI {
		return "", false
	}
	return string(enc[1:]), true
}
