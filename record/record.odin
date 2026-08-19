// The system of record: an append-only, hash-chained, segmented log as
// the single durable representation of an RDF dataset, and a
// memory-resident projection — fact table, dictionary arena, sorted
// permutations — rebuilt from it by replay on every start. Nothing is
// ever updated in place, and nothing durable exists that the log does
// not determine: the running store is a cache of the record, never a
// second authority.
//
// The design is specified in doc/design/ — log.md for the on-disk
// format, api.md for the resident layout and the pattern-matching API,
// architecture.md for the premises both inherit — and the phase-0
// decisions are the ADRs under .metis/adrs/, all decided before the
// first byte of code because several (the inline-term encoding above
// all, RECORD-A-0001) are frozen at first write.
//
// The package is one deliberate unit rather than a log subpackage and
// a store subpackage: consumers import `record` and nothing else, and
// the log and the resident store are two halves of one design — the
// log determines everything resident, so an internal package boundary
// would only force internals into a public surface. Files map to the
// initiative's tasks: encode.odin and crc32c.odin are the pure
// encoding layer (RECORD-T-0001); writer.odin and writer_posix.odin are
// the single-writer append path with its injectable file seam
// (RECORD-T-0002); open.odin is the open path — chain verification and
// torn-tail recovery (RECORD-T-0003); replay.odin streams the verified
// log to a consumer procedure set, the seam the resident store binds
// to (RECORD-T-0004); resident.odin is the resident layout — the fact
// table, the dictionary arena, the epoch table — and load.odin the
// Loader that fills it from the replay seam (RECORD-T-0007);
// permute.odin is the six sorted permutations, radix-built after
// replay (RECORD-T-0008); snapshot.odin is publication and the
// refcounted read handle — Index_Set, Latest/At, the epoch discipline
// (RECORD-T-0009); read.odin is the pattern-matching read API — Match,
// Iter, Resolve, Bytes, Term (RECORD-T-0010); boot.odin is store_open,
// the composition of all of it — recover, replay, sort, publish,
// writer resume, and the startup environment note (RECORD-T-0011). The
// CLI
// (verify, dump, head) lives in tool/ at the repository root,
// following the family's root-level main-package pattern.
package record
