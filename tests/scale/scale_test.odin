package scale_test

import "core:fmt"
import "core:log"
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
// production path uses. Only log-level validity is generated: an
// occasional duplicate assert of a live quad can occur, which the
// format permits and Apply (a later initiative) refuses.

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
// invariants; this owns which ids exist and which quads are live.
@(private = "file")
Gen :: struct {
	rng:       u64,
	next_term: u64,
	date_dt:   u64, // the xsd:date IRI's id, defined first (par. 5.2 ordering)
	live:      [dynamic]Quad,
	iris:      [dynamic]u64, // term ids usable as S and G
	objects:   [dynamic]u64, // term ids usable as O
	preds:     [dynamic]u64, // a small predicate pool, ISMS-shaped
	// per-commit accumulators; enc strings are freed after the commit
	terms:     [dynamic]rec.Term_Def,
	ops:       [dynamic]rec.Fact_Op,
	arena:     [dynamic]string,
}

@(private = "file")
gen_new_term :: proc(g: ^Gen, enc: string) -> u64 {
	id := g.next_term
	g.next_term += 1
	append(&g.arena, enc)
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
gen_store :: proc(t: ^testing.T, dir: string, epochs: int, seed: u64) -> (last_epoch: u64, terms: u64, sizes: int) {
	fs: Mem_FS
	defer mem_destroy(&fs)
	g: Gen
	g.rng = seed
	g.next_term = 1
	defer {
		delete(g.live)
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
				append(&g.live, Quad{s, p, o, gr})
				append(&g.ops, rec.Fact_Op{op = .Assert, s = s, p = p, o = o, g = gr})
			}
		}
		werr := rec.writer_commit(&w, {epoch = u64(e), wall = WALL + u64(e), terms = g.terms[:], ops = g.ops[:]})
		testing.expect_value(t, werr, rec.Writer_Error.None)
		for s in g.arena {
			delete(s)
		}
		clear(&g.arena)
	}
	last_epoch = w.prev_epoch
	terms = w.next_term_id - 1

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
	return last_epoch, terms, sizes
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
	last_epoch, terms, size := gen_store(t, dir, epochs, SEED)
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

@(test)
test_scale_bulk_loaded :: proc(t: ^testing.T) {
	measure(t, "bulk-loaded", "build/scale/bulk", 1_000)
}

@(test)
test_scale_hand_edited :: proc(t: ^testing.T) {
	measure(t, "hand-edited", "build/scale/edited", 200_000)
}
