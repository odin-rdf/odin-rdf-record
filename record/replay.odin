// Replay (RECORD-T-0004): log.md par. 8 minus the resident store —
// every record read in order through the verifying reader, and what
// the records carry streamed to a consumer procedure set. That seam is
// the initiative's one forward-looking interface: the resident store
// binds to it in the next initiative, the dump tool (RECORD-T-0005)
// binds to it now, and it is deliberately record-shaped — it delivers
// what the log says and converts nothing, because a consumer can
// always build more from a faithful stream, and a seam that
// pre-digests cannot deliver less.
//
// # Replay judges what verify does not
//
// Verification and reading are one pass, not two: replay runs the
// exact walk verify runs (open.odin) and aborts with the same verdicts
// — there is no unverified read path. On top of it, replay enforces
// what the records *say*, which verify deliberately leaves alone: the
// par. 5.2 dictionary self-check (every term definition's id is the
// next expected), the api.md par. 3.4 boundary assertion (every
// dictionary id fits the resident scheme), every op component defined
// or inlined within RECORD-A-0001's frozen range, and a note's
// lastEpoch equal to the epoch it follows. A perfect chain around a
// writer's nonsense verifies — it does not replay.
//
// What replay does NOT judge: the live-quad preconditions of par. 5.3
// (a retract of a quad that is not live, an assert of one that is).
// Those need the resident state being rebuilt, so they are the
// consumer's to raise — the seam gives it the abort lever.
package record

// RESIDENT_ID_LIMIT is the resident scheme's ceiling on dictionary ids
// (api.md par. 3): resident ids are u32 with bit 31 as the inline
// flag, so a dictionary id must stay below 2^31. api.md par. 3.4 says
// "fits in u32"; its own encoding table says bit 31 is spoken for, and
// the sharper bound is the true one. At the design scale of ~10^5
// terms the margin is 20,000x; the assertion exists because this is
// the boundary where the derived representation makes its scale
// assumption, and an assumption belongs where it is checked.
RESIDENT_ID_LIMIT :: u64(1) << 31

// Consumer is the replay seam: one procedure per thing a record can
// carry, with a context pointer, in the family's procedure-set style.
// It leaks no resident types — ids are the log's u64s, encodings are
// the log's bytes — and it is the binding point the resident store's
// initiative implements.
//
// Delivery order is log order: for each epoch commit, `commit` first
// (the boundary — epoch, wall, actor, reason), then every term
// definition in first-appearance order, then every fact op; ops may
// reference terms delivered under the same commit. Notes arrive
// between commits, where they sit in the chain. Seals are not
// delivered: par. 5.4 is explicit that a seal is a summary nothing
// downstream reads, and par. 8's replay applies nothing for one.
//
// `enc` and `payload` borrow from the segment buffer and are valid
// only for the duration of the call — a consumer that keeps one clones
// it (the family's zero-copy discipline). Every procedure returns
// whether to continue; false aborts replay with .Consumer_Abort, which
// is how a consumer surfaces its own refusals (a retract of a quad it
// knows is not live, an allocation failure) without this layer
// guessing at their taxonomy. A nil procedure skips that delivery —
// the checks above still run; only the call is omitted.
Consumer :: struct {
	data:   rawptr,
	commit: proc(data: rawptr, epoch, wall, actor, reason: u64) -> bool,
	term:   proc(data: rawptr, id: u64, enc: []byte) -> bool,
	op:     proc(data: rawptr, epoch: u64, op: Fact_Op) -> bool,
	note:   proc(data: rawptr, last_epoch: u64, payload: []byte) -> bool,
}

// replay reads the whole log through the verifying walk and streams it
// to the consumer. Read-only, like verify: a torn tail is reported as
// .Torn with everything durable before it already delivered — the
// stream is exactly the log that recovery would leave, so a caller
// that runs recover first replays clean, and one that replays first
// can recover after without replaying again. On a halting verdict the
// consumer has received every record before the damage and nothing at
// or after it.
replay :: proc(
	dir: string,
	ops: File_Ops,
	c: Consumer,
	allocator := context.allocator,
) -> (
	r: Verify_Result,
	tear: Tear,
	err: Open_Error,
) {
	c := c
	return open_walk(dir, ops, &c, allocator)
}

// replay_commit judges one chain-verified commit against the walk's
// running state and delivers it. Checks precede every delivery: a
// record that fails them is delivered in no part, so a consumer never
// has to unwind a half-applied commit.
@(private)
replay_commit :: proc(r: ^Verify_Result, c: ^Consumer, v: Commit_View) -> Open_Error {
	// The par. 5.2 self-check: ids are assigned in first-appearance
	// order and the reader counts them out, so the recorded id is
	// redundant — and a mismatch is a cheap, loud signal that reader
	// and writer disagree about something fundamental.
	next := r.next_term_id
	terms := commit_terms(v)
	for t in term_next(&terms) {
		if t.id != next {
			return .Term_Order
		}
		if next >= RESIDENT_ID_LIMIT {
			return .Term_Overflow
		}
		next += 1
	}
	// Actor and reason are dictionary ids or zero (log.md par. 5.1) —
	// never inlined, and defined by this record or an earlier one.
	for id in ([2]u64{v.actor, v.reason}) {
		if id != 0 && (id&INLINE_FLAG != 0 || id >= next) {
			return .Bad_Term_Id
		}
	}
	// Every op component is either a defined dictionary id or an
	// inlined value the resident scheme can hold — the writer-side
	// rules of commit_encode, mirrored at the boundary the resident
	// store trusts (api.md par. 3.4). G alone may be 0 (the default
	// graph) and may never be inlined: a graph label is not a literal
	// (log.md par. 5.3, amended).
	ops := commit_ops(v)
	for op in op_next(&ops) {
		for id in ([3]u64{op.s, op.p, op.o}) {
			if id == 0 {
				return .Bad_Term_Id
			}
			if id & INLINE_FLAG != 0 {
				if !inline_ok(id) {
					return .Inline_Range
				}
			} else if id >= next {
				return .Bad_Term_Id
			}
		}
		if op.g != DEFAULT_GRAPH {
			if op.g&INLINE_FLAG != 0 || op.g >= next {
				return .Bad_Term_Id
			}
		}
	}

	if c.commit != nil && !c.commit(c.data, v.epoch, v.wall, v.actor, v.reason) {
		return .Consumer_Abort
	}
	if c.term != nil {
		terms = commit_terms(v)
		for t in term_next(&terms) {
			if !c.term(c.data, t.id, t.enc) {
				return .Consumer_Abort
			}
		}
	}
	if c.op != nil {
		ops = commit_ops(v)
		for op in op_next(&ops) {
			if !c.op(c.data, v.epoch, op) {
				return .Consumer_Abort
			}
		}
	}
	return .None
}

// replay_note judges and delivers one chain-verified note. lastEpoch
// is redundant like par. 5.2's id — the reader already knows what
// epoch it is at — and is checked for the same reason.
@(private)
replay_note :: proc(r: ^Verify_Result, c: ^Consumer, v: Note_View) -> Open_Error {
	if v.last_epoch != r.last_epoch {
		return .Note_Epoch
	}
	if c.note != nil && !c.note(c.data, v.last_epoch, v.payload) {
		return .Consumer_Abort
	}
	return .None
}
