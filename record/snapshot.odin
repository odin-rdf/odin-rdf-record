// Snapshots and publication (RECORD-T-0009, made safe under a live
// writer in RECORD-T-0014): the epoch discipline of log.md par. 7.1
// steps 4-5 and the refcounted read handle of RECORD-A-0005 — how a
// reader gets a consistent, immutable view of a store that a writer
// keeps advancing, with no lock on the read path.
//
// # The single-writer / N-reader model, precisely
//
// There is exactly one writer (log.md par. 10). It publishes an
// Index_Set: the six permutations, the term index, the origin bitset,
// the high-water marks — and, because this is a language without a
// collector, its own copies of every list a reader would otherwise
// have to read from the Store while the writer grows it: the fact
// chunk list, the dictionary's chunk list, fill counts and offsets,
// the epoch chunk list (api.md par. 13.8: "every structure a reader
// touches lives inside indexSet precisely so that one atomic load
// yields a consistent set"). A reader therefore touches the Store
// through exactly one kind of memory: chunk payloads, which never move
// and are never rewritten below the set's bounds. The one field a
// reader loads that the writer mutates in place is Fact.retract
// (api.md par. 2.3), stored and loaded atomically; a reader that
// misses a just-written retraction computes the same answer, because
// a retraction recorded after the reader pinned epoch e always carries
// retract > e. Facts and terms the writer has appended since a set
// published sit past its n_facts and n_terms and are never reached.
// Environment notes (store_note_at) are the one structure read from
// the Store directly: they are appended only at boot, before a reader
// exists.
//
// # Acquire, publish, release — and why acquire takes a lock
//
// RECORD-A-0005 says reads are lock-free, and they are: snapshot_match,
// range_iter, scan_next, snapshot_resolve, snapshot_bytes and
// snapshot_term take no lock. *Acquire* does (RECORD-I-0003
// decision 3): store_latest and store_at take the store's mutex around
// load-idx-and-increment, and store_publish takes it around
// swap-idx-and-announce. Without it, a reader preempted between
// loading the set pointer and raising its count races a publish that
// releases the store's reference and frees the set — a window a retire
// list would narrow to one commit interval but not close. With it the
// proof is two sentences: an acquirer either runs before the swap and
// raises the count of a set the publisher has not yet released, or
// after it and sees the new set; the publisher releases the old set
// only after the swap, so every reference it drops to zero was
// counted under the lock. Release takes no lock — it can only lower a
// count the lock saw raised, and a free on zero happens after the
// store's own reference went under the lock. The lock is per request
// (one uncontended acquire), never per match, iterate or resolve; at
// the workload's ~99:1 read-to-write ratio that is the whole cost.
//
// # Reclamation (RECORD-A-0005)
//
// An Index_Set owns what publication replaces — the permutation arrays
// and the term index (moved out of Store.ord and Store.terms by
// store_publish, which is why a rebuild after publish cannot dangle a
// published set), its bitset copy, and its list copies — and is freed
// when its reference count drops to zero: the store holds one
// reference from publish until it publishes a successor or closes, and
// every live Snapshot holds one.
package record

import "core:slice"
import "core:sync"

// Snapshot_Error is how acquisition refuses.
Snapshot_Error :: enum {
	None,
	Unpublished,  // the store has never published — nothing to read
	Future_Epoch, // At(e) past the published epoch: the future is not readable
}

// Index_Set is the writer's unit of publication (api.md par. 12.1):
// one pointer swap covers everything a reader needs, so a reader
// cannot observe a mixed-version set. It owns its arrays. The chunk
// payloads it points into — fact chunks, dictionary chunks, epoch
// chunks — are owned by the store, never move, and outlive every set
// (RECORD-A-0005 part 1); the set bounds what it reads of them with
// n_facts and n_terms, and reads them through its own copies of the
// chunk lists, taken at publication (package comment).
Index_Set :: struct {
	ord:     [Order][]Fact_ID, // the six sorted FactID permutations
	terms:   []Term_ID, // the term index: dictionary ids sorted by encoding (termindex.odin)
	derived: []u64, // the origin bitset at publication
	facts:   [][]Fact, // the fact chunk list at publication
	dict:    [][]byte, // the dictionary chunk list at publication
	used:    []u32, // each dictionary chunk's fill at publication
	off:     []u32, // the dictionary offsets at publication, one per term
	epochs:  [][]Epoch_Meta, // the epoch chunk list at publication
	epoch:   Epoch, // the epoch this set published
	n_facts: u32, // facts this set covers; ids at or past this are not in ord
	n_terms: u32, // dictionary high-water mark at publication (api.md par. 13.8); len(terms) and len(off)
	refs:    int, // atomic reference count: the store's publish reference plus one per live Snapshot
}

// Snapshot is a logical instant: a pinned epoch plus the index set
// published at or after it. It is a resource, not a plain value
// (RECORD-A-0005 part 2): acquire with store_latest or store_at, use,
// and release exactly once with snapshot_release — a live snapshot
// pins its whole index set, so the expected discipline is
// request-scoped, nothing held across think-time (api.md par. 13.2).
Snapshot :: struct {
	epoch: Epoch,
	idx:   ^Index_Set,
	store: ^Store,
}

// store_publish publishes the store's current state: the built
// permutations and term index become a fresh Index_Set — with the
// bitset and the list copies it takes here — installed and announced
// under the mutex in par. 7.1's order (set first, epoch second), after
// which the store releases its reference to the set it supersedes. The
// caller must have run store_build_permutations and
// store_build_term_index or store_merge_term_index since the last
// append — publication is the apply/publish boundary, and a set
// covering facts or terms its arrays do not sort would answer wrongly,
// so both are asserted. Boot calls it once. apply calls its two halves
// separately — build_index_set before the fsync, for the candidate the
// validator sees; install_index_set after it.
store_publish :: proc(s: ^Store) {
	install_index_set(s, build_index_set(s))
}

// build_index_set takes the store's built arrays into a fresh set —
// the candidate — and returns it unpublished, holding the one
// reference the store will own once it is installed. A candidate that
// is not installed is released with release_set, which frees what it
// took.
@(private)
build_index_set :: proc(s: ^Store) -> ^Index_Set {
	set := new(Index_Set, s.allocator)
	for o in Order {
		assert(len(s.ord[o]) == int(s.n_facts), "store_publish: permutations not built over the current facts")
		set.ord[o] = s.ord[o]
		s.ord[o] = nil
	}
	assert(len(s.terms) == len(s.dict.off), "store_publish: the term index not built over the current dictionary")
	set.terms = s.terms
	s.terms = nil
	set.derived = slice.clone(s.derived[:], s.allocator)
	set.facts = slice.clone(s.facts[:], s.allocator)
	set.dict = slice.clone(s.dict.chunks[:], s.allocator)
	set.used = slice.clone(s.dict.used[:], s.allocator)
	set.off = slice.clone(s.dict.off[:], s.allocator)
	set.epochs = slice.clone(s.epochs[:], s.allocator)
	set.epoch = Epoch(s.n_epochs)
	set.n_facts = s.n_facts
	set.n_terms = u32(len(s.dict.off))
	set.refs = 1 // the store's own reference
	return set
}

// install_index_set publishes a built set: the swap and the epoch
// store under the mutex, then the store's reference to the superseded
// set released outside it (package comment).
@(private)
install_index_set :: proc(s: ^Store, set: ^Index_Set) {
	sync.mutex_lock(&s.mu)
	old := s.idx
	sync.atomic_store_explicit(&s.idx, set, .Release)
	sync.atomic_store_explicit(&s.published, set.epoch, .Release)
	sync.mutex_unlock(&s.mu)
	if old != nil {
		release_set(s, old)
	}
}

// store_latest pins the published epoch and the current index set —
// api.md par. 12.1's Latest. The caller owns the snapshot and must
// release it.
store_latest :: proc(s: ^Store) -> (snap: Snapshot, err: Snapshot_Error) {
	return acquire(s, 0, true)
}

// store_at pins a historical epoch: any 0 <= e <= published, epoch 0
// being the empty world before the first commit. The past stays
// readable at zero retention cost because nothing is ever removed —
// the facts of epoch e sit in every later set with their intervals
// intact — and the future is refused, not clamped.
store_at :: proc(s: ^Store, epoch: Epoch) -> (snap: Snapshot, err: Snapshot_Error) {
	return acquire(s, epoch, false)
}

// acquire is the one acquisition path, under the mutex (package
// comment): the set and the published epoch are read together and the
// count is raised before the lock is dropped, so no publish can free
// the set in between.
@(private = "file")
acquire :: proc(s: ^Store, epoch: Epoch, latest: bool) -> (snap: Snapshot, err: Snapshot_Error) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	set := s.idx
	if set == nil {
		return {}, .Unpublished
	}
	e := s.published if latest else epoch
	if e > s.published {
		return {}, .Future_Epoch
	}
	sync.atomic_add_explicit(&set.refs, 1, .Relaxed)
	return {epoch = e, idx = set, store = s}, .None
}

// snapshot_release returns the snapshot's reference and inerts the
// handle. Exactly once per acquired snapshot: the zeroed handle makes
// a second release or a later use fail its assertion loudly rather
// than corrupt a count. Freeing happens here when the last reference
// was this one and the store has already moved on. No lock: see the
// package comment.
snapshot_release :: proc(snap: ^Snapshot) {
	assert(snap.idx != nil, "snapshot_release: a released or never-acquired snapshot")
	release_set(snap.store, snap.idx)
	snap^ = {}
}

// snapshot_fact returns fact `id` through the set's chunk list — the
// reader's accessor, valid for any id below the set's n_facts. The
// pointer stays valid for the life of the store.
snapshot_fact :: proc(snap: Snapshot, id: Fact_ID) -> ^Fact {
	assert(snap.idx != nil, "snapshot_fact: a released snapshot")
	assert(u32(id) < snap.idx.n_facts, "snapshot_fact: a fact id past the set")
	return fact_in(snap.idx.facts, id)
}

// snapshot_visible is the one visibility test in the system
// (api.md par. 2): a fact is visible at the pinned epoch iff
// assert <= epoch < retract. Facts at or past the set's n_facts are
// not visible by construction — they were applied after this set
// published, and their assert epochs are ones this snapshot rejects
// anyway; the bound is what lets enumeration stop at the set.
snapshot_visible :: proc(snap: Snapshot, id: Fact_ID) -> bool {
	assert(snap.idx != nil, "snapshot_visible: a released snapshot")
	if u32(id) >= snap.idx.n_facts {
		return false
	}
	f := fact_in(snap.idx.facts, id)
	retract := sync.atomic_load_explicit(&f.retract, .Relaxed)
	return f.assert <= snap.epoch && snap.epoch < retract
}

// snapshot_derived reports a visible-or-not fact's origin from the
// set's own bitset copy, so the answer is of the publication, not of
// whatever the writer has appended since.
snapshot_derived :: proc(snap: Snapshot, id: Fact_ID) -> bool {
	assert(snap.idx != nil, "snapshot_derived: a released snapshot")
	assert(u32(id) < snap.idx.n_facts, "snapshot_derived: a fact id past the set")
	return snap.idx.derived[id >> 6] & (u64(1) << (id & 63)) != 0
}

// snapshot_epoch_meta returns the wall/actor/reason of one committed
// epoch (api.md par. 2.4) through the set's epoch chunk list — the
// reader's form of store_epoch_meta, for any epoch the set has
// published.
snapshot_epoch_meta :: proc(snap: Snapshot, epoch: Epoch) -> Epoch_Meta {
	assert(snap.idx != nil, "snapshot_epoch_meta: a released snapshot")
	assert(epoch >= 1 && epoch <= snap.idx.epoch, "snapshot_epoch_meta: an epoch this set has not published")
	i := epoch - 1
	return snap.idx.epochs[i >> EPOCH_CHUNK_BITS][i & EPOCH_CHUNK_MASK]
}

// snapshot_terms is the dictionary high-water mark as of this set's
// publication (api.md par. 13.8): the one guard for sizing anything
// indexed by term id, and the bound Resolve honors.
snapshot_terms :: proc(snap: Snapshot) -> u32 {
	assert(snap.idx != nil, "snapshot_terms: a released snapshot")
	return snap.idx.n_terms
}

// set_bytes is dict_bytes over a set's copies — the reader's arena
// view, bounded by the set's n_terms.
@(private)
set_bytes :: proc(set: ^Index_Set, id: Term_ID) -> []byte {
	return dict_bytes_in(set.dict, set.used, set.off, set.n_terms, id)
}

// release_set decrements and frees on zero — shared by snapshot
// release, the store's publish-supersede path, and store_destroy.
@(private)
release_set :: proc(s: ^Store, set: ^Index_Set) {
	old := sync.atomic_sub_explicit(&set.refs, 1, .Acq_Rel)
	assert(old >= 1, "release_set: a reference count underflow")
	if old == 1 {
		for o in Order {
			delete(set.ord[o], s.allocator)
		}
		delete(set.terms, s.allocator)
		delete(set.derived, s.allocator)
		delete(set.facts, s.allocator)
		delete(set.dict, s.allocator)
		delete(set.used, s.allocator)
		delete(set.off, s.allocator)
		delete(set.epochs, s.allocator)
		free(set, s.allocator)
	}
}
