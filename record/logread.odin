// Reading a log as RDF (RECORD-T-0035): the decoded counterpart to
// `replay`. `replay` delivers a log's records at the level the format
// speaks -- term ids, a dictionary the caller must accumulate, and
// `Fact_Op`s of four `u64`s -- because that is what the resident build
// needs, and it is deliberately below the data model. Everything that
// wants to *look at* a log instead of load it wants quads, and until
// this file existed the package offered no way to get them: the record
// CLI accumulated the dictionary itself, wrote its own `Resolve_Iri`,
// and called `term_decode` per component. That is nine format internals
// exported for one caller, and doc/api-surface.txt carried them as a
// stated exception (RECORD-I-0007).
//
// `log_read` is that loop, once, inside the package. It owns the
// dictionary, resolves every id -- inlined, dictionary, split IRI or
// triple term -- and hands the consumer `rdf.Quad`s. Nothing else
// changes: the walk is `replay`'s, so the verification, the torn-tail
// rule and the judged/altered split are exactly as they were.
//
// Lifetime: a term handed to a callback is valid FOR THAT CALL. Ids are
// decoded into a per-op temporary that is released when the callback
// returns, which is what keeps a dump of a 38 MB log flat in memory.
// A consumer that keeps a term must clone it (`rdf.term_clone`).
package record

import "base:runtime"
import "core:mem"
import "rdf:rdf"

// Log_Consumer is the decoded delivery seam, the shape `Consumer` has
// with the format taken out. `commit` opens an epoch and carries its
// attribution as terms rather than ids -- `actor` and `reason` are nil
// where the log recorded none. `op` receives one operation as a quad;
// `note` is the environment note, still bytes, because it is a payload
// this package does not interpret. A callback returning false stops the
// walk with `.Consumer_Abort`, as it does for `replay`.
//
// Every field may be nil: a caller counting epochs binds `commit` alone
// and pays nothing to decode terms it will not look at.
Log_Consumer :: struct {
	data:   rawptr,
	commit: proc(data: rawptr, epoch, wall: u64, actor, reason: rdf.Term) -> bool,
	op:     proc(data: rawptr, epoch: u64, kind: Op_Kind, q: rdf.Quad) -> bool,
	note:   proc(data: rawptr, last_epoch: u64, payload: []byte) -> bool,
}

// Log_Cursor is the walk's private state: the dictionary as the log
// defines it, and the arena the current op's terms live in.
@(private = "file")
Log_Cursor :: struct {
	c:          Log_Consumer,
	dict:       [dynamic][]byte,
	allocator:  runtime.Allocator,
	scratch:    mem.Scratch_Allocator,
	inline_buf: [3][INLINE_LEXICAL_MAX]u8,
	// The open epoch, held until its terms are in. A commit record
	// carries its term definitions AFTER the header replay reads the
	// attribution from, and an epoch's actor is typically defined BY that
	// epoch -- it is interned last, after the ops. So the ids are kept
	// here and the consumer's `commit` fires just before the epoch's
	// first op, by which time every definition has arrived. Resolving at
	// the record boundary instead reads a dictionary that does not yet
	// contain the term, which is a decode failure on a sound log.
	pending:    bool,
	epoch:      u64,
	wall:       u64,
	actor:      u64,
	reason:     u64,
}

// log_read walks a log and delivers it decoded. The return values are
// `replay`'s: the verified result, the tear if the tail was torn, and
// the open error -- including `.Consumer_Abort` when a callback
// refused. A torn tail delivers the durable prefix and says so, which
// is the property a dump of a crashed writer's log depends on.
//
// The dictionary is accumulated in `allocator` and freed before
// returning; a log's terms are bounded by the log, not by the caller.
log_read :: proc(
	dir: string,
	ops: File_Ops,
	c: Log_Consumer,
	allocator := context.allocator,
) -> (
	r: Verify_Result,
	tear: Tear,
	err: Open_Error,
) {
	cur := Log_Cursor {
		c         = c,
		allocator = allocator,
	}
	cur.dict.allocator = allocator
	mem.scratch_allocator_init(&cur.scratch, 4 * 1024, allocator)
	defer {
		for enc in cur.dict {
			delete(enc, allocator)
		}
		delete(cur.dict)
		mem.scratch_allocator_destroy(&cur.scratch)
	}

	r, tear, err = replay(dir, ops, Consumer{
		data   = &cur,
		commit = log_commit,
		term   = log_term,
		op     = log_op,
		note   = log_note,
	}, allocator)
	// An epoch with no ops -- a commit that only defines terms -- still
	// happened, and a consumer counting epochs must see it.
	if err == .None && cur.pending && !log_flush_commit(&cur) {
		err = .Consumer_Abort
	}
	return
}

// log_term keeps the definition. Replay has already enforced that ids
// arrive in first-appearance order, so position is identity and the
// copy is what makes the encoding outlive the frame it was read from.
@(private = "file")
log_term :: proc(data: rawptr, id: u64, enc: []byte) -> bool {
	cur := (^Log_Cursor)(data)
	owned := make([]byte, len(enc), cur.allocator)
	copy(owned, enc)
	append(&cur.dict, owned)
	return true
}

// log_commit opens an epoch. It resolves nothing yet -- see Log_Cursor's
// `pending` -- but it does close the previous one, so an ops-less commit
// is still delivered.
@(private = "file")
log_commit :: proc(data: rawptr, epoch, wall, actor, reason: u64) -> bool {
	cur := (^Log_Cursor)(data)
	if cur.pending && !log_flush_commit(cur) {
		return false
	}
	cur.pending = true
	cur.epoch, cur.wall, cur.actor, cur.reason = epoch, wall, actor, reason
	return true
}

// log_flush_commit delivers the held epoch, its attribution decoded
// against the dictionary as it now stands.
@(private = "file")
log_flush_commit :: proc(cur: ^Log_Cursor) -> bool {
	cur.pending = false
	if cur.c.commit == nil {
		return true
	}
	defer free_all(mem.scratch_allocator(&cur.scratch))
	a, r: rdf.Term
	ok := true
	if cur.actor != 0 {
		a, ok = log_term_at(cur, cur.actor, cur.inline_buf[0][:])
	}
	if ok && cur.reason != 0 {
		r, ok = log_term_at(cur, cur.reason, cur.inline_buf[1][:])
	}
	if !ok {
		return false
	}
	return cur.c.commit(cur.c.data, cur.epoch, cur.wall, a, r)
}

@(private = "file")
log_note :: proc(data: rawptr, last_epoch: u64, payload: []byte) -> bool {
	cur := (^Log_Cursor)(data)
	if cur.pending && !log_flush_commit(cur) {
		return false
	}
	if cur.c.note == nil {
		return true
	}
	return cur.c.note(cur.c.data, last_epoch, payload)
}

// log_op decodes one operation's four components and delivers it. The
// scratch is released on the way out, so a term's lifetime is the
// callback's -- api.md par. 12.7's borrowing rule, one level up.
@(private = "file")
log_op :: proc(data: rawptr, epoch: u64, op: Fact_Op) -> bool {
	cur := (^Log_Cursor)(data)
	if cur.pending && !log_flush_commit(cur) {
		return false
	}
	if cur.c.op == nil {
		return true
	}
	defer free_all(mem.scratch_allocator(&cur.scratch))

	s, s_ok := log_term_at(cur, op.s, cur.inline_buf[0][:])
	p, p_ok := log_term_at(cur, op.p, cur.inline_buf[1][:])
	o, o_ok := log_term_at(cur, op.o, cur.inline_buf[2][:])
	g: rdf.Term
	g_ok := true
	if op.g != DEFAULT_GRAPH {
		g, g_ok = log_term_at(cur, op.g, nil) // a graph label is never inlined
	}
	if !s_ok || !p_ok || !o_ok || !g_ok {
		return false
	}

	// A graph label is an IRI or a blank node and never a literal, which
	// rdf.Graph_Label makes unrepresentable; the log cannot hold one
	// either, so a component that decodes to anything else is corruption
	// rather than a case to handle.
	gl: rdf.Graph_Label
	switch t in g {
	case rdf.IRI:
		gl = t
	case rdf.Blank_Node:
		gl = t
	case nil:
		gl = nil
	case rdf.Literal, ^rdf.Triple:
		return false
	}
	q := rdf.Quad{subject = s, predicate = p, object = o, graph = gl}
	return cur.c.op(cur.c.data, epoch, op.op, q)
}

// log_term_at materializes one id. Inlined ids decode into the caller's
// buffer; dictionary ids decode from the accumulated definitions, with
// a split IRI's namespace and a triple term's components resolved
// through the same dictionary -- so an RDF 1.2 log reads here exactly
// as it does through a store.
@(private = "file")
log_term_at :: proc(cur: ^Log_Cursor, id: u64, buf: []byte) -> (rdf.Term, bool) {
	if id & INLINE_FLAG != 0 {
		return inline_term(id, buf)
	}
	if id == 0 || id > u64(len(cur.dict)) {
		return nil, false
	}
	return term_decode(
		cur.dict[id - 1],
		log_resolve_iri,
		cur,
		log_resolve_term,
		mem.scratch_allocator(&cur.scratch),
	)
}

// log_resolve_iri answers term_decode's datatype and namespace
// lookups. Only a directly-encoded IRI resolves: a namespace that is
// itself split is refused rather than chased, which is the encoder's
// own rule read back.
@(private = "file")
log_resolve_iri :: proc(data: rawptr, id: u64) -> (string, bool) {
	cur := (^Log_Cursor)(data)
	if id == 0 || id > u64(len(cur.dict)) {
		return "", false
	}
	enc := cur.dict[id - 1]
	if len(enc) < 1 || enc[0] != TERM_TAG_IRI {
		return "", false
	}
	return string(enc[1:]), true
}

// log_resolve_term answers a triple term's component lookups.
@(private = "file")
log_resolve_term :: proc(data: rawptr, id: u64, allocator: runtime.Allocator) -> (rdf.Term, bool) {
	cur := (^Log_Cursor)(data)
	buf: [INLINE_LEXICAL_MAX]u8
	if id & INLINE_FLAG != 0 {
		t, ok := inline_term(id, buf[:])
		if !ok {
			return nil, false
		}
		return rdf.clone_term(t, allocator), true
	}
	if id == 0 || id > u64(len(cur.dict)) {
		return nil, false
	}
	return term_decode(cur.dict[id - 1], log_resolve_iri, cur, log_resolve_term, allocator)
}
