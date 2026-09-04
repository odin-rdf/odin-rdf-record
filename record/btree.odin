#+private
// The permutation tree (RECORD-I-0009, RECORD-A-0012): a copy-on-write
// B+tree of Fact_IDs, the resident shape of one permutation. It exists
// because the flat sorted []Fact_ID of RECORD-A-0005 part 3 had to be
// re-sorted on every commit — 37 ms of a 37.5 ms apply at 4×10⁵ facts
// — where a tree absorbs a commit's inserts by copying the path they
// touch: ~10 µs and a few kilobytes for one assert across all seven
// orders, measured in btree_bench_test.odin.
//
// # Shape
//
// A leaf holds Fact_IDs and nothing else, PERM_LEAF_CAP of them, 1 KB —
// no key is copied out of the fact table, the pointer-free discipline
// api.md par. 4.1 prices across tenants, so a leaf search gathers from
// the table exactly as the flat binary search did, over 256 ids instead
// of 4×10⁵. An inner node holds, per child, the child's minimum key and
// its entry count. A key is the fact's four components in the order's
// sequence followed by the fact id (Perm_Key): the total order the
// radix sort's stability yields, made explicit, so a tree and the sort
// agree entry for entry. A descent compares in-node keys and sums the
// counts it passes, which is how perm_rank turns a prefix bound into a
// rank — the number the flat array got from slice arithmetic — and how
// range_len stays an exact O(1)-after-match count.
//
// # Immutability and generations
//
// A node carries the build generation that created it. That generation
// may mutate it in place; every later one must copy it first. A commit
// is one generation, so its inserts path-copy each node of an earlier
// generation they pass — a leaf and its ancestors — and a published
// root and everything under it are never written. Nodes live in
// chunked slot arenas (Perm_Arena) that never relocate, addressed by
// index, so a reader holding a root reads through its set's copies of
// the chunk lists and needs no pointer into anything that can move.
//
// # Reclamation
//
// Per-node reference counts, parents counted with the root pointer as
// one (perm_root_retain / perm_root_release). A released node at zero
// cascades to its children and returns its slot to the arena's free
// list. Path copying keeps the counts exact: a copied inner node takes a
// reference on each child, and the parent that switches from the old
// child to the new one drops the old child's — so a node off the copied
// path ends shared by both versions, and a node on it stays the old
// version's alone. Who owns a root is perm_insert's contract, and only
// its. Every procedure here is single-threaded: the arena is the
// writer's, and the store's job (snapshot.odin) is to make sure no
// other thread mutates it.
//
// # Build
//
// perm_build packs a sorted permutation into full leaves in one linear
// pass — the boot path, run over what permute.odin's radix sort
// produces. log.md par. 8's argument for sorting once at the end rather
// than maintaining order during replay was re-measured for the tree and
// holds by 13×: streaming inserts build it in 568 ms at 72% fill against
// 44 ms packed full. Inserting is for commits.
package record

import "base:runtime"

PERM_LEAF_CAP :: 256 // ids per leaf: 1 KB, the unit an insert copies
PERM_INNER_CAP :: 64 // children per inner node
PERM_LEAF_CHUNK :: 1024 // leaves per arena chunk (1 MB)
PERM_INNER_CHUNK :: 256 // inner nodes per arena chunk

// PERM_BUILD_FILL is how many ids perm_build puts in a leaf. Production
// packs full (RECORD-A-0012 decision 4: every wake is a full repack);
// the config exists for the benchmark to measure slack.
PERM_BUILD_FILL :: #config(XB_FILL, PERM_LEAF_CAP)

// Perm_Key is a permutation's total order made explicit: the components
// in the order's key sequence, then the fact id.
Perm_Key :: [5]u32

Perm_Leaf :: struct {
	n:   u32,
	gen: u32,
	ids: [PERM_LEAF_CAP]Fact_ID,
}

Perm_Inner :: struct {
	n:     u32,
	gen:   u32,
	total: u32, // sum of count[0..n)
	child: [PERM_INNER_CAP]u32,
	count: [PERM_INNER_CAP]u32,
	key:   [PERM_INNER_CAP]Perm_Key, // minimum key under child i
}

// Perm_Root is what an index set holds per order: a node index, its
// level (0: the root is a leaf), and the entry count.
Perm_Root :: struct {
	node:  u32,
	level: u8,
	n:     u32,
}

// Perm_Arena owns every node of every order of one store: two chunked
// slot arenas whose chunks never move, a reference count per slot, and
// a free list per kind. A reader holds copies of `leaves` and `inners`
// (the chunk lists) taken at publication; everything else is the
// writer's.
Perm_Arena :: struct {
	leaves:     [dynamic][]Perm_Leaf,
	inners:     [dynamic][]Perm_Inner,
	leaf_refs:  [dynamic]u32,
	inner_refs: [dynamic]u32,
	leaf_free:  [dynamic]u32,
	inner_free: [dynamic]u32,
	allocator:  runtime.Allocator,
}

perm_arena_init :: proc(a: ^Perm_Arena, allocator := context.allocator) {
	a.allocator = allocator
	a.leaves = make([dynamic][]Perm_Leaf, allocator)
	a.inners = make([dynamic][]Perm_Inner, allocator)
	a.leaf_refs = make([dynamic]u32, allocator)
	a.inner_refs = make([dynamic]u32, allocator)
	a.leaf_free = make([dynamic]u32, allocator)
	a.inner_free = make([dynamic]u32, allocator)
}

// perm_arena_destroy frees the arena wholesale, whatever its counts —
// the store's close path, after it has asserted every root is released.
perm_arena_destroy :: proc(a: ^Perm_Arena) {
	for c in a.leaves {
		delete(c, a.allocator)
	}
	for c in a.inners {
		delete(c, a.allocator)
	}
	delete(a.leaves)
	delete(a.inners)
	delete(a.leaf_refs)
	delete(a.inner_refs)
	delete(a.leaf_free)
	delete(a.inner_free)
	a^ = {}
}

// perm_arena_live counts the slots in use and the bytes they occupy —
// the resident figure, and the suites' proof that everything was
// released (zero after the last root goes).
perm_arena_live :: proc(a: ^Perm_Arena) -> (leaves, inners, bytes: int) {
	leaves = len(a.leaf_refs) - len(a.leaf_free)
	inners = len(a.inner_refs) - len(a.inner_free)
	bytes = leaves*size_of(Perm_Leaf) + inners*size_of(Perm_Inner)
	return
}

// perm_leaf and perm_inner index the arena's chunk lists; a reader
// passes its set's copies of the lists (perm_leaf_in / perm_inner_in).
perm_leaf :: #force_inline proc(a: ^Perm_Arena, id: u32) -> ^Perm_Leaf {
	return perm_leaf_in(a.leaves[:], id)
}

perm_inner :: #force_inline proc(a: ^Perm_Arena, id: u32) -> ^Perm_Inner {
	return perm_inner_in(a.inners[:], id)
}

perm_leaf_in :: #force_inline proc(leaves: [][]Perm_Leaf, id: u32) -> ^Perm_Leaf {
	return &leaves[id / PERM_LEAF_CHUNK][id % PERM_LEAF_CHUNK]
}

perm_inner_in :: #force_inline proc(inners: [][]Perm_Inner, id: u32) -> ^Perm_Inner {
	return &inners[id / PERM_INNER_CHUNK][id % PERM_INNER_CHUNK]
}

// perm_leaf_alloc / perm_inner_alloc take a slot — from the free list,
// else a fresh one, growing the arena by a chunk when needed — with one
// reference, which the caller becomes: the parent that will point to
// it, or the set that will hold it as a root.
perm_leaf_alloc :: proc(a: ^Perm_Arena, gen: u32) -> u32 {
	id: u32
	if len(a.leaf_free) > 0 {
		id = pop(&a.leaf_free)
	} else {
		id = u32(len(a.leaf_refs))
		if int(id) % PERM_LEAF_CHUNK == 0 {
			append(&a.leaves, make([]Perm_Leaf, PERM_LEAF_CHUNK, a.allocator))
		}
		append(&a.leaf_refs, 0)
	}
	a.leaf_refs[id] = 1
	l := perm_leaf(a, id)
	l.n = 0
	l.gen = gen
	return id
}

perm_inner_alloc :: proc(a: ^Perm_Arena, gen: u32) -> u32 {
	id: u32
	if len(a.inner_free) > 0 {
		id = pop(&a.inner_free)
	} else {
		id = u32(len(a.inner_refs))
		if int(id) % PERM_INNER_CHUNK == 0 {
			append(&a.inners, make([]Perm_Inner, PERM_INNER_CHUNK, a.allocator))
		}
		append(&a.inner_refs, 0)
	}
	a.inner_refs[id] = 1
	nd := perm_inner(a, id)
	nd.n = 0
	nd.total = 0
	nd.gen = gen
	return id
}

perm_inc :: #force_inline proc(a: ^Perm_Arena, id: u32, level: u8) {
	if level == 0 {
		a.leaf_refs[id] += 1
	} else {
		a.inner_refs[id] += 1
	}
}

// perm_dec drops one reference and frees on zero, cascading to the
// children of a freed inner node.
perm_dec :: proc(a: ^Perm_Arena, id: u32, level: u8) {
	if level == 0 {
		assert(a.leaf_refs[id] > 0, "perm_dec: leaf refcount underflow")
		a.leaf_refs[id] -= 1
		if a.leaf_refs[id] == 0 {
			append(&a.leaf_free, id)
		}
		return
	}
	assert(a.inner_refs[id] > 0, "perm_dec: inner refcount underflow")
	a.inner_refs[id] -= 1
	if a.inner_refs[id] == 0 {
		nd := perm_inner(a, id)
		for j in 0 ..< nd.n {
			perm_dec(a, nd.child[j], level - 1)
		}
		append(&a.inner_free, id)
	}
}

// perm_root_release drops a set's reference to its root. Exactly once
// per reference taken by perm_build, by a perm_insert that replaced the
// root, or by perm_root_retain.
perm_root_release :: proc(a: ^Perm_Arena, r: Perm_Root) {
	perm_dec(a, r.node, r.level)
}

// perm_root_retain takes one more reference on a root — what a new set
// does for an order no insert touched, so that the root it shares with
// its predecessor survives the predecessor's release.
perm_root_retain :: proc(a: ^Perm_Arena, r: Perm_Root) {
	perm_inc(a, r.node, r.level)
}

// perm_key_of gathers one fact's key under an order's component
// sequence — the one place the tree reads the fact table.
perm_key_of :: #force_inline proc(facts: [][]Fact, key: [4]Component, id: Fact_ID) -> Perm_Key {
	f := fact_in(facts, id)
	return {
		u32(fact_component(f, key[0])),
		u32(fact_component(f, key[1])),
		u32(fact_component(f, key[2])),
		u32(fact_component(f, key[3])),
		u32(id),
	}
}

perm_key_less :: #force_inline proc(a, b: Perm_Key) -> bool {
	for i in 0 ..< 5 {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

// perm_pred is the monotone predicate a prefix search descends on: the
// key's first k components compare > (upper) or >= (lower) the wanted
// prefix. Monotone over a sorted sequence, which is what lets one
// descent find the bound.
perm_pred :: #force_inline proc(x: Perm_Key, want: [4]Term_ID, k: int, upper: bool) -> bool {
	for j in 0 ..< k {
		w := u32(want[j])
		if x[j] != w {
			return x[j] > w
		}
	}
	return !upper
}

// Perm_Tree is the writer's handle for one order across one build
// generation: the arena, the order's component sequence, the
// generation whose nodes it may mutate, and the root as it stands.
Perm_Tree :: struct {
	arena: ^Perm_Arena,
	key:   [4]Component,
	gen:   u32,
	root:  Perm_Root,
}

// perm_build packs `sorted` — a permutation in the order t.key, as the
// radix sort produces it — into leaves of PERM_BUILD_FILL ids and stacks
// the inner levels over them, linear in n. Sets t.root, holding one
// reference for the caller. An empty permutation is one empty leaf.
perm_build :: proc(t: ^Perm_Tree, facts: [][]Fact, sorted: []Fact_ID) {
	a := t.arena
	n := len(sorted)
	ids := make([dynamic]u32, a.allocator)
	keys := make([dynamic]Perm_Key, a.allocator)
	counts := make([dynamic]u32, a.allocator)
	defer {
		delete(ids)
		delete(keys)
		delete(counts)
	}
	if n == 0 {
		id := perm_leaf_alloc(a, t.gen)
		t.root = {id, 0, 0}
		return
	}
	for at := 0; at < n; at += PERM_BUILD_FILL {
		id := perm_leaf_alloc(a, t.gen)
		l := perm_leaf(a, id)
		m := min(PERM_BUILD_FILL, n - at)
		copy(l.ids[:m], sorted[at:at + m])
		l.n = u32(m)
		append(&ids, id)
		append(&keys, perm_key_of(facts, t.key, sorted[at]))
		append(&counts, u32(m))
	}
	level: u8 = 0
	for len(ids) > 1 {
		nids := make([dynamic]u32, a.allocator)
		nkeys := make([dynamic]Perm_Key, a.allocator)
		ncounts := make([dynamic]u32, a.allocator)
		for at := 0; at < len(ids); at += PERM_INNER_CAP {
			id := perm_inner_alloc(a, t.gen)
			nd := perm_inner(a, id)
			m := min(PERM_INNER_CAP, len(ids) - at)
			total: u32
			for j in 0 ..< m {
				nd.child[j] = ids[at + j]
				nd.key[j] = keys[at + j]
				nd.count[j] = counts[at + j]
				total += counts[at + j]
			}
			nd.n = u32(m)
			nd.total = total
			append(&nids, id)
			append(&nkeys, keys[at])
			append(&ncounts, total)
		}
		delete(ids)
		delete(keys)
		delete(counts)
		ids, keys, counts = nids, nkeys, ncounts
		level += 1
	}
	t.root = {ids[0], level, u32(n)}
}

// perm_min_key is the key of the leftmost entry under a node.
perm_min_key :: proc(t: ^Perm_Tree, facts: [][]Fact, node: u32, level: u8) -> Perm_Key {
	node, level := node, level
	for level > 0 {
		node = perm_inner(t.arena, node).child[0]
		level -= 1
	}
	l := perm_leaf(t.arena, node)
	assert(l.n > 0, "perm_min_key: an empty leaf below the root")
	return perm_key_of(facts, t.key, l.ids[0])
}

Perm_Ins :: struct {
	node:   u32,
	count:  u32,
	right:  u32,
	rkey:   Perm_Key,
	rcount: u32,
	split:  bool,
}

// perm_insert adds one fact id under generation t.gen, path-copying
// every node of an earlier generation between the root and the leaf it
// lands in; t.root is updated in place.
//
// **Root ownership.** The reference on a root belongs to the set that
// published it, never to this handle. When an insert replaces the root
// (a copy, or a split growing a level), the new root arrives holding
// one reference for the set that will publish it, and the old root is
// left untouched for the set that holds it to release. When a build
// ends with the root it started from — no insert reached this order —
// the new set shares it and must perm_root_retain it before the old set
// releases. That is the whole discipline, and it lives here and nowhere
// else.
perm_insert :: proc(t: ^Perm_Tree, facts: [][]Fact, id: Fact_ID) {
	k := perm_key_of(facts, t.key, id)
	res := perm_insert_rec(t, facts, t.root.node, t.root.level, k, id)
	t.root.node = res.node
	t.root.n += 1
	if res.split {
		r := perm_inner_alloc(t.arena, t.gen)
		nd := perm_inner(t.arena, r)
		nd.n = 2
		nd.child[0] = res.node
		nd.key[0] = perm_min_key(t, facts, res.node, t.root.level)
		nd.count[0] = res.count
		nd.child[1] = res.right
		nd.key[1] = res.rkey
		nd.count[1] = res.rcount
		nd.total = res.count + res.rcount
		t.root.node = r
		t.root.level += 1
	}
}

perm_insert_rec :: proc(t: ^Perm_Tree, facts: [][]Fact, node: u32, level: u8, k: Perm_Key, id: Fact_ID) -> (r: Perm_Ins) {
	a := t.arena
	if level == 0 {
		lid := node
		l := perm_leaf(a, lid)
		if l.gen != t.gen {
			nid := perm_leaf_alloc(a, t.gen)
			nl := perm_leaf(a, nid)
			nl.n = l.n
			copy(nl.ids[:l.n], l.ids[:l.n])
			lid, l = nid, nl
		}
		lo, hi := 0, int(l.n)
		for lo < hi {
			mid := int(uint(lo + hi) >> 1)
			if perm_key_less(perm_key_of(facts, t.key, l.ids[mid]), k) {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		if l.n < PERM_LEAF_CAP {
			copy(l.ids[lo + 1:l.n + 1], l.ids[lo:l.n])
			l.ids[lo] = id
			l.n += 1
			return {node = lid, count = l.n}
		}
		rid := perm_leaf_alloc(a, t.gen)
		rl := perm_leaf(a, rid)
		half := PERM_LEAF_CAP / 2
		copy(rl.ids[:PERM_LEAF_CAP - half], l.ids[half:])
		rl.n = u32(PERM_LEAF_CAP - half)
		l.n = u32(half)
		if lo <= half {
			copy(l.ids[lo + 1:l.n + 1], l.ids[lo:l.n])
			l.ids[lo] = id
			l.n += 1
		} else {
			p := lo - half
			copy(rl.ids[p + 1:rl.n + 1], rl.ids[p:rl.n])
			rl.ids[p] = id
			rl.n += 1
		}
		return {node = lid, count = l.n, right = rid, rkey = perm_key_of(facts, t.key, rl.ids[0]), rcount = rl.n, split = true}
	}

	nd := perm_inner(a, node)
	lo, hi := 0, int(nd.n)
	for lo < hi {
		mid := int(uint(lo + hi) >> 1)
		if perm_key_less(k, nd.key[mid]) {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	i := max(lo - 1, 0)
	c := perm_insert_rec(t, facts, nd.child[i], level - 1, k, id)
	iid := node
	if nd.gen != t.gen {
		nid := perm_inner_alloc(a, t.gen)
		nin := perm_inner(a, nid)
		nin.n = nd.n
		nin.total = nd.total
		copy(nin.child[:nd.n], nd.child[:nd.n])
		copy(nin.key[:nd.n], nd.key[:nd.n])
		copy(nin.count[:nd.n], nd.count[:nd.n])
		for j in 0 ..< nd.n {
			perm_inc(a, nd.child[j], level - 1)
		}
		iid, nd = nid, nin
	}
	if c.node != nd.child[i] {
		perm_dec(a, nd.child[i], level - 1)
		nd.child[i] = c.node
	}
	nd.count[i] = c.count
	if i == 0 && perm_key_less(k, nd.key[0]) {
		nd.key[0] = k // a new minimum under the first child is this node's too
	}
	nd.total += 1
	if !c.split {
		return {node = iid, count = nd.total}
	}
	// The child split: entry i+1 is the right half. Make room first.
	if nd.n < PERM_INNER_CAP {
		perm_inner_insert(nd, i + 1, c.right, c.rkey, c.rcount)
		return {node = iid, count = nd.total}
	}
	qid := perm_inner_alloc(a, t.gen)
	q := perm_inner(a, qid)
	half := PERM_INNER_CAP / 2
	q.n = u32(PERM_INNER_CAP - half)
	copy(q.child[:q.n], nd.child[half:])
	copy(q.key[:q.n], nd.key[half:])
	copy(q.count[:q.n], nd.count[half:])
	nd.n = u32(half)
	if i + 1 <= half {
		perm_inner_insert(nd, i + 1, c.right, c.rkey, c.rcount)
	} else {
		perm_inner_insert(q, i + 1 - half, c.right, c.rkey, c.rcount)
	}
	nd.total = 0
	for j in 0 ..< nd.n {
		nd.total += nd.count[j]
	}
	q.total = 0
	for j in 0 ..< q.n {
		q.total += q.count[j]
	}
	return {node = iid, count = nd.total, right = qid, rkey = q.key[0], rcount = q.total, split = true}
}

perm_inner_insert :: #force_inline proc(nd: ^Perm_Inner, at: int, child: u32, key: Perm_Key, count: u32) {
	m := int(nd.n)
	copy(nd.child[at + 1:m + 1], nd.child[at:m])
	copy(nd.key[at + 1:m + 1], nd.key[at:m])
	copy(nd.count[at + 1:m + 1], nd.count[at:m])
	nd.child[at] = child
	nd.key[at] = key
	nd.count[at] = count
	nd.n += 1
}

// perm_rank is the match: the rank of the first entry whose first k
// components compare >= the wanted prefix (upper = false) or > it
// (upper = true) — k = 0 answers 0 and n. One descent comparing in-node
// keys and summing the counts it passes, then one binary search in the
// leaf gathering from the fact table. Reads through the caller's chunk
// lists so a reader passes its set's copies.
perm_rank :: proc(leaves: [][]Perm_Leaf, inners: [][]Perm_Inner, facts: [][]Fact, key: [4]Component, root: Perm_Root, want: [4]Term_ID, k: int, upper: bool) -> int {
	node, level := root.node, root.level
	rank := 0
	for level > 0 {
		nd := perm_inner_in(inners, node)
		lo, hi := 0, int(nd.n)
		for lo < hi {
			mid := int(uint(lo + hi) >> 1)
			if perm_pred(nd.key[mid], want, k, upper) {
				hi = mid
			} else {
				lo = mid + 1
			}
		}
		i := max(lo - 1, 0)
		for j in 0 ..< i {
			rank += int(nd.count[j])
		}
		node = nd.child[i]
		level -= 1
	}
	l := perm_leaf_in(leaves, node)
	lo, hi := 0, int(l.n)
	for lo < hi {
		mid := int(uint(lo + hi) >> 1)
		if perm_pred(perm_key_of(facts, key, l.ids[mid]), want, k, upper) {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return rank + lo
}

// Perm_Cursor walks entries [lo, hi) of a root in order: a path of
// (inner node, child index) down to the current leaf, advanced by
// stepping the deepest index that can step and descending leftmost.
// Leaves carry no sibling links on purpose — a link would make every
// leaf copy cascade into its neighbour. Borrows the chunk lists it was
// opened with.
Perm_Cursor :: struct {
	leaves:    [][]Perm_Leaf,
	inners:    [][]Perm_Inner,
	path:      [8]struct {
		node: u32,
		i:    u32,
	},
	depth:     int,
	leaf:      u32,
	pos:       u32,
	remaining: int,
}

// perm_cursor opens a cursor at rank lo, to yield hi - lo entries.
perm_cursor :: proc(leaves: [][]Perm_Leaf, inners: [][]Perm_Inner, root: Perm_Root, lo, hi: int) -> (c: Perm_Cursor) {
	c.leaves = leaves
	c.inners = inners
	c.remaining = hi - lo
	if c.remaining <= 0 {
		return
	}
	node, level := root.node, root.level
	r := lo
	d := 0
	for level > 0 {
		nd := perm_inner_in(inners, node)
		i := 0
		for i < int(nd.n) - 1 && r >= int(nd.count[i]) {
			r -= int(nd.count[i])
			i += 1
		}
		c.path[d] = {node, u32(i)}
		d += 1
		node = nd.child[i]
		level -= 1
	}
	c.depth = d
	c.leaf = node
	c.pos = u32(r)
	return
}

// perm_next yields the next entry, false when the window is consumed.
perm_next :: proc(c: ^Perm_Cursor) -> (id: Fact_ID, ok: bool) {
	if c.remaining <= 0 {
		return 0, false
	}
	l := perm_leaf_in(c.leaves, c.leaf)
	id = l.ids[c.pos]
	c.pos += 1
	c.remaining -= 1
	if c.pos == l.n && c.remaining > 0 {
		d := c.depth - 1
		for d >= 0 {
			nd := perm_inner_in(c.inners, c.path[d].node)
			if c.path[d].i + 1 < nd.n {
				c.path[d].i += 1
				break
			}
			d -= 1
		}
		assert(d >= 0, "perm_next: ran off the tree with entries remaining")
		node := perm_inner_in(c.inners, c.path[d].node).child[c.path[d].i]
		for e := d + 1; e < c.depth; e += 1 {
			c.path[e] = {node, 0}
			node = perm_inner_in(c.inners, node).child[0]
		}
		c.leaf = node
		c.pos = 0
	}
	return id, true
}
