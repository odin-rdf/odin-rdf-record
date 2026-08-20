// The read API (RECORD-T-0010): api.md par. 12's layer 1 and its
// resolution procedures, on the snapshot layer 0 ships — Match as one
// binary-searched prefix range over one permutation, Iter streaming
// facts through the filter set, Resolve with the cheap miss, and term
// materialization over the arena and the codec. This is the surface
// odin-rdf-sparql and odin-rdf-shacl eventually target; nothing here
// materializes a result set, and nothing reaches past a snapshot.
//
// Lifetimes: a Range and a Scan borrow their snapshot — they take no
// reference of their own, so they are valid exactly while the caller
// holds the snapshot they were made from. Bytes returned by
// snapshot_bytes are arena views, valid for the life of the store.
package record

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

// Filter is everything the prefix could not express, evaluated per
// candidate by the scan. `graphs` scopes to a set of graphs (api.md
// par. 12.8's FROM/FROM NAMED shape): nil means every graph, otherwise
// a small slice scanned linearly, holding stored G components — 0 or
// MATCH_DEFAULT_GRAPH for the default graph, both accepted. It is
// distinct from Pattern.g, which is what GRAPH ?g binds.
Filter :: struct {
	origin: Origin,
	graphs: []Term_ID,
}

// Range is what Match returns: a window into one permutation, the
// order it is in, and the pattern the prefix could not express — a
// view, not a container; nothing is copied and range_len is
// arithmetic. `delta` is the second run of RECORD-A-0005's promised
// shape and is permanently empty until Apply's delta structure lands;
// it is carried so that adopting deltas changes the scan's internals
// and nothing downstream.
Range :: struct {
	snap:     Snapshot,
	order:    Order,
	main:     []Fact_ID,
	delta:    []Fact_ID,
	residual: Pattern,
}

// range_len is the candidate count: an exact count of every fact
// generation in the window, and therefore an exact upper bound on
// visible matches at any epoch — what a join planner prices with
// (api.md par. 12.4). O(1) here; the binary searches were paid in
// Match.
range_len :: proc(r: Range) -> int {
	return len(r.main) + len(r.delta)
}

// Scan streams a range through the filters. Concrete, not an
// interface: the hot path is a bounds check, one gather into the fact
// table, and register compares (api.md par. 12.3's stated shape).
Scan :: struct {
	snap:    Snapshot,
	ids:     []Fact_ID, // the unconsumed window
	origin:  Origin,
	graphs:  []Term_ID,
	s, p, o: Term_ID, // residual component checks; 0 = not checked
	g_want:  Term_ID, // the stored G value to require when g_bound
	g_bound: bool,
}

// snapshot_match answers a pattern as one prefix range, choosing the
// permutation api.md par. 12.2 prescribes: the order whose key starts
// with the pattern's bound components, G never among them — a bound
// graph is always residual (RECORD-A-0004), one comparison against a
// field the visibility test already loaded. Two binary searches per
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
	want: [3]Term_ID
	k := 0
	for ; k < 3; k += 1 {
		v := pattern_component(p, key[k])
		if v == 0 {
			break
		}
		want[k] = v
	}
	ids := snap.idx.ord[order]
	lo := prefix_bound(snap.idx, ids, key, want, k, false)
	hi := prefix_bound(snap.idx, ids, key, want, k, true)
	return Range{snap = snap, order = order, main = ids[lo:hi], residual = p}
}

// range_iter binds the filter set and returns the scan. Origin must be
// stated — Origin(0) is refused here, per api.md par. 12.5. The
// residual checks are the full pattern: prefix components pass
// trivially (they are equal by construction), and re-checking them
// costs register compares against tracking which were covered.
range_iter :: proc(r: Range, f: Filter) -> Scan {
	assert(r.snap.idx != nil, "range_iter: a released snapshot")
	assert(f.origin >= .Asserted && f.origin <= .Any, "range_iter: origin must be stated (api.md par. 12.5)")
	assert(len(r.delta) == 0, "range_iter: the delta run arrives with Apply")
	sc := Scan{
		snap   = r.snap,
		ids    = r.main,
		origin = f.origin,
		graphs = f.graphs,
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
	candidates: for len(sc.ids) > 0 {
		id = sc.ids[0]
		sc.ids = sc.ids[1:]
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
		if sc.graphs != nil {
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
// literal's datatype resolves recursively; a datatype this snapshot
// does not know makes the literal a miss, as does any term the format
// cannot encode. The id must have been interned at or before this
// snapshot's publication: a term the writer added since is a miss
// here, by the n_terms bound.
snapshot_resolve :: proc(snap: Snapshot, t: rdf.Term, allocator := context.allocator) -> (id: Term_ID, ok: bool) {
	assert(snap.idx != nil, "snapshot_resolve: a released snapshot")
	if iid, inlined := term_inline(t); inlined {
		return iid, true
	}
	snap := snap
	buf: [256]u8
	enc, err := term_encode(t, resolve_snap_datatype, &snap, buf[:], allocator)
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

// Term_Kind is what snapshot_kind answers: the three kinds of RDF term
// this store can hold, with no reference to how they are encoded.
Term_Kind :: enum u8 {
	IRI,
	Blank,
	Literal,
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
	switch set_bytes(snap.idx, id)[0] {
	case TERM_TAG_IRI, TERM_TAG_SPLIT_IRI:
		return .IRI
	case TERM_TAG_BLANK:
		return .Blank
	}
	return .Literal
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
// decodes from its arena bytes, borrowing them (a split IRI joins in
// one allocation); an inlined id materializes into the caller's
// buffer, at least INLINE_LEXICAL_MAX bytes, and borrows that. Not ok
// for id 0, an id past the snapshot, or bytes the codec refuses.
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
	return term_decode(set_bytes(snap.idx, id), resolve_snap_iri, &snap, allocator)
}

// --- order selection -------------------------------------------------

// choose_order is api.md par. 12.2's table: the order whose key leads
// with the bound components, longest prefix first, SPOG for the full
// scan. G never enters the choice.
@(private = "file")
choose_order :: proc(p: Pattern) -> (o: Order, k: int) {
	bs, bp, bo := p.s != 0, p.p != 0, p.o != 0
	switch {
	case bs && bp:
		return .SPOG, 3 if bo else 2
	case bs && bo:
		return .SOPG, 2
	case bp && bo:
		return .POSG, 2
	case bs:
		return .SPOG, 1
	case bp:
		return .PSOG, 1
	case bo:
		return .OSPG, 1
	}
	return .SPOG, 0
}

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
		return 0 // G never enters a prefix (RECORD-A-0004)
	}
	unreachable()
}

// prefix_bound binary-searches one permutation for the edge of the
// prefix window: the first index whose fact compares >= the wanted
// prefix (upper false), or > it (upper true).
@(private = "file")
prefix_bound :: proc(set: ^Index_Set, ids: []Fact_ID, key: [4]Component, want: [3]Term_ID, k: int, upper: bool) -> int {
	lo, hi := 0, len(ids)
	for lo < hi {
		mid := int(uint(lo+hi) >> 1)
		f := fact_in(set.facts, ids[mid])
		cmp := 0
		for j in 0 ..< k {
			v := fact_component(f, key[j])
			if v != want[j] {
				cmp = -1 if v < want[j] else 1
				break
			}
		}
		if cmp < 0 || (upper && cmp == 0) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
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
