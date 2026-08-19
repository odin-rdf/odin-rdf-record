package record

import "core:testing"

// The snapshot layer's tests (RECORD-T-0009): the refcount lifecycle
// is exercised for real — counts observed at every step, a superseded
// set freed when its last reader lets go, the store-close assertion
// reachable only with every snapshot released — and visibility is
// proven exact across assert -> retract -> re-assert -> retract
// chains, with the publication discipline's promise checked directly:
// applied-but-unpublished state is unobservable, and a historical
// epoch answers identically before and after later epochs exist.

@(private = "file")
snap_fact :: proc(s: ^Store, sub, obj, from, until: u32, derived := false) -> u32 {
	return fact_append(s, Fact{s = sub, p = 2, o = obj, g = 0, assert = from, retract = until}, derived)
}

@(test)
test_snapshot_lifecycle :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)

	// Nothing published: acquisition refuses, latest included.
	_, uerr := store_latest(&s)
	testing.expect_value(t, uerr, Snapshot_Error.Unpublished)

	_ = snap_fact(&s, 1, 3, 1, LIVE_EPOCH)
	_ = snap_fact(&s, 1, 4, 2, LIVE_EPOCH)
	epoch_append(&s, Epoch_Meta{wall = 1})
	epoch_append(&s, Epoch_Meta{wall = 2})
	store_build_permutations(&s)
	store_publish(&s)

	// Publication moved the permutations into the set.
	testing.expect_value(t, s.published, u32(2))
	testing.expect_value(t, len(s.ord[.SPOG]), 0)
	testing.expect_value(t, len(s.idx.ord[.SPOG]), 2)
	testing.expect_value(t, s.idx.refs, 1)

	// Acquire pins; every acquire is one reference.
	latest, lerr := store_latest(&s)
	testing.expect_value(t, lerr, Snapshot_Error.None)
	testing.expect_value(t, latest.epoch, u32(2))
	testing.expect_value(t, snapshot_terms(latest), u32(0))
	old, aerr := store_at(&s, 1)
	testing.expect_value(t, aerr, Snapshot_Error.None)
	testing.expect_value(t, s.idx.refs, 3)

	// The future is refused, and refusal takes no reference.
	_, ferr := store_at(&s, 3)
	testing.expect_value(t, ferr, Snapshot_Error.Future_Epoch)
	testing.expect_value(t, s.idx.refs, 3)

	// Epoch 0 is the empty world.
	empty, eerr := store_at(&s, 0)
	testing.expect_value(t, eerr, Snapshot_Error.None)
	testing.expect(t, !snapshot_visible(empty, 0), "nothing precedes epoch 1")
	testing.expect(t, !snapshot_visible(empty, 1), "nothing precedes epoch 1")

	// The pinned epoch filters; the set is shared.
	testing.expect(t, snapshot_visible(old, 0), "fact 0 lives at epoch 1")
	testing.expect(t, !snapshot_visible(old, 1), "fact 1 arrives at epoch 2")
	testing.expect(t, snapshot_visible(latest, 1), "fact 1 lives at epoch 2")

	// Release exactly once each; the handle goes inert.
	snapshot_release(&empty)
	snapshot_release(&old)
	testing.expect_value(t, s.idx.refs, 2)
	snapshot_release(&latest)
	testing.expect_value(t, s.idx.refs, 1)
	testing.expect(t, latest.idx == nil && latest.store == nil, "a released handle is inert")
	// store_destroy (deferred) is the close assertion: it would fail
	// loudly if any of the releases above were missing.
}

@(test)
test_snapshot_visibility_exact :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)

	// One quad through assert(1) -> retract(2) -> re-assert(3) ->
	// retract(4): two generations with disjoint intervals [1,2) and
	// [3,4). A second quad live since 2. The re-asserted generation is
	// marked derived to pin the set's origin bitset.
	f0 := snap_fact(&s, 1, 3, 1, 2)
	f1 := snap_fact(&s, 1, 3, 3, 4, derived = true)
	f2 := snap_fact(&s, 1, 4, 2, LIVE_EPOCH)
	for e in u64(1) ..= 4 {
		epoch_append(&s, Epoch_Meta{wall = e})
	}
	store_build_permutations(&s)
	store_publish(&s)

	want := [5][3]bool{
		{false, false, false}, // epoch 0: the empty world
		{true, false, false},  // epoch 1: first generation live
		{false, false, true},  // epoch 2: retracted; f2 arrives
		{false, true, true},   // epoch 3: second generation live
		{false, false, true},  // epoch 4: retracted again
	}
	for row, e in want {
		snap, err := store_at(&s, u32(e))
		testing.expect_value(t, err, Snapshot_Error.None)
		testing.expect_value(t, snapshot_visible(snap, f0), row[0])
		testing.expect_value(t, snapshot_visible(snap, f1), row[1])
		testing.expect_value(t, snapshot_visible(snap, f2), row[2])
		snapshot_release(&snap)
	}

	// Latest is At(published), and origin reads from the set's copy.
	latest, _ := store_latest(&s)
	testing.expect_value(t, latest.epoch, u32(4))
	testing.expect_value(t, snapshot_derived(latest, f0), false)
	testing.expect_value(t, snapshot_derived(latest, f1), true)
	testing.expect_value(t, snapshot_derived(latest, f2), false)
	snapshot_release(&latest)
}

@(test)
test_snapshot_publication_discipline :: proc(t: ^testing.T) {
	s: Store
	store_init(&s)
	defer store_destroy(&s)

	// Three epochs published as set 1: f0 [1, live), f1 [2, 3).
	f0 := snap_fact(&s, 1, 3, 1, LIVE_EPOCH)
	f1 := snap_fact(&s, 1, 4, 2, 3)
	for e in u64(1) ..= 3 {
		epoch_append(&s, Epoch_Meta{wall = e})
	}
	store_build_permutations(&s)
	store_publish(&s)
	set1 := s.idx

	hist, herr := store_at(&s, 2)
	testing.expect_value(t, herr, Snapshot_Error.None)
	testing.expect(t, snapshot_visible(hist, f0), "f0 lives at 2")
	testing.expect(t, snapshot_visible(hist, f1), "f1 lives at 2")

	// Epoch 4 applied but not published: a new fact, and a retraction
	// written in place on f0 — the writer's real apply shape. Neither
	// is observable: the new fact sits past the set's bound carrying an
	// epoch no reader holds, and the retraction is at an epoch every
	// pinned reader rejects (retract > e, the par. 2.3 argument).
	f2 := snap_fact(&s, 1, 5, 4, LIVE_EPOCH)
	store_fact(&s, f0).retract = 4
	epoch_append(&s, Epoch_Meta{wall = 4})

	pinned, _ := store_latest(&s)
	testing.expect_value(t, pinned.epoch, u32(3))
	testing.expect(t, !snapshot_visible(pinned, f2), "an unpublished fact is unobservable")
	testing.expect(t, snapshot_visible(pinned, f0), "an unpublished retraction is unobservable")
	testing.expect(t, !snapshot_visible(pinned, f1), "f1's interval ended at 3")
	testing.expect(t, snapshot_visible(hist, f0) && snapshot_visible(hist, f1), "history is undisturbed")

	// Publish epoch 4 as set 2. The store hands its reference on set 1
	// to the readers still holding it; new acquisitions get set 2, and
	// At(2) answers identically from either set.
	store_build_permutations(&s)
	store_publish(&s)
	testing.expect(t, s.idx != set1, "a fresh set was installed")
	testing.expect_value(t, s.published, u32(4))
	testing.expect_value(t, set1.refs, 2) // hist and pinned; the store moved on

	hist2, _ := store_at(&s, 2)
	testing.expect_value(t, snapshot_visible(hist2, f0), true)
	testing.expect_value(t, snapshot_visible(hist2, f1), true)
	testing.expect_value(t, snapshot_visible(hist2, f2), false)

	latest, _ := store_latest(&s)
	testing.expect_value(t, latest.epoch, u32(4))
	testing.expect(t, !snapshot_visible(latest, f0), "the retraction published")
	testing.expect(t, snapshot_visible(latest, f2), "the new fact published")

	// The old readers drain; set 1 frees on the last release (the
	// memory tracker fails this test if it does not, or if it frees
	// twice).
	snapshot_release(&hist)
	testing.expect_value(t, set1.refs, 1)
	snapshot_release(&pinned)

	snapshot_release(&hist2)
	snapshot_release(&latest)
}
