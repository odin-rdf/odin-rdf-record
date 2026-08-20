package record

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:testing"

import "rdf:rdf"

// Apply's tests (RECORD-T-0015): the error taxonomy, one minimal
// changeset per kind with the intra-changeset cases; rollback proven
// exact by comparing a store whose writer failed mid-apply against one
// that never saw the changeset; replay equivalence — the initiative's
// standing proof — after N random changesets on both file seams; and
// the crash sweep across apply at every operation cut point, boot,
// and continue.

@(private = "file")
iri :: proc(s: string) -> rdf.Term {
	return rdf.IRI(s)
}

@(private = "file")
op :: proc(kind: Op_Kind, s, p, o: rdf.Term, g: rdf.Graph_Label = nil) -> Op {
	return Op{kind = kind, quad = {triple = {s, p, o}, graph = g}}
}

@(private = "file")
at_open :: proc(t: ^testing.T, s: ^Store, ops: File_Ops, target := SEGMENT_TARGET_SIZE, validator := Validator{}, loc := #caller_location) {
	_, err, lerr, werr := store_open(s, "store", ops, validator, target)
	testing.expect_value(t, err, Open_Error.None, loc = loc)
	testing.expect_value(t, lerr, Load_Error.None, loc = loc)
	testing.expect_value(t, werr, Writer_Error.None, loc = loc)
}

@(private = "file")
at_ok :: proc(t: ^testing.T, s: ^Store, ops: []Op, loc := #caller_location) -> Epoch {
	e, conforms, err := apply(s, {ops = ops})
	testing.expect_value(t, err, Apply_Error{}, loc = loc)
	testing.expect(t, conforms, "no validator: everything conforms", loc = loc)
	return e
}

@(private = "file")
at_exists :: proc(s: ^Store, epoch: Epoch, q: Op) -> bool {
	snap, err := store_at(s, epoch)
	if err != .None {
		return false
	}
	defer snapshot_release(&snap)
	p: Pattern
	ok: bool
	if p.s, ok = snapshot_resolve(snap, q.subject); !ok {
		return false
	}
	if p.p, ok = snapshot_resolve(snap, q.predicate); !ok {
		return false
	}
	if p.o, ok = snapshot_resolve(snap, q.object); !ok {
		return false
	}
	p.g = MATCH_DEFAULT_GRAPH
	switch g in q.graph {
	case rdf.IRI:
		if p.g, ok = snapshot_resolve(snap, g); !ok {
			return false
		}
	case rdf.Blank_Node:
		if p.g, ok = snapshot_resolve(snap, g); !ok {
			return false
		}
	}
	return snapshot_exists(snap, p, {origin = .Any})
}

// same_projection compares two stores structure by structure — fact
// table, dictionary, epoch table, and the published set's term index
// and six permutations — the comparison both the rollback and the
// replay-equivalence tests rest on. `walls` compares the epochs' wall
// clocks too: right when both stores read one log, meaningless when
// each took its own clock.
@(private = "file")
same_projection :: proc(t: ^testing.T, a, b: ^Store, walls := true, loc := #caller_location) {
	testing.expect_value(t, a.n_facts, b.n_facts, loc = loc)
	testing.expect_value(t, len(a.facts), len(b.facts), loc = loc)
	testing.expect_value(t, len(a.derived), len(b.derived), loc = loc)
	for id in 0 ..< min(a.n_facts, b.n_facts) {
		testing.expect_value(t, store_fact(a, Fact_ID(id))^, store_fact(b, Fact_ID(id))^, loc = loc)
		testing.expect_value(t, store_derived(a, Fact_ID(id)), store_derived(b, Fact_ID(id)), loc = loc)
	}
	testing.expect_value(t, len(a.dict.off), len(b.dict.off), loc = loc)
	testing.expect_value(t, len(a.dict.chunks), len(b.dict.chunks), loc = loc)
	testing.expect(t, slice.equal(a.dict.used[:], b.dict.used[:]), "arena fills agree", loc = loc)
	testing.expect(t, slice.equal(a.dict.off[:], b.dict.off[:]), "arena offsets agree", loc = loc)
	for id in 1 ..= u32(min(len(a.dict.off), len(b.dict.off))) {
		testing.expect(t, string(dict_bytes(&a.dict, Term_ID(id))) == string(dict_bytes(&b.dict, Term_ID(id))), "term bytes agree", loc = loc)
	}
	testing.expect_value(t, a.n_epochs, b.n_epochs, loc = loc)
	testing.expect_value(t, len(a.epochs), len(b.epochs), loc = loc)
	for e in 1 ..= min(a.n_epochs, b.n_epochs) {
		ma, mb := store_epoch_meta(a, Epoch(e)), store_epoch_meta(b, Epoch(e))
		if !walls {
			ma.wall, mb.wall = 0, 0
		}
		testing.expect_value(t, ma, mb, loc = loc)
	}
	testing.expect_value(t, a.published, b.published, loc = loc)
	testing.expect_value(t, a.idx.epoch, b.idx.epoch, loc = loc)
	testing.expect_value(t, a.idx.n_facts, b.idx.n_facts, loc = loc)
	testing.expect_value(t, a.idx.n_terms, b.idx.n_terms, loc = loc)
	testing.expect(t, slice.equal(a.idx.terms, b.idx.terms), "term indexes agree", loc = loc)
	for o in Order {
		testing.expect(t, slice.equal(a.idx.ord[o], b.idx.ord[o]), "permutations agree", loc = loc)
	}
}

@(test)
test_apply_taxonomy :: proc(t: ^testing.T) {
	fs: Mem_FS
	defer mem_fs_destroy(&fs)
	s: Store
	at_open(t, &s, mem_file_ops(&fs))
	defer store_close(&s)

	alice, knows, bob, carol := iri("http://ex/alice"), iri("http://ex/knows"), iri("http://ex/bob"), iri("http://ex/carol")
	A := op(.Assert, alice, knows, bob)
	B := op(.Assert, alice, knows, carol)

	// Nothing to do is refused, not committed as a marker epoch.
	_, _, empty := apply(&s, {})
	testing.expect_value(t, empty, Apply_Error{.Empty, -1})

	// The frozen format's gaps are typed refusals naming the op.
	tt := rdf.Triple{alice, knows, bob}
	bad := [2]Op{A, op(.Assert, alice, knows, &tt)}
	_, _, uerr := apply(&s, {ops = bad[:]})
	testing.expect_value(t, uerr, Apply_Error{.Unsupported_Term, 1})
	one := [1]Op{A}
	_, _, aerr := apply(&s, {ops = one[:], actor = rdf.Literal{lexical = "5", datatype = rdf.XSD_INTEGER}})
	testing.expect_value(t, aerr, Apply_Error{.Unsupported_Term, -1})
	testing.expect_value(t, s.n_epochs, u32(0))
	testing.expect_value(t, s.n_facts, u32(0))
	testing.expect_value(t, len(s.dict.off), 0)

	// Intra-changeset preconditions.
	twice := [2]Op{A, A}
	_, _, derr := apply(&s, {ops = twice[:]})
	testing.expect_value(t, derr, Apply_Error{.Already_Live, 1})
	gone := [1]Op{op(.Retract, alice, knows, bob)}
	_, _, nerr := apply(&s, {ops = gone[:]})
	testing.expect_value(t, nerr, Apply_Error{.Not_Live, 0})
	testing.expect_value(t, s.n_epochs, u32(0))

	// Assert then retract in one epoch is legal: a generation with the
	// interval [E, E), visible at no epoch.
	flicker := [3]Op{A, op(.Retract, alice, knows, bob), B}
	e1 := at_ok(t, &s, flicker[:])
	testing.expect_value(t, e1, Epoch(1))
	testing.expect_value(t, s.n_facts, u32(2))
	testing.expect_value(t, store_fact(&s, 0).assert, Epoch(1))
	testing.expect_value(t, store_fact(&s, 0).retract, Epoch(1))
	testing.expect(t, !at_exists(&s, 1, A), "the flickered quad is not visible at its own epoch")
	testing.expect(t, at_exists(&s, 1, B), "the other assert is")

	// Head preconditions, and retract then re-assert as a new generation.
	e2 := at_ok(t, &s, one[:])
	testing.expect_value(t, e2, Epoch(2))
	_, _, herr := apply(&s, {ops = one[:]})
	testing.expect_value(t, herr, Apply_Error{.Already_Live, 0})
	again := [2]Op{op(.Retract, alice, knows, bob), A}
	e3 := at_ok(t, &s, again[:])
	testing.expect_value(t, e3, Epoch(3))
	testing.expect_value(t, s.n_facts, u32(4))
	testing.expect_value(t, store_fact(&s, 2).retract, Epoch(3))
	testing.expect_value(t, store_fact(&s, 3).assert, Epoch(3))
	testing.expect(t, at_exists(&s, 2, A) && at_exists(&s, 3, A), "live before and after the generation change")
	e4 := at_ok(t, &s, gone[:])
	testing.expect_value(t, e4, Epoch(4))
	testing.expect(t, !at_exists(&s, 4, A) && at_exists(&s, 3, A), "retracted at 4, still live at 3")
	_, _, n2 := apply(&s, {ops = gone[:]})
	testing.expect_value(t, n2, Apply_Error{.Not_Live, 0})

	// Actor, reason, a named graph, and every term shape through one
	// changeset — the meta resolves back to the terms given.
	g := rdf.IRI("http://ex/g")
	shapes := [?]Op{
		op(.Assert, alice, knows, rdf.Literal{lexical = "Alice", datatype = rdf.RDF_LANG_STRING, language = "EN"}, g),
		op(.Assert, alice, knows, rdf.Literal{lexical = "5", datatype = rdf.XSD_INTEGER}, g),
		op(.Assert, alice, knows, rdf.Literal{lexical = "05", datatype = rdf.XSD_INTEGER}, g),
		op(.Assert, alice, knows, rdf.Literal{lexical = "1.5", datatype = "http://www.w3.org/2001/XMLSchema#decimal"}, g),
		op(.Assert, rdf.Blank_Node("b0"), knows, rdf.Literal{lexical = "2024-02-29", datatype = XSD_DATE}, rdf.Blank_Node("b0")),
		op(.Assert, alice, knows, rdf.Literal{lexical = "hello"}),
	}
	e5, _, serr := apply(&s, {ops = shapes[:], actor = alice, reason = rdf.Literal{lexical = "because", datatype = rdf.XSD_STRING}})
	testing.expect_value(t, serr, Apply_Error{})
	testing.expect_value(t, e5, Epoch(5))
	for sh in shapes {
		testing.expect(t, at_exists(&s, 5, sh), "every shape is live at its epoch")
		testing.expect(t, !at_exists(&s, 4, sh), "and not before it")
	}
	snap, _ := store_latest(&s)
	defer snapshot_release(&snap)
	meta := snapshot_epoch_meta(snap, 5)
	buf: [INLINE_LEXICAL_MAX]byte
	actor_term, aok := snapshot_term(snap, meta.actor, buf[:])
	testing.expect(t, aok && actor_term == alice, "the actor is the term given")
	reason_term, rok := snapshot_term(snap, meta.reason, buf[:])
	testing.expect(t, rok && reason_term == rdf.Term(rdf.Literal{lexical = "because", datatype = rdf.XSD_STRING}), "the reason is the term given")
	testing.expect_value(t, snapshot_epoch_meta(snap, 4).actor, Term_ID(0))
	testing.expect(t, meta.wall > 1_700_000_000_000_000_000, "the wall clock is the writer's, in Unix ns")
	testing.expect(t, snapshot_terms(snap) >= 10, "terms were interned")

	// A failed writer refuses before touching anything.
	s.writer.failed = true
	_, _, werr := apply(&s, {ops = one[:]})
	testing.expect_value(t, werr, Apply_Error{.Writer, -1})
	s.writer.failed = false
}

@(test)
test_apply_epoch_exhausted :: proc(t: ^testing.T) {
	// LIVE_EPOCH is never issued: a store one short of it refuses before
	// any mutation. Four billion commits from the design scale, so the
	// counter is set by hand on a projection without a writer.
	s: Store
	store_init(&s)
	defer store_destroy(&s)
	s.n_epochs = u32(LIVE_EPOCH) - 1
	store_build_permutations(&s)
	store_build_term_index(&s)
	store_publish(&s)
	one := [1]Op{op(.Assert, iri("http://ex/a"), iri("http://ex/p"), iri("http://ex/b"))}
	_, _, err := apply(&s, {ops = one[:]})
	testing.expect_value(t, err, Apply_Error{.Epoch_Exhausted, -1})
	testing.expect_value(t, s.n_epochs, u32(LIVE_EPOCH)-1)
	testing.expect_value(t, len(s.dict.off), 0)
}

@(test)
test_apply_rollback_exact :: proc(t: ^testing.T) {
	// Two stores, the same three changesets; then one more on A alone
	// that the writer fails at the fsync — after the mutation, before
	// the acknowledgement. A must equal B structure for structure. The
	// failing changeset is shaped to touch every rollback path: a
	// retract of a head fact, new terms including one larger than an
	// arena chunk (a dedicated chunk to free), new facts, a new epoch.
	a_fs, b_fs: OFS
	defer ofs_destroy(&a_fs)
	defer ofs_destroy(&b_fs)
	a, b: Store
	at_open(t, &a, ofs_ops(&a_fs))
	at_open(t, &b, ofs_ops(&b_fs))
	defer store_close(&a)
	defer store_close(&b)

	alice, knows, bob := iri("http://ex/alice"), iri("http://ex/knows"), iri("http://ex/bob")
	script := [3][]Op{
		{op(.Assert, alice, knows, bob)},
		{op(.Assert, bob, knows, alice), op(.Assert, alice, knows, rdf.Literal{lexical = "x"})},
		{op(.Retract, bob, knows, alice)},
	}
	for cs in script {
		at_ok(t, &a, cs)
		at_ok(t, &b, cs)
	}
	same_projection(t, &a, &b, walls = false)

	big := make([]byte, DICT_CHUNK_SIZE+1)
	defer delete(big)
	for i in 0 ..< len(big) {
		big[i] = 'z'
	}
	failing := [4]Op{
		op(.Retract, alice, knows, bob),
		op(.Assert, alice, knows, rdf.Literal{lexical = string(big)}),
		op(.Assert, iri("http://ex/new"), knows, iri("http://ex/newer"), rdf.IRI("http://ex/g")),
		op(.Assert, alice, knows, bob),
	}
	// The commit's first operation is the append, the second the fsync:
	// let the append through and fail the fsync.
	a_fs.budget = a_fs.used + 1
	_, _, err := apply(&a, {ops = failing[:]})
	testing.expect_value(t, err, Apply_Error{.Writer, -1})
	testing.expect_value(t, a.write_err, Writer_Error.IO_Sync)
	testing.expect(t, a.writer.failed, "the writer is fail-stop")
	same_projection(t, &a, &b, walls = false)
	testing.expect(t, at_exists(&a, 3, op(.Assert, alice, knows, bob)), "the retracted-then-rolled-back quad is live again")

	// Fail-stop: nothing more is accepted on A; B continues.
	_, _, again := apply(&a, {ops = failing[3:]})
	testing.expect_value(t, again, Apply_Error{.Writer, -1})
	a_fs.budget = 0
	at_ok(t, &b, failing[:])
	testing.expect_value(t, b.n_epochs, u32(4))

	// The durable log of A is the three acknowledged epochs: the
	// unacknowledged frame is whatever the crash left, and recovery
	// discards it.
	durable: OFS
	defer ofs_destroy(&durable)
	for &f in a_fs.files {
		if data, ok := ofs_durable(&a_fs, f.name, false); ok {
			ofs_seed(&durable, f.name, data)
		}
	}
	a2: Store
	at_open(t, &a2, ofs_ops(&durable))
	defer store_close(&a2)
	testing.expect_value(t, a2.published, Epoch(3))
	same_projection(t, &a, &a2)
}

// --- replay equivalence ------------------------------------------------

@(private = "file")
Vocab :: struct {
	subjects:   [12]rdf.Term,
	predicates: [4]rdf.Term,
	objects:    [24]rdf.Term,
	graphs:     [4]rdf.Graph_Label,
}

@(private = "file")
Key :: struct {
	s, p, o, g: int,
}

@(private = "file")
splitmix :: proc(x: ^u64) -> u64 {
	x^ += 0x9E3779B97F4A7C15
	z := x^
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

@(private = "file")
vocab_make :: proc() -> (v: Vocab, owned: [dynamic]string) {
	for i in 0 ..< len(v.subjects) {
		s := fmt.aprintf("http://ex/s%d", i)
		append(&owned, s)
		if i % 3 == 2 {
			v.subjects[i] = rdf.Blank_Node(s)
		} else {
			v.subjects[i] = rdf.IRI(s)
		}
	}
	for i in 0 ..< len(v.predicates) {
		p := fmt.aprintf("http://ex/p%d", i)
		append(&owned, p)
		v.predicates[i] = rdf.IRI(p)
	}
	for i in 0 ..< len(v.objects) {
		switch i % 8 {
		case 0:
			o := fmt.aprintf("http://ex/o%d", i)
			append(&owned, o)
			v.objects[i] = rdf.IRI(o)
		case 1:
			o := fmt.aprintf("string %d", i)
			append(&owned, o)
			v.objects[i] = rdf.Literal{lexical = o, datatype = rdf.XSD_STRING}
		case 2:
			o := fmt.aprintf("Wort %d", i)
			append(&owned, o)
			v.objects[i] = rdf.Literal{lexical = o, datatype = rdf.RDF_LANG_STRING, language = "de-CH"}
		case 3:
			o := fmt.aprintf("%d", i*7)
			append(&owned, o)
			v.objects[i] = rdf.Literal{lexical = o, datatype = rdf.XSD_INTEGER} // inlined
		case 4:
			o := fmt.aprintf("0%d", i)
			append(&owned, o)
			v.objects[i] = rdf.Literal{lexical = o, datatype = rdf.XSD_INTEGER} // not canonical: a dictionary term
		case 5:
			o := fmt.aprintf("%d.5", i)
			append(&owned, o)
			v.objects[i] = rdf.Literal{lexical = o, datatype = "http://www.w3.org/2001/XMLSchema#decimal"}
		case 6:
			o := fmt.aprintf("2024-01-%02d", 1+i%28)
			append(&owned, o)
			v.objects[i] = rdf.Literal{lexical = o, datatype = XSD_DATE} // inlined
		case 7:
			o := fmt.aprintf("b%d", i)
			append(&owned, o)
			v.objects[i] = rdf.Blank_Node(o)
		}
	}
	v.graphs[0] = nil
	for i in 1 ..< len(v.graphs) {
		g := fmt.aprintf("http://ex/g%d", i)
		append(&owned, g)
		v.graphs[i] = rdf.IRI(g)
	}
	return
}

// drive applies `rounds` random changesets — asserts of quads not
// live, retracts of quads that are, one to twelve ops each, every term
// shape — and returns the live set for the head check.
@(private = "file")
drive :: proc(t: ^testing.T, s: ^Store, v: ^Vocab, rounds: int, seed: u64) -> (live: map[Key]bool) {
	rng := seed
	keys := make([dynamic]Key)
	defer delete(keys)
	ops := make([dynamic]Op)
	defer delete(ops)
	for _ in 0 ..< rounds {
		clear(&ops)
		n := 1 + int(splitmix(&rng) % 12)
		for _ in 0 ..< n {
			if len(keys) > 0 && splitmix(&rng)%100 < 30 {
				i := int(splitmix(&rng) % u64(len(keys)))
				k := keys[i]
				unordered_remove(&keys, i)
				delete_key(&live, k)
				append(&ops, op(.Retract, v.subjects[k.s], v.predicates[k.p], v.objects[k.o], v.graphs[k.g]))
			} else {
				k: Key
				for {
					k = Key{
						int(splitmix(&rng) % u64(len(v.subjects))),
						int(splitmix(&rng) % u64(len(v.predicates))),
						int(splitmix(&rng) % u64(len(v.objects))),
						int(splitmix(&rng) % u64(len(v.graphs))),
					}
					if !(k in live) {
						break
					}
				}
				live[k] = true
				append(&keys, k)
				append(&ops, op(.Assert, v.subjects[k.s], v.predicates[k.p], v.objects[k.o], v.graphs[k.g]))
			}
		}
		actor: rdf.Term
		if splitmix(&rng)%2 == 0 {
			actor = v.subjects[splitmix(&rng)%u64(len(v.subjects))]
		}
		_, _, err := apply(s, {ops = ops[:], actor = actor})
		testing.expect_value(t, err, Apply_Error{})
	}
	return
}

@(private = "file")
equivalence :: proc(t: ^testing.T, ops: File_Ops, seed: u64) {
	v, owned := vocab_make()
	defer {
		for s in owned {
			delete(s)
		}
		delete(owned)
	}
	s: Store
	at_open(t, &s, ops, 4096) // a small target so the log rotates under apply
	live := drive(t, &s, &v, 60, seed)
	defer delete(live)
	testing.expect_value(t, s.n_epochs, u32(60))

	// The head's live set is the script's.
	snap, _ := store_latest(&s)
	n := 0
	sc := range_iter(snapshot_match(snap, {}), {origin = .Any})
	for _ in scan_next(&sc) {
		n += 1
	}
	testing.expect_value(t, n, len(live))
	snapshot_release(&snap)
	for k in live {
		testing.expect(t, at_exists(&s, 60, op(.Assert, v.subjects[k.s], v.predicates[k.p], v.objects[k.o], v.graphs[k.g])), "a live quad is found at head")
	}
	testing.expect(t, s.writer.seg_no > 1, "the log rotated under apply")

	// Boot the same directory into a second store while the first is
	// still up: the projection replay builds from the log apply wrote
	// must be the projection apply built — fact for fact, term for
	// term, epoch for epoch (wall clocks included: both read the log's).
	// The second boot appends nothing (the environment note is
	// unchanged), so the first store's writer is undisturbed.
	s1: Store
	at_open(t, &s1, ops)
	defer store_close(&s1)
	testing.expect_value(t, s1.published, Epoch(60))
	same_projection(t, &s, &s1)
	testing.expect_value(t, store_close(&s), Writer_Error.None)
}

@(test)
test_apply_replay_equivalence_ofs :: proc(t: ^testing.T) {
	fs: OFS
	defer ofs_destroy(&fs)
	equivalence(t, ofs_ops(&fs), 0xA11CE)
}

@(test)
test_apply_replay_equivalence_mem :: proc(t: ^testing.T) {
	fs: Mem_FS
	defer mem_fs_destroy(&fs)
	equivalence(t, mem_file_ops(&fs), 0xB0B)
}

// --- the crash sweep -----------------------------------------------------

// sweep_apply drives one store life: open, four changesets (a new
// term and a fact each, one retract), with a small target so rotation
// fires on its own — under a budget that fails operation k+1. Returns
// the epochs apply acknowledged before the cut.
@(private = "file")
sweep_apply :: proc(fs: ^OFS) -> (acked: [dynamic]Epoch) {
	s: Store
	_, err, lerr, werr := store_open(&s, "store", ofs_ops(fs), target_size = 300)
	if err != .None || lerr != .None || werr != .None {
		return
	}
	defer store_close(&s)
	name: [4][32]byte
	for i in 0 ..< 4 {
		subj := fmt.bprintf(name[i][:], "http://ex/t%d", i)
		ops := [2]Op{
			op(.Assert, rdf.IRI(subj), iri("http://ex/p"), rdf.Literal{lexical = "v", datatype = rdf.XSD_STRING}),
			op(.Retract, iri("http://ex/t0"), iri("http://ex/p"), rdf.Literal{lexical = "v", datatype = rdf.XSD_STRING}),
		}
		e, _, aerr := apply(&s, {ops = ops[:2] if i == 1 else ops[:1]})
		if aerr.kind != .None {
			return
		}
		append(&acked, e)
	}
	return
}

@(test)
test_apply_crash_sweep :: proc(t: ^testing.T) {
	probe: OFS
	probe.budget = 1 << 30
	acked0 := sweep_apply(&probe)
	total := probe.used
	testing.expect_value(t, len(acked0), 4)
	delete(acked0)
	ofs_destroy(&probe)
	testing.expect(t, total > 20, "the script exercises a real spread of operations")

	for half in ([2]bool{false, true}) {
		for cut in 1 ..= total {
			fs: OFS
			fs.budget = cut
			acked := sweep_apply(&fs)
			defer delete(acked)

			durable: OFS
			for &f in fs.files {
				if data, ok := ofs_durable(&fs, f.name, half); ok {
					ofs_seed(&durable, f.name, data)
				}
			}
			ofs_destroy(&fs)
			defer ofs_destroy(&durable)

			// Boot from the durable view: no acknowledged epoch is lost,
			// nothing partial was read, and the next apply continues
			// the chain.
			s: Store
			_, err, lerr, werr := store_open(&s, "store", ofs_ops(&durable), target_size = 300)
			testing.expectf(t, err == .None && lerr == .None && werr == .None, "cut %d half %v: boot %v %v %v", cut, half, err, lerr, werr)
			last := Epoch(0)
			if len(acked) > 0 {
				last = acked[len(acked)-1]
			}
			testing.expectf(t, s.published >= last, "cut %d half %v: acked epoch %d lost (published %d)", cut, half, last, s.published)
			more := [1]Op{op(.Assert, iri("http://ex/after"), iri("http://ex/p"), iri("http://ex/crash"))}
			e, _, aerr := apply(&s, {ops = more[:]})
			testing.expectf(t, aerr.kind == .None && e == s.published && e > last, "cut %d half %v: resumed apply %v", cut, half, aerr)
			resumed := s.published
			store_close(&s)

			// The combined log verifies and replays to the union of both
			// lives.
			col: Sweep_Count
			r, _, verr := replay("store", ofs_ops(&durable), sweep_consumer(&col))
			testing.expectf(t, verr == .None, "cut %d half %v: combined log replay %v", cut, half, verr)
			testing.expect_value(t, Epoch(r.last_epoch), resumed)
			testing.expect_value(t, col.commits, u32(resumed))
		}
	}
}

@(private = "file")
Sweep_Count :: struct {
	commits: u32,
}

@(private = "file")
sweep_consumer :: proc(c: ^Sweep_Count) -> Consumer {
	return {
		data = c,
		commit = proc(data: rawptr, epoch, wall, actor, reason: u64) -> bool {
			(^Sweep_Count)(data).commits += 1
			return true
		},
	}
}

// --- the validation hook (RECORD-T-0016) ----------------------------------

// Probe is a validator that records what it saw: the candidate's
// epoch, whether the changeset's assert and retract are visible in
// the candidate and in the head, whether a term the changeset defines
// resolves in each, and the ops it was handed — and answers with a
// preset verdict.
@(private = "file")
Probe :: struct {
	verdict:          bool,
	calls:            int,
	epoch:            Epoch,
	n_ops:            int,
	kinds:            [8]Op_Kind,
	cand_asserted:    bool, // the asserted quad exists in the candidate
	cand_retracted:   bool, // the retracted quad exists in the candidate
	head_asserted:    bool, // ... and in the head, through store_latest
	head_retracted:   bool,
	cand_new_term:    bool, // a term the changeset defines resolves in the candidate
	head_new_term:    bool, // ... and in the head
	retained:         Snapshot, // the candidate, kept for the identity check after apply
	asserted, retracted: Op,
	new_term:         rdf.Term,
}

@(private = "file")
probe_exists :: proc(snap: Snapshot, q: Op) -> bool {
	p: Pattern
	ok: bool
	if p.s, ok = snapshot_resolve(snap, q.subject); !ok {
		return false
	}
	if p.p, ok = snapshot_resolve(snap, q.predicate); !ok {
		return false
	}
	if p.o, ok = snapshot_resolve(snap, q.object); !ok {
		return false
	}
	p.g = MATCH_DEFAULT_GRAPH
	return snapshot_exists(snap, p, {origin = .Any})
}

@(private = "file")
probe_check :: proc(data: rawptr, candidate: Snapshot, ops: []Resident_Op, allocator: runtime.Allocator) -> bool {
	pr := (^Probe)(data)
	pr.calls += 1
	pr.epoch = candidate.epoch
	pr.n_ops = len(ops)
	for o, i in ops {
		if i < len(pr.kinds) {
			pr.kinds[i] = o.kind
		}
	}
	pr.cand_asserted = probe_exists(candidate, pr.asserted)
	pr.cand_retracted = probe_exists(candidate, pr.retracted)
	_, pr.cand_new_term = snapshot_resolve(candidate, pr.new_term)
	head, herr := store_latest(candidate.store)
	if herr == .None {
		pr.head_asserted = probe_exists(head, pr.asserted)
		pr.head_retracted = probe_exists(head, pr.retracted)
		_, pr.head_new_term = snapshot_resolve(head, pr.new_term)
		snapshot_release(&head)
	}
	pr.retained = candidate
	// The scratch allocator is usable for transient work.
	scratch := make([]byte, 16, allocator)
	delete(scratch, allocator)
	return pr.verdict
}

@(test)
test_apply_validator_sees_the_candidate :: proc(t: ^testing.T) {
	fs: Mem_FS
	defer mem_fs_destroy(&fs)
	pr := Probe{verdict = true}
	s: Store
	at_open(t, &s, mem_file_ops(&fs), validator = Validator{check = probe_check, data = &pr})
	defer store_close(&s)

	alice, knows, bob, carol := iri("http://ex/alice"), iri("http://ex/knows"), iri("http://ex/bob"), iri("http://ex/carol")
	first := [1]Op{op(.Assert, alice, knows, bob)}
	pr.asserted = first[0]
	pr.retracted = op(.Retract, alice, knows, carol) // nothing to retract yet: absent in both views
	pr.new_term = bob
	e1 := at_ok(t, &s, first[:])
	testing.expect_value(t, e1, Epoch(1))
	testing.expect_value(t, pr.calls, 1)
	testing.expect_value(t, pr.epoch, Epoch(1))
	testing.expect_value(t, pr.n_ops, 1)
	testing.expect_value(t, pr.kinds[0], Op_Kind.Assert)
	testing.expect(t, pr.cand_asserted && !pr.head_asserted, "the candidate shows the assert; the head does not")
	testing.expect(t, pr.cand_new_term && !pr.head_new_term, "the candidate resolves the new term; the head does not")
	// On success the candidate became the published set: same set, now
	// held by the store (the hook must not keep its own reference).
	now, _ := store_latest(&s)
	testing.expect(t, now.idx == pr.retained.idx, "the candidate is the published set after a successful apply")
	snapshot_release(&now)

	// Retract bob, assert carol: the candidate shows carol and not bob;
	// the head the other way round.
	second := [2]Op{op(.Retract, alice, knows, bob), op(.Assert, alice, knows, carol)}
	pr.asserted = second[1]
	pr.retracted = second[0]
	pr.new_term = carol
	e2 := at_ok(t, &s, second[:])
	testing.expect_value(t, e2, Epoch(2))
	testing.expect_value(t, pr.calls, 2)
	testing.expect_value(t, pr.epoch, Epoch(2))
	testing.expect_value(t, pr.n_ops, 2)
	testing.expect(t, pr.kinds[0] == .Retract && pr.kinds[1] == .Assert, "the ops arrive in order with their kinds")
	testing.expect(t, pr.cand_asserted && !pr.cand_retracted, "the candidate is the post-state")
	testing.expect(t, !pr.head_asserted && pr.head_retracted, "the head is the pre-state")
	testing.expect(t, pr.cand_new_term && !pr.head_new_term, "the candidate resolves the new term; the head does not")

	// A refused changeset never reaches the hook.
	_, _, err := apply(&s, {ops = second[1:]}) // carol is live: Already_Live
	testing.expect_value(t, err, Apply_Error{.Already_Live, 0})
	testing.expect_value(t, pr.calls, 2)
}

@(test)
test_apply_validator_modes :: proc(t: ^testing.T) {
	// Three stores, one changeset each: A judged false under Enforce,
	// B judged false under Record, C judged true under Enforce. A
	// writes nothing and stays identical to a store that never saw the
	// changeset; B commits with conforms = false; and B's epoch is C's
	// epoch — the log does not record that a judge objected.
	a_fs, b_fs, c_fs, z_fs: Mem_FS
	defer mem_fs_destroy(&a_fs)
	defer mem_fs_destroy(&b_fs)
	defer mem_fs_destroy(&c_fs)
	defer mem_fs_destroy(&z_fs)
	no := Probe{verdict = false}
	yes := Probe{verdict = true}
	a, b, c, z: Store
	at_open(t, &a, mem_file_ops(&a_fs), validator = {probe_check, &no})
	at_open(t, &b, mem_file_ops(&b_fs), validator = {probe_check, &no})
	at_open(t, &c, mem_file_ops(&c_fs), validator = {probe_check, &yes})
	at_open(t, &z, mem_file_ops(&z_fs))
	defer store_close(&a)
	defer store_close(&b)
	defer store_close(&c)
	defer store_close(&z)

	alice, knows, bob := iri("http://ex/alice"), iri("http://ex/knows"), iri("http://ex/bob")
	seed := [1]Op{op(.Assert, alice, knows, bob)}
	for st in ([4]^Store{&a, &b, &c, &z}) {
		_, _, err := apply(st, {ops = seed[:], mode = .Record})
		testing.expect_value(t, err, Apply_Error{})
	}
	log_bytes :: proc(fs: ^Mem_FS) -> (n: int) {
		for f in fs.files {
			n += len(f.data)
		}
		return
	}
	a_log := log_bytes(&a_fs)
	a_head := a.writer.head

	cs := [2]Op{op(.Retract, alice, knows, bob), op(.Assert, bob, knows, rdf.Literal{lexical = "judged"})}
	_, a_conf, a_err := apply(&a, {ops = cs[:], mode = .Enforce})
	testing.expect_value(t, a_err, Apply_Error{.Rejected, -1})
	testing.expect(t, !a_conf, "Enforce: the verdict is reported with the refusal")
	testing.expect_value(t, log_bytes(&a_fs), a_log)
	testing.expect(t, a.writer.head == a_head, "Enforce: nothing was appended")
	testing.expect(t, !a.writer.failed, "a refusal is not a writer failure")
	same_projection(t, &a, &z, walls = false)
	testing.expect(t, at_exists(&a, 1, seed[0]), "the retract was rolled back")
	// A continues normally afterwards.
	_, _, a_again := apply(&a, {ops = cs[:], mode = .Record})
	testing.expect_value(t, a_again, Apply_Error{})

	b_e, b_conf, b_err := apply(&b, {ops = cs[:], mode = .Record})
	testing.expect_value(t, b_err, Apply_Error{})
	testing.expect(t, !b_conf, "Record: the epoch commits and the verdict is reported")
	testing.expect_value(t, b_e, Epoch(2))
	c_e, c_conf, c_err := apply(&c, {ops = cs[:], mode = .Enforce})
	testing.expect_value(t, c_err, Apply_Error{})
	testing.expect(t, c_conf, "Enforce with a conforming changeset commits")
	testing.expect_value(t, c_e, Epoch(2))
	same_projection(t, &b, &c, walls = false)

	// Decision 5: the two logs' epoch-2 commits differ only by their
	// wall clocks — replay B's and C's logs and compare the projections.
	b2, c2: Store
	_, berr, _, _ := store_open(&b2, "store", mem_file_ops(&b_fs))
	_, cerr, _, _ := store_open(&c2, "store", mem_file_ops(&c_fs))
	testing.expect_value(t, berr, Open_Error.None)
	testing.expect_value(t, cerr, Open_Error.None)
	defer store_close(&b2)
	defer store_close(&c2)
	same_projection(t, &b2, &c2, walls = false)
	same_projection(t, &b, &b2)
}

