package record

import "core:slice"
import "core:testing"

// The permutations' tests (RECORD-T-0008): exact expected orders on a
// hand-computed corpus built to collide at every depth, the inline
// numeric-ordering property, and a brute-force tuple oracle over a
// duplicate-heavy generated corpus — the quiet failure being a
// comparator that agrees with the oracle on random data and disagrees
// on adjacent duplicates, so the corpus is constructed to contain
// them, not hoped to.

@(test)
test_permutations_exact :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)

	// Seven facts colliding at every depth: f3/f4 differ only in G (the
	// residual decides), f4/f5 are the same quad re-asserted — two
	// generations, disjoint intervals, adjacent under every order with
	// FactID breaking the tie.
	facts := [7]Fact{
		{s = 2, p = 10, o = 7, g = 0, assert = 1, retract = LIVE_EPOCH}, // f0
		{s = 1, p = 11, o = 7, g = 1, assert = 1, retract = LIVE_EPOCH}, // f1
		{s = 2, p = 10, o = 5, g = 1, assert = 1, retract = LIVE_EPOCH}, // f2
		{s = 1, p = 10, o = 7, g = 0, assert = 1, retract = LIVE_EPOCH}, // f3
		{s = 1, p = 10, o = 7, g = 1, assert = 1, retract = 2},          // f4: retracted...
		{s = 1, p = 10, o = 7, g = 1, assert = 2, retract = LIVE_EPOCH}, // f5: ...and re-asserted
		{s = 1, p = 12, o = 6, g = 0, assert = 2, retract = LIVE_EPOCH}, // f6
	}
	for f in facts {
		fact_append(&s, f, false)
	}
	store_build_permutations(&s)

	// Hand-computed, most-significant component first, G then FactID
	// breaking ties. The retracted f4 is indexed like anything else.
	want := [Order][7]Fact_ID{
		.SPOG = {3, 4, 5, 1, 6, 2, 0},
		.SOPG = {6, 3, 4, 5, 1, 2, 0},
		.PSOG = {3, 4, 5, 2, 0, 1, 6},
		.POSG = {2, 3, 4, 5, 0, 1, 6},
		.OSPG = {2, 6, 3, 4, 5, 1, 0},
		.OPSG = {2, 6, 3, 4, 5, 0, 1},
	}
	for o in Order {
		w := want[o]
		testing.expectf(t, slice.equal(s.ord[o], w[:]), "%v: got %v, want %v", o, s.ord[o], w)
	}
}

@(test)
test_permutations_empty :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	store_build_permutations(&s)
	for o in Order {
		testing.expect_value(t, len(s.ord[o]), 0)
	}
}

@(test)
test_permutations_inline_order :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)

	// One subject and predicate, five objects spanning the id space: a
	// dictionary id sorts below every inlined id (bit 31), and inlined
	// ids sort by tag (boolean < integer < date) and numerically within
	// one — the offset-binary property RECORD-A-0001 bought.
	neg, _ := inline_integer(-3)
	pos, _ := inline_integer(4)
	tru := INLINE_FLAG | u64(INLINE_TAG_BOOLEAN) << INLINE_TAG_SHIFT | 1
	date := INLINE_FLAG | u64(INLINE_TAG_DATE) << INLINE_TAG_SHIFT | INLINE_BIAS
	objects := [5]Term_ID{resident_id(pos), 1, resident_id(date), resident_id(tru), resident_id(neg)}
	for o in objects {
		fact_append(&s, Fact{s = 2, p = 3, o = o, g = 0, assert = 1, retract = LIVE_EPOCH}, false)
	}
	store_build_permutations(&s)

	// dict 1 (f1) < true (f3) < -3 (f4) < 4 (f0) < date (f2).
	want := [5]Fact_ID{1, 3, 4, 0, 2}
	testing.expectf(t, slice.equal(s.ord[.OSPG], want[:]), "OSPG: got %v, want %v", s.ord[.OSPG], want)
	testing.expectf(t, slice.equal(s.ord[.OPSG], want[:]), "OPSG: got %v, want %v", s.ord[.OPSG], want)
}

// The oracle: an independent lexicographic compare over materialized
// key tuples — extract-then-compare, against the comparator's
// compare-in-place — with FactID as the fifth element, so "sorted and
// deterministic" is one check.
@(private = "file")
oracle_tuple :: proc(s: ^Store, key: [4]Component, id: Fact_ID) -> [5]u32 {
	f := store_fact(s, id)
	return {
		u32(fact_component(f, key[0])),
		u32(fact_component(f, key[1])),
		u32(fact_component(f, key[2])),
		u32(fact_component(f, key[3])),
		u32(id),
	}
}

@(private = "file")
oracle_lt :: proc(a, b: [5]u32) -> bool {
	for i in 0 ..< 5 {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

@(private = "file")
oracle_fill :: proc(s: ^Store, seed: u64) {
	neg, _ := inline_integer(-1)
	zero, _ := inline_integer(0)
	one, _ := inline_integer(1)
	pool := [6]Term_ID{1, 2, 3, resident_id(neg), resident_id(zero), resident_id(one)}
	rng := seed
	for i in 0 ..< 4096 {
		r := splitmix_test(&rng)
		f := Fact{
			s       = 1 + Term_ID(r%3),
			p       = 4 + Term_ID((r>>8)%2),
			o       = pool[(r>>16)%6],
			g       = Term_ID((r >> 24) % 3), // 0 (default) or the "named" ids 1, 2
			assert  = 1,
			retract = LIVE_EPOCH,
		}
		fact_append(s, f, i%5 == 0)
	}
}

@(private = "file")
splitmix_test :: proc(state: ^u64) -> u64 {
	state^ += 0x9E3779B97F4A7C15
	z := state^
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

@(test)
test_permutations_oracle :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)

	// 4096 facts over 108 distinct quads: every order is wall-to-wall
	// duplicate prefixes and full-quad ties, the case the comparator
	// must get right rather than usually get right.
	oracle_fill(&s, 0xDA7A_5EED)
	store_build_permutations(&s)

	seen := make([]bool, s.n_facts)
	defer delete(seen)
	for o in Order {
		ids := s.ord[o]
		testing.expect_value(t, u32(len(ids)), s.n_facts)

		// A true permutation: every FactID exactly once.
		slice.fill(seen, false)
		for id in ids {
			testing.expect(t, !seen[id], "no FactID appears twice")
			seen[id] = true
		}

		// Strictly ascending under the materialized-tuple oracle — the
		// FactID element makes ties impossible, so sortedness and
		// FactID-broken determinism are the same assertion.
		key := order_key(o)
		for i in 1 ..< len(ids) {
			a := oracle_tuple(&s, key, ids[i-1])
			b := oracle_tuple(&s, key, ids[i])
			testing.expectf(t, oracle_lt(a, b), "%v: %v before %v", o, a, b)
		}
	}

	// Byte-identical across builds: a second store from the same
	// corpus, and a rebuild over the same store, both reproduce every
	// order exactly.
	s2: Store
	store_init(&s2)
	defer store_destroy(&s2)
	oracle_fill(&s2, 0xDA7A_5EED)
	store_build_permutations(&s2)
	for o in Order {
		testing.expect(t, slice.equal(s.ord[o], s2.ord[o]), "same corpus, same permutation")
	}
	store_build_permutations(&s2)
	for o in Order {
		testing.expect(t, slice.equal(s.ord[o], s2.ord[o]), "a rebuild reproduces the order")
	}
}
