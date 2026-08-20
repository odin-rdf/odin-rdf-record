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
fact_component :: proc(f: ^Fact, c: Component) -> Term_ID {
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
// radix_pass is one stable counting pass over the 16-bit digit of each
// element's column value at `shift`: histogram, exclusive prefix sum,
// scatter in source order — stability is what carries the previous
// passes' order, and ultimately the FactID order the chain starts
// from, through to the result. Returns whether it scattered; a pass
// whose elements all share one digit is the identity and is skipped
// without moving anything.
@(private = "file")
radix_pass :: proc(src, dst: []Fact_ID, col: []u32, counts: []u32, shift: uint) -> bool {
	if len(src) == 0 {
		return false
	}
	slice.fill(counts, 0)
	for id in src {
		counts[(col[id] >> shift) & 0xFFFF] += 1
	}
	d0 := (col[src[0]] >> shift) & 0xFFFF
	if int(counts[d0]) == len(src) {
		return false
	}
	total: u32 = 0
	for &c in counts {
		n := c
		c = total
		total += n
	}
	for id in src {
		d := (col[id] >> shift) & 0xFFFF
		dst[counts[d]] = id
		counts[d] += 1
	}
	return true
}

// store_build_permutations sorts all six orders over the current fact
// table — log.md par. 8's buildPermutations, the end of replay. It is
// also the eventual delta-merge rebuild (api.md par. 5.2): one code
// path, exercised on every load. Rebuilding replaces each order
// wholesale; the fact table itself is never reordered.
//
// The sort is LSD radix rather than comparison, because this is the
// hottest procedure on the boot path and every wake from eviction pays
// it (api.md par. 8): a comparison sort's ~38M indirect comparator
// calls cost 535 ms at ISMS scale where these linear passes cost tens
// of milliseconds. Per order, one stable 16-bit counting pass per
// component digit, least-significant component first, starting from
// FactID order — so equal quads end FactID-ascending by stability, the
// ordering is total, and the same log yields byte-identical
// permutations. Component values are gathered once into dense columns
// (the passes then read 1.3 MB columns instead of gathering from the
// fact table), and a component whose values never reach the high 16
// bits — every dictionary-id-only column in practice — skips that
// digit's pass entirely. All of it is transient scaffolding in log.md
// par. 8's sense, freed before returning; the resident form stays
// []FactID and nothing else (RECORD-A-0004, api.md par. 5).
store_build_permutations :: proc(s: ^Store) {
	n := int(s.n_facts)
	cols: [Component][]u32
	maxs: [Component]u32
	for c in Component {
		cols[c] = make([]u32, n, s.allocator)
	}
	defer for c in Component {
		delete(cols[c], s.allocator)
	}
	for i in 0 ..< n {
		f := store_fact(s, Fact_ID(i))
		for c in Component {
			v := u32(fact_component(f, c))
			cols[c][i] = v
			maxs[c] = max(maxs[c], v)
		}
	}
	buf_a := make([]Fact_ID, n, s.allocator)
	buf_b := make([]Fact_ID, n, s.allocator)
	counts := make([]u32, 1 << 16, s.allocator)
	defer {
		delete(buf_a, s.allocator)
		delete(buf_b, s.allocator)
		delete(counts, s.allocator)
	}

	for o in Order {
		key := order_key(o)
		for i in 0 ..< n {
			buf_a[i] = Fact_ID(i)
		}
		cur, alt := buf_a, buf_b
		for ki := 3; ki >= 0; ki -= 1 {
			col := cols[key[ki]]
			if radix_pass(cur, alt, col, counts, 0) {
				cur, alt = alt, cur
			}
			if maxs[key[ki]] > 0xFFFF {
				if radix_pass(cur, alt, col, counts, 16) {
					cur, alt = alt, cur
				}
			}
		}
		ids := make([]Fact_ID, n, s.allocator)
		copy(ids, cur)
		delete(s.ord[o], s.allocator)
		s.ord[o] = ids
	}
}
