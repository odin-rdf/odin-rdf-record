---
id: the-stats-command-what-the-log
level: task
title: "The stats command: what the log says the store holds, without opening it for write"
short_code: "RECORD-T-0050"
created_at: 2026-09-06T19:51:45.232449+00:00
updated_at: 2026-09-06T19:51:45.232449+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#feature"


exit_criteria_met: false
initiative_id: NULL
---

# The stats command: what the log says the store holds, without opening it for write

## Objective

Add `rdfrecord stats <dir>` to `tool/main.odin`: live fact count, distinct
graphs, and a per-class census of `rdf:type` objects, in `--format=plain`
(default) and `--format=json`, with `--prefix=<iri-prefix>` to restrict the
class census.

## Backlog Item Details

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P2 - Medium (nice to have)

### Business Justification
- **User Value**: "what is actually in this store" is the first question anyone
  asks of a store directory, and today the only answer is `dump | wc -l`, which
  counts *operations* rather than facts and cannot tell an asserted fact from
  one asserted and later retracted.
- **Business Value**: JSON output makes it a building block rather than a
  terminal read -- odin-rdf-app and any operator script can consume it.
- **Effort Estimate**: S

## Acceptance Criteria

- [ ] `rdfrecord stats <dir>` prints head, segments, terms, epochs, op totals,
      live facts, a graph count and a class census.
- [ ] `--format=json` prints one JSON object with the same figures; `--format=plain`
      is the default and is the documented human form.
- [ ] `--prefix=<s>` restricts the class census to class IRIs with that prefix,
      and the JSON output states the prefix it applied.
- [ ] The class census is sorted by count descending, then by name ascending, so
      the output is deterministic and diffable.
- [ ] **Read-only**: the command opens no writer, stamps no `HEAD`, appends no
      environment note. Exit codes match the existing three: 0 clean, 2 torn
      tail, 1 otherwise.
- [ ] A precondition anomaly the log-level walk can see (a duplicate assert, a
      retract of a quad with no live generation) is counted and reported rather
      than silently folded away.
- [ ] Tests in `record/tool_test.odin` alongside the existing CLI tests.

## Implementation Notes

### Technical Approach

**The source of the numbers is `log_read`, not `store_open`** -- decided with the
owner, 2026-09-06. `store_open` would answer all three exactly and nearly for
free (`range_len` is O(1), `snapshot_match` on a bound P is a prefix read), but
it is not a read: it recovers, resumes the writer, rewrites `HEAD`
unconditionally, and appends a startup environment note where the environment
differs. The CLI's header promises every subcommand is read-only, and an
auditor's tool that mutates the thing it is auditing is the wrong trade for a
faster count -- doubly so with RECORD-T-0037 about to make the open path compare
an anchor before it overwrites. So `stats` is a fourth `Log_Consumer` beside
`Dumper`, on the same seam `dump` uses.

The cost of that choice, stated so it is not rediscovered: the fold that the
`Loader` does residently (log.md par. 8's live map) is done again in `tool/`, over
owned string keys rather than resident ids, because the tool has no dictionary and
no fact table. At ISMS scale (4x10^5 ops) that is a map of ~4x10^5 keys averaging
~120 bytes -- tens of MB, transient, in a short-lived process. This is a
*deliberate* second implementation of one narrow rule (assert adds, retract
removes), not a re-export of format internals: it names nothing private, and
RECORD-T-0035's finding -- that the CLI should stop reassembling the *format* by
hand -- is not violated, since `log_read` still owns the dictionary, the decode
and the term resolution.

**The key.** A fact is its quad, so the fold keys on an injective rendering of
`(s, p, o, g)` in N-Triples-ish syntax, built once per op into a builder and
owned by the map. The object and graph are recorded as offsets into that same
allocation, so the censuses cost no second copy and print directly.

**`rdf:type` is a vocabulary assumption**, and the only one this package makes
anywhere. It is confined to the tool, where a census is a convenience rather
than a contract, and it is stated in the usage banner.

### Dependencies

`rec.log_read`, `rec.Log_Consumer`, `rec.Op_Kind`, `rec.posix_file_ops`,
`rdf.RDF_TYPE`. Nothing new is exported from `record`; `doc/api-surface.txt` is
unchanged.

### Risk Considerations

Memory is proportional to the live set rather than to the log, which is the
right bound but is still unbounded from the tool's side. Noted, not mitigated:
a store too large to count this way is a store too large to `dump` either.

## Status Updates

**2026-09-06 — done.** `rdfrecord stats [--format=plain|json] [--prefix=<iri>] <dir>`
is in `tool/main.odin`, a fourth `Log_Consumer` beside `Dumper`, and
`record/tool_test.odin` gained `test_tool_stats` over its own store (three
asserts, one retract, two classes in two namespaces, two graphs) asserting both
formats byte for byte, the prefix filter with and without angle brackets, the
torn-tail path, and the two exit-1 cases. `make check` (74 exported names,
unchanged) and `make test` green.

Every acceptance criterion is met. Notes on what the implementation decided:

- **The censuses are slices into the fact key.** The key is an N-Triples
  rendering of `(s, p, o, g)` -- injective, and readable, which is why it is
  also what the censuses print. `Stats_Live` holds the object's and graph
  label's offsets into it, so a census costs no second copy. The N-Triples term
  writer is the tool's own: `rdf/quads` emits whole statements and its per-term
  writer is internal to that package.
- **The default graph renders as nothing**, which no graph label does, so the
  empty rendering is unambiguous in the data. It prints as `(default graph)`
  and serializes as JSON `null`.
- **A literal's base direction is in the key** (`"x"@en--ltr`): it is part of
  an RDF 1.2 term's identity, so two facts differing only in it are two facts.
- **JSON names graphs and classes as N-Triples term strings**, not bare lexical
  forms, because a class need not be an IRI and a bare string could not say
  which it was. `--prefix` matches the IRI's own characters and a class that is
  not an IRI never matches one; a leading `<` and trailing `>` in the argument
  are stripped, since a prefix of an IRI reads naturally in brackets.
- **Anomalies are counted.** The preconditions of log.md par. 5.3 are the
  `Loader`'s and not `replay`'s, so this fold is the only thing in the CLI that
  can see a duplicate assert or a retract of no live fact. Both are tallied and
  reported (plain: a line only when nonzero; JSON: always). On a sound log both
  are zero, and a nonzero one is a finding.

**Measured**, optimized build over `build/scale/bulk` (4x10^5 ops, 8.1x10^4
terms, 2.8x10^5 live facts, 30363 graphs): **0.87 s wall, 0.57 s user, 135 MB
RSS**. Against the same store's 273 ms boot and 65 ms replay, that is the price
of the read-only choice, and it is the right one at CLI scale. The bound is the
live set, not the log.

**2026-09-06, later — the paragraph above was wrong about where the price came
from, and the implementation was rewritten.** Asked why streaming a store to
count it should cost 135 MB and beat a resident boot, the honest answer was that
it should not. Three builds over the same store separated the walk from the fold:

| | wall | user | RSS |
|---|---|---|---|
| `log_read` walk alone, consumer counts and returns | 0.37 s | 0.09 s | 34.6 MB |
| + render the key, discard it | 0.57 s | 0.30 s | 34.6 MB |
| + clone, keys list, map insert (as shipped) | 0.91 s | 0.57 s | 135 MB |

So the walk was never the cost: **100 MB and 0.48 s of the 0.57 s user time were
the fold**, and it was waste. Keying the live set on the rendered text of the
whole quad stores the expanded form of all four terms for every one of 340,145
asserts and throws away the one thing the log had already done -- it interned
every term. The resident store holds the same content in 22.8 MB because a fact
there is four ids and two epochs. Two smaller faults compounded it: a `keys`
list that grew with every assert and was never freed, and a renderer writing a
byte at a time through an `io.Writer` vtable.

**Rewritten to intern.** Each distinct term is rendered once, owned once and
given a `u32`; the live set is keyed on `Quad_Key`, four of those; rendering
appends into a reused byte buffer; the censuses tally ids and render nothing
until the end. Output is byte-identical -- `test_tool_stats` passed unchanged,
which is what an assertion on exact bytes is for -- and the same store now reads

    0.61 s wall, 0.33 s user, 82 MB RSS

**2026-09-06, later still — measured on a real store**, `vsuite-be/build/volume.record`
(1.23 MB log, 12 epochs, 24,597 asserts, **0 retracts**, 24,597 live facts, 7,556
terms, 21 graphs), optimized builds, macOS peak memory footprint rather than
maximum RSS -- the two differ by the binary's own file-backed pages, ~6.6 MB
here, and mixing them is how the figures above read high:

| | user | footprint |
|---|---|---|
| `dump` | 0.010 s | 3.78 MB |
| stats: walk only | 0.010 s | 3.73 MB |
| stats: + intern | 0.040 s | 5.58 MB |
| stats: full | 0.050 s | 8.16 MB |
| stats, pre-intern build | 0.060 s | 16.67 MB |

The intern rewrite is worth 16.7 -> 8.2 MB on this store, and the residue above
`dump` is +4.4 MB and +0.04 s, of which **three quarters of the time is the
intern** -- the same finding as at scale, and the reason [[RECORD-T-0051]] is
about time here rather than memory.

Two things this store taught that the synthetic one could not:

- **`retracts: 0`.** An append-only store makes `facts == asserts` exactly, so
  the live set is insurance against a retraction that has not happened. A cheap
  win nobody has asked for yet: keep no set until the first retract arrives and
  build it from the walk at that point, which would put stats at `dump` + intern
  on every store that has only ever appended. Noted, not filed -- it is ~20 lines
  and wants a consumer asking for it.
- **A stale `make install` is indistinguishable from a slow program.** The
  figures that started this investigation were a binary installed ten minutes
  before the rewrite. `make install` builds `-o:speed` into its own path and the
  suite asserts against the debug `build/rdfrecord`, so the two can disagree
  silently and did.

**47 MB and 0.24 s still sit above the walk**, and that residue is not fixable
from `tool/`: it is a dictionary of 80,879 terms rebuilt beside the one
`log_read` owns, because the seam decodes ids into terms and drops the ids. Filed
as [[RECORD-T-0051]] with these measurements, per the family's
capability-gaps-become-evidence convention. Not pursued here, and worth naming so
it is not re-derived: the *next* win after that would be log.md par. 8's own
argument -- collect the ops flat and sort once instead of hashing 4x10^5 times --
which would save perhaps 15 MB more and is not worth the complexity in an
auditor's tool.

**2026-09-06, later — RECORD-T-0052: graphs are counted, not listed.** The
consumer's deployment gets one named graph per organizational workspace, named
by a UUID that says nothing, so on a real store the graph census was a wall of
identifiers above the thing anyone reads. `graphs:` is now a header figure
beside `facts:`, and the class census is the whole body -- which is the part
that carries weight, since class counts feed licensing decisions. JSON's
`"graphs"` is a number where it was an array. The distinct-graph set is still
built (it is what a count *is*); only the printing went, and `census_label`
went with it. Restoring the list behind a flag is ~5 lines if anyone asks.

**And the head epoch is not printed beside the commit count**, because they are
the same number and the format guarantees it: `open.odin` refuses a commit whose
epoch is not `last_epoch + 1` (`.Epoch_Gap`) and `last_epoch` starts at 0, so
epochs are contiguous 1..N. `epochs:` carries both meanings -- the count, and the
coordinate `head` reports and `store_at` takes. The two are still *computed*
independently, from the chain and from the walk's own commit deliveries, and a
disagreement is reported on stderr as a defect in this package rather than a
finding about the log: `log_read`'s flush path for an epoch that defines terms
and has no ops is exactly where one would hide.

Worth recording against a natural mis-statement of the rule, since it came up:
"HEAD cannot move without a commit" is not quite true. **An environment note is a
chain link too** -- `writer_note` hashes over the current head and replaces it
(`writer.odin:292-301`) -- so a boot whose environment differs moves HEAD with no
new epoch. A **seal** is the opposite: a summary, not a link, leaving the head
unchanged. Neither disturbs the equality, because notes and seals arrive on their
own callbacks and never on `commit`.

**Not changed, and noticed on the way**: `dump --format=json` still refuses a
triple term -- `json_term`'s `^rdf.Triple` arm returns false with the comment
"no triple terms in format v1 (tag 0x07 reserved)", which format v2
(RECORD-I-0004) falsified. `dump --format=nquads` renders them correctly, and
`stats` does too. That is a separate defect and wants its own task.
