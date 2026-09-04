// The index-shape benchmark behind btree.odin (RECORD-I-0009,
// RECORD-A-0012's evidence). Behind RECORD_XBENCH so no ordinary run executes it:
//
//   odin test record -collection:rdf=../odin-rdf-parser \
//     -define:RECORD_XBENCH=true -o:speed \
//     -define:ODIN_TEST_NAMES=record.test_xbench_index,record.test_xbench_apply_breakdown
//
// Three permutation shapes over one fact table at ISMS scale:
//   flat/rebuild  the current one — radix re-sort of all seven orders
//   flat/merge    a flat array kept, k new ids placed by binary search
//                 and the array copied around them (O(k log n) gathers
//                 + O(n) memcpy per order)
//   btree         the copy-on-write B+tree of btree.odin
// measured on: match latency per pattern shape, ordered-scan
// throughput, per-commit index cost for k = 1, 2, 10, 100 asserts, and
// resident bytes. The second test times the real apply's pieces.
//
// Measured 2026-09-04, arm64 darwin dev machine, -o:speed, 4×10⁵
// facts (the ISMS shape: 10⁴ subjects, 40 predicates, 6×10⁴ objects,
// 500 graphs, 30% named):
//
//   apply of 1–2 ops today: 37.5 ms, of which the seven-order radix
//   re-sort is 37.1 ms; term-index merge and set build are microseconds.
//
//   per-commit index cost      k=1       k=2       k=10      k=100
//     flat/rebuild (today)     37 ms     37 ms     37 ms     37 ms
//     flat/merge               440 µs    445 µs    580 µs    1.23 ms   (10.7 MB allocated each)
//     btree                    9–11 µs   13–17 µs  70 µs     420–475 µs (a few KB each)
//
//   match latency (two bounds) flat 148–380 ns, btree 111–337 ns:
//     10–30% faster on every shape; scans 2.5 ns/candidate on both.
//   resident: flat 10.68 MB; btree 11.08 MB packed full (12.65 MB at
//     87.5% fill); random inserts into full leaves split them, so a
//     long-lived tree drifts toward ~70% fill, ~15.5 MB, unless
//     re-packed by the boot path's sort (43 ms) now and then.
//   a reader pinned across 50 one-assert commits retains 0.6–0.7 MB
//     of superseded tree nodes; the flat set it would pin is 10.8 MB,
//     and today's rebuild allocates 20 MB transiently per commit.
//   bulk build from the sorted arrays: 1.3 ms on top of the 43 ms sort.
package record

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:testing"
import "core:time"

import "rdf:rdf"

XB_N :: 400_000
XB_SUBJECTS :: 10_000
XB_PREDS :: 40
XB_OBJECTS :: 60_000
XB_GRAPHS :: 500

@(private = "file")
xb_rng :: proc(x: ^u64) -> u64 {
	x^ += 0x9E3779B97F4A7C15
	z := x^
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

@(private = "file")
xb_quad :: proc(rng: ^u64) -> Quad {
	q := Quad{
		s = Term_ID(1 + xb_rng(rng) % XB_SUBJECTS),
		p = Term_ID(XB_SUBJECTS + 1 + xb_rng(rng) % XB_PREDS),
		o = Term_ID(XB_SUBJECTS + XB_PREDS + 1 + xb_rng(rng) % XB_OBJECTS),
	}
	if xb_rng(rng) % 100 < 30 {
		q.g = Term_ID(XB_SUBJECTS + XB_PREDS + XB_OBJECTS + 1 + xb_rng(rng) % XB_GRAPHS)
	}
	return q
}

// xb_fill appends n distinct live facts at epoch 1, straight into the
// table — the index shapes are what is under test, not the dictionary.
@(private = "file")
xb_fill :: proc(s: ^Store, n: int, rng: ^u64) {
	seen := make(map[Quad]bool)
	defer delete(seen)
	for s.n_facts < u32(n) {
		q := xb_quad(rng)
		if q in seen {
			continue
		}
		seen[q] = true
		fact_append(s, Fact{s = q.s, p = q.p, o = q.o, g = q.g, assert = 1, retract = LIVE_EPOCH}, false)
	}
}

// The same order choice as read.odin's choose_order, which is
// file-private there.
@(private = "file")
xb_choose :: proc(p: Pattern) -> Order {
	bs, bp, bo, bg := p.s != 0, p.p != 0, p.o != 0, p.g != 0
	switch {
	case bs && bp:
		return .SPOG
	case bs && bo:
		return .SOPG
	case bs:
		return .SPOG
	case bg && bp:
		return .GPOS
	case bp && bo:
		return .POSG
	case bp:
		return .PSOG
	case bo:
		return .OSPG
	case bg:
		return .GPOS
	}
	return .SPOG
}

@(private = "file")
xb_prefix :: proc(p: Pattern, key: [4]Component) -> (want: [4]Term_ID, k: int) {
	for ; k < 4; k += 1 {
		v: Term_ID
		switch key[k] {
		case .S:
			v = p.s
		case .P:
			v = p.p
		case .O:
			v = p.o
		case .G:
			v = p.g
		}
		if v == 0 {
			break
		}
		want[k] = 0 if key[k] == .G && v == MATCH_DEFAULT_GRAPH else v
	}
	return
}

@(private = "file")
xb_tree_match :: proc(a: ^Perm_Arena, facts: [][]Fact, roots: [Order]Perm_Root, p: Pattern) -> (order: Order, lo, hi: int) {
	order = xb_choose(p)
	key := order_key(order)
	want, k := xb_prefix(p, key)
	lo = perm_rank(a.leaves[:], a.inners[:], facts, key, roots[order], want, k, false)
	hi = perm_rank(a.leaves[:], a.inners[:], facts, key, roots[order], want, k, true)
	return
}

// xb_tree_scan_count is scan_next's per-candidate work over a cursor:
// visibility, the residual components, origin (.Any: skipped).
@(private = "file")
xb_tree_scan_count :: proc(a: ^Perm_Arena, facts: [][]Fact, root: Perm_Root, lo, hi: int, epoch: Epoch, p: Pattern) -> (n: int) {
	c := perm_cursor(a.leaves[:], a.inners[:], root, lo, hi)
	g_want := Term_ID(0) if p.g == MATCH_DEFAULT_GRAPH else p.g
	for id in perm_next(&c) {
		f := fact_in(facts, id)
		if !(f.assert <= epoch && epoch < f.retract) {
			continue
		}
		if p.s != 0 && f.s != p.s {
			continue
		}
		if p.p != 0 && f.p != p.p {
			continue
		}
		if p.o != 0 && f.o != p.o {
			continue
		}
		if p.g != 0 && f.g != g_want {
			continue
		}
		n += 1
	}
	return
}

// The flat array's read path, kept here as the benchmark's reference
// now that read.odin's is the tree's: prefix_bound as it was, and the
// scan over the slice with scan_next's per-candidate work.
@(private = "file")
xb_flat_bound :: proc(facts: [][]Fact, ids: []Fact_ID, key: [4]Component, want: [4]Term_ID, k: int, upper: bool) -> int {
	lo, hi := 0, len(ids)
	for lo < hi {
		mid := int(uint(lo+hi) >> 1)
		f := fact_in(facts, ids[mid])
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

@(private = "file")
xb_flat_match :: proc(facts: [][]Fact, flat: [Order][]Fact_ID, p: Pattern) -> (order: Order, ids: []Fact_ID) {
	order = xb_choose(p)
	key := order_key(order)
	want, k := xb_prefix(p, key)
	lo := xb_flat_bound(facts, flat[order], key, want, k, false)
	hi := xb_flat_bound(facts, flat[order], key, want, k, true)
	return order, flat[order][lo:hi]
}

@(private = "file")
xb_flat_scan_count :: proc(facts: [][]Fact, flat: [Order][]Fact_ID, epoch: Epoch, p: Pattern) -> (n: int) {
	_, ids := xb_flat_match(facts, flat, p)
	g_want := Term_ID(0) if p.g == MATCH_DEFAULT_GRAPH else p.g
	for id in ids {
		f := fact_in(facts, id)
		if !(f.assert <= epoch && epoch < f.retract) {
			continue
		}
		if p.s != 0 && f.s != p.s {
			continue
		}
		if p.p != 0 && f.p != p.p {
			continue
		}
		if p.o != 0 && f.o != p.o {
			continue
		}
		if p.g != 0 && f.g != g_want {
			continue
		}
		n += 1
	}
	return
}

// xb_flat_merge is the "flat array done well" per-commit step: new ids
// sorted among themselves, each placed by one binary search over the
// old array, and the old array copied around them into a fresh one.
@(private = "file")
xb_flat_merge :: proc(facts: [][]Fact, key: [4]Component, old: []Fact_ID, fresh: []Fact_ID, allocator := context.allocator) -> []Fact_ID {
	// insertion sort of the few new ids by key
	for i in 1 ..< len(fresh) {
		j := i
		for j > 0 && perm_key_less(perm_key_of(facts, key, fresh[j]), perm_key_of(facts, key, fresh[j - 1])) {
			fresh[j], fresh[j - 1] = fresh[j - 1], fresh[j]
			j -= 1
		}
	}
	out := make([]Fact_ID, len(old) + len(fresh), allocator)
	from, at := 0, 0
	for id in fresh {
		k := perm_key_of(facts, key, id)
		lo, hi := from, len(old)
		for lo < hi {
			mid := int(uint(lo + hi) >> 1)
			if perm_key_less(perm_key_of(facts, key, old[mid]), k) {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		at += copy(out[at:], old[from:lo])
		out[at] = id
		at += 1
		from = lo
	}
	copy(out[at:], old[from:])
	return out
}

// Referenced outside the guarded tests so every import is used in an
// ordinary build (an unused import is an error; an unused proc is not).
@(private = "file")
xb_imports_used :: proc(t: ^testing.T) {
	_ = t
	log.info(fmt.tprint(slice.clone([]Fact_ID{}), time.now(), rdf.XSD_STRING, os.args))
}

@(private = "file")
ns :: proc(d: time.Duration, per: int) -> f64 {
	return f64(time.duration_nanoseconds(d)) / f64(max(per, 1))
}

@(private = "file")
ms :: proc(d: time.Duration) -> f64 {
	return time.duration_milliseconds(d)
}

@(private = "file")
XB_Shape :: struct {
	name: string,
	s, p, o, g: bool,
}

@(private = "file")
xb_pattern :: proc(sh: XB_Shape, rng: ^u64) -> (p: Pattern) {
	q := xb_quad(rng)
	if sh.s {
		p.s = q.s
	}
	if sh.p {
		p.p = q.p
	}
	if sh.o {
		p.o = q.o
	}
	if sh.g {
		p.g = q.g if q.g != 0 else MATCH_DEFAULT_GRAPH
	}
	return
}

when #config(RECORD_XBENCH, false) {

@(test)
test_xbench_index :: proc(t: ^testing.T) {
	rng: u64 = 0xB7EE
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	xb_fill(&s, XB_N, &rng)
	epoch_append(&s, {})

	// --- the current rebuild ---
	best := time.Duration(max(i64))
	for _ in 0 ..< 3 {
		start := time.tick_now()
		store_build_permutations(&s)
		best = min(best, time.tick_since(start))
	}
	log.infof("sort-and-pack: seven radix sorts + packs over %d facts: %.1f ms (best of 3)", s.n_facts, ms(best))

	// Keep a flat copy of every order for the merge experiment, then
	// publish so the flat read path runs through the real API.
	flat: [Order][]Fact_ID
	for o in Order {
		flat[o] = perm_collect(&s.perm, s.ord[o])
	}
	defer for o in Order {
		delete(flat[o])
	}
	store_build_term_index(&s)
	store_publish(&s)
	snap, serr := store_latest(&s)
	testing.expect_value(t, serr, Snapshot_Error.None)
	defer snapshot_release(&snap)
	facts := s.facts[:]

	// --- the tree, bulk-built from the sorted arrays ---
	arena: Perm_Arena
	perm_arena_init(&arena)
	defer perm_arena_destroy(&arena)
	gen: u32 = 1
	roots: [Order]Perm_Root
	{
		start := time.tick_now()
		for o in Order {
			tr := Perm_Tree{arena = &arena, key = order_key(o), gen = gen}
			perm_build(&tr, facts, flat[o])
			roots[o] = tr.root
		}
		built := time.tick_since(start)
		leaves, inners, bytes := perm_arena_live(&arena)
		log.infof("btree: bulk build of seven orders %.1f ms; %d leaves + %d inners = %.2f MB (flat: %.2f MB); root level %d",
			ms(built), leaves, inners, f64(bytes) / (1024 * 1024), f64(7 * int(s.n_facts) * 4) / (1024 * 1024), roots[.SPOG].level)
	}

	// --- correctness: every shape's window agrees with the flat one ---
	shapes := [?]XB_Shape{
		{"S", true, false, false, false},
		{"SP", true, true, false, false},
		{"SPO", true, true, true, false},
		{"P", false, true, false, false},
		{"PO", false, true, true, false},
		{"O", false, false, true, false},
		{"GP", false, true, false, true},
		{"GPO", false, true, true, true},
		{"G", false, false, false, true},
	}
	{
		vr := rng
		for sh in shapes {
			for _ in 0 ..< 2000 {
				p := xb_pattern(sh, &vr)
				fo, fids := xb_flat_match(facts, flat, p)
				r := snapshot_match(snap, p)
				o, lo, hi := xb_tree_match(&arena, facts, roots, p)
				testing.expect_value(t, o, fo)
				testing.expect_value(t, o, r.order)
				testing.expect_value(t, hi - lo, len(fids))
				testing.expect_value(t, range_len(r), len(fids))
				if hi - lo != len(fids) {
					return
				}
				// same ids in the same order
				c := perm_cursor(arena.leaves[:], arena.inners[:], roots[o], lo, hi)
				for id in fids {
					got, ok := perm_next(&c)
					if !ok || got != id {
						testing.fail_now(t, "tree window differs from the flat window")
					}
				}
			}
		}
	}

	// --- match latency ---
	Q :: 200_000
	pats := make([]Pattern, Q)
	defer delete(pats)
	for sh in shapes {
		pr := rng
		for &p in pats {
			p = xb_pattern(sh, &pr)
		}
		total_f, total_t := 0, 0
		start := time.tick_now()
		for p in pats {
			_, ids := xb_flat_match(facts, flat, p)
			total_f += len(ids)
		}
		flat_d := time.tick_since(start)
		start = time.tick_now()
		for p in pats {
			_, lo, hi := xb_tree_match(&arena, facts, roots, p)
			total_t += hi - lo
		}
		tree_d := time.tick_since(start)
		testing.expect_value(t, total_t, total_f)
		log.infof("match %-4s flat %6.0f ns  btree %6.0f ns   (mean window %d)", sh.name, ns(flat_d, Q), ns(tree_d, Q), total_f / Q)
	}

	// --- ordered scan throughput ---
	{
		scan_shapes := [?]XB_Shape{
			{"S", true, false, false, false},
			{"SP", true, true, false, false},
			{"PO", false, true, true, false},
			{"P", false, true, false, false},
			{"G", false, false, false, true},
			{"all", false, false, false, false},
		}
		for sh in scan_shapes {
			reps := 100_000 if sh.name == "S" || sh.name == "SP" else 100 if sh.name != "all" else 3
			pr := rng
			nf, nt := 0, 0
			cand := 0
			flat_d, tree_d: time.Duration
			for _ in 0 ..< reps {
				p := xb_pattern(sh, &pr)
				start := time.tick_now()
				nf += xb_flat_scan_count(facts, flat, snap.epoch, p)
				flat_d += time.tick_since(start)
				start = time.tick_now()
				o, lo, hi := xb_tree_match(&arena, facts, roots, p)
				nt += xb_tree_scan_count(&arena, facts, roots[o], lo, hi, snap.epoch, p)
				tree_d += time.tick_since(start)
				cand += hi - lo
			}
			testing.expect_value(t, nt, nf)
			log.infof("scan  %-4s flat %5.1f ns/candidate  btree %5.1f ns/candidate  (%d candidates over %d scans); per query incl. match: flat %.2f µs  btree %.2f µs",
				sh.name, ns(flat_d, cand), ns(tree_d, cand), cand, reps, ns(flat_d, reps) / 1000, ns(tree_d, reps) / 1000)
		}
	}

	// --- per-commit index cost ---
	// Each commit appends k facts; both structures then index them,
	// timed separately. The tree releases the previous generation's
	// roots as the store would when no snapshot is held; the flat merge
	// frees the previous array.
	for k in ([?]int{1, 2, 10, 100}) {
		C := 50
		t_lo, t_hi, t_sum: time.Duration = time.Duration(max(i64)), 0, 0
		f_lo, f_hi, f_sum: time.Duration = time.Duration(max(i64)), 0, 0
		fresh := make([]Fact_ID, k)
		defer delete(fresh)
		for _ in 0 ..< C {
			gen += 1
			first := s.n_facts
			for _ in 0 ..< k {
				q := xb_quad(&rng)
				fact_append(&s, Fact{s = q.s, p = q.p, o = q.o, g = q.g, assert = Epoch(gen), retract = LIVE_EPOCH}, false)
			}
			facts = s.facts[:]
			// btree
			start := time.tick_now()
			prev := roots
			for o in Order {
				tr := Perm_Tree{arena = &arena, key = order_key(o), gen = gen, root = roots[o]}
				for id in first ..< s.n_facts {
					perm_insert(&tr, facts, Fact_ID(id))
				}
				roots[o] = tr.root
			}
			// publish: the new roots are the store's; release the old
			// set's — a root that did not change is shared, so retain
			// it once for the new set before releasing the old.
			for o in Order {
				if roots[o].node == prev[o].node {
					perm_root_retain(&arena, roots[o])
				}
				perm_root_release(&arena, prev[o])
			}
			d := time.tick_since(start)
			t_lo = min(t_lo, d)
			t_hi = max(t_hi, d)
			t_sum += d
			// flat/merge
			start = time.tick_now()
			for o in Order {
				for j in 0 ..< k {
					fresh[j] = Fact_ID(first + u32(j))
				}
				out := xb_flat_merge(facts, order_key(o), flat[o], fresh)
				delete(flat[o])
				flat[o] = out
			}
			d = time.tick_since(start)
			f_lo = min(f_lo, d)
			f_hi = max(f_hi, d)
			f_sum += d
		}
		leaves, inners, bytes := perm_arena_live(&arena)
		log.infof("commit k=%-3d btree      min %7.1f µs  mean %7.1f µs  max %7.1f µs   (%d leaves + %d inners = %.2f MB live)",
			k, ns(t_lo, 1000), ns(t_sum, 1000 * C), ns(t_hi, 1000), leaves, inners, f64(bytes) / (1024 * 1024))
		log.infof("commit k=%-3d flat/merge min %7.1f µs  mean %7.1f µs  max %7.1f µs   (%.2f MB allocated per commit)",
			k, ns(f_lo, 1000), ns(f_sum, 1000 * C), ns(f_hi, 1000), f64(7 * len(flat[.SPOG]) * 4) / (1024 * 1024))
	}

	// --- a pinned reader ---
	// A snapshot held across H commits of one assert each keeps its
	// set alive: for the flat array that is a whole 10.7 MB set per
	// distinct set held; for the tree it is the path copies since.
	{
		H :: 50
		held := roots
		for o in Order {
			perm_root_retain(&arena, held[o])
		}
		_, _, before := perm_arena_live(&arena)
		for _ in 0 ..< H {
			gen += 1
			first := s.n_facts
			q := xb_quad(&rng)
			fact_append(&s, Fact{s = q.s, p = q.p, o = q.o, g = q.g, assert = Epoch(gen), retract = LIVE_EPOCH}, false)
			facts = s.facts[:]
			prev := roots
			for o in Order {
				tr := Perm_Tree{arena = &arena, key = order_key(o), gen = gen, root = roots[o]}
				perm_insert(&tr, facts, Fact_ID(first))
				roots[o] = tr.root
			}
			for o in Order {
				if roots[o].node == prev[o].node {
					perm_root_retain(&arena, roots[o])
				}
				perm_root_release(&arena, prev[o])
			}
			fresh := [1]Fact_ID{Fact_ID(first)}
			for o in Order {
				out := xb_flat_merge(facts, order_key(o), flat[o], fresh[:])
				delete(flat[o])
				flat[o] = out
			}
		}
		_, _, during := perm_arena_live(&arena)
		for o in Order {
			perm_root_release(&arena, held[o])
		}
		_, _, after := perm_arena_live(&arena)
		log.infof("pinned reader across %d one-assert commits: tree retains %.2f MB for the pinned set (%.2f MB live with it, %.2f MB after release); the flat set it would pin is %.2f MB",
			H, f64(during - after) / (1024 * 1024), f64(during) / (1024 * 1024), f64(after) / (1024 * 1024), f64(7 * len(flat[.SPOG]) * 4) / (1024 * 1024))
		_ = before
	}
	// Both structures against the oracle: strictly ascending under the
	// key, over every fact.
	{
		facts = s.facts[:]
		for o in Order {
			key := order_key(o)
			// flat
			for i in 1 ..< len(flat[o]) {
				if !perm_key_less(perm_key_of(facts, key, flat[o][i - 1]), perm_key_of(facts, key, flat[o][i])) {
					testing.fail_now(t, "flat/merge broke the order")
				}
			}
			testing.expect_value(t, len(flat[o]), int(s.n_facts))
			// tree
			c := perm_cursor(arena.leaves[:], arena.inners[:], roots[o], 0, int(roots[o].n))
			prev, ok := perm_next(&c)
			n := 1
			for id in perm_next(&c) {
				if !perm_key_less(perm_key_of(facts, key, prev), perm_key_of(facts, key, id)) {
					testing.fail_now(t, "btree broke the order")
				}
				prev = id
				n += 1
			}
			testing.expect(t, ok)
			testing.expect_value(t, n, int(s.n_facts))
			testing.expect_value(t, int(roots[o].n), int(s.n_facts))
		}
	}
	for o in Order {
		perm_root_release(&arena, roots[o])
	}
	leaves, inners, _ := perm_arena_live(&arena)
	testing.expect_value(t, leaves, 0)
	testing.expect_value(t, inners, 0)
}

}

// --- the real apply, in pieces --------------------------------------

@(private = "file")
xb_corpus :: proc() -> (ops: [dynamic]Op, owned: [dynamic]string) {
	own :: proc(owned: ^[dynamic]string, str: string) -> string {
		append(owned, str)
		return str
	}
	subjects := make([]rdf.Term, XB_SUBJECTS)
	defer delete(subjects)
	for &sub, i in subjects {
		sub = rdf.IRI(own(&owned, fmt.aprintf("http://example.org/isms/asset/%06d", i)))
	}
	preds := make([]rdf.Term, XB_PREDS)
	defer delete(preds)
	for &pr, i in preds {
		pr = rdf.IRI(own(&owned, fmt.aprintf("http://example.org/isms/vocab/p%02d", i)))
	}
	objects := make([]rdf.Term, XB_OBJECTS)
	defer delete(objects)
	for &o, i in objects {
		o = rdf.IRI(own(&owned, fmt.aprintf("http://example.org/isms/control/%06d", i)))
	}
	graphs := make([]rdf.Graph_Label, XB_GRAPHS)
	defer delete(graphs)
	for &g, i in graphs {
		if i > 0 {
			g = rdf.IRI(own(&owned, fmt.aprintf("http://example.org/isms/graph/%04d", i)))
		}
	}
	rng: u64 = 0xC0FFEE
	seen := make(map[Quad]bool)
	defer delete(seen)
	ops = make([dynamic]Op, 0, XB_N)
	for len(ops) < XB_N {
		q := xb_quad(&rng)
		if q in seen {
			continue
		}
		seen[q] = true
		g := graphs[0]
		if q.g != 0 {
			g = graphs[int(q.g) - (XB_SUBJECTS + XB_PREDS + XB_OBJECTS + 1)]
		}
		append(&ops, Op{kind = .Assert, quad = {triple = {subjects[int(q.s) - 1], preds[int(q.p) - (XB_SUBJECTS + 1)], objects[int(q.o) - (XB_SUBJECTS + XB_PREDS + 1)]}, graph = g}})
	}
	return
}

when #config(RECORD_XBENCH, false) {

@(test)
test_xbench_apply_breakdown :: proc(t: ^testing.T) {
	fs: Mem_FS
	defer mem_fs_destroy(&fs)
	s: Store
	_, err, _, _ := store_open(&s, "xbench", mem_file_ops(&fs))
	testing.expect_value(t, err, Open_Error.None)
	defer store_close(&s)
	ops, owned := xb_corpus()
	defer {
		for str in owned {
			delete(str)
		}
		delete(owned)
		delete(ops)
	}
	{
		start := time.tick_now()
		_, _, aerr := apply(&s, {ops = ops[:]})
		testing.expect_value(t, aerr, Apply_Error{})
		log.infof("bulk apply of %d ops: %.0f ms", len(ops), ms(time.tick_since(start)))
	}

	R :: 5
	perm, terms, set: time.Duration
	for _ in 0 ..< R {
		start := time.tick_now()
		store_build_permutations(&s)
		perm += time.tick_since(start)
		start = time.tick_now()
		store_merge_term_index(&s, s.idx.terms)
		terms += time.tick_since(start)
		start = time.tick_now()
		cand := build_index_set(&s)
		set += time.tick_since(start)
		release_set(&s, cand)
	}
	// build_index_set moved the roots and the term index out of the
	// store; apply rebuilds both from the published set, so nothing is
	// owed here.
	log.infof("apply pieces at %d facts, %d terms: permutations %.1f ms, term-index merge %.1f ms, index-set build %.2f ms (means of %d)",
		s.n_facts, len(s.dict.off), ms(perm) / R, ms(terms) / R, ms(set) / R, R)

	N :: 24
	lo, hi, sum: time.Duration = time.Duration(max(i64)), 0, 0
	prev: Op
	for i in 0 ..< N {
		two: [2]Op
		n := 0
		if i > 0 {
			two[n] = prev
			two[n].kind = .Retract
			n += 1
		}
		two[n] = Op{kind = .Assert, quad = {triple = {rdf.IRI("http://example.org/isms/asset/000001"), rdf.IRI("http://example.org/isms/vocab/p00"), rdf.Literal{lexical = fmt.tprintf("commit %d", i), datatype = rdf.XSD_STRING}}, graph = nil}}
		prev = two[n]
		n += 1
		start := time.tick_now()
		_, _, cerr := apply(&s, {ops = two[:n], actor = rdf.IRI("http://example.org/isms/editor")})
		d := time.tick_since(start)
		testing.expect_value(t, cerr, Apply_Error{})
		lo = min(lo, d)
		hi = max(hi, d)
		sum += d
	}
	log.infof("apply of 1–2 ops, %d commits: min %.1f ms, mean %.1f ms, max %.1f ms", N, ms(lo), ms(sum) / N, ms(hi))
}

}

// --- awake: boot from disk, flat versus flat-then-pack ------------------

when #config(RECORD_XBENCH, false) {

@(test)
test_xbench_boot :: proc(t: ^testing.T) {
	dir := "build/xbench/boot"
	os.make_directory("build")
	os.make_directory("build/xbench")
	os.make_directory(dir)
	if h, err := os.open(dir); err == nil {
		files, _ := os.read_dir(h, -1, context.allocator)
		for f in files {
			os.remove(f.fullpath)
		}
		os.file_info_slice_delete(files, context.allocator)
		os.close(h)
	}
	ops := posix_file_ops()
	{
		s: Store
		_, err, _, _ := store_open(&s, dir, ops)
		testing.expect_value(t, err, Open_Error.None)
		corpus, owned := xb_corpus()
		defer {
			for str in owned {
				delete(str)
			}
			delete(owned)
			delete(corpus)
		}
		_, _, aerr := apply(&s, {ops = corpus[:]})
		testing.expect_value(t, aerr, Apply_Error{})
		store_close(&s)
	}
	R :: 3
	open_best := time.Duration(max(i64))
	sort_best := time.Duration(max(i64))
	pack_best := time.Duration(max(i64))
	bytes := 0
	for _ in 0 ..< R {
		s: Store
		start := time.tick_now()
		_, err, _, _ := store_open(&s, dir, ops)
		open_best = min(open_best, time.tick_since(start))
		testing.expect_value(t, err, Open_Error.None)
		// sort-and-pack again over the booted store, then the pack alone
		// from the arrays it produced
		start = time.tick_now()
		store_build_permutations(&s)
		sort_best = min(sort_best, time.tick_since(start))
		sorted: [Order][]Fact_ID
		for o in Order {
			sorted[o] = perm_collect(&s.perm, s.ord[o])
		}
		arena: Perm_Arena
		perm_arena_init(&arena)
		start = time.tick_now()
		roots: [Order]Perm_Root
		for o in Order {
			tr := Perm_Tree{arena = &arena, key = order_key(o), gen = 1}
			perm_build(&tr, s.facts[:], sorted[o])
			roots[o] = tr.root
		}
		pack_best = min(pack_best, time.tick_since(start))
		_, _, bytes = perm_arena_live(&arena)
		for o in Order {
			perm_root_release(&arena, roots[o])
			delete(sorted[o])
		}
		perm_arena_destroy(&arena)
		store_close(&s)
	}
	log.infof("awake from disk at %d facts (best of %d): store_open %.0f ms, of which sort-and-pack is %.0f ms and the pack alone %.1f ms at fill %d (%.2f MB)",
		XB_N, R, ms(open_best), ms(sort_best), ms(pack_best), PERM_BUILD_FILL, f64(bytes) / (1024 * 1024))
}

}

// --- §8 re-asked for the tree: build by streaming inserts versus
// sort-then-pack --------------------------------------------------------

when #config(RECORD_XBENCH, false) {

@(test)
test_xbench_stream_build :: proc(t: ^testing.T) {
	rng: u64 = 0xB7EE
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	xb_fill(&s, XB_N, &rng)
	epoch_append(&s, {})
	facts := s.facts[:]

	// sort-then-pack, the boot path (store_build_permutations does both
	// since RECORD-T-0041; the pack is then re-timed alone)
	sort_d := time.Duration(max(i64))
	pack_d := time.Duration(max(i64))
	packed_bytes := 0
	sorted: [Order][]Fact_ID
	defer for o in Order {
		delete(sorted[o])
	}
	for _ in 0 ..< 3 {
		start := time.tick_now()
		store_build_permutations(&s)
		sort_d = min(sort_d, time.tick_since(start))
		for o in Order {
			delete(sorted[o])
			sorted[o] = perm_collect(&s.perm, s.ord[o])
		}
		arena: Perm_Arena
		perm_arena_init(&arena)
		start = time.tick_now()
		roots: [Order]Perm_Root
		for o in Order {
			tr := Perm_Tree{arena = &arena, key = order_key(o), gen = 1}
			perm_build(&tr, facts, sorted[o])
			roots[o] = tr.root
		}
		pack_d = min(pack_d, time.tick_since(start))
		_, _, packed_bytes = perm_arena_live(&arena)
		for o in Order {
			perm_root_release(&arena, roots[o])
		}
		perm_arena_destroy(&arena)
	}
	log.infof("sort-then-pack: sort-and-pack %.1f ms, of which the pack alone is %.1f ms; tree %.2f MB, sort scaffolding transient ~%.1f MB",
		ms(sort_d), ms(pack_d), f64(packed_bytes) / (1024 * 1024),
		f64(4*int(s.n_facts)*4 + 2*int(s.n_facts)*4 + (1 << 16)*4 + 7*int(s.n_facts)*4) / (1024 * 1024))

	// streaming: every fact inserted in id (log) order, one generation
	stream_d := time.Duration(max(i64))
	stream_bytes := 0
	leaves, inners: int
	for _ in 0 ..< 2 {
		arena: Perm_Arena
		perm_arena_init(&arena)
		trees: [Order]Perm_Tree
		for o in Order {
			trees[o] = Perm_Tree{arena = &arena, key = order_key(o), gen = 1}
			perm_build(&trees[o], facts, nil)
		}
		start := time.tick_now()
		for id in 0 ..< s.n_facts {
			for o in Order {
				perm_insert(&trees[o], facts, Fact_ID(id))
			}
		}
		stream_d = min(stream_d, time.tick_since(start))
		leaves, inners, stream_bytes = perm_arena_live(&arena)
		// same result as the sort?
		for o in Order {
			c := perm_cursor(arena.leaves[:], arena.inners[:], trees[o].root, 0, int(trees[o].root.n))
			for want in sorted[o] {
				got, ok := perm_next(&c)
				if !ok || got != want {
					testing.fail_now(t, "streamed tree differs from the sorted permutation")
				}
			}
			perm_root_release(&arena, trees[o].root)
		}
		perm_arena_destroy(&arena)
	}
	log.infof("streaming build: %d inserts x 7 orders in %.0f ms (%.2f µs per fact); tree %.2f MB (%d leaves, %.0f%% fill), no scaffolding",
		s.n_facts, ms(stream_d), ns(stream_d, int(s.n_facts)) / 1000, f64(stream_bytes) / (1024 * 1024), leaves,
		100 * f64(7 * int(s.n_facts)) / f64(leaves * PERM_LEAF_CAP))
}

}
