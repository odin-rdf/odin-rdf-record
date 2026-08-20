package record

import "core:bytes"
import "core:fmt"
import "core:log"
import "core:sync"
import "core:testing"
import "core:thread"

import "rdf:rdf"

// The term index's tests (RECORD-T-0014): the sorted array is sorted
// and complete, the probe finds every term and misses every non-term,
// a merge equals a rebuild, and — the point of the task — readers and
// a writer run concurrently under the memory checker: threads acquire,
// resolve, match, test existence and release while the writer appends
// terms and facts, retracts, rebuilds, merges and publishes hundreds of
// times, with every answer checked against the writer's deterministic
// schedule.

@(private = "file")
ti_enc :: proc(s: string) -> []byte {
	return transmute([]byte)s
}

@(private = "file")
ti_add :: proc(t: ^testing.T, s: ^Store, encs: []string) {
	for e in encs {
		_, err := dict_add(&s.dict, ti_enc(e), s.allocator)
		testing.expect_value(t, err, Load_Error.None)
	}
}

// ti_sorted checks an index against its dictionary: one id per term,
// strictly ascending by bytes.
@(private = "file")
ti_sorted :: proc(t: ^testing.T, s: ^Store, terms: []Term_ID, loc := #caller_location) {
	testing.expect_value(t, len(terms), len(s.dict.off), loc = loc)
	seen := make([]bool, len(terms)+1)
	defer delete(seen)
	for id, i in terms {
		testing.expect(t, id >= 1 && int(id) <= len(terms) && !seen[id], "every id once", loc = loc)
		seen[id] = true
		if i > 0 {
			testing.expect(t, bytes.compare(dict_bytes(&s.dict, terms[i-1]), dict_bytes(&s.dict, id)) < 0, "strictly ascending by encoding", loc = loc)
		}
	}
}

@(test)
test_term_index_build_and_find :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	// Deliberately unsorted, with shared prefixes and every tag.
	encs := [?]string{
		"\x03hello",
		"\x01http://ex/b",
		"\x01http://ex/a",
		"\x02b0",
		"\x01http://ex/ab",
		"\x04\x02enHello",
		"\x05\x00\x00\x00\x00\x00\x00\x00\x0299",
		"\x03",
		"\x01http://ex/",
	}
	ti_add(t, &s, encs[:])
	store_build_term_index(&s)
	ti_sorted(t, &s, s.terms)
	store_build_permutations(&s)
	store_publish(&s)
	snap, serr := store_latest(&s)
	testing.expect_value(t, serr, Snapshot_Error.None)
	defer snapshot_release(&snap)

	for e, i in encs {
		id, ok := snapshot_find(snap, ti_enc(e))
		testing.expect(t, ok, "every interned encoding is found")
		testing.expect_value(t, id, Term_ID(i+1))
	}
	misses := [?]string{"", "\x01http://ex/c", "\x01http://ex/", "\x03hell", "\x03hello!", "\x02b1", "\x06x"}
	for m, i in misses {
		_, ok := snapshot_find(snap, ti_enc(m))
		testing.expect(t, !ok || i == 2, "an absent encoding is a miss") // "\x01http://ex/" is present
	}

	// The empty index: nothing is found, nothing breaks.
	e: Store
	store_init(&e)
	defer store_destroy(&e)
	store_build_term_index(&e)
	testing.expect_value(t, len(e.terms), 0)
	store_build_permutations(&e)
	store_publish(&e)
	esnap, _ := store_latest(&e)
	defer snapshot_release(&esnap)
	_, eok := snapshot_find(esnap, ti_enc("\x01http://ex/a"))
	testing.expect(t, !eok, "the empty index misses")
}

@(test)
test_term_index_merge_equals_rebuild :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	first := [?]string{"\x01http://ex/m", "\x01http://ex/c", "\x03zzz", "\x02b"}
	ti_add(t, &s, first[:])
	store_build_term_index(&s)
	base := make([]Term_ID, len(s.terms))
	defer delete(base)
	copy(base, s.terms)

	// New ids land on both sides of and between the published ones,
	// including a run of several in a row.
	later := [?]string{"\x01http://ex/a", "\x03zzzz", "\x01http://ex/d", "\x01http://ex/e", "\x01http://ex/f", "\x00", "\x02a", "\x04\x02enx"}
	ti_add(t, &s, later[:])
	store_merge_term_index(&s, base)
	ti_sorted(t, &s, s.terms)
	merged := make([]Term_ID, len(s.terms))
	defer delete(merged)
	copy(merged, s.terms)

	store_build_term_index(&s)
	testing.expect(t, bytes.compare(transmute([]byte)merged, transmute([]byte)s.terms) == 0, "a merge is a rebuild")

	// Merging nothing new is a copy.
	full := make([]Term_ID, len(s.terms))
	defer delete(full)
	copy(full, s.terms)
	store_merge_term_index(&s, full)
	testing.expect(t, bytes.compare(transmute([]byte)full, transmute([]byte)s.terms) == 0, "an empty merge is the identity")
}

// --- the reader/writer torture -----------------------------------------

// The schedule, all arithmetic: the predicate is term 1, published at
// epoch 0. Round i (0-based) commits epoch E = i+1: interns term i+2
// ("http://ex/t<i>"), asserts fact i = (i+2, 1, i+2, 0) at E, and
// retracts fact i-2 at E when i >= 2. So at epoch E, fact j is visible
// iff j <= E-1 and E < j+3, i.e. E-2 <= j <= E-1: the live count is
// min(E, 2), and Exists({s = j+2}) is that same predicate.
@(private = "file")
TORTURE_ROUNDS :: 300
@(private = "file")
TORTURE_READERS :: 4

@(private = "file")
Torture :: struct {
	s:      ^Store,
	done:   bool, // atomic
	reads:  int, // atomic: snapshots acquired by readers
	faults: int, // atomic: checks that failed, reported on the main thread
	mid:    int, // atomic: reads pinned strictly between the first and the last publish — proof the readers overlapped the writer
}

@(private = "file")
torture_fault :: proc(tt: ^Torture, ok: bool) {
	if !ok {
		sync.atomic_add(&tt.faults, 1)
	}
}

@(private = "file")
torture_check :: proc(tt: ^Torture, snap: Snapshot) {
	E := snap.epoch
	set := snap.idx
	// The set is internally consistent: one term per id, the index
	// and the offsets sized to it, the facts sized to the schedule.
	torture_fault(tt, int(set.n_terms) == len(set.terms) && int(set.n_terms) == len(set.off))
	torture_fault(tt, set.epoch >= E && set.n_terms == u32(set.epoch)+1 && set.n_facts == u32(set.epoch))

	// Resolve: the predicate and the last term this epoch interned,
	// by name, and the term after it is a miss for a set at this epoch
	// (it may exist in a newer set, never in this one's bound).
	p, pok := snapshot_resolve(snap, rdf.IRI("http://ex/p"))
	torture_fault(tt, pok && p == 1)
	if E >= 1 {
		name: [32]byte
		last := fmt.bprintf(name[:], "http://ex/t%d", E-1)
		id, ok := snapshot_resolve(snap, rdf.IRI(last))
		torture_fault(tt, ok && u32(id) == u32(E)+1)
		torture_fault(tt, snapshot_kind(snap, id) == .IRI)
	}
	if set.epoch == E {
		name: [32]byte
		next := fmt.bprintf(name[:], "http://ex/t%d", E)
		_, ok := snapshot_resolve(snap, rdf.IRI(next))
		torture_fault(tt, !ok)
	}

	// Match: the live count at E is min(E, 2), scanned through the
	// permutation the writer keeps rebuilding under us.
	n := 0
	sc := range_iter(snapshot_match(snap, {p = 1}), {origin = .Any})
	for id in scan_next(&sc) {
		f := snapshot_fact(snap, id)
		// The schedule numbers terms, facts and epochs in lockstep, so the
		// three id spaces are compared through their raw values on purpose.
		k := u32(id)
		torture_fault(tt, u32(f.s) == k+2 && u32(f.o) == k+2 && k+1 <= u32(E) && u32(E) < k+3)
		n += 1
	}
	torture_fault(tt, n == min(int(E), 2))

	// Exists, at the edges of the live window.
	if E >= 1 {
		torture_fault(tt, snapshot_exists(snap, {s = Term_ID(E) + 1}, {origin = .Any}))
	}
	if E >= 3 {
		torture_fault(tt, !snapshot_exists(snap, {s = Term_ID(E) - 1}, {origin = .Any}))
	}
	torture_fault(tt, !snapshot_exists(snap, {s = Term_ID(E) + 2}, {origin = .Any}))
	// The epoch table through the set: every published epoch's meta.
	if E >= 1 {
		torture_fault(tt, snapshot_epoch_meta(snap, E).wall == u64(E))
	}
}

@(private = "file")
torture_reader :: proc(tt: ^Torture) {
	for !sync.atomic_load(&tt.done) {
		snap, err := store_latest(tt.s)
		if err != .None {
			torture_fault(tt, false)
			continue
		}
		torture_check(tt, snap)
		if snap.epoch > 0 && snap.epoch < TORTURE_ROUNDS {
			sync.atomic_add(&tt.mid, 1)
		}
		// A historical pin from the same set answers about its epoch.
		if snap.epoch >= 2 {
			old, oerr := store_at(tt.s, snap.epoch/2)
			torture_fault(tt, oerr == .None)
			if oerr == .None {
				torture_check(tt, old)
				snapshot_release(&old)
			}
		}
		snapshot_release(&snap)
		sync.atomic_add(&tt.reads, 1)
	}
}

@(test)
test_term_index_reader_writer_torture :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	_, perr := dict_add(&s.dict, ti_enc("\x01http://ex/p"), s.allocator)
	testing.expect_value(t, perr, Load_Error.None)
	store_build_permutations(&s)
	store_build_term_index(&s)
	store_publish(&s)

	tt := Torture{s = &s}
	readers: [TORTURE_READERS]^thread.Thread
	for &r in readers {
		r = thread.create_and_start_with_poly_data(&tt, torture_reader, init_context = context)
	}

	// The writer: this thread, the schedule above, through the
	// procedures Apply (RECORD-T-0015) will drive.
	name: [32]byte
	for i in 0 ..< TORTURE_ROUNDS {
		E := u32(i + 1)
		enc := fmt.bprintf(name[:], "\x01http://ex/t%d", i)
		id, aerr := dict_add(&s.dict, transmute([]byte)enc, s.allocator)
		testing.expect_value(t, aerr, Load_Error.None)
		testing.expect_value(t, id, Term_ID(E+1))
		epoch_append(&s, Epoch_Meta{wall = u64(E)})
		fact_append(&s, Fact{s = id, p = 1, o = id, g = 0, assert = Epoch(E), retract = LIVE_EPOCH}, false)
		if i >= 2 {
			sync.atomic_store_explicit(&store_fact(&s, Fact_ID(i-2)).retract, Epoch(E), .Relaxed)
		}
		store_build_permutations(&s)
		store_merge_term_index(&s, s.idx.terms)
		store_publish(&s)
	}
	sync.atomic_store(&tt.done, true)
	for r in readers {
		thread.join(r)
		thread.destroy(r)
	}

	testing.expect_value(t, tt.faults, 0)
	testing.expect(t, tt.reads > TORTURE_ROUNDS, "readers ran throughout: more acquisitions than publishes")
	testing.expect(t, tt.mid > 0, "readers overlapped the writer: some pinned an epoch strictly between the first and the last publish")
	log.infof("torture: %d publishes, %d reader acquisitions, %d of them mid-run", TORTURE_ROUNDS, tt.reads, tt.mid)
}
