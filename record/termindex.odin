// The term index (RECORD-T-0014): the dictionary's ids sorted by their
// canonical encoding — the seventh sorted array beside the six
// permutations, and the only term lookup on the read side (RECORD-I-0003
// decision 2, amending api.md par. 4 and par. 12.7). It replaced a map
// the writer mutated while readers probed it; an array built by the
// writer and published atomically with everything else a reader
// touches is correct by construction, the way par. 13.8 made n_terms
// correct. Resolve is a binary search comparing arena bytes — ~17
// probes at 8x10^4 terms — against the map's one hash, on a path the
// consumers take once per ground term per query, not per row.
//
// Built once at boot by sorting (store_build_term_index), and per
// commit by merging the few new ids into a fresh array
// (store_merge_term_index) — an O(n) copy the flat copy-on-write of
// RECORD-A-0005 already pays six times over for the permutations. The
// order is plain byte order over encodings: it need not mean anything,
// only be total and agree between the sort and the search, which one
// comparison procedure guarantees.
package record

import "core:bytes"

// store_build_term_index sorts every dictionary id by its encoding into
// s.terms — boot's one-time build, after replay and before publish,
// like the permutations. Replaces whatever s.terms held.
store_build_term_index :: proc(s: ^Store) {
	n := len(s.dict.off)
	ids := make([]u32, n, s.allocator)
	for i in 0 ..< n {
		ids[i] = u32(i + 1)
	}
	sort_term_ids(&s.dict, ids)
	delete(s.terms, s.allocator)
	s.terms = ids
}

// store_merge_term_index is the per-commit build: `base` is the
// published index — every id 1..len(base), in order — and the ids the
// writer has interned since, len(base)+1 .. len(off), are sorted among
// themselves and merged with it into a fresh s.terms. `base` is read,
// never written or freed; it stays the published set's until that set
// is released. The writer's step between dict_add and store_publish
// (RECORD-T-0015).
store_merge_term_index :: proc(s: ^Store, base: []u32) {
	n := len(s.dict.off)
	assert(len(base) <= n, "store_merge_term_index: the base index is larger than the dictionary")
	fresh := make([]u32, n-len(base), s.allocator)
	defer delete(fresh, s.allocator)
	for i in 0 ..< len(fresh) {
		fresh[i] = u32(len(base) + 1 + i)
	}
	sort_term_ids(&s.dict, fresh)

	out := make([]u32, n, s.allocator)
	i, j, k := 0, 0, 0
	for i < len(base) && j < len(fresh) {
		if bytes.compare(dict_bytes(&s.dict, base[i]), dict_bytes(&s.dict, fresh[j])) < 0 {
			out[k] = base[i]
			i += 1
		} else {
			out[k] = fresh[j]
			j += 1
		}
		k += 1
	}
	k += copy(out[k:], base[i:])
	copy(out[k:], fresh[j:])
	delete(s.terms, s.allocator)
	s.terms = out
}

// term_index_find binary-searches a published set's index for an
// encoding — the read side's one dictionary probe, behind
// snapshot_resolve and the intern. The bytes compared are the set's
// own view of the arena, so a term defined after the set published is
// a miss by construction.
@(private)
term_index_find :: proc(set: ^Index_Set, enc: []byte) -> (id: u32, ok: bool) {
	lo, hi := 0, len(set.terms)
	for lo < hi {
		mid := int(uint(lo+hi) >> 1)
		c := bytes.compare(set_bytes(set, set.terms[mid]), enc)
		switch {
		case c < 0:
			lo = mid + 1
		case c > 0:
			hi = mid
		case:
			return set.terms[mid], true
		}
	}
	return 0, false
}

// Term_Key is the sort's transient record: the arena view beside the
// id, so the sort reads no dictionary — the same trade permute.odin's
// Perm_Rec makes, for the same reason (a sort that gathers through the
// store is the slow half of a sort).
@(private = "file")
Term_Key :: struct {
	enc: []byte,
	id:  u32,
}

// sort_term_ids sorts ids in place by their arena bytes, through a
// transient array of keys freed before returning. The sort is a
// three-way string quicksort (Bentley-Sedgewick), not a comparison
// sort over whole encodings: a store's IRIs share long prefixes — the
// ISMS corpus's share ~30 bytes — and a comparison sort re-scans that
// prefix on every one of its n log n comparisons, where partitioning
// on one byte per depth scans it once per level. Measured at 8x10^4
// terms: 43 ms by comparison, 7 ms this way. Encodings are
// injective, so there are no equal keys and stability does not arise.
@(private = "file")
sort_term_ids :: proc(d: ^Dict, ids: []u32) {
	keys := make([]Term_Key, len(ids), context.temp_allocator)
	defer delete(keys, context.temp_allocator)
	for id, i in ids {
		keys[i] = {enc = dict_bytes(d, id), id = id}
	}
	multikey_sort(keys, 0)
	for k, i in keys {
		ids[i] = k.id
	}
}

// multikey_sort partitions keys three ways on the byte at `depth`
// (-1 past an encoding's end, so a prefix sorts before its
// extensions), recurses into the less and greater parts at the same
// depth and the equal part one byte deeper, and iterates on the
// largest part to bound the recursion. Small parts finish by insertion
// sort from `depth`, the bytes before it being equal by construction.
@(private = "file")
multikey_sort :: proc(keys: []Term_Key, depth: int) {
	byte_at :: #force_inline proc(k: Term_Key, d: int) -> int {
		return int(k.enc[d]) if d < len(k.enc) else -1
	}
	keys, depth := keys, depth
	for len(keys) > 1 {
		if len(keys) <= 12 {
			for i in 1 ..< len(keys) {
				for j := i; j > 0 && bytes.compare(keys[j].enc[depth:], keys[j-1].enc[depth:]) < 0; j -= 1 {
					keys[j], keys[j-1] = keys[j-1], keys[j]
				}
			}
			return
		}
		pivot := byte_at(keys[len(keys)/2], depth)
		lt, i, gt := 0, 0, len(keys)
		for i < gt {
			c := byte_at(keys[i], depth)
			switch {
			case c < pivot:
				keys[lt], keys[i] = keys[i], keys[lt]
				lt += 1
				i += 1
			case c > pivot:
				gt -= 1
				keys[i], keys[gt] = keys[gt], keys[i]
			case:
				i += 1
			}
		}
		// Recurse into the two smaller parts, loop on the largest.
		less, equal, greater := keys[:lt], keys[lt:gt], keys[gt:]
		if pivot < 0 {
			equal = nil // all ended here: one key, since encodings are injective
		}
		switch {
		case len(less) >= len(equal) && len(less) >= len(greater):
			multikey_sort(equal, depth+1)
			multikey_sort(greater, depth)
			keys = less
		case len(greater) >= len(equal):
			multikey_sort(less, depth)
			multikey_sort(equal, depth+1)
			keys = greater
		case:
			multikey_sort(less, depth)
			multikey_sort(greater, depth)
			keys, depth = equal, depth+1
		}
	}
}
