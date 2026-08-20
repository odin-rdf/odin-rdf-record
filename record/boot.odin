// Boot, end to end (RECORD-T-0011): store_open is the one way a store
// comes up — recover, replay into the resident build, sort the
// permutations, publish, resume the writer from the verified walk, and
// write the startup environment note where the environment changed.
// It is the composition of everything the initiative built, and the
// path every wake from eviction runs (api.md par. 8) — which is why
// its pieces were each built and proven separately first.
//
// One sequencing choice is load-bearing for the reload peak: the
// Loader (and its transient live-quad and seen-term maps, ~the largest
// transients of the boot) is destroyed BEFORE the permutation sort
// allocates its scaffolding, so the boot's peak memory is the larger
// of the two, never their sum. The term index is sorted after the
// permutations, before the one publication.
package record

// ENV_NOTE_V1 is the startup environment note's payload — the v1
// content decided in RECORD-T-0011 (log.md par. 5.5, amended): the
// format version this writer speaks, and the RECORD-A-0002
// derived-facts regime — no reasoner exists and derived facts are not
// logged, so replay's materialization pass is vacuous and the log says
// so itself. Keys are emitted in this fixed order so that "the
// environment differs from the last note" (log.md par. 7.1) is a byte
// comparison. A reasoner's arrival grows this payload (engine version,
// rule set id and hash, par. 5.5) and writes a differing note at the
// next startup, exactly as designed.
ENV_NOTE_V1 :: `{"format":1,"derived":"none"}`

// store_open boots a store from its directory: log.md par. 7.2's
// recovery, par. 8's replay as the only load path, the six sorts, one
// publication, and the writer resumed to continue the chain. A fresh
// directory (or one whose only segment never durably opened) is
// created rather than resumed. On success the caller owns the store
// with its writer inside it (s.writer, which apply commits through),
// and releases both with store_close after every snapshot — s is
// initialized here and left empty on failure.
//
// Failures keep their own taxonomies rather than being flattened:
// `err` is the open path's verdict, passed through untouched — with
// `load_err` naming the Loader's refusal when err is .Consumer_Abort —
// and `write_err` is the resume path's. Exactly one is set on failure.
// A recovery event is surfaced in `tear`, never swallowed: err .None
// with a non-None tear.kind means the repair was applied and the boot
// continued — the caller logs it, alerts on it, and counts it.
//
// The startup environment note (log.md par. 7.1): after the writer is
// up, the current environment (ENV_NOTE_V1) is compared byte-for-byte
// against the last note replay delivered, and appended — durably, and
// mirrored into the resident note table — only when it differs. A
// fresh store always differs, so the first record after any store's
// header is the note that makes the log self-describing.
//
// The validator (RECORD-A-0006) is wired here and only here, so every
// changeset apply commits is judged by it; the default, no validator,
// is the consumer's stated posture.
store_open :: proc(
	s: ^Store,
	dir: string,
	ops: File_Ops,
	validator := Validator{},
	target_size := SEGMENT_TARGET_SIZE,
	allocator := context.allocator,
) -> (
	tear: Tear,
	err: Open_Error,
	load_err: Load_Error,
	write_err: Writer_Error,
) {
	store_init(s, allocator)
	s.validator = validator
	w := &s.writer

	r, rtear, rerr := recover(dir, ops, allocator)
	tear = rtear
	fresh := rerr == .No_Store
	if !fresh && rerr != .None {
		store_destroy(s)
		return tear, rerr, .None, .None
	}

	if fresh {
		w^, write_err = writer_create(dir, ops, target_size, allocator)
		if write_err != .None {
			store_close(s)
			return tear, .None, .None, write_err
		}
	} else {
		ld: Loader
		loader_init(&ld, s)
		r2, _, rperr := replay(dir, ops, loader_consumer(&ld), allocator)
		load_err = ld.err
		loader_destroy(&ld) // the live map dies before the sort allocates
		if rperr != .None {
			store_destroy(s)
			return tear, rperr, load_err, .None
		}
		r = r2
	}

	store_build_permutations(s)
	store_build_term_index(s)
	store_publish(s)

	if !fresh {
		w^, write_err = writer_open(dir, ops, r, target_size, allocator)
		if write_err != .None {
			store_close(s)
			return tear, .None, .None, write_err
		}
	}

	// The startup note, only on change — byte comparison against the
	// last note in the log, which replay just delivered (none, for a
	// fresh store).
	current := transmute([]byte)string(ENV_NOTE_V1)
	if len(s.notes) == 0 || string(s.notes[len(s.notes)-1].payload) != ENV_NOTE_V1 {
		if write_err = writer_note(w, current); write_err != .None {
			store_close(s)
			return tear, .None, .None, write_err
		}
		// Mirror it residently, keyed by the epoch it follows, so
		// store_note_at answers about this boot without another replay.
		cloned := make([]byte, len(current), s.allocator)
		copy(cloned, current)
		append(&s.notes, Env_Note{last_epoch = Epoch(w.prev_epoch), payload = cloned})
	}

	return tear, .None, .None, .None
}
