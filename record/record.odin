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
// encoding layer (RECORD-T-0001); writer.odin and writer_os.odin are
// the single-writer append path with its injectable file seam
// (RECORD-T-0002); the open path, replay, and the resident structures
// follow as their tasks land. The CLI (verify, dump, head) will live
// in tool/ at the repository root, following the family's root-level
// main-package pattern.
package record
