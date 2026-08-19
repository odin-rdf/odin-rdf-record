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
// architecture.md for the premises both inherit — and the decisions
// still open before the first record is written are the phase-0 ADRs
// under .metis/adrs/. This package is intentionally empty until those
// are settled: several of them (the inline-term encoding above all,
// api.md par. 3.3) are frozen at first write and cannot be revisited
// by a later version.
package record
