// The load path (RECORD-T-0007): the Consumer that binds replay to the
// resident structures — log.md par. 8 with the store finally on the
// other end of the seam. Replay is the only load path and the only
// recovery path; this file is what makes a Store from it, and nothing
// else writes one.
//
// # What the Loader judges that replay does not
//
// Replay enforces what any conforming log must satisfy (replay.odin);
// the live-quad preconditions of log.md par. 5.3 need resident state
// to judge, so they are enforced here, where that state finally
// exists: a retract must name a currently-live quad, and an assert
// must not — a graph is a set, and at most one generation of a quad is
// live at any epoch. Both are replay errors in log.md par. 8's terms,
// but they are *this store's* semantics rather than the format's — a
// foreign consumer may legitimately tolerate what this one refuses —
// so they are typed here as Load_Error rather than widening
// Open_Error, and surface through the seam's abort lever as
// .Consumer_Abort with the diagnosis on the Loader. The dump tool's
// fail field set the idiom (RECORD-T-0005); this follows it.
package record

// Load_Error is every way the resident build refuses a log that
// verifies — and, for the first two, replays — clean. Chain-perfect
// nonsense is still nonsense: the judged/altered split of the replay
// tests, extended one layer up.
Load_Error :: enum {
	None,
	Retract_Not_Live, // a retract of a quad with no live generation (log.md par. 5.3)
	Duplicate_Assert, // an assert of a quad already live (log.md par. 5.3)
	Duplicate_Term,   // a term definition whose encoding is already interned (architecture.md par. 3.2 injectivity)
	Epoch_Overflow,   // an epoch at or past LIVE_EPOCH — beyond the resident u32 scheme (api.md par. 2.1)
	Dict_Overflow,    // the arena past its u32 addressing (resident.odin)
}

// Loader is the resident store's Consumer: one replay through it
// turns an empty Store into the log's projection. On a refusal the
// delivery returns false — replay reports .Consumer_Abort — and the
// diagnosis is here: err, the epoch it happened in, and the offending
// op or term id where one exists. The store then holds everything
// before the refusal and nothing at or after it, exactly as the seam
// delivers.
//
// `live` maps each live quad to its fact id — log.md par. 8's replay
// scaffolding, which api.md par. 6 rules out of the steady state. It
// lives on the Loader rather than the Store so that dropping it is
// the default: loader_destroy takes it and leaves the Store standing;
// Apply checks liveness against the published SPO permutation instead
// (RECORD-I-0003). `seen` is the same kind of scaffolding for terms:
// par. 5.2's self-check that no two definitions carry one encoding,
// keyed by views into the arena (chunks never move), dropped with the
// Loader — the store keeps no map from encoding to id (decision 2).
Loader :: struct {
	store: ^Store,
	live:  map[Quad]u32,
	seen:  map[string]u32,
	err:   Load_Error,
	epoch: u64,     // the epoch being applied when err was set
	op:    Fact_Op, // the offending op, zero-valued for non-op refusals
	term:  u64,     // the offending term definition's id, 0 for non-term refusals
}

// loader_init binds a Loader to the store it fills. The store is the
// caller's, initialized and destroyed by the caller; the map is the
// Loader's own and uses the store's allocator.
loader_init :: proc(ld: ^Loader, s: ^Store) {
	ld.store = s
	ld.live = make(map[Quad]u32, s.allocator)
	ld.seen = make(map[string]u32, s.allocator)
}

// loader_destroy drops the transient scaffolding. The store it built
// is untouched.
loader_destroy :: proc(ld: ^Loader) {
	delete(ld.live)
	delete(ld.seen)
	ld^ = {}
}

// loader_consumer is the seam binding: pass it to replay with the
// Loader's store empty, then read ld.err before trusting the store —
// a .Consumer_Abort from replay is this Loader refusing.
loader_consumer :: proc(ld: ^Loader) -> Consumer {
	return {data = ld, commit = load_commit, term = load_term, op = load_op, note = load_note}
}

@(private = "file")
load_fail :: proc(ld: ^Loader, err: Load_Error) -> bool {
	ld.err = err
	return false
}

@(private)
load_commit :: proc(data: rawptr, epoch, wall, actor, reason: u64) -> bool {
	ld := (^Loader)(data)
	ld.epoch = epoch
	if epoch >= u64(LIVE_EPOCH) {
		return load_fail(ld, .Epoch_Overflow)
	}
	// Contiguity from 1 is the walk's guarantee (open.odin), which is
	// what makes the dense epoch table's index the epoch number.
	assert(epoch == u64(ld.store.n_epochs)+1, "load_commit: replay delivered a non-contiguous epoch")
	// Actor and reason are dictionary ids or 0 — replay has bounded
	// both, so the re-tag is a pass-through.
	epoch_append(ld.store, Epoch_Meta{wall = wall, actor = resident_id(actor), reason = resident_id(reason)})
	return true
}

@(private)
load_term :: proc(data: rawptr, id: u64, enc: []byte) -> bool {
	ld := (^Loader)(data)
	// Two ids with one meaning would break architecture.md par. 3.2's
	// injectivity; a chain-perfect log that does it is refused here.
	if string(enc) in ld.seen {
		ld.term = id
		return load_fail(ld, .Duplicate_Term)
	}
	// dict_add clones into the arena within the call, honoring the
	// seam's borrow; the id it assigns is the log's, because replay's
	// par. 5.2 self-check already matched this delivery against
	// first-appearance order.
	got, err := dict_add(&ld.store.dict, enc, ld.store.allocator)
	if err != .None {
		ld.term = id
		return load_fail(ld, err)
	}
	assert(u64(got) == id, "load_term: the arena and the log disagree about an id")
	ld.seen[string(dict_bytes(&ld.store.dict, got))] = got
	return true
}

@(private)
load_op :: proc(data: rawptr, epoch: u64, op: Fact_Op) -> bool {
	ld := (^Loader)(data)
	q := Quad{resident_id(op.s), resident_id(op.p), resident_id(op.o), resident_id(op.g)}
	switch op.op {
	case .Assert, .Assert_Derived:
		if q in ld.live {
			ld.op = op
			return load_fail(ld, .Duplicate_Assert)
		}
		id := fact_append(
			ld.store,
			Fact{s = q.s, p = q.p, o = q.o, g = q.g, assert = u32(epoch), retract = LIVE_EPOCH},
			op.op == .Assert_Derived,
		)
		ld.live[q] = id
	case .Retract, .Retract_Derived:
		// Resolution to the currently-live generation (log.md par. 5.3):
		// unambiguous because a graph is a set. Assert -> retract ->
		// re-assert yields two facts with disjoint intervals.
		id, is_live := ld.live[q]
		if !is_live {
			ld.op = op
			return load_fail(ld, .Retract_Not_Live)
		}
		store_fact(ld.store, id).retract = u32(epoch)
		delete_key(&ld.live, q)
	}
	return true
}

@(private)
load_note :: proc(data: rawptr, last_epoch: u64, payload: []byte) -> bool {
	ld := (^Loader)(data)
	s := ld.store
	// last_epoch equals the epoch the note follows (replay's check),
	// which load_commit has already bounded below LIVE_EPOCH.
	cloned := make([]byte, len(payload), s.allocator)
	copy(cloned, payload)
	append(&s.notes, Env_Note{last_epoch = u32(last_epoch), payload = cloned})
	return true
}
