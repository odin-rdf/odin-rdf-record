package record

// The three id spaces (RECORD-T-0020), each a distinct type so that the
// compiler keeps them apart. All three are u32 underneath — the resident
// widths api.md par. 3 fixes — and before this file they *were* u32, four
// meanings on one type: a fact id handed to snapshot_term, or an epoch
// where a term id goes, compiled and answered wrongly. Now it does not
// compile. Conversions are explicit and live where the meaning changes —
// the inline-bit test, a chunk index, the u64 widening for the log — and
// nowhere else.
//
// Counts stay u32: n_facts, n_terms, n_epochs are quantities, not
// identities, and comparing an id against its table's size is one of the
// places a conversion is written out on purpose.

// Term_ID names a term residently: a dictionary id (1-based; 0 is "none"
// — the default graph in a fact's G, an absent actor or reason) or, with
// bit 31 set, an inlined literal that lives in the id itself
// (api.md par. 3, RECORD-A-0001). The id a pattern binds, a fact carries,
// snapshot_resolve answers and snapshot_term decodes. Never an index into
// anything a caller holds; a term index sorts them, it is not indexed by
// them.
Term_ID :: distinct u32

// Fact_ID is a fact generation's position in the fact table, 0-based —
// what scan_next yields and snapshot_fact takes; what the six
// permutations hold. It is an index, and the chunked table is where the
// shift-and-mask on it happens.
Fact_ID :: distinct u32

// Epoch numbers a commit: contiguous from 1, 0 being the empty world
// before the first commit (store_at(s, 0)), LIVE_EPOCH the retract field
// of a fact still live. The as-of coordinate — there is no wall-clock
// index; a caller holding a time finds its epoch through
// snapshot_epoch_meta.
Epoch :: distinct u32
