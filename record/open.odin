// The open path (RECORD-T-0003): log.md par. 6's verification walk and
// par. 7.2's torn-tail recovery. This is the code that runs at every
// open — segments in order, every header validated, every base hash
// checked by equality against the previous segment's head, the SHA-256
// chain over commits and environment notes, epoch contiguity — and it
// is deliberately small enough to read against the document side by
// side, because the independent Python verifier (RECORD-T-0006) must
// agree with it verdict for verdict.
//
// # The position rule
//
// A CRC mismatch is ambiguous between "torn write" and "someone edited
// the file", and the two want different responses (par. 7.2). The
// distinguishing evidence is position: a torn write can only be the
// final record of the open segment. A failure anywhere in a sealed
// segment halts as corruption; so does one in the open segment that is
// provably not final — a CRC-failed frame whose own length field says
// it ends before the file does, since the writer is fail-stop and
// never appends past a failed append. Only the true tail may be
// truncated, and the truncation is surfaced as a returned Tear, never
// swallowed: in a system of record a truncation is an event someone
// should look at.
//
// # verify is read-only; recover repairs
//
// verify walks and judges, touching nothing — it is what the CLI and
// an auditor run. recover is verify plus the one repair the format
// allows: truncate the torn tail (fsync), or remove a final segment
// whose header never became durable — the rotation-crash husk, a file
// created whose 64 header bytes were never synced. Everything sealed
// is immutable to both.
package record

// Open_Error is the open path's verdict taxonomy. Clean is None; Torn
// is verify's report of a recoverable tear (recover converts it into
// the repair); everything else halts, because it is evidence of
// corruption or tampering that truncation would destroy.
Open_Error :: enum {
	None,
	No_Store,           // segment 000001.rlog is absent — nothing to open
	IO_Read,            // a segment exists but could not be read
	IO_Recover,         // recover could not truncate or remove
	Bad_Header,         // a header that fails to decode, or disagrees with the walk
	Base_Hash_Mismatch, // a base hash that is not the previous segment's head
	Corrupt,            // a damaged or unknown record outside the one recoverable position
	Chain_Broken,       // a prev_hash or hash that does not verify (log.md par. 6)
	Epoch_Gap,          // a commit whose epoch is not last_epoch + 1
	Torn,               // verify only: a recoverable tear, located by the Tear
}

// Tear_Kind classifies the recoverable crash artifacts. Tail is
// par. 7.2's torn tail: the final record of the open segment never
// became durable. Header is the rotation-crash husk: the open segment
// file exists but its header never became durable, so the segment
// never durably opened at all.
Tear_Kind :: enum {
	None,
	Tail,
	Header,
}

// Tear locates what recovery cuts. It is the surfaced event: verify
// returns it with .Torn and touches nothing; recover returns it with
// the repair applied, for the caller to log, alert on, and count.
Tear :: struct {
	segment: u32,
	kind:    Tear_Kind,
	offset:  int, // where the bad record starts; the post-truncation size
	lost:    int, // bytes past offset that the repair discards
}

// Verify_Result is the state of the durable log: log.md par. 6's
// returns — the head hash, which is what gets published, and the last
// epoch — plus the walk's running counters, which are exactly what
// resuming the writer needs (RECORD-T-0004). When a tear is reported,
// every field describes the log as recovery would leave it. On a
// halting error the fields hold whatever the walk had reached and mean
// nothing more than that.
Verify_Result :: struct {
	head:         [HASH_SIZE]u8, // hash of the last chained record; zero if none
	last_epoch:   u64,
	segments:     u32, // segment count; the tail segment's number
	next_term_id: u64, // 1 + term definitions seen (first-appearance order)
	fact_count:   u32, // asserts seen — the fact-ID high-water mark
	tail_size:    int, // durable bytes in the tail segment
	tail_records: u64, // epoch commits in the tail segment (seal bookkeeping)
	tail_sealed:  bool, // the tail segment's last record is a seal
}

// verify is log.md par. 6's one sequential pass, strictly read-only:
// framing and CRCs, header cross-checks, base-hash equality across
// segments, the hash chain over commits and notes, epoch contiguity.
// Seals are read — their structure must decode and their frame CRC
// must hold — but not chained, per par. 5.4. A recoverable tear is
// reported as .Torn with its location in `tear` and the file left
// untouched; `r` then describes the log as recovery would leave it.
verify :: proc(
	dir: string,
	ops: File_Ops,
	allocator := context.allocator,
) -> (
	r: Verify_Result,
	tear: Tear,
	err: Open_Error,
) {
	r.next_term_id = 1 // id 0 is "none" and is never allocated

	path_buf: [512]u8
	contents, status := ops.read(ops.data, segment_path(path_buf[:], dir, 1), allocator)
	if status == .Error {
		return r, tear, .IO_Read
	}
	if status == .Absent {
		return r, tear, .No_Store
	}

	// The tail segment's stats one segment back, in case the final
	// file turns out to be a husk and the log really ends before it.
	prev_size: int
	prev_records: u64
	prev_sealed: bool

	for seg_no := u32(1); ; seg_no += 1 {
		r.segments = seg_no

		// One-file lookahead decides finality: segment numbering is
		// contiguous by construction, so the first absent file ends
		// the log — and the position rule needs to know whether a
		// later segment exists before judging this one.
		next, nstatus := ops.read(ops.data, segment_path(path_buf[:], dir, seg_no+1), allocator)
		if nstatus == .Error {
			delete(contents, allocator)
			return r, tear, .IO_Read
		}
		final := nstatus == .Absent

		size: int
		records: u64
		sealed: bool
		size, records, sealed, tear, err = walk_segment(&r, contents, seg_no, final)
		delete(contents, allocator)
		if err != .None {
			delete(next, allocator)
			return r, tear, err
		}

		switch tear.kind {
		case .Header:
			// The final segment never durably opened: the log ends at
			// the previous segment, which rotation sealed before this
			// file could exist.
			r.segments = seg_no - 1
			r.tail_size = prev_size
			r.tail_records = prev_records
			r.tail_sealed = prev_sealed
			return r, tear, .Torn
		case .Tail:
			r.tail_size = tear.offset
			r.tail_records = records
			r.tail_sealed = sealed
			return r, tear, .Torn
		case .None:
		}

		if final {
			r.tail_size = size
			r.tail_records = records
			r.tail_sealed = sealed
			return r, tear, .None
		}
		prev_size = size
		prev_records = records
		prev_sealed = sealed
		contents = next
	}
}

// recover is verify plus par. 7.2's repair: truncate a torn tail to
// the bad record's start offset and fsync, or remove a husk and fsync
// the directory. The applied repair is surfaced in `tear` — never
// silent. Removing a segment-1 husk leaves no store, and .No_Store
// says so. Halting verdicts pass through untouched: everything that is
// not the one recoverable position is evidence, not debris.
recover :: proc(
	dir: string,
	ops: File_Ops,
	allocator := context.allocator,
) -> (
	r: Verify_Result,
	tear: Tear,
	err: Open_Error,
) {
	r, tear, err = verify(dir, ops, allocator)
	if err != .Torn {
		return r, tear, err
	}
	path_buf: [512]u8
	path := segment_path(path_buf[:], dir, tear.segment)
	switch tear.kind {
	case .Tail:
		if !ops.truncate(ops.data, path, tear.offset) {
			return r, tear, .IO_Recover
		}
		err = .None
	case .Header:
		if !ops.remove(ops.data, path) {
			return r, tear, .IO_Recover
		}
		if !ops.sync_dir(ops.data, dir) {
			return r, tear, .IO_Recover
		}
		err = .No_Store if tear.segment == 1 else .None
	case .None:
		// unreachable: .Torn always carries a located tear
	}
	return r, tear, err
}

// walk_segment verifies one segment against the walk's running state,
// advancing it record by record. `final` is the position rule's input:
// only the final segment may report a Tear; the same damage anywhere
// else is a halting verdict.
@(private)
walk_segment :: proc(
	r: ^Verify_Result,
	data: []byte,
	seg_no: u32,
	final: bool,
) -> (
	size: int,
	records: u64,
	sealed: bool,
	tear: Tear,
	err: Open_Error,
) {
	hdr, herr := header_decode(data)
	if herr != .None {
		// The rotation-crash husk: the final segment's 64 header bytes
		// never became durable — the file is shorter than a header, or
		// exactly one whose magic or CRC fails. A valid header carrying
		// an unknown version is a future format, never a husk; and a
		// bad header with records after it cannot be a create crash,
		// because the writer appends nothing until the header's fsync
		// has returned.
		if final && len(data) <= HEADER_SIZE && herr != .Bad_Version {
			return size, records, sealed, Tear{segment = seg_no, kind = .Header, lost = len(data)}, .None
		}
		return size, records, sealed, tear, .Bad_Header
	}
	// The header's positional fields are redundant with the walk —
	// which is why they are checkable, the same way the base hash is:
	// by equality against state the chain already determines.
	if hdr.segment != seg_no || hdr.first_epoch != r.last_epoch+1 || hdr.first_fact_id != r.fact_count {
		return size, records, sealed, tear, .Bad_Header
	}
	if hdr.base_hash != r.head {
		return size, records, sealed, tear, .Base_Hash_Mismatch
	}

	offset := HEADER_SIZE
	rest := data[HEADER_SIZE:]
	scan: for {
		body, next_rest, status := frame_next(rest)
		switch status {
		case .Clean_End:
			if len(rest) == 0 {
				break scan
			}
			// 1..7 trailing bytes: a partial frame header. In the open
			// segment that is a torn append; anywhere sealed it is
			// corruption, like every other tear.
			if final {
				return size, records, sealed, Tear{segment = seg_no, kind = .Tail, offset = offset, lost = len(rest)}, .None
			}
			return size, records, sealed, tear, .Corrupt
		case .Torn:
			if !final {
				return size, records, sealed, tear, .Corrupt
			}
			// The position rule's refinement: if the frame's length
			// field is plausible and its extent ends before the file
			// does, this cannot be a torn append — the writer is
			// fail-stop and never writes past a failed append — so it
			// is evidence, and truncating it would destroy it.
			if len(rest) >= FRAME_OVERHEAD {
				length := int(get_u32(rest))
				if length >= 1 && length <= MAX_RECORD_SIZE &&
				   length <= len(rest)-FRAME_OVERHEAD &&
				   FRAME_OVERHEAD+length < len(rest) {
					return size, records, sealed, tear, .Corrupt
				}
			}
			return size, records, sealed, Tear{segment = seg_no, kind = .Tail, offset = offset, lost = len(rest)}, .None
		case .Ok:
		}

		kind, known := record_kind(body)
		if !known {
			// An unknown kind fails, never skips (log.md par. 4) — and
			// it is never torn, because its frame CRC just verified:
			// these bytes were fully written by something that was not
			// our writer.
			return size, records, sealed, tear, .Corrupt
		}
		#partial switch kind {
		case .Epoch_Commit:
			v, derr := commit_decode(body)
			if derr != .None {
				return size, records, sealed, tear, .Corrupt
			}
			if v.epoch != r.last_epoch+1 {
				return size, records, sealed, tear, .Epoch_Gap
			}
			if v.prev_hash != r.head {
				return size, records, sealed, tear, .Chain_Broken
			}
			if chain_hash(body) != v.hash {
				return size, records, sealed, tear, .Chain_Broken
			}
			r.head = v.hash
			r.last_epoch = v.epoch
			r.next_term_id += u64(v.n_terms)
			it := commit_ops(v)
			for op in op_next(&it) {
				if op.op == .Assert || op.op == .Assert_Derived {
					r.fact_count += 1
				}
			}
			records += 1
			sealed = false
		case .Environment_Note:
			v, derr := note_decode(body)
			if derr != .None {
				return size, records, sealed, tear, .Corrupt
			}
			if v.prev_hash != r.head {
				return size, records, sealed, tear, .Chain_Broken
			}
			if chain_hash(body) != v.hash {
				return size, records, sealed, tear, .Chain_Broken
			}
			r.head = v.hash
			sealed = false
		case .Segment_Seal:
			// Read but not chained (log.md par. 5.4): the structure
			// must decode — a seal that does not parse is corruption —
			// but its values are a summary nothing downstream trusts.
			if _, derr := seal_decode(body); derr != .None {
				return size, records, sealed, tear, .Corrupt
			}
			sealed = true
		}
		offset += FRAME_OVERHEAD + len(body)
		rest = next_rest
	}
	return len(data), records, sealed, tear, .None
}
