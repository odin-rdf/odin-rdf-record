// Snapshots and publication (RECORD-T-0009): the epoch discipline of
// log.md par. 7.1 steps 4-5 and the refcounted read handle of
// RECORD-A-0005 — how a reader gets a consistent, immutable view of a
// store that a writer keeps advancing, without locks on the read path.
//
// # The single-writer / N-reader model, precisely
//
// There is exactly one writer (log.md par. 10), and it publishes in
// two atomic steps, in this order:
//
//	1. store the new ^Index_Set into Store.idx     (.Release)
//	2. store the new epoch into Store.published    (.Release)
//
// A reader mirrors it in reverse (api.md par. 12.1): load `published`
// first (.Acquire), then `idx` (.Acquire). The index set it gets is
// therefore *at least as new* as the epoch it pinned — possibly newer,
// which is harmless, because every fact a newer set carries from later
// epochs has an assert epoch the visibility test is already rejecting.
// Loading in the other order could pair a pre-E set with epoch E: facts
// visible but absent from the index, a silently short answer. That is
// the whole reason the order is a contract and not a choice.
//
// The same argument makes partial state unobservable during apply: the
// writer applies a commit's facts *before* publishing its epoch, so an
// applied-but-unpublished fact carries an epoch no reader has been
// handed yet. Fact.retract is the one field mutated in place
// (api.md par. 2.3); it is stored and loaded atomically, and a reader
// that misses a just-written retraction computes the same answer,
// because a retraction recorded after the reader pinned epoch e always
// carries retract > e.
//
// # Reclamation (RECORD-A-0005)
//
// An Index_Set owns what publication replaces — the six permutation
// arrays (moved out of Store.ord by store_publish, which is why a
// rebuild after publish cannot dangle a published set) and its copy of
// the origin bitset — and is freed when its reference count drops to
// zero: the store holds one reference from publish until it publishes
// a successor or closes, and every live Snapshot holds one. In this
// initiative the publisher is replay at boot, before concurrent
// readers exist. One window is therefore documented rather than
// closed: a reader between its idx load and its refcount increment
// races a concurrent publish that frees the old set. store_latest
// already re-checks idx after incrementing (bounding the stale-set
// case); making the increment itself safe needs the writer to defer
// frees — retire a superseded set and free it only on a later publish
// once its count has drained. That retire list is Apply's to add
// (next initiative), and this comment is the recorded reason.
package record

import "core:sync"

// Snapshot_Error is how acquisition refuses.
Snapshot_Error :: enum {
	None,
	Unpublished,  // the store has never published — nothing to read
	Future_Epoch, // At(e) past the published epoch: the future is not readable
}

// Index_Set is the writer's unit of publication (api.md par. 12.1):
// one atomic pointer swap covers the six permutations, the origin
// bitset, and the high-water marks, so a reader cannot observe a
// mixed-version set. The chunked structures a set does NOT own — fact
// chunks, dictionary chunks, the epoch table — are owned by the store,
// never move, and outlive every set (RECORD-A-0005 part 1); a set
// bounds what it reads of them with n_facts and n_terms.
Index_Set :: struct {
	ord:     [Order][]u32, // the six sorted FactID permutations; owned by this set
	derived: []u64, // the origin bitset at publication; owned by this set
	epoch:   u32, // the epoch this set published
	n_facts: u32, // facts this set covers; ids at or past this are not in ord
	n_terms: u32, // dictionary high-water mark at publication (api.md par. 13.8)
	refs:    int, // atomic reference count: the store's publish reference plus one per live Snapshot
}

// Snapshot is a logical instant: a pinned epoch plus the index set
// published at or after it. It is a resource, not a plain value
// (RECORD-A-0005 part 2): acquire with store_latest or store_at, use,
// and release exactly once with snapshot_release — a live snapshot
// pins its whole index set, so the expected discipline is
// request-scoped, nothing held across think-time (api.md par. 13.2).
Snapshot :: struct {
	epoch: u32,
	idx:   ^Index_Set,
	store: ^Store,
}

// store_publish publishes the store's current state: the built
// permutations and bitset become a fresh Index_Set, installed and
// announced in par. 7.1's order (set first, epoch second), and the
// store releases its reference to the set it supersedes. The caller
// must have run store_build_permutations since the last append —
// publication is the apply/publish boundary, and a set covering facts
// its permutations do not sort would answer wrongly, so that is
// asserted. In this initiative the one caller is boot (replay, then
// build, then publish); Apply inherits the same call per commit.
store_publish :: proc(s: ^Store) {
	set := new(Index_Set, s.allocator)
	for o in Order {
		assert(len(s.ord[o]) == int(s.n_facts), "store_publish: permutations not built over the current facts")
		set.ord[o] = s.ord[o]
		s.ord[o] = nil
	}
	set.derived = make([]u64, len(s.derived), s.allocator)
	copy(set.derived, s.derived[:])
	set.epoch = s.n_epochs
	set.n_facts = s.n_facts
	set.n_terms = u32(len(s.dict.off))
	set.refs = 1 // the store's own reference

	old := sync.atomic_load_explicit(&s.idx, .Relaxed)
	sync.atomic_store_explicit(&s.idx, set, .Release)
	sync.atomic_store_explicit(&s.published, set.epoch, .Release)
	if old != nil {
		release_set(s, old)
	}
}

// store_latest pins the published epoch and the current index set —
// api.md par. 12.1's Latest, with the acquire discipline the package
// comment specifies. The caller owns the snapshot and must release it.
store_latest :: proc(s: ^Store) -> (snap: Snapshot, err: Snapshot_Error) {
	return store_at(s, sync.atomic_load_explicit(&s.published, .Acquire))
}

// store_at pins a historical epoch: any 0 <= e <= published, epoch 0
// being the empty world before the first commit. The past stays
// readable at zero retention cost because nothing is ever removed —
// the facts of epoch e sit in every later set with their intervals
// intact — and the future is refused, not clamped.
store_at :: proc(s: ^Store, epoch: u32) -> (snap: Snapshot, err: Snapshot_Error) {
	for {
		published := sync.atomic_load_explicit(&s.published, .Acquire)
		set := sync.atomic_load_explicit(&s.idx, .Acquire)
		if set == nil {
			return {}, .Unpublished
		}
		if epoch > published {
			return {}, .Future_Epoch
		}
		sync.atomic_add_explicit(&set.refs, 1, .Relaxed)
		if sync.atomic_load_explicit(&s.idx, .Acquire) == set {
			return {epoch = epoch, idx = set, store = s}, .None
		}
		// A publish landed between the load and the increment: this
		// count went to a superseded set. Undo and retry — see the
		// package comment for the window this bounds and the retire
		// list that closes it when concurrent publishes arrive.
		release_set(s, set)
	}
}

// snapshot_release returns the snapshot's reference and inerts the
// handle. Exactly once per acquired snapshot: the zeroed handle makes
// a second release or a later use fail its assertion loudly rather
// than corrupt a count. Freeing happens here when the last reference
// was this one and the store has already moved on.
snapshot_release :: proc(snap: ^Snapshot) {
	assert(snap.idx != nil, "snapshot_release: a released or never-acquired snapshot")
	release_set(snap.store, snap.idx)
	snap^ = {}
}

// snapshot_visible is the one visibility test in the system
// (api.md par. 2): a fact is visible at the pinned epoch iff
// assert <= epoch < retract. Facts at or past the set's n_facts are
// not visible by construction — they were applied after this set
// published, and their assert epochs are ones this snapshot rejects
// anyway; the bound is what lets enumeration stop at the set.
snapshot_visible :: proc(snap: Snapshot, id: u32) -> bool {
	assert(snap.idx != nil, "snapshot_visible: a released snapshot")
	if id >= snap.idx.n_facts {
		return false
	}
	f := store_fact(snap.store, id)
	retract := sync.atomic_load_explicit(&f.retract, .Relaxed)
	return f.assert <= snap.epoch && snap.epoch < retract
}

// snapshot_derived reports a visible-or-not fact's origin from the
// set's own bitset copy, so the answer is of the publication, not of
// whatever the writer has appended since.
snapshot_derived :: proc(snap: Snapshot, id: u32) -> bool {
	assert(snap.idx != nil, "snapshot_derived: a released snapshot")
	assert(id < snap.idx.n_facts, "snapshot_derived: a fact id past the set")
	return snap.idx.derived[id >> 6] & (u64(1) << (id & 63)) != 0
}

// snapshot_terms is the dictionary high-water mark as of this set's
// publication (api.md par. 13.8): the one guard for sizing anything
// indexed by term id, and the bound Resolve honors.
snapshot_terms :: proc(snap: Snapshot) -> u32 {
	assert(snap.idx != nil, "snapshot_terms: a released snapshot")
	return snap.idx.n_terms
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
		delete(set.derived, s.allocator)
		free(set, s.allocator)
	}
}
