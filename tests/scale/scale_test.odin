package scale_test

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import rec "../../record"

// The scale measurement (RECORD-T-0006): a synthetic ISMS-shaped log —
// ~4x10^5 fact operations over ~10^5 distinct terms with realistic
// lengths — generated deterministically by seed, in both of log.md
// par. 9's epoch shapes: bulk-loaded (10^3 epochs of ~400 ops) and
// fully hand-edited (2x10^5 epochs of 2 ops). Full chain verification
// and full replay are timed against the vision's sub-second criterion
// (RECORD-V-0001: replay is the only recovery path and runs on every
// start).
//
// Generation runs through the real writer against an in-memory
// File_Ops — an fsync per epoch on a real disk would measure the
// generator, not the reader — and the finished segments are then
// written to disk so verify and replay run through the posix ops the
// production path uses. The generator honors both write disciplines a
// real writer will (RECORD-T-0007): it interns (one id per encoding,
// log.md par. 5.2) and keeps every graph a set (no assert of a live
// quad, par. 5.3), so the corpus is a valid resident-build substrate.
//
// RECORD-T-0012 grows this file into the initiative's exit gate: full
// boot — store_open end to end — timed against the vision's sub-second
// criterion, and the resident footprint measured against api.md
// par. 10's budget, in both epoch shapes.

OPS_TOTAL :: 400_000
TERMS_TARGET :: 100_000
SEED :: u64(0xDA7A_5EED_0D1B_57EF)
WALL :: u64(1_700_000_000_000_000_000)

// splitmix64 — hand-rolled so the corpus is identical across Odin
// releases; determinism by seed is part of the contract.
@(private = "file")
splitmix :: proc(s: ^u64) -> u64 {
	s^ += 0x9E3779B97F4A7C15
	z := s^
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

@(private = "file")
Mem_File :: struct {
	name: string, // cloned
	data: [dynamic]u8,
}

@(private = "file")
Mem_FS :: struct {
	files: [dynamic]Mem_File,
}

@(private = "file")
mem_ops :: proc(fs: ^Mem_FS) -> rec.File_Ops {
	return {
		data = fs,
		create = proc(data: rawptr, path: string) -> (rec.File_Handle, bool) {
			fs := (^Mem_FS)(data)
			append(&fs.files, Mem_File{name = strings.clone(path)})
			return rec.File_Handle(len(fs.files)), true
		},
		append = proc(data: rawptr, f: rec.File_Handle, bytes: []byte) -> bool {
			fs := (^Mem_FS)(data)
			append(&fs.files[int(f)-1].data, ..bytes)
			return true
		},
		sync = proc(data: rawptr, f: rec.File_Handle) -> bool {return true},
		close = proc(data: rawptr, f: rec.File_Handle) -> bool {return true},
		sync_dir = proc(data: rawptr, dir: string) -> bool {return true},
		put_file = proc(data: rawptr, path: string, content: []byte) -> bool {
			fs := (^Mem_FS)(data)
			for &f in fs.files {
				if f.name == path {
					clear(&f.data)
					append(&f.data, ..content)
					return true
				}
			}
			append(&fs.files, Mem_File{name = strings.clone(path)})
			append(&fs.files[len(fs.files)-1].data, ..content)
			return true
		},
	}
}

@(private = "file")
mem_destroy :: proc(fs: ^Mem_FS) {
	for &f in fs.files {
		delete(f.name)
		delete(f.data)
	}
	delete(fs.files)
	fs^ = {}
}

@(private = "file")
Quad :: struct {
	s, p, o, g: u64,
}

// Gen is the generator's running state: the writer owns the log-level
// invariants; this owns which ids exist and which quads are live —
// including the set semantics of log.md par. 5.3, which the writer
// does not enforce (that is the resident store's Apply, next
// initiative) but which this generator must honor for the corpus to
// be a valid substrate for the resident build: a graph is a set, so
// an assert must never duplicate a live quad.
@(private = "file")
Gen :: struct {
	rng:       u64,
	next_term: u64,
	date_dt:   u64, // the xsd:date IRI's id, defined first (par. 5.2 ordering)
	live:      [dynamic]Quad,
	live_set:  map[Quad]bool, // the same quads, for the duplicate-assert check
	enc_ids:   map[string]u64, // encoding -> id: the generator interns, as a real writer does (par. 5.2)
	iris:      [dynamic]u64, // term ids usable as S and G
	objects:   [dynamic]u64, // term ids usable as O
	preds:     [dynamic]u64, // a small predicate pool, ISMS-shaped
	// per-commit accumulators
	terms:     [dynamic]rec.Term_Def,
	ops:       [dynamic]rec.Fact_Op,
	// every encoding of the run, owned here: enc_ids' keys and the
	// pending Term_Defs view these, so they are freed once at the end
	arena:     [dynamic]string,
}

// gen_new_term interns: literals draw from small value spaces (630
// possible dates, word-salad strings), so a fresh encoding frequently
// equals an existing term — and a real writer reuses the id rather
// than defining the same encoding twice, which the resident build
// refuses (.Duplicate_Term). The arena therefore owns every encoding
// for the whole run — the map's keys view them — and is freed once at
// the end.
@(private = "file")
gen_new_term :: proc(g: ^Gen, enc: string) -> u64 {
	if id, ok := g.enc_ids[enc]; ok {
		delete(enc)
		return id
	}
	id := g.next_term
	g.next_term += 1
	append(&g.arena, enc)
	g.enc_ids[enc] = id
	append(&g.terms, rec.Term_Def{id = id, enc = transmute([]u8)enc})
	return id
}

@(private = "file")
gen_iri :: proc(g: ^Gen) -> u64 {
	kinds := [4]string{"asset", "control", "risk", "policy"}
	id := gen_new_term(g, fmt.aprintf("\x01http://example.org/isms/%s/%06d", kinds[splitmix(&g.rng)%4], g.next_term))
	append(&g.iris, id)
	append(&g.objects, id)
	return id
}

@(private = "file")
gen_literal :: proc(g: ^Gen) -> u64 {
	words := [8]string{"annual", "review", "of", "the", "asset", "register", "and", "controls"}
	b := strings.builder_make()
	strings.write_string(&b, "\x03")
	n := 3 + int(splitmix(&g.rng) % 8) // 20-80 byte lexical forms, roughly
	for i in 0 ..< n {
		if i > 0 {
			strings.write_string(&b, " ")
		}
		strings.write_string(&b, words[splitmix(&g.rng)%8])
	}
	id := gen_new_term(g, strings.to_string(b))
	append(&g.objects, id)
	return id
}

@(private = "file")
gen_lang :: proc(g: ^Gen) -> u64 {
	id := gen_new_term(g, fmt.aprintf("\x04\x02enControl objective %d", splitmix(&g.rng)%100_000))
	append(&g.objects, id)
	return id
}

@(private = "file")
gen_typed_date :: proc(g: ^Gen) -> u64 {
	dt: [8]u8
	v := g.date_dt
	for i := 7; i >= 0; i -= 1 {
		dt[i] = u8(v)
		v >>= 8
	}
	id := gen_new_term(g, fmt.aprintf("\x05%s202%d-0%d-1%d", string(dt[:]), splitmix(&g.rng)%7, 1+splitmix(&g.rng)%9, splitmix(&g.rng)%10))
	append(&g.objects, id)
	return id
}

@(private = "file")
gen_object :: proc(g: ^Gen) -> u64 {
	switch splitmix(&g.rng) % 100 {
	case 0 ..< 65: // an existing term
		return g.objects[splitmix(&g.rng)%u64(len(g.objects))]
	case 65 ..< 73: // a new IRI
		return gen_iri(g)
	case 73 ..< 81: // a new string literal
		return gen_literal(g)
	case 81 ..< 85: // a new language literal
		return gen_lang(g)
	case 85 ..< 88: // a new typed date
		return gen_typed_date(g)
	case: // an inlined integer
		id, _ := rec.inline_integer(i64(splitmix(&g.rng) % 100_000))
		return id
	}
}

// gen_store writes one synthetic store through the real writer into
// memory, then flushes the finished segments to dir on disk. Returns
// the writer's end state for the replay cross-check.
@(private = "file")
gen_store :: proc(t: ^testing.T, dir: string, epochs: int, seed: u64) -> (last_epoch: u64, terms: u64, sizes: int, live: int) {
	fs: Mem_FS
	defer mem_destroy(&fs)
	g: Gen
	g.rng = seed
	g.next_term = 1
	defer {
		delete(g.live)
		delete(g.live_set)
		delete(g.enc_ids)
		delete(g.iris)
		delete(g.objects)
		delete(g.preds)
		delete(g.terms)
		delete(g.ops)
		for s in g.arena {
			delete(s)
		}
		delete(g.arena)
	}

	w, err := rec.writer_create(dir, mem_ops(&fs))
	defer rec.writer_destroy(&w)
	testing.expect_value(t, err, rec.Writer_Error.None)

	ops_per_epoch := OPS_TOTAL / epochs
	for e in 1 ..= epochs {
		clear(&g.terms)
		clear(&g.ops)
		if e == 1 {
			// The datatype IRI precedes every literal that cites it
			// (log.md par. 5.2), and a predicate pool precedes its use.
			g.date_dt = gen_new_term(g = &g, enc = strings.clone("\x01http://www.w3.org/2001/XMLSchema#date"))
			for i in 0 ..< 40 {
				id := gen_new_term(&g, fmt.aprintf("\x01http://example.org/isms/vocab/p%02d", i))
				append(&g.preds, id)
			}
			for _ in 0 ..< 20 {
				gen_iri(&g)
			}
		}
		for _ in 0 ..< ops_per_epoch {
			retract := len(g.live) > 0 && splitmix(&g.rng)%100 < 15
			if retract {
				i := splitmix(&g.rng) % u64(len(g.live))
				q := g.live[i]
				unordered_remove(&g.live, int(i))
				delete_key(&g.live_set, q)
				append(&g.ops, rec.Fact_Op{op = .Retract, s = q.s, p = q.p, o = q.o, g = q.g})
			} else {
				s := g.iris[splitmix(&g.rng)%u64(len(g.iris))]
				if splitmix(&g.rng)%100 < 5 {
					s = gen_iri(&g)
				}
				p := g.preds[splitmix(&g.rng)%u64(len(g.preds))]
				o := gen_object(&g)
				gr := rec.DEFAULT_GRAPH
				if splitmix(&g.rng)%100 < 30 {
					gr = g.iris[splitmix(&g.rng)%u64(len(g.iris))]
				}
				// Objects come from a reused pool, so a fresh draw can
				// collide with a live quad; re-roll the object until it
				// does not. Rare enough that the corpus is unchanged in
				// shape, and it keeps the log a set (par. 5.3).
				q := Quad{s, p, o, gr}
				for {
					if !(q in g.live_set) {
						break
					}
					q.o = gen_object(&g)
				}
				g.live_set[q] = true
				append(&g.live, q)
				append(&g.ops, rec.Fact_Op{op = .Assert, s = q.s, p = q.p, o = q.o, g = q.g})
			}
		}
		werr := rec.writer_commit(&w, {epoch = u64(e), wall = WALL + u64(e), terms = g.terms[:], ops = g.ops[:]})
		testing.expect_value(t, werr, rec.Writer_Error.None)
	}
	last_epoch = w.prev_epoch
	terms = w.next_term_id - 1
	live = len(g.live)

	// Flush the finished segments (and HEAD) to disk; verify and
	// replay then read them through the production posix ops.
	os.make_directory("build")
	os.make_directory("build/scale")
	os.make_directory(dir)
	for f in fs.files {
		os.remove(f.name)
		werr := os.write_entire_file(f.name, f.data[:])
		testing.expect(t, werr == nil, "the store flushes to disk")
		sizes += len(f.data)
	}
	return last_epoch, terms, sizes, live
}

@(private = "file")
Counter :: struct {
	commits, terms, ops, notes: u64,
}

@(private = "file")
counting_consumer :: proc(c: ^Counter) -> rec.Consumer {
	return {
		data = c,
		commit = proc(data: rawptr, epoch, wall, actor, reason: u64) -> bool {
			(^Counter)(data).commits += 1
			return true
		},
		term = proc(data: rawptr, id: u64, enc: []byte) -> bool {
			(^Counter)(data).terms += 1
			return true
		},
		op = proc(data: rawptr, epoch: u64, op: rec.Fact_Op) -> bool {
			(^Counter)(data).ops += 1
			return true
		},
		note = proc(data: rawptr, last_epoch: u64, payload: []byte) -> bool {
			(^Counter)(data).notes += 1
			return true
		},
	}
}

@(private = "file")
measure :: proc(t: ^testing.T, name: string, dir: string, epochs: int) {
	last_epoch, terms, size, _ := gen_store(t, dir, epochs, SEED)
	testing.expect_value(t, last_epoch, u64(epochs))
	testing.expect(t, terms > 60_000 && terms < 170_000, "the term count is ISMS-shaped")

	start := time.tick_now()
	r, tear, verr := rec.verify(dir, rec.posix_file_ops())
	verify_ms := time.duration_milliseconds(time.tick_since(start))
	testing.expect_value(t, verr, rec.Open_Error.None)
	testing.expect_value(t, tear.kind, rec.Tear_Kind.None)
	testing.expect_value(t, r.last_epoch, u64(epochs))
	testing.expect_value(t, r.next_term_id, terms+1)

	c: Counter
	start = time.tick_now()
	r2, _, rerr := rec.replay(dir, rec.posix_file_ops(), counting_consumer(&c))
	replay_ms := time.duration_milliseconds(time.tick_since(start))
	testing.expect_value(t, rerr, rec.Open_Error.None)
	testing.expect_value(t, c.commits, u64(epochs))
	testing.expect_value(t, c.ops, u64(OPS_TOTAL))
	testing.expect_value(t, c.terms, terms)
	testing.expect(t, r2.head == r.head, "verify and replay agree on the head")

	log.infof(
		"%s: %d epochs, %d ops, %d terms, %.1f MB — verify %.0f ms, replay %.0f ms",
		name, epochs, OPS_TOTAL, terms, f64(size)/(1024*1024), verify_ms, replay_ms,
	)

	// The vision's criterion: replay is the only recovery path, runs on
	// every start, and must stay comfortably under a second — and
	// verification runs at every startup too (log.md par. 6).
	testing.expect(t, verify_ms < 1000, "full verification stays under a second")
	testing.expect(t, replay_ms < 1000, "full replay stays under a second")
}

// Mirror is the resident build's independent witness at scale
// (RECORD-T-0007): a second replay over the same log, checking every
// delivery against the already-built store — terms byte-for-byte
// through the arena, asserts against their positional fact, retracts
// resolved through its own live map rather than the Loader's.
@(private = "file")
Mirror :: struct {
	t:    ^testing.T,
	s:    ^rec.Store,
	live: map[rec.Quad]u32,
	n:    u32, // asserts seen — the fact id the next assert must land on
}

@(private = "file")
mirror_consumer :: proc(m: ^Mirror) -> rec.Consumer {
	return {
		data = m,
		term = proc(data: rawptr, id: u64, enc: []byte) -> bool {
			m := (^Mirror)(data)
			got := rec.dict_bytes(&m.s.dict, rec.resident_id(id))
			ok := string(got) == string(enc)
			testing.expect(m.t, ok, "the arena holds the log's encoding verbatim")
			return ok
		},
		op = proc(data: rawptr, epoch: u64, op: rec.Fact_Op) -> bool {
			m := (^Mirror)(data)
			q := rec.Quad{rec.resident_id(op.s), rec.resident_id(op.p), rec.resident_id(op.o), rec.resident_id(op.g)}
			ok: bool
			switch op.op {
			case .Assert, .Assert_Derived:
				f := rec.store_fact(m.s, m.n)^
				ok = f.s == q.s && f.p == q.p && f.o == q.o && f.g == q.g && f.assert == u32(epoch)
				testing.expect(m.t, ok, "an assert lands at its positional fact id")
				m.live[q] = m.n
				m.n += 1
			case .Retract, .Retract_Derived:
				id, was_live := m.live[q]
				ok = was_live && rec.store_fact(m.s, id).retract == u32(epoch)
				testing.expect(m.t, ok, "a retract resolved to the live generation")
				delete_key(&m.live, q)
			}
			return ok
		},
	}
}

@(test)
test_scale_resident_build :: proc(t: ^testing.T) {
	dir :: "build/scale/resident"
	last_epoch, terms, _, live := gen_store(t, dir, 1_000, SEED)

	s: rec.Store
	rec.store_init(&s)
	defer rec.store_destroy(&s)
	ld: rec.Loader
	rec.loader_init(&ld, &s)
	defer rec.loader_destroy(&ld)
	r, tear, err := rec.replay(dir, rec.posix_file_ops(), rec.loader_consumer(&ld))
	testing.expect_value(t, err, rec.Open_Error.None)
	testing.expect_value(t, tear.kind, rec.Tear_Kind.None)
	testing.expect_value(t, ld.err, rec.Load_Error.None)

	// Counts against the verified walk and the generator's own state.
	testing.expect_value(t, s.n_facts, r.fact_count)
	testing.expect_value(t, u64(s.n_epochs), last_epoch)
	testing.expect_value(t, u64(len(s.dict.off)), terms)
	testing.expect_value(t, len(ld.live), live)
	n_live: int
	for id in u32(0) ..< s.n_facts {
		if rec.store_fact(&s, id).retract == rec.LIVE_EPOCH {
			n_live += 1
		}
	}
	testing.expect_value(t, n_live, live)

	// Contents: a second replay mirrors the stream against the store,
	// ops one for one, terms byte-for-byte.
	m := Mirror{t = t, s = &s}
	defer delete(m.live)
	_, _, merr := rec.replay(dir, rec.posix_file_ops(), mirror_consumer(&m))
	testing.expect_value(t, merr, rec.Open_Error.None)
	testing.expect_value(t, m.n, s.n_facts)
	testing.expect_value(t, len(m.live), live)

	// The six permutations over the full table (RECORD-T-0008):
	// sortedness asserted at scale through the public key surface, and
	// the build timed informally — the formal boot measurement is
	// RECORD-T-0012's.
	start := time.tick_now()
	rec.store_build_permutations(&s)
	sort_ms := time.duration_milliseconds(time.tick_since(start))
	for o in rec.Order {
		ids := s.ord[o]
		testing.expect_value(t, u32(len(ids)), s.n_facts)
		key := rec.order_key(o)
		for i in 1 ..< len(ids) {
			fa := rec.store_fact(&s, ids[i-1])
			fb := rec.store_fact(&s, ids[i])
			ordered := false
			for c in key {
				va := rec.fact_component(fa, c)
				vb := rec.fact_component(fb, c)
				if va != vb {
					ordered = va < vb
					break
				}
				ordered = ids[i-1] < ids[i]
			}
			if !ordered {
				testing.expectf(t, ordered, "%v out of order at %d", o, i)
				break
			}
		}
	}
	log.infof("permutations: 6 orders over %d facts sorted in %.0f ms", s.n_facts, sort_ms)

	// The read API at scale (RECORD-T-0010): publish, then sampled
	// patterns — components lifted from real facts across the table —
	// at the head and at a mid-history epoch, each checked against a
	// brute-force scan of the whole fact table.
	rec.store_publish(&s)
	for epoch in ([2]u32{s.published, s.published / 2}) {
		snap, serr := rec.store_at(&s, epoch)
		testing.expect_value(t, serr, rec.Snapshot_Error.None)
		for probe in 0 ..< 4 {
			f := rec.store_fact(&s, u32(probe) * (s.n_facts / 4))
			pats := [4]rec.Pattern{
				{s = f.s},
				{p = f.p},
				{s = f.s, p = f.p, o = f.o},
				{p = f.p, g = f.g if f.g != 0 else rec.MATCH_DEFAULT_GRAPH},
			}
			for p in pats {
				want := 0
				for id in u32(0) ..< s.n_facts {
					c := rec.store_fact(&s, id)
					if p.s != 0 && c.s != p.s do continue
					if p.p != 0 && c.p != p.p do continue
					if p.o != 0 && c.o != p.o do continue
					if p.g != 0 {
						pg := u32(0) if p.g == rec.MATCH_DEFAULT_GRAPH else p.g
						if c.g != pg do continue
					}
					if !(c.assert <= epoch && epoch < c.retract) do continue
					want += 1
				}
				got := 0
				sc := rec.range_iter(rec.snapshot_match(snap, p), {origin = .Any})
				for _ in rec.scan_next(&sc) {
					got += 1
				}
				testing.expectf(t, got == want, "pattern %v at epoch %d: got %d, want %d", p, epoch, got, want)
			}
		}
		rec.snapshot_release(&snap)
	}
}

// measure_boot is RECORD-T-0012's gate: store_open end to end on a
// generated store, timed and memory-tracked. The first boot writes the
// startup environment note (the log has none) and is discarded; the
// measured boot is the steady-state wake — the one api.md par. 8 puts
// on a user-facing latency path. The store's allocator is a tracking
// allocator, so resident memory is what the store actually holds and
// the peak includes the transient replay map and sort scaffolding —
// measured, not derived. A phase breakdown is timed separately over
// the same store with the same decomposition store_open runs.
@(private = "file")
measure_boot :: proc(t: ^testing.T, name: string, dir: string, epochs: int) {
	last_epoch, terms, _, live := gen_store(t, dir, epochs, SEED)
	ops := rec.posix_file_ops()

	// Settle the environment note, so the measured boot is a wake, not
	// a first run.
	{
		s: rec.Store
		w, _, err, lerr, werr := rec.store_open(&s, dir, ops)
		testing.expect_value(t, err, rec.Open_Error.None)
		testing.expect_value(t, lerr, rec.Load_Error.None)
		testing.expect_value(t, werr, rec.Writer_Error.None)
		rec.writer_destroy(&w)
		rec.store_destroy(&s)
	}

	// The measured boot.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	s: rec.Store
	start := time.tick_now()
	w, tear, err, lerr, werr := rec.store_open(&s, dir, ops, rec.SEGMENT_TARGET_SIZE, alloc)
	boot_ms := time.duration_milliseconds(time.tick_since(start))
	testing.expect_value(t, err, rec.Open_Error.None)
	testing.expect_value(t, lerr, rec.Load_Error.None)
	testing.expect_value(t, werr, rec.Writer_Error.None)
	testing.expect_value(t, tear.kind, rec.Tear_Kind.None)
	testing.expect_value(t, u64(s.published), last_epoch)
	testing.expect_value(t, u64(len(s.dict.off)), terms)

	// Read-path sanity on the booted store (the full oracle is
	// test_scale_resident_build's): the head's live count through
	// Match, against the generator's own live set.
	snap, serr := rec.store_latest(&s)
	testing.expect_value(t, serr, rec.Snapshot_Error.None)
	n_live := 0
	sc := rec.range_iter(rec.snapshot_match(snap, {}), {origin = .Any})
	for _ in rec.scan_next(&sc) {
		n_live += 1
	}
	testing.expect_value(t, n_live, live)
	rec.snapshot_release(&snap)

	// The resident footprint, by structure (bytes actually allocated),
	// with the by-term map and small slack as the tracker's remainder.
	fact_b := len(s.facts) * rec.FACT_CHUNK_SIZE * size_of(rec.Fact)
	perm_b := 0
	for o in rec.Order {
		perm_b += len(s.idx.ord[o]) * size_of(u32)
	}
	epoch_b := len(s.epochs) * rec.EPOCH_CHUNK_SIZE * size_of(rec.Epoch_Meta)
	arena_b := 0
	for c in s.dict.chunks {
		arena_b += len(c)
	}
	off_b := cap(s.dict.off) * size_of(u32)
	derived_b := cap(s.derived)*size_of(u64) + len(s.idx.derived)*size_of(u64)
	resident := int(track.current_memory_allocated)
	peak := int(track.peak_memory_allocated)
	accounted := fact_b + perm_b + epoch_b + arena_b + off_b + derived_b
	mb :: proc(n: int) -> f64 {return f64(n) / (1024 * 1024)}

	log.infof(
		"%s boot: %.0f ms — resident %.1f MB (facts %.1f, permutations %.1f, arena %.1f, epochs %.2f, offsets+origin %.2f, by-term map+rest %.1f), transient peak %.1f MB",
		name, boot_ms, mb(resident), mb(fact_b), mb(perm_b), mb(arena_b), mb(epoch_b),
		mb(off_b + derived_b), mb(resident - accounted), mb(peak),
	)
	testing.expect(t, boot_ms < 1000, "full boot stays under a second")
	testing.expect(t, resident > accounted, "the walked structures are within what the tracker saw")

	rec.writer_destroy(&w)
	rec.store_destroy(&s)

	// The phase breakdown, over the same store: recover + replay-into-
	// the-build versus the permutation sort — the same decomposition
	// store_open runs, timed at its two seams.
	s2: rec.Store
	rec.store_init(&s2)
	defer rec.store_destroy(&s2)
	start = time.tick_now()
	_, _, rerr := rec.recover(dir, ops)
	testing.expect_value(t, rerr, rec.Open_Error.None)
	ld: rec.Loader
	rec.loader_init(&ld, &s2)
	_, _, perr := rec.replay(dir, ops, rec.loader_consumer(&ld))
	testing.expect_value(t, perr, rec.Open_Error.None)
	rec.loader_destroy(&ld)
	load_ms := time.duration_milliseconds(time.tick_since(start))
	start = time.tick_now()
	rec.store_build_permutations(&s2)
	sort_ms := time.duration_milliseconds(time.tick_since(start))
	rec.store_publish(&s2)
	log.infof("%s boot phases: recover+replay+build %.0f ms, permutation sort %.0f ms", name, load_ms, sort_ms)
}

@(test)
test_scale_boot_bulk :: proc(t: ^testing.T) {
	measure_boot(t, "bulk-loaded", "build/scale/boot-bulk", 1_000)
}

@(test)
test_scale_boot_edited :: proc(t: ^testing.T) {
	measure_boot(t, "hand-edited", "build/scale/boot-edited", 200_000)
}

@(test)
test_scale_bulk_loaded :: proc(t: ^testing.T) {
	measure(t, "bulk-loaded", "build/scale/bulk", 1_000)
}

@(test)
test_scale_hand_edited :: proc(t: ^testing.T) {
	measure(t, "hand-edited", "build/scale/edited", 200_000)
}
