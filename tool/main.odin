// The auditor's read surface (RECORD-T-0005, log.md par. 12 q6): one
// binary, three subcommands, no logic the library lacks.
//
//	record verify <dir>
//	record head   <dir>
//	record dump [--format=nquads|json] <dir>
//
// verify runs the full chain verification and prints the head hash,
// last epoch, and segment count. head prints the derived head beside
// the advisory HEAD file and warns on stderr when they disagree — HEAD
// is derived and never trusted, so a mismatch is a stale convenience,
// not a failed audit. dump replays the log through a
// dictionary-building consumer and emits every fact operation with its
// terms resolved. All three are read-only; nothing here repairs a torn
// tail — recovery belongs to the store's own open, not to an auditor's
// tools.
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
	case:
		usage()
		code = 1
	}
	os.exit(code)
}

usage :: proc() {
	fmt.eprintln("usage: record verify <dir>")
	fmt.eprintln("       record head <dir>")
	fmt.eprintln("       record dump [--format=nquads|json] <dir>")
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
