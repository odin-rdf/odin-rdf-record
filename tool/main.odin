// The auditor's read surface (RECORD-T-0005, log.md par. 12 q6): one
// binary, three subcommands, no logic the library lacks.
//
//	rdfrecord verify <dir>
//	rdfrecord head   <dir>
//	rdfrecord dump  [--format=nquads|json] <dir>
//	rdfrecord stats [--format=plain|json] [--prefix=<iri-prefix>] <dir>
//
// verify runs the full chain verification and prints the head hash,
// last epoch, and segment count. head prints the derived head beside
// the advisory HEAD file and warns on stderr when they disagree — HEAD
// is derived and never trusted, so a mismatch is a stale convenience,
// not a failed audit. dump replays the log through a
// dictionary-building consumer and emits every fact operation with its
// terms resolved. stats folds that same walk into a census — live
// facts, the graphs they are in, and how many instances each rdf:type
// class has.
//
// All four are read-only, and that is a constraint rather than an
// observation: none of them opens the store. store_open would answer
// stats in a handful of calls, but it recovers, resumes the writer,
// rewrites HEAD and can append an environment note — an auditor's tool
// must not mutate the thing it is auditing (RECORD-T-0050). Nothing
// here repairs a torn tail either; recovery belongs to the store's own
// open.
//
// Exit codes: 0 clean; 2 a torn tail was found (reported, untouched);
// 1 everything else — a halting verdict, an unreadable store, a usage
// error.
//
// # The dump formats
//
// A dump is a rendering of the log — the sequence of fact operations —
// not an export of the graph they produce: a quad asserted and later
// retracted appears twice, because both events are the record.
//
// nquads: every assert of an underived fact is a plain N-Quads
// statement line, emitted by the parser repo's rdf/quads emitter — the
// format is the W3C's, not ours. A retract is an event, not a quad in
// the graph, so retracts and both derived kinds (which this store's
// writer never emits, RECORD-A-0002, but the format defines) are the
// same emitted statement behind a comment marker:
//
//	<s> <p> <o> <g> .
//	# retract: <s> <p> <o> <g> .
//	# assert-derived: <s> <p> <o> <g> .
//	# retract-derived: <s> <p> <o> <g> .
//
// A strict N-Quads parser reading a dump therefore sees exactly the
// asserted, underived statements.
//
// json: one operation per line (JSON Lines), a deliberately minimal
// shape of our own. Terms are structured rather than re-serialized —
// {"iri": "..."}, {"blank": "..."}, or {"lit": "...", "dt": "...",
// "lang": "..."} (lang only when tagged) — so the only escaping in
// play is JSON's. Each line carries the op kind, its epoch, and the
// epoch's wall/actor/reason: wall is a decimal string because u64
// nanoseconds exceed a JSON number's 2^53 exact range; actor and
// reason are term objects or null; g is a term object or null for the
// default graph. Environment notes and seals are not dumped — dump
// emits fact operations; the chain around them is verify's business.
package main

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"

import rec "../record"
import "rdf:rdf"
import "rdf:rdf/quads"

main :: proc() {
	args := os.args[1:]
	if len(args) < 1 {
		usage()
		os.exit(1)
	}
	code: int
	switch args[0] {
	case "verify":
		code = cmd_verify(args[1:])
	case "head":
		code = cmd_head(args[1:])
	case "dump":
		code = cmd_dump(args[1:])
	case "stats":
		code = cmd_stats(args[1:])
	case:
		usage()
		code = 1
	}
	os.exit(code)
}

usage :: proc() {
	fmt.eprintln("usage: rdfrecord verify <dir>")
	fmt.eprintln("       rdfrecord head <dir>")
	fmt.eprintln("       rdfrecord dump [--format=nquads|json] <dir>")
	fmt.eprintln("       rdfrecord stats [--format=plain|json] [--prefix=<iri-prefix>] <dir>")
}

cmd_verify :: proc(args: []string) -> int {
	if len(args) != 1 {
		usage()
		return 1
	}
	dir := args[0]
	r, tear, err := rec.verify(dir, rec.posix_file_ops())
	#partial switch err {
	case .None, .Torn:
	case:
		fmt.eprintf("verify: %s: %v\n", dir, err)
		return 1
	}
	hex: [rec.HASH_SIZE * 2]u8
	fmt.printf("head:     %s\n", hex_hash(r.head, hex[:]))
	fmt.printf("epoch:    %d\n", r.last_epoch)
	fmt.printf("segments: %d\n", r.segments)
	if err == .Torn {
		fmt.eprintf(
			"verify: %s: torn %v in segment %06d at offset %d (%d bytes) — recoverable, not repaired\n",
			dir, tear.kind, tear.segment, tear.offset, tear.lost,
		)
		return 2
	}
	return 0
}

cmd_head :: proc(args: []string) -> int {
	if len(args) != 1 {
		usage()
		return 1
	}
	dir := args[0]
	r, _, err := rec.verify(dir, rec.posix_file_ops())
	#partial switch err {
	case .None, .Torn:
	case:
		fmt.eprintf("head: %s: %v\n", dir, err)
		return 1
	}
	hex: [rec.HASH_SIZE * 2]u8
	derived := fmt.tprintf("%s %d\n", hex_hash(r.head, hex[:]), r.last_epoch)
	fmt.print(derived)

	head_path := fmt.tprintf("%s/HEAD", dir)
	advisory, aerr := os.read_entire_file_from_path(head_path, context.allocator)
	defer delete(advisory)
	if aerr != nil {
		fmt.eprintf("head: %s: no HEAD file — advisory only, nothing verified against it\n", dir)
	} else if string(advisory) != derived {
		fmt.eprintf("head: %s: HEAD is stale: %q — derived from the segments: %q\n", dir, string(advisory), derived)
	}
	if err == .Torn {
		fmt.eprintf("head: %s: the open segment has a torn tail; the head above is the durable one\n", dir)
		return 2
	}
	return 0
}

hex_hash :: proc(h: [rec.HASH_SIZE]u8, buf: []byte) -> string {
	hex := "0123456789abcdef"
	for b, i in h {
		buf[i*2] = hex[b>>4]
		buf[i*2+1] = hex[b&0xF]
	}
	return string(buf[:rec.HASH_SIZE*2])
}

Format :: enum {
	NQuads,
	JSON,
}

// Dumper is the dump consumer on record's decoded log seam
// (record.Log_Consumer): it interns nothing, resolves nothing and judges
// nothing — log_read verified the chain, accumulated the dictionary and
// decoded the terms — it only prints.
//
// It used to do the resolving too, which is why nine of the package's
// format internals were exported. RECORD-T-0035 moved that loop into
// record, where it is one implementation instead of one per caller.
Dumper :: struct {
	epoch:  u64,
	wall:   u64,
	// The epoch's attribution, cloned because a term handed to a callback
	// is valid for that call and these print once per op. Released and
	// rebuilt at each commit.
	actor:  rdf.Term,
	reason: rdf.Term,
	attrib: mem.Scratch_Allocator,
	format: Format,
	w:      io.Writer,
	fail:   string, // the dumper's own failure, reported after the abort
}

cmd_dump :: proc(args: []string) -> int {
	format := Format.NQuads
	dir := ""
	for a in args {
		switch {
		case a == "--format=nquads":
			format = .NQuads
		case a == "--format=json":
			format = .JSON
		case len(a) > 0 && a[0] == '-':
			usage()
			return 1
		case dir == "":
			dir = a
		case:
			usage()
			return 1
		}
	}
	if dir == "" {
		usage()
		return 1
	}

	buffered: bufio.Writer
	bufio.writer_init(&buffered, os.to_writer(os.stdout))
	defer bufio.writer_destroy(&buffered)

	d := Dumper {
		format = format,
		w      = bufio.writer_to_stream(&buffered),
	}
	mem.scratch_allocator_init(&d.attrib, 1024)
	defer mem.scratch_allocator_destroy(&d.attrib)

	_, tear, err := rec.log_read(dir, rec.posix_file_ops(), rec.Log_Consumer{
		data   = &d,
		commit = dump_commit,
		op     = dump_op,
	})
	bufio.writer_flush(&buffered)

	#partial switch err {
	case .None:
		return 0
	case .Torn:
		fmt.eprintf(
			"dump: %s: torn %v in segment %06d at offset %d — dumped the durable prefix\n",
			dir, tear.kind, tear.segment, tear.offset,
		)
		return 2
	case .Consumer_Abort:
		// d.fail is set when the printer failed. An empty one means
		// log_read itself refused -- a term of a chain-verified log that
		// does not decode, which is corruption the CRC did not catch.
		why := d.fail
		if why == "" {
			why = "a term of the log does not decode"
		}
		fmt.eprintf("dump: %s: %s\n", dir, why)
		return 1
	case:
		fmt.eprintf("dump: %s: %v\n", dir, err)
		return 1
	}
}

dump_commit :: proc(data: rawptr, epoch, wall: u64, actor, reason: rdf.Term) -> bool {
	d := (^Dumper)(data)
	d.epoch = epoch
	d.wall = wall
	free_all(mem.scratch_allocator(&d.attrib))
	a := mem.scratch_allocator(&d.attrib)
	d.actor = rdf.clone_term(actor, a)
	d.reason = rdf.clone_term(reason, a)
	return true
}

dump_op :: proc(data: rawptr, epoch: u64, kind: rec.Op_Kind, q: rdf.Quad) -> bool {
	d := (^Dumper)(data)
	_ = epoch // the commit set it; every op of the epoch shares it
	switch d.format {
	case .NQuads:
		return dump_nquads(d, kind, q)
	case .JSON:
		return dump_json(d, kind, q)
	}
	return false
}

op_marker :: proc(kind: rec.Op_Kind) -> string {
	#partial switch kind {
	case .Retract:
		return "# retract: "
	case .Assert_Derived:
		return "# assert-derived: "
	case .Retract_Derived:
		return "# retract-derived: "
	}
	return ""
}

dump_nquads :: proc(d: ^Dumper, kind: rec.Op_Kind, q: rdf.Quad) -> bool {
	if _, werr := io.write_string(d.w, op_marker(kind)); werr != nil {
		d.fail = "write failed"
		return false
	}
	if quads.emit(d.w, q) != nil {
		d.fail = "write failed"
		return false
	}
	return true
}

op_name :: proc(kind: rec.Op_Kind) -> string {
	#partial switch kind {
	case .Retract:
		return "retract"
	case .Assert_Derived:
		return "assert-derived"
	case .Retract_Derived:
		return "retract-derived"
	}
	return "assert"
}

dump_json :: proc(d: ^Dumper, kind: rec.Op_Kind, q: rdf.Quad) -> bool {
	w := d.w
	s, p, o := q.subject, q.predicate, q.object
	g: rdf.Term
	switch v in q.graph {
	case rdf.IRI:
		g = v
	case rdf.Blank_Node:
		g = v
	case nil:
	}
	ok := true
	ok &&= ws(w, `{"op":"`) && ws(w, op_name(kind)) && ws(w, `","epoch":`)
	ok &&= wu(w, d.epoch)
	ok &&= ws(w, `,"wall":"`) && wu(w, d.wall) && ws(w, `"`)
	ok &&= ws(w, `,"actor":`) && json_attrib(d, d.actor)
	ok &&= ws(w, `,"reason":`) && json_attrib(d, d.reason)
	ok &&= ws(w, `,"s":`) && json_term(w, s)
	ok &&= ws(w, `,"p":`) && json_term(w, p)
	ok &&= ws(w, `,"o":`) && json_term(w, o)
	ok &&= ws(w, `,"g":`)
	if g == nil {
		ok &&= ws(w, "null")
	} else {
		ok &&= json_term(w, g)
	}
	ok &&= ws(w, "}\n")
	if !ok {
		d.fail = "write failed"
	}
	return ok
}

// json_id_term renders an actor or reason: null for none, else the
// dictionary term. log_read hands nil where the log recorded none.
json_attrib :: proc(d: ^Dumper, t: rdf.Term) -> bool {
	if t == nil {
		return ws(d.w, "null")
	}
	return json_term(d.w, t)
}

json_term :: proc(w: io.Writer, t: rdf.Term) -> bool {
	switch v in t {
	case rdf.IRI:
		return ws(w, `{"iri":`) && json_string(w, string(v)) && ws(w, "}")
	case rdf.Blank_Node:
		return ws(w, `{"blank":`) && json_string(w, string(v)) && ws(w, "}")
	case rdf.Literal:
		ok := ws(w, `{"lit":`) && json_string(w, v.lexical)
		ok &&= ws(w, `,"dt":`) && json_string(w, string(v.datatype))
		if v.language != "" {
			ok &&= ws(w, `,"lang":`) && json_string(w, v.language)
		}
		return ok && ws(w, "}")
	case ^rdf.Triple:
		return false // no triple terms in format v1 (tag 0x07 reserved)
	case nil:
		return false
	}
	return false
}

json_string :: proc(w: io.Writer, s: string) -> bool {
	if io.write_byte(w, '"') != nil {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c == '"':
			if _, e := io.write_string(w, `\"`); e != nil {
				return false
			}
		case c == '\\':
			if _, e := io.write_string(w, `\\`); e != nil {
				return false
			}
		case c == '\n':
			if _, e := io.write_string(w, `\n`); e != nil {
				return false
			}
		case c == '\r':
			if _, e := io.write_string(w, `\r`); e != nil {
				return false
			}
		case c == '\t':
			if _, e := io.write_string(w, `\t`); e != nil {
				return false
			}
		case c < 0x20:
			hex := "0123456789abcdef"
			esc := [6]u8{'\\', 'u', '0', '0', hex[c>>4], hex[c&0xF]}
			if _, e := io.write_string(w, string(esc[:])); e != nil {
				return false
			}
		case:
			if io.write_byte(w, c) != nil {
				return false
			}
		}
	}
	return io.write_byte(w, '"') == nil
}

ws :: proc(w: io.Writer, s: string) -> bool {
	_, err := io.write_string(w, s)
	return err == nil
}

wu :: proc(w: io.Writer, v: u64) -> bool {
	buf: [20]u8
	return ws(w, fmt.bprintf(buf[:], "%d", v))
}

// ---------------------------------------------------------------------------
// stats (RECORD-T-0050)
//
// What a store holds, counted from the log and nothing else. `store_open`
// would answer this in a handful of calls -- range_len is O(1) and a
// bound-P match is a prefix read -- but opening a store is not a read: it
// recovers, resumes the writer, rewrites HEAD and appends an environment
// note where the environment differs. Every subcommand here is read-only,
// so stats is a fourth consumer on the same log_read seam dump uses, and
// it folds the live set itself.
//
// The fold is log.md par. 5.3's rule and only that rule: an assert adds
// the quad, a retract removes it. That duplicates, in the tool and over
// owned strings, what the Loader does residently over ids -- deliberately,
// because the tool has no dictionary and no fact table, and because the
// duplication is one line of semantics rather than a re-export of the
// format. Memory is proportional to the ops walked; a store too large to
// count this way is too large to dump either.
//
// Because the fold is the tool's own, it also *sees* the preconditions
// replay does not judge (they are the Loader's): an assert of a quad
// already live, or a retract of one that is not. Those are counted and
// reported rather than folded away silently -- on a sound log both are
// zero, and a nonzero one is a finding.
//
// Facts are keyed by an N-Triples rendering of (s, p, o, g), which is
// injective, and the graph and class censuses are slices into that same
// key, so a census costs no second copy of a term.
//
// rdf:type is the one vocabulary assumption anywhere in this repository,
// and it lives here, where a census is a convenience rather than a
// contract. --prefix restricts it to class IRIs with a given prefix; a
// class that is not an IRI never matches one.
//
// Both output formats carry the same figures. --format=json renders graph
// and class names as N-Triples term strings ("<http://...>", "_:b0",
// "\"x\"@en") rather than bare lexical forms, because a class need not be
// an IRI and a bare string could not say which it was.

Stats_Format :: enum {
	Plain,
	JSON,
}

// Live is one live quad's census data, held as offsets into the map key
// that owns the rendering: [o_lo, o_hi) is the object, [g_lo, g_hi) the
// graph label -- empty for the default graph, which has no rendering.
Stats_Live :: struct {
	o_lo, o_hi: u32,
	g_lo, g_hi: u32,
	is_type:    bool,
}

Stats :: struct {
	live:     map[string]Stats_Live,
	keys:     [dynamic]string, // every key ever cloned, for the free
	sb:       strings.Builder, // the per-op key scratch, reused
	epochs:   u64,
	asserts:  u64,
	retracts: u64,
	derived:  u64,
	dup:      u64, // an assert of a quad already live
	miss:     u64, // a retract of a quad with no live generation
	fail:     string,
}

// Census is one row of either tally, sorted by count descending then by
// name ascending so that the output is deterministic and diffable.
Census :: struct {
	name:  string, // the N-Triples rendering; "" is the default graph
	count: u64,
}

cmd_stats :: proc(args: []string) -> int {
	format := Stats_Format.Plain
	prefix := ""
	has_prefix := false
	dir := ""
	for a in args {
		switch {
		case a == "--format=plain":
			format = .Plain
		case a == "--format=json":
			format = .JSON
		case strings.has_prefix(a, "--prefix="):
			prefix = class_prefix(a[len("--prefix="):])
			has_prefix = true
		case len(a) > 0 && a[0] == '-':
			usage()
			return 1
		case dir == "":
			dir = a
		case:
			usage()
			return 1
		}
	}
	if dir == "" {
		usage()
		return 1
	}

	st: Stats
	st.live = make(map[string]Stats_Live)
	strings.builder_init(&st.sb)
	defer {
		for k in st.keys {
			delete(k)
		}
		delete(st.keys)
		delete(st.live)
		strings.builder_destroy(&st.sb)
	}

	r, tear, err := rec.log_read(dir, rec.posix_file_ops(), rec.Log_Consumer{
		data   = &st,
		commit = stats_commit,
		op     = stats_op,
	})
	#partial switch err {
	case .None, .Torn:
	case .Consumer_Abort:
		why := st.fail
		if why == "" {
			why = "a term of the log does not decode"
		}
		fmt.eprintf("stats: %s: %s\n", dir, why)
		return 1
	case:
		fmt.eprintf("stats: %s: %v\n", dir, err)
		return 1
	}

	graphs := census_graphs(&st)
	defer delete(graphs)
	classes, class_total := census_classes(&st, prefix, has_prefix)
	defer delete(classes)

	buffered: bufio.Writer
	bufio.writer_init(&buffered, os.to_writer(os.stdout))
	defer bufio.writer_destroy(&buffered)
	w := bufio.writer_to_stream(&buffered)

	switch format {
	case .Plain:
		stats_plain(w, &st, r, graphs, classes, class_total, prefix, has_prefix, err == .Torn)
	case .JSON:
		stats_json(w, &st, r, graphs, classes, class_total, prefix, has_prefix, err == .Torn)
	}
	bufio.writer_flush(&buffered)

	if err == .Torn {
		fmt.eprintf(
			"stats: %s: torn %v in segment %06d at offset %d — counted the durable prefix\n",
			dir, tear.kind, tear.segment, tear.offset,
		)
		return 2
	}
	return 0
}

// class_prefix takes the --prefix argument as the user wrote it. An IRI
// is commonly written in angle brackets, and a prefix of one reads
// naturally that way too, so a leading `<` (and a trailing `>`) is
// stripped: the match is against the IRI's own characters.
class_prefix :: proc(arg: string) -> string {
	s := arg
	if len(s) > 0 && s[0] == '<' {
		s = s[1:]
	}
	if len(s) > 0 && s[len(s)-1] == '>' {
		s = s[:len(s)-1]
	}
	return s
}

stats_commit :: proc(data: rawptr, epoch, wall: u64, actor, reason: rdf.Term) -> bool {
	st := (^Stats)(data)
	_, _, _ = wall, actor, reason
	_ = epoch
	st.epochs += 1
	return true
}

stats_op :: proc(data: rawptr, epoch: u64, kind: rec.Op_Kind, q: rdf.Quad) -> bool {
	st := (^Stats)(data)
	_ = epoch
	key, live, ok := stats_render(st, q)
	if !ok {
		st.fail = "a term of the log does not render"
		return false
	}
	#partial switch kind {
	case .Assert, .Assert_Derived:
		st.asserts += 1
		if kind == .Assert_Derived {
			st.derived += 1
		}
		if key in st.live {
			st.dup += 1
			return true // the first generation stands; the key is not re-owned
		}
		owned := strings.clone(key)
		append(&st.keys, owned)
		st.live[owned] = live
	case .Retract, .Retract_Derived:
		st.retracts += 1
		if !(key in st.live) {
			st.miss += 1
			return true
		}
		delete_key(&st.live, key)
	}
	return true
}

// stats_render builds the fact's key in the reused builder and returns
// it borrowed -- valid until the next op, which is exactly as long as
// the caller needs it to decide whether to clone. The offsets it reports
// are into the key, so they survive the clone unchanged.
stats_render :: proc(st: ^Stats, q: rdf.Quad) -> (key: string, live: Stats_Live, ok: bool) {
	strings.builder_reset(&st.sb)
	w := strings.to_writer(&st.sb)
	if !nt_term(w, q.subject) {
		return "", {}, false
	}
	if !ws(w, " ") || !nt_term(w, q.predicate) || !ws(w, " ") {
		return "", {}, false
	}
	live.o_lo = u32(strings.builder_len(st.sb))
	if !nt_term(w, q.object) {
		return "", {}, false
	}
	live.o_hi = u32(strings.builder_len(st.sb))
	if !ws(w, " ") {
		return "", {}, false
	}
	live.g_lo = u32(strings.builder_len(st.sb))
	switch v in q.graph {
	case rdf.IRI:
		if !nt_term(w, v) {
			return "", {}, false
		}
	case rdf.Blank_Node:
		if !nt_term(w, v) {
			return "", {}, false
		}
	case nil: // the default graph renders as nothing, which no label does
	}
	live.g_hi = u32(strings.builder_len(st.sb))
	if iri, is_iri := q.predicate.(rdf.IRI); is_iri {
		live.is_type = string(iri) == string(rdf.RDF_TYPE)
	}
	return strings.to_string(st.sb), live, true
}

census_graphs :: proc(st: ^Stats) -> []Census {
	tally := make(map[string]u64)
	defer delete(tally)
	for k, v in st.live {
		tally[k[v.g_lo:v.g_hi]] += 1
	}
	return census_sorted(tally)
}

// census_classes tallies the object of every live rdf:type fact.
// `total` is the count before the prefix filter, so the plain output can
// say "3 of 137" rather than leave the filter's effect invisible.
census_classes :: proc(st: ^Stats, prefix: string, has_prefix: bool) -> (rows: []Census, total: int) {
	tally := make(map[string]u64)
	defer delete(tally)
	all := make(map[string]bool)
	defer delete(all)
	for k, v in st.live {
		if !v.is_type {
			continue
		}
		name := k[v.o_lo:v.o_hi]
		all[name] = true
		if has_prefix {
			// A class that is not an IRI has no prefix to match: the
			// rendering of every other kind starts with something else.
			if len(name) == 0 || name[0] != '<' || !strings.has_prefix(name[1:], prefix) {
				continue
			}
		}
		tally[name] += 1
	}
	return census_sorted(tally), len(all)
}

census_sorted :: proc(tally: map[string]u64) -> []Census {
	rows := make([]Census, len(tally))
	i := 0
	for name, count in tally {
		rows[i] = Census{name = name, count = count}
		i += 1
	}
	slice.sort_by(rows, proc(a, b: Census) -> bool {
		if a.count != b.count {
			return a.count > b.count
		}
		return a.name < b.name
	})
	return rows
}

stats_plain :: proc(
	w: io.Writer,
	st: ^Stats,
	r: rec.Verify_Result,
	graphs, classes: []Census,
	class_total: int,
	prefix: string,
	has_prefix, torn: bool,
) {
	hex: [rec.HASH_SIZE * 2]u8
	fmt.wprintf(w, "head:      %s\n", hex_hash(r.head, hex[:]))
	fmt.wprintf(w, "epoch:     %d\n", r.last_epoch)
	fmt.wprintf(w, "segments:  %d\n", r.segments)
	fmt.wprintf(w, "terms:     %d\n", r.next_term_id - 1)
	fmt.wprintf(w, "epochs:    %d\n", st.epochs)
	fmt.wprintf(w, "asserts:   %d\n", st.asserts)
	fmt.wprintf(w, "retracts:  %d\n", st.retracts)
	fmt.wprintf(w, "derived:   %d\n", st.derived)
	fmt.wprintf(w, "facts:     %d\n", len(st.live))
	if torn {
		fmt.wprintf(w, "torn:      yes — the figures above are the durable prefix\n")
	}
	if st.dup != 0 || st.miss != 0 {
		fmt.wprintf(
			w,
			"anomalies: %d duplicate asserts, %d retracts of no live fact (log.md par. 5.3)\n",
			st.dup, st.miss,
		)
	}

	fmt.wprintf(w, "\ngraphs: %d\n", len(graphs))
	for row in graphs {
		census_row(w, row.count, census_label(row.name))
	}

	if has_prefix {
		fmt.wprintf(w, "\nclasses: %d of %d (rdf:type objects with prefix %q)\n", len(classes), class_total, prefix)
	} else {
		fmt.wprintf(w, "\nclasses: %d (rdf:type objects)\n", len(classes))
	}
	for row in classes {
		census_row(w, row.count, row.name)
	}
}

// census_row prints one census line as `uniq -c` does: a right-aligned
// count, two spaces, the name. The padding is spelled out because Odin's
// %10d pads with zeros, which would read as part of the number.
census_row :: proc(w: io.Writer, count: u64, name: string) {
	digits := fmt.tprintf("%d", count)
	for _ in len(digits) ..< 10 {
		io.write_byte(w, ' ')
	}
	fmt.wprintf(w, "%s  %s\n", digits, name)
}

// census_label names the default graph in the plain output. The empty
// rendering is unambiguous in the data -- no label renders as nothing --
// but it is not readable, and the JSON form says null instead.
census_label :: proc(name: string) -> string {
	return "(default graph)" if name == "" else name
}

stats_json :: proc(
	w: io.Writer,
	st: ^Stats,
	r: rec.Verify_Result,
	graphs, classes: []Census,
	class_total: int,
	prefix: string,
	has_prefix, torn: bool,
) {
	hex: [rec.HASH_SIZE * 2]u8
	fmt.wprintf(w, `{{"head":"%s"`, hex_hash(r.head, hex[:]))
	fmt.wprintf(w, `,"epoch":%d,"segments":%d,"terms":%d`, r.last_epoch, r.segments, r.next_term_id - 1)
	fmt.wprintf(w, `,"epochs":%d`, st.epochs)
	fmt.wprintf(
		w,
		`,"ops":{{"assert":%d,"retract":%d,"derived":%d}}`,
		st.asserts, st.retracts, st.derived,
	)
	fmt.wprintf(w, `,"facts":%d`, len(st.live))
	fmt.wprintf(w, `,"torn":%s`, "true" if torn else "false")
	fmt.wprintf(
		w,
		`,"anomalies":{{"duplicate_assert":%d,"retract_not_live":%d}}`,
		st.dup, st.miss,
	)

	ws(w, `,"graphs":[`)
	for row, i in graphs {
		if i > 0 {
			ws(w, ",")
		}
		ws(w, `{"graph":`)
		if row.name == "" {
			ws(w, "null")
		} else {
			json_string(w, row.name)
		}
		fmt.wprintf(w, `,"facts":%d}}`, row.count)
	}
	ws(w, "]")

	ws(w, `,"classes":{"prefix":`)
	if has_prefix {
		json_string(w, prefix)
	} else {
		ws(w, "null")
	}
	fmt.wprintf(w, `,"distinct":%d,"distinct_total":%d,"counts":[`, len(classes), class_total)
	for row, i in classes {
		if i > 0 {
			ws(w, ",")
		}
		ws(w, `{"class":`)
		json_string(w, row.name)
		fmt.wprintf(w, `,"instances":%d}}`, row.count)
	}
	ws(w, "]}")

	ws(w, "}\n")
}

// ---------------------------------------------------------------------------
// N-Triples term rendering.
//
// The key's job is injectivity -- two distinct quads must never render
// alike -- and the census's job is readability, and N-Triples syntax is
// the one rendering that serves both. It is written here rather than
// taken from the parser repo because rdf/quads emits whole statements and
// its per-term writer is internal to that package; a term at a time is
// what a key needs.

nt_term :: proc(w: io.Writer, t: rdf.Term) -> bool {
	switch v in t {
	case rdf.IRI:
		return nt_iri(w, string(v))
	case rdf.Blank_Node:
		return ws(w, "_:") && ws(w, string(v))
	case rdf.Literal:
		if !nt_quoted(w, v.lexical) {
			return false
		}
		if v.language != "" {
			// The direction is part of the term's identity (RDF 1.2) and
			// so must be part of the key: "x"@en--ltr, the N-Triples form.
			ok := ws(w, "@") && ws(w, v.language)
			switch v.direction {
			case .None:
			case .LTR:
				ok &&= ws(w, "--ltr")
			case .RTL:
				ok &&= ws(w, "--rtl")
			}
			return ok
		}
		return ws(w, "^^") && nt_iri(w, string(v.datatype))
	case ^rdf.Triple:
		if v == nil {
			return false
		}
		ok := ws(w, "<<(") && nt_term(w, v.subject) && ws(w, " ")
		ok &&= nt_term(w, v.predicate) && ws(w, " ")
		ok &&= nt_term(w, v.object) && ws(w, ")>>")
		return ok
	case nil:
		return false
	}
	return false
}

// nt_iri escapes what N-Triples forbids inside IRIREF, which is also
// exactly what injectivity needs: an unescaped `>` would let one IRI
// render as another term's rendering.
nt_iri :: proc(w: io.Writer, s: string) -> bool {
	if io.write_byte(w, '<') != nil {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case 0x00 ..= 0x20, '<', '>', '"', '{', '}', '|', '^', '`', '\\':
			if !nt_uescape(w, c) {
				return false
			}
		case:
			if io.write_byte(w, c) != nil {
				return false
			}
		}
	}
	return io.write_byte(w, '>') == nil
}

nt_quoted :: proc(w: io.Writer, s: string) -> bool {
	if io.write_byte(w, '"') != nil {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		esc: string
		switch c {
		case '"':
			esc = `\"`
		case '\\':
			esc = `\\`
		case '\n':
			esc = `\n`
		case '\r':
			esc = `\r`
		case '\t':
			esc = `\t`
		case:
			if c < 0x20 {
				if !nt_uescape(w, c) {
					return false
				}
			} else if io.write_byte(w, c) != nil {
				return false
			}
			continue
		}
		if _, e := io.write_string(w, esc); e != nil {
			return false
		}
	}
	return io.write_byte(w, '"') == nil
}

nt_uescape :: proc(w: io.Writer, c: u8) -> bool {
	hex := "0123456789ABCDEF"
	esc := [6]u8{'\\', 'u', '0', '0', hex[c>>4], hex[c&0xF]}
	_, e := io.write_string(w, string(esc[:]))
	return e == nil
}
