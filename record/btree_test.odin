package record

import "core:slice"
import "core:testing"

// The permutation tree's tests (RECORD-T-0040): the tree against the
// radix sort as oracle, packed and streamed, over the permute suite's
// duplicate-heavy corpus and a larger random one; both split paths with
// the counts checked after each; the cursor from every rank; the
// reference-count discipline under held and released sets; and a
// random-insert property test with generations interleaved. Every test
// ends with the arena empty, which is the discipline's proof.

@(private = "file")
bt_rng :: proc(x: ^u64) -> u64 {
	x^ += 0x9E3779B97F4A7C15
	z := x^
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

// bt_append adds one random live fact with the benchmark's id shape:
// 10⁴ subjects, 40 predicates, 6×10⁴ objects, 500 graphs, 30% named.
@(private = "file")
bt_append :: proc(s: ^Store, rng: ^u64, epoch: Epoch = 1) -> Fact_ID {
	f := Fact{
		s       = Term_ID(1 + bt_rng(rng) % 10_000),
		p       = Term_ID(10_001 + bt_rng(rng) % 40),
		o       = Term_ID(10_041 + bt_rng(rng) % 60_000),
		assert  = epoch,
		retract = LIVE_EPOCH,
	}
	if bt_rng(rng) % 100 < 30 {
		f.g = Term_ID(70_041 + bt_rng(rng) % 500)
	}
	return fact_append(s, f, false)
}

// bt_collect enumerates a root in order.
@(private = "file")
bt_collect :: proc(a: ^Perm_Arena, root: Perm_Root, allocator := context.allocator) -> []Fact_ID {
	out := make([]Fact_ID, root.n, allocator)
	c := perm_cursor(a.leaves[:], a.inners[:], root, 0, int(root.n))
	i := 0
	for id in perm_next(&c) {
		out[i] = id
		i += 1
	}
	assert(i == int(root.n))
	return out
}

// bt_check walks a root and asserts every structural invariant: leaves
// sorted and within capacity, inner keys equal to the child's minimum
// and ascending, counts equal to the child's entries, totals the sum,
// every reachable node referenced, and root.n the grand total. Returns
// the entry count and the minimum key of the subtree.
@(private = "file")
bt_check_node :: proc(t: ^testing.T, a: ^Perm_Arena, facts: [][]Fact, key: [4]Component, node: u32, level: u8, loc := #caller_location) -> (n: u32, min: Perm_Key) {
	if level == 0 {
		testing.expect(t, a.leaf_refs[node] >= 1, "a reachable leaf is referenced", loc = loc)
		l := perm_leaf(a, node)
		testing.expect(t, l.n <= PERM_LEAF_CAP, "leaf within capacity", loc = loc)
		for i in 1 ..< int(l.n) {
			testing.expect(t, perm_key_less(perm_key_of(facts, key, l.ids[i-1]), perm_key_of(facts, key, l.ids[i])), "leaf sorted", loc = loc)
		}
		if l.n > 0 {
			min = perm_key_of(facts, key, l.ids[0])
		}
		return l.n, min
	}
	testing.expect(t, a.inner_refs[node] >= 1, "a reachable inner node is referenced", loc = loc)
	nd := perm_inner(a, node)
	testing.expect(t, nd.n >= 1 && nd.n <= PERM_INNER_CAP, "inner within capacity", loc = loc)
	total: u32
	for j in 0 ..< int(nd.n) {
		cn, cmin := bt_check_node(t, a, facts, key, nd.child[j], level - 1, loc)
		testing.expect_value(t, nd.count[j], cn, loc = loc)
		testing.expect_value(t, nd.key[j], cmin, loc = loc)
		if j > 0 {
			testing.expect(t, perm_key_less(nd.key[j-1], nd.key[j]), "inner keys ascending", loc = loc)
		}
		total += cn
	}
	testing.expect_value(t, nd.total, total, loc = loc)
	return total, nd.key[0]
}

@(private = "file")
bt_check :: proc(t: ^testing.T, a: ^Perm_Arena, facts: [][]Fact, key: [4]Component, root: Perm_Root, loc := #caller_location) {
	n, _ := bt_check_node(t, a, facts, key, root.node, root.level, loc)
	testing.expect_value(t, root.n, n, loc = loc)
}

@(private = "file")
bt_live_zero :: proc(t: ^testing.T, a: ^Perm_Arena, loc := #caller_location) {
	leaves, inners, _ := perm_arena_live(a)
	testing.expect_value(t, leaves, 0, loc = loc)
	testing.expect_value(t, inners, 0, loc = loc)
}

// bt_sorted_insert keeps an expected permutation sorted by key — the
// oracle the property test compares against.
@(private = "file")
bt_sorted_insert :: proc(exp: ^[dynamic]Fact_ID, facts: [][]Fact, key: [4]Component, id: Fact_ID) {
	k := perm_key_of(facts, key, id)
	lo, hi := 0, len(exp)
	for lo < hi {
		mid := (lo + hi) / 2
		if perm_key_less(perm_key_of(facts, key, exp[mid]), k) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	inject_at(exp, lo, id)
}

// --- the oracle ------------------------------------------------------

@(private = "file")
bt_oracle_corpus :: proc(t: ^testing.T, s: ^Store) {
	store_build_permutations(s)
	facts := s.facts[:]
	a: Perm_Arena
	perm_arena_init(&a)
	defer perm_arena_destroy(&a)
	for o in Order {
		key := order_key(o)
		// packed
		packed := Perm_Tree{arena = &a, key = key, gen = 1}
		perm_build(&packed, facts, s.ord[o])
		testing.expect_value(t, int(packed.root.n), len(s.ord[o]))
		bt_check(t, &a, facts, key, packed.root)
		got := bt_collect(&a, packed.root)
		testing.expectf(t, slice.equal(got, s.ord[o]), "%v: packed tree equals the sort", o)
		delete(got)
		// streamed, in id order — log.md par. 8's alternative, as a
		// correctness check only
		streamed := Perm_Tree{arena = &a, key = key, gen = 2}
		perm_build(&streamed, facts, nil)
		for id in 0 ..< s.n_facts {
			perm_insert(&streamed, facts, Fact_ID(id))
		}
		bt_check(t, &a, facts, key, streamed.root)
		got = bt_collect(&a, streamed.root)
		testing.expectf(t, slice.equal(got, s.ord[o]), "%v: streamed tree equals the sort", o)
		delete(got)
		perm_root_release(&a, packed.root)
		perm_root_release(&a, streamed.root)
	}
	bt_live_zero(t, &a)
}

@(test)
test_btree_oracle :: proc(t: ^testing.T) {
	// The permute suite's corpus: 4096 facts over 108 distinct quads,
	// wall-to-wall duplicate prefixes and full-quad ties.
	{
		s: Store
		store_init(&s)
		defer store_destroy(&s)
		oracle_fill(&s, 0xDA7A_5EED)
		bt_oracle_corpus(t, &s)
	}
	// A larger random one with the benchmark's shape: several levels.
	{
		s: Store
		store_init(&s)
		defer store_destroy(&s)
		rng: u64 = 0xB7EE
		for _ in 0 ..< 60_000 {
			bt_append(&s, &rng)
		}
		bt_oracle_corpus(t, &s)
	}
}

// --- the split paths ------------------------------------------------

@(test)
test_btree_splits :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	rng: u64 = 0x5917
	for _ in 0 ..< 20_000 {
		bt_append(&s, &rng)
	}
	store_build_permutations(&s)
	facts := s.facts[:]
	key := order_key(.SPOG)
	sorted := s.ord[.SPOG]
	a: Perm_Arena
	perm_arena_init(&a)
	defer perm_arena_destroy(&a)

	// A leaf root splits: 256 packed, one more → level 1, two leaves.
	{
		tr := Perm_Tree{arena = &a, key = key, gen = 1}
		perm_build(&tr, facts, sorted[:PERM_LEAF_CAP])
		testing.expect_value(t, tr.root.level, u8(0))
		perm_insert(&tr, facts, sorted[PERM_LEAF_CAP])
		testing.expect_value(t, tr.root.level, u8(1))
		testing.expect_value(t, perm_inner(&a, tr.root.node).n, u32(2))
		bt_check(t, &a, facts, key, tr.root)
		got := bt_collect(&a, tr.root)
		testing.expect(t, slice.equal(got, sorted[:PERM_LEAF_CAP + 1]))
		delete(got)
		perm_root_release(&a, tr.root)
	}
	// An inner root splits: 64 full leaves, one more at the end → the
	// last leaf splits, the inner overflows, the root grows to level 2.
	{
		N := PERM_LEAF_CAP * PERM_INNER_CAP
		tr := Perm_Tree{arena = &a, key = key, gen = 1}
		perm_build(&tr, facts, sorted[:N])
		testing.expect_value(t, tr.root.level, u8(1))
		testing.expect_value(t, perm_inner(&a, tr.root.node).n, u32(PERM_INNER_CAP))
		perm_insert(&tr, facts, sorted[N])
		testing.expect_value(t, tr.root.level, u8(2))
		testing.expect_value(t, perm_inner(&a, tr.root.node).n, u32(2))
		bt_check(t, &a, facts, key, tr.root)
		got := bt_collect(&a, tr.root)
		testing.expect(t, slice.equal(got, sorted[:N + 1]))
		delete(got)
		perm_root_release(&a, tr.root)
	}
	// An inner node splits below a level-2 root: 65 full leaves packed
	// with one entry left out of leaf 0, then that entry inserted — leaf
	// 0 splits, the first inner overflows, the root gains a third child
	// and stays at level 2.
	{
		N := PERM_LEAF_CAP * (PERM_INNER_CAP + 1)
		hole := 100
		with_hole := make([]Fact_ID, N)
		defer delete(with_hole)
		copy(with_hole[:hole], sorted[:hole])
		copy(with_hole[hole:], sorted[hole + 1:N + 1])
		tr := Perm_Tree{arena = &a, key = key, gen = 1}
		perm_build(&tr, facts, with_hole)
		testing.expect_value(t, tr.root.level, u8(2))
		testing.expect_value(t, perm_inner(&a, tr.root.node).n, u32(2))
		perm_insert(&tr, facts, sorted[hole])
		testing.expect_value(t, tr.root.level, u8(2))
		testing.expect_value(t, perm_inner(&a, tr.root.node).n, u32(3))
		bt_check(t, &a, facts, key, tr.root)
		got := bt_collect(&a, tr.root)
		testing.expect(t, slice.equal(got, sorted[:N + 1]))
		delete(got)
		perm_root_release(&a, tr.root)
	}
	bt_live_zero(t, &a)
}

// --- the cursor -----------------------------------------------------

@(test)
test_btree_cursor :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	rng: u64 = 0xC0DE
	for _ in 0 ..< 17_000 {
		bt_append(&s, &rng)
	}
	store_build_permutations(&s)
	facts := s.facts[:]
	sorted := s.ord[.POSG]
	a: Perm_Arena
	perm_arena_init(&a)
	defer perm_arena_destroy(&a)

	// Level 1, three leaves (256, 256, 88): every lo, and every window
	// at a stride, across both leaf boundaries.
	{
		n := 600
		tr := Perm_Tree{arena = &a, key = order_key(.POSG), gen = 1}
		perm_build(&tr, facts, sorted[:n])
		testing.expect_value(t, tr.root.level, u8(1))
		for lo in 0 ..= n {
			c := perm_cursor(a.leaves[:], a.inners[:], tr.root, lo, n)
			testing.expect_value(t, c.remaining, n - lo)
			for i in lo ..< n {
				id, ok := perm_next(&c)
				testing.expect(t, ok && id == sorted[i], "suffix from every rank")
			}
			_, ok := perm_next(&c)
			testing.expect(t, !ok, "ends exactly")
		}
		for lo := 0; lo < n; lo += 7 {
			for hi := lo; hi <= n; hi += 13 {
				c := perm_cursor(a.leaves[:], a.inners[:], tr.root, lo, hi)
				for i in lo ..< hi {
					id, ok := perm_next(&c)
					testing.expect(t, ok && id == sorted[i], "window")
				}
				_, ok := perm_next(&c)
				testing.expect(t, !ok)
			}
		}
		perm_root_release(&a, tr.root)
	}
	// Level 2 (65 leaves, two inner nodes): strided starts and random
	// windows across the inner boundary.
	{
		n := PERM_LEAF_CAP * (PERM_INNER_CAP + 1)
		tr := Perm_Tree{arena = &a, key = order_key(.POSG), gen = 1}
		perm_build(&tr, facts, sorted[:n])
		testing.expect_value(t, tr.root.level, u8(2))
		for lo := 0; lo < n; lo += 997 {
			c := perm_cursor(a.leaves[:], a.inners[:], tr.root, lo, n)
			for i in lo ..< n {
				id, ok := perm_next(&c)
				if !ok || id != sorted[i] {
					testing.fail_now(t, "level-2 suffix")
				}
			}
		}
		for _ in 0 ..< 200 {
			lo := int(bt_rng(&rng) % u64(n))
			hi := lo + int(bt_rng(&rng) % u64(n - lo + 1))
			c := perm_cursor(a.leaves[:], a.inners[:], tr.root, lo, hi)
			for i in lo ..< hi {
				id, ok := perm_next(&c)
				if !ok || id != sorted[i] {
					testing.fail_now(t, "level-2 window")
				}
			}
			_, ok := perm_next(&c)
			testing.expect(t, !ok)
		}
		perm_root_release(&a, tr.root)
	}
	bt_live_zero(t, &a)
}

// --- reference counts ------------------------------------------------

@(test)
test_btree_refcounts :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	rng: u64 = 0x4EF5
	for _ in 0 ..< 3000 {
		bt_append(&s, &rng)
	}
	store_build_permutations(&s)
	facts := s.facts[:]
	key := order_key(.OSPG)
	base := slice.clone(s.ord[.OSPG])
	defer delete(base)

	for release_old_first in ([?]bool{true, false}) {
		a: Perm_Arena
		perm_arena_init(&a)
		defer perm_arena_destroy(&a)
		// Set 1 publishes root A and a reader holds it.
		g1 := Perm_Tree{arena = &a, key = key, gen = 1}
		perm_build(&g1, facts, base)
		held := g1.root
		perm_root_retain(&a, held)
		// Set 2: 400 inserts under generation 2 — more than a leaf's
		// worth, so leaves split and inner nodes are copied.
		exp := slice.clone_to_dynamic(base)
		defer delete(exp)
		g2 := Perm_Tree{arena = &a, key = key, gen = 2, root = g1.root}
		for _ in 0 ..< 400 {
			id := bt_append(&s, &rng, 2)
			facts = s.facts[:]
			perm_insert(&g2, facts, id)
			bt_sorted_insert(&exp, facts, key, id)
		}
		testing.expect(t, g2.root.node != held.node, "the root was copied")
		// Set 1's reference is released (set 2 superseded it); the
		// reader still holds A.
		perm_root_release(&a, g1.root)
		bt_check(t, &a, facts, key, held)
		bt_check(t, &a, facts, key, g2.root)
		old := bt_collect(&a, held)
		testing.expect(t, slice.equal(old, base), "the held set's window is intact")
		delete(old)
		new := bt_collect(&a, g2.root)
		testing.expect(t, slice.equal(new, exp[:]), "the new set sees the inserts")
		delete(new)
		if release_old_first {
			perm_root_release(&a, held)
			bt_check(t, &a, facts, key, g2.root)
			perm_root_release(&a, g2.root)
		} else {
			perm_root_release(&a, g2.root)
			bt_check(t, &a, facts, key, held)
			perm_root_release(&a, held)
		}
		bt_live_zero(t, &a)
	}

	// An order no insert touched: the new set shares the root, retains
	// it, and the two releases leave nothing.
	{
		a: Perm_Arena
		perm_arena_init(&a)
		defer perm_arena_destroy(&a)
		g1 := Perm_Tree{arena = &a, key = key, gen = 1}
		perm_build(&g1, facts, base)
		g2 := Perm_Tree{arena = &a, key = key, gen = 2, root = g1.root}
		testing.expect_value(t, g2.root.node, g1.root.node)
		perm_root_retain(&a, g2.root)
		perm_root_release(&a, g1.root)
		got := bt_collect(&a, g2.root)
		testing.expect(t, slice.equal(got, base))
		delete(got)
		perm_root_release(&a, g2.root)
		bt_live_zero(t, &a)
	}
}

// --- the property test -----------------------------------------------

@(test)
test_btree_property :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	rng: u64 = 0x9A0B
	for _ in 0 ..< 2000 {
		bt_append(&s, &rng)
	}
	store_build_permutations(&s)
	facts := s.facts[:]
	key := order_key(.PSOG)
	a: Perm_Arena
	perm_arena_init(&a)
	defer perm_arena_destroy(&a)

	Held :: struct {
		root: Perm_Root,
		exp:  []Fact_ID,
	}
	held := make([dynamic]Held)
	defer delete(held)
	exp := slice.clone_to_dynamic(s.ord[.PSOG])
	defer delete(exp)

	cur := Perm_Tree{arena = &a, key = key, gen = 1}
	perm_build(&cur, facts, s.ord[.PSOG])
	for gen in u32(2) ..= 200 {
		k := int(bt_rng(&rng) % 13)
		next := Perm_Tree{arena = &a, key = key, gen = gen, root = cur.root}
		for _ in 0 ..< k {
			id := bt_append(&s, &rng, Epoch(gen))
			facts = s.facts[:]
			perm_insert(&next, facts, id)
			bt_sorted_insert(&exp, facts, key, id)
		}
		if next.root.node == cur.root.node {
			testing.expect_value(t, k, 0)
			perm_root_retain(&a, next.root)
		}
		perm_root_release(&a, cur.root)
		cur = next
		got := bt_collect(&a, cur.root)
		if !slice.equal(got, exp[:]) {
			testing.fail_now(t, "the current root differs from the sorted oracle")
		}
		delete(got)
		if gen % 10 == 0 {
			bt_check(t, &a, facts, key, cur.root)
		}
		switch bt_rng(&rng) % 4 {
		case 0:
			perm_root_retain(&a, cur.root)
			append(&held, Held{cur.root, slice.clone(exp[:])})
		case 1:
			if len(held) > 0 {
				i := int(bt_rng(&rng) % u64(len(held)))
				h := held[i]
				at_release := bt_collect(&a, h.root)
				testing.expect(t, slice.equal(at_release, h.exp), "a held root is intact at release")
				delete(at_release)
				delete(h.exp)
				perm_root_release(&a, h.root)
				unordered_remove(&held, i)
			}
		}
		for h in held {
			still := bt_collect(&a, h.root)
			if !slice.equal(still, h.exp) {
				testing.fail_now(t, "a held root changed under a later generation")
			}
			delete(still)
		}
	}
	for h in held {
		delete(h.exp)
		perm_root_release(&a, h.root)
	}
	perm_root_release(&a, cur.root)
	bt_live_zero(t, &a)
}
