// Apply (RECORD-T-0015): the one write path — log.md par. 7.1's five
// steps as one call, api.md par. 12's write surface, the vision's
// "there is one write path". A changeset of asserts and retracts in
// RDF terms goes in; the committed epoch, or one typed error naming
// the offending op, comes out. Everything before it in this package
// was built to be driven from here: the intern (intern.odin) turns
// terms into ids and the commit's definitions, the preconditions are
// snapshot_exists over the published SPO order (api.md par. 6: no
// resident live-quad map), the writer appends and fsyncs, and
// publication is the Index_Set swap the readers already live by.
//
// # The order, and why it is this order
//
// refuse the trivially wrong → intern → check preconditions → mutate
// → build the candidate set → [validate, RECORD-T-0016] → encode,
// append, fsync → publish. Everything up to "mutate" fails with
// nothing to undo. Everything after it fails through one rollback.
//
// Resident mutation happens BEFORE the fsync (RECORD-I-0003
// decision 1, amending log.md par. 7.1 and RECORD-A-0006): the
// candidate — this epoch's facts appended, the retracted facts'
// intervals closed, the new terms in the arena, fresh permutations and
// term index — is built in writer-private state that no published
// reader can observe, because every reader is bounded by its set's
// n_facts, n_terms and epoch, and this epoch is past all three. That
// candidate, as a Snapshot pinned at E+1, is the overlay view the
// validation hook receives — the real read API over the real
// post-state, no second representation of anything. If the writer then
// fails, the rollback restores the projection exactly: the counters
// back, every closed interval reopened, the arena truncated, the
// candidate freed. Nothing is published before the fsync, and nothing
// a reader can observe changes before it — which is what par. 7.1's
// two boundaries were for.
//
// # What a changeset may not do
//
// An assert of a quad that is live, or a retract of one that is not,
// is a caller error (log.md par. 5.3, par. 8) — judged against the
// published head AND the changeset's own earlier ops, so assert-then-
// retract of one quad in one epoch is legal and yields a fact whose
// interval [E, E) is visible at no epoch, and assert-then-assert is
// refused at the second. A graph label is never a literal — rdf.Quad
// makes that unrepresentable, so there is no error for it. A triple
// term or a literal with a base direction has no encoding in the
// frozen format and is refused, never guessed at. An empty changeset
// is refused (decision 6). apply is not safe against itself: one
// writer, one store, one call at a time (log.md par. 10).
package record

import "core:sync"
import "core:time"

import "rdf:rdf"

// Op is one operation of a changeset: assert or retract of one quad.
// The quad is the parser's own type — what TriG and N-Quads parsers
// produce and what a consumer holding triples builds with a struct
// literal — embedded so op.subject, op.graph and op.triple read
// directly. A nil graph is the default graph. Only .Assert and
// .Retract are accepted: the derived kinds exist in the format
// (RECORD-A-0002) and no path produces them.
Op :: struct {
	kind:       Op_Kind,
	using quad: rdf.Quad,
}

// Mode is the validation posture of one changeset (RECORD-A-0006):
// Enforce refuses a changeset the validator rejects and writes
// nothing; Record commits it and reports the verdict. With no
// validator wired (RECORD-T-0016) every changeset conforms.
Mode :: enum u8 {
	Enforce,
	Record,
}

// Changeset is one epoch's worth of change: the ops in order, who and
// why as terms (nil for none — recorded as id 0, exactly as the log
// does), and the mode. One word, as the founding documents spell it.
Changeset :: struct {
	ops:    []Op,
	actor:  rdf.Term,
	reason: rdf.Term,
	mode:   Mode,
}

// Apply_Error_Kind is every way apply refuses. The first five are the
// caller's and cost nothing to undo; .Rejected is the validator's;
// the last three are the store's — after .Writer or .Dict_Overflow
// the store is fail-stop (the writer already is), and the caller's
// recovery is the open path.
Apply_Error_Kind :: enum u8 {
	None,
	Empty,            // no ops (decision 6)
	Not_Live,         // a retract of a quad with no live generation
	Already_Live,     // an assert of a quad that is live
	Unsupported_Term, // a term the frozen format cannot encode; also an inlined actor or reason, which the log cannot carry
	Rejected,         // Enforce: the validator said no (RECORD-T-0016)
	Writer,           // the writer failed; detail in Store.write_err
	Dict_Overflow,    // the arena past its u32 addressing — the format's own ceiling
	Epoch_Exhausted,  // the epoch counter is at its resident ceiling; LIVE_EPOCH is never issued
}

// Apply_Error names the kind and the offending op's index, -1 where
// no single op is at fault (an empty changeset, the actor or reason,
// the writer).
Apply_Error :: struct {
	kind: Apply_Error_Kind,
	op:   int,
}

// Resident_Op is an op with its terms interned — what the validator
// (RECORD-T-0016) sees beside the candidate snapshot.
Resident_Op :: struct {
	kind:       Op_Kind,
	s, p, o, g: u32,
}

// apply commits one changeset as the next epoch: the epoch number on
// success, `conforms` (always true until a validator is wired), and
// a zero Apply_Error. On any error the store is exactly as it was,
// and the epoch was not issued. Scratch — the intern's table, the
// plan, the effects map — comes from `allocator` and is freed before
// returning; everything the store keeps comes from the store's own.
// The wall time is this clock, Unix nanoseconds UTC: evidence, not
// proof (api.md par. 2.4).
apply :: proc(s: ^Store, c: Changeset, allocator := context.allocator) -> (epoch: u32, conforms: bool, err: Apply_Error) {
	conforms = true
	if len(c.ops) == 0 {
		return 0, conforms, {.Empty, -1}
	}
	if s.writer.failed {
		return 0, conforms, {.Writer, -1}
	}
	head, herr := store_latest(s)
	assert(herr == .None, "apply: a store that never published — store_open publishes before it returns")
	defer snapshot_release(&head)
	assert(head.idx.epoch == s.n_epochs, "apply: the published epoch is not the store's last")
	if head.idx.epoch >= LIVE_EPOCH-1 {
		return 0, conforms, {.Epoch_Exhausted, -1}
	}
	E := head.idx.epoch + 1

	// Intern. A refusal here has nothing to undo: the intern touches
	// no store state (intern.odin).
	it: Intern
	intern_init(&it, head, allocator)
	defer intern_destroy(&it)
	plan := make([]Plan_Op, len(c.ops), allocator)
	defer delete(plan, allocator)
	for op, i in c.ops {
		assert(op.kind == .Assert || op.kind == .Retract, "apply: derived op kinds are not produced by any path (RECORD-A-0002)")
		q: Quad
		terr: Term_Error
		if q.s, terr = intern_term(&it, op.subject); terr != .None {
			return 0, conforms, {.Unsupported_Term, i}
		}
		if q.p, terr = intern_term(&it, op.predicate); terr != .None {
			return 0, conforms, {.Unsupported_Term, i}
		}
		if q.o, terr = intern_term(&it, op.object); terr != .None {
			return 0, conforms, {.Unsupported_Term, i}
		}
		if q.g, terr = intern_graph(&it, op.graph); terr != .None {
			return 0, conforms, {.Unsupported_Term, i}
		}
		plan[i] = Plan_Op{kind = op.kind, q = q}
	}
	actor, reason: u32
	if c.actor != nil {
		a, terr := intern_term(&it, c.actor)
		if terr != .None || a&RES_INLINE_FLAG != 0 {
			return 0, conforms, {.Unsupported_Term, -1}
		}
		actor = a
	}
	if c.reason != nil {
		r, terr := intern_term(&it, c.reason)
		if terr != .None || r&RES_INLINE_FLAG != 0 {
			return 0, conforms, {.Unsupported_Term, -1}
		}
		reason = r
	}

	// Preconditions, in op order, against head and the changeset's
	// own earlier effects. Nothing is mutated yet; the plan records,
	// for each retract, which fact it ends.
	effects := make(map[Quad]Effect, allocator)
	defer delete(effects)
	n_asserts := 0
	for &p, i in plan {
		live, from_head, id := liveness(head, &effects, p.q)
		switch p.kind {
		case .Assert:
			if live {
				return 0, conforms, {.Already_Live, i}
			}
			effects[p.q] = Effect{live = true, pending = n_asserts}
			n_asserts += 1
		case .Retract:
			if !live {
				return 0, conforms, {.Not_Live, i}
			}
			p.target = id
			p.target_pending = !from_head
			effects[p.q] = Effect{live = false}
		case .Assert_Derived, .Retract_Derived:
			unreachable()
		}
	}

	// Mutate, in writer-private state: from here on, one rollback.
	mark := take_mark(s)
	touched := make([dynamic]u32, allocator)
	defer delete(touched)
	appended := make([]u32, n_asserts, allocator)
	defer delete(appended, allocator)

	for def in intern_defs(&it) {
		got, derr := dict_add(&s.dict, def.enc, s.allocator)
		if derr != .None {
			rollback(s, mark, touched[:])
			return 0, conforms, {.Dict_Overflow, -1}
		}
		assert(u64(got) == def.id, "apply: the arena and the intern disagree about an id")
	}
	k := 0
	for p in plan {
		switch p.kind {
		case .Assert:
			appended[k] = fact_append(s, Fact{s = p.q.s, p = p.q.p, o = p.q.o, g = p.q.g, assert = E, retract = LIVE_EPOCH}, false)
			k += 1
		case .Retract:
			id := appended[p.target] if p.target_pending else p.target
			sync.atomic_store_explicit(&store_fact(s, id).retract, E, .Relaxed)
			if !p.target_pending {
				append(&touched, id)
			}
		case .Assert_Derived, .Retract_Derived:
			unreachable()
		}
	}
	wall := u64(time.to_unix_nanoseconds(time.now()))
	epoch_append(s, Epoch_Meta{wall = wall, actor = actor, reason = reason})
	store_build_permutations(s)
	store_merge_term_index(s, head.idx.terms)
	candidate := build_index_set(s)
	assert(candidate.epoch == E, "apply: the candidate set is not at the new epoch")
	// RECORD-T-0016: the validator runs here, over Snapshot{E, candidate, s}
	// and the plan's resident ops; Enforce refuses with .Rejected through
	// the same rollback as the writer's failure below.

	// Encode, append, fsync — the durability boundary.
	fact_ops := make([]Fact_Op, len(plan), allocator)
	defer delete(fact_ops, allocator)
	for p, i in plan {
		fact_ops[i] = Fact_Op{op = p.kind, s = disk_id(p.q.s), p = disk_id(p.q.p), o = disk_id(p.q.o), g = u64(p.q.g)}
	}
	werr := writer_commit(
		&s.writer,
		{epoch = u64(E), wall = wall, actor = u64(actor), reason = u64(reason), terms = intern_defs(&it), ops = fact_ops},
	)
	if werr != .None {
		s.write_err = werr
		release_set(s, candidate)
		rollback(s, mark, touched[:])
		return 0, conforms, {.Writer, -1}
	}

	// Publish — the visibility boundary.
	install_index_set(s, candidate)
	return E, conforms, {}
}

// store_close releases both halves of an opened store: the writer
// (closing the open segment, without sealing it) and the projection.
// Every snapshot must have been released first. The writer's close
// error is returned; there is nothing to retry on it.
store_close :: proc(s: ^Store) -> Writer_Error {
	err := writer_destroy(&s.writer)
	store_destroy(s)
	return err
}

// --- internals -------------------------------------------------------

// Plan_Op is an op with its terms interned and, for a retract, the
// fact it ends: a head fact id, or (target_pending) the index among
// this changeset's own asserts of the generation it closes.
@(private = "file")
Plan_Op :: struct {
	kind:           Op_Kind,
	q:              Quad,
	target:         u32,
	target_pending: bool,
}

// Effect is what the changeset's earlier ops did to one quad: live or
// not after them, and if live by this changeset's own assert, which.
@(private = "file")
Effect :: struct {
	live:    bool,
	pending: int,
}

// liveness answers whether q is live after head plus the changeset's
// earlier ops, and which fact makes it so: `from_head` with the head
// fact id, or the pending assert index. Head is consulted through the
// published SPO order — a prefix range with the graph residual, first
// hit — which is snapshot_exists with the id kept.
@(private = "file")
liveness :: proc(head: Snapshot, effects: ^map[Quad]Effect, q: Quad) -> (live: bool, from_head: bool, id: u32) {
	if e, seen := effects[q]; seen {
		return e.live, false, u32(e.pending)
	}
	g := q.g if q.g != 0 else MATCH_DEFAULT_GRAPH
	sc := range_iter(snapshot_match(head, {s = q.s, p = q.p, o = q.o, g = g}), {origin = .Any})
	fid, hit := scan_next(&sc)
	return hit, true, fid
}

// Mark is the projection's high-water marks before an apply mutates
// it — everything rollback needs to put it back.
@(private = "file")
Mark :: struct {
	n_facts:        u32,
	n_fact_chunks:  int,
	n_derived:      int,
	n_terms:        int,
	n_dict_chunks:  int,
	used_last:      u32,
	n_epochs:       u32,
	n_epoch_chunks: int,
}

@(private = "file")
take_mark :: proc(s: ^Store) -> Mark {
	m := Mark{
		n_facts        = s.n_facts,
		n_fact_chunks  = len(s.facts),
		n_derived      = len(s.derived),
		n_terms        = len(s.dict.off),
		n_dict_chunks  = len(s.dict.chunks),
		n_epochs       = s.n_epochs,
		n_epoch_chunks = len(s.epochs),
	}
	if len(s.dict.used) > 0 {
		m.used_last = s.dict.used[len(s.dict.used)-1]
	}
	return m
}

// rollback restores the projection to its mark: every interval this
// apply closed is reopened (atomic stores, as they were closed), the
// fact and epoch tables are cut back — chunks this apply opened are
// freed, so the next append opens them again rather than doubling
// them — and the arena is truncated to the published high-water
// mark: offsets cut, the last chunk's fill restored, chunks this apply
// allocated freed. Bytes past the fill are not zeroed; nothing reads
// them. The permutations and term index were moved into the candidate
// and die with it. Readers are unaffected throughout: everything
// touched lies past their sets' bounds, and a reopened interval means
// the same thing to a reader at or below the published epoch as the
// closed one did.
@(private = "file")
rollback :: proc(s: ^Store, m: Mark, touched: []u32) {
	for id in touched {
		sync.atomic_store_explicit(&store_fact(s, id).retract, LIVE_EPOCH, .Relaxed)
	}
	for len(s.facts) > m.n_fact_chunks {
		delete(pop(&s.facts), s.allocator)
	}
	resize(&s.derived, m.n_derived)
	s.n_facts = m.n_facts
	for len(s.dict.chunks) > m.n_dict_chunks {
		delete(pop(&s.dict.chunks), s.allocator)
		pop(&s.dict.used)
	}
	if m.n_dict_chunks > 0 {
		s.dict.used[m.n_dict_chunks-1] = m.used_last
	}
	resize(&s.dict.off, m.n_terms)
	for len(s.epochs) > m.n_epoch_chunks {
		delete(pop(&s.epochs), s.allocator)
	}
	s.n_epochs = m.n_epochs
	for o in Order {
		delete(s.ord[o], s.allocator)
		s.ord[o] = nil
	}
	delete(s.terms, s.allocator)
	s.terms = nil
}

// disk_id re-tags a resident id for the log: dictionary ids pass
// through, inlined ids go back to the on-disk scheme.
@(private = "file")
disk_id :: proc(id: u32) -> u64 {
	if id & RES_INLINE_FLAG != 0 {
		return res_inline_disk(id)
	}
	return u64(id)
}
