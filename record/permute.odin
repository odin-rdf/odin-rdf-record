// The six permutations (RECORD-T-0008): sorted []FactID views of the
// fact table, one per order of (S, P, O) with G as the residual
// tiebreaker — RECORD-A-0004's decision, enforced here by the type
// surface: Order has exactly these six members and order_key places G
// at depth 3 in every one of them, so nothing graph-first can be
// requested, only wished for.
//
// Built once, at the end of replay, by sorting — never by incremental
// insertion (log.md par. 8's cost argument: six sorts are tens of
// milliseconds against an O(n) memmove per insert). Every fact
// generation is indexed, retracted ones included: visibility at an
// epoch is the reader's filter, never the index's shape, which is what
// makes an as-of read a filter change instead of a different index.
// The permutations are []FactID and nothing else — no keys are copied
// out of the fact table — the pointer-free property api.md par. 4.1
// prices across hundreds of tenant processes.
package record

import "core:slice"

// Order names the six permutations: architecture.md par. 4.1's triple
// orders with G appended (RECORD-A-0004). The names read as the sort
// key, most-significant first.
Order :: enum u8 {
	SPOG,
	SOPG,
	PSOG,
	POSG,
	OSPG,
	OPSG,
}

// Component names one position of a fact, for key tables and the
// coming read API's distinct-counting (api.md par. 12.5).
Component :: enum u8 {
	S,
	P,
	O,
	G,
}

// order_key is an order's sort key as component depths, G always last
// — the one rule RECORD-A-0004 sets for every order.
order_key :: proc(o: Order) -> [4]Component {
	switch o {
	case .SPOG:
		return {.S, .P, .O, .G}
	case .SOPG:
		return {.S, .O, .P, .G}
	case .PSOG:
		return {.P, .S, .O, .G}
	case .POSG:
		return {.P, .O, .S, .G}
	case .OSPG:
		return {.O, .S, .P, .G}
	case .OPSG:
		return {.O, .P, .S, .G}
	}
	unreachable()
}

// fact_component reads one position of a fact.
fact_component :: proc(f: ^Fact, c: Component) -> u32 {
	switch c {
	case .S:
		return f.s
	case .P:
		return f.p
	case .O:
		return f.o
	case .G:
		return f.g
	}
	unreachable()
}

// Perm_Rec is the transient sort record: one order's key materialized
// beside the FactID, 20 bytes, no padding. Sorting FactIDs in place
// and comparing through the fact table costs two random gathers per
// probe — measured at 756 ms for the six orders at ISMS scale, most
// of the boot budget — where sorting these contiguous records is an
// order of magnitude cheaper. Scaffolding in log.md par. 8's sense:
// one buffer, reused across the six sorts, freed before returning.
// The resident form stays []FactID and nothing else (RECORD-A-0004,
// api.md par. 5).
@(private = "file")
Perm_Rec :: struct {
	hi: u64, // components 0 and 1 of the order's key, packed big end first
	lo: u64, // components 2 and 3
	id: u32,
}

// perm_rec_less compares key then FactID — resident ids are u32s whose
// encoding already sorts inlined values numerically within a type
// (api.md par. 3.2), and packing preserves the component order under
// integer comparison. The FactID tie makes the ordering total: equal
// quads (a re-asserted generation) sit adjacent in log order, and the
// same log yields byte-identical permutations.
@(private = "file")
perm_rec_less :: proc(a, b: Perm_Rec) -> bool {
	if a.hi != b.hi {
		return a.hi < b.hi
	}
	if a.lo != b.lo {
		return a.lo < b.lo
	}
	return a.id < b.id
}

// store_build_permutations sorts all six orders over the current fact
// table — log.md par. 8's buildPermutations, the end of replay. It is
// also the eventual delta-merge rebuild (api.md par. 5.2): one code
// path, exercised on every load. Rebuilding replaces each order
// wholesale; the fact table itself is never reordered.
store_build_permutations :: proc(s: ^Store) {
	recs := make([]Perm_Rec, s.n_facts, s.allocator)
	defer delete(recs, s.allocator)
	for o in Order {
		key := order_key(o)
		for i in u32(0) ..< s.n_facts {
			f := store_fact(s, i)
			recs[i] = {
				u64(fact_component(f, key[0])) << 32 | u64(fact_component(f, key[1])),
				u64(fact_component(f, key[2])) << 32 | u64(fact_component(f, key[3])),
				i,
			}
		}
		slice.sort_by(recs, perm_rec_less)
		ids := make([]u32, s.n_facts, s.allocator)
		for r, i in recs {
			ids[i] = r.id
		}
		delete(s.ord[o], s.allocator)
		s.ord[o] = ids
	}
}
