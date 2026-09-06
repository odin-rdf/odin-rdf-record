---
id: log-read-drops-the-ids-it-decoded
level: task
title: "log_read drops the ids it decoded: a consumer that counts re-interns what the package just un-interned"
short_code: "RECORD-T-0051"
created_at: 2026-09-06T21:09:57.510070+00:00
updated_at: 2026-09-06T21:09:57.510070+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#tech-debt"


exit_criteria_met: false
initiative_id: NULL
---

# log_read drops the ids it decoded: a consumer that counts re-interns what the package just un-interned

## Objective

`Log_Consumer.op` hands a consumer `rdf.Quad`s and nothing else. The ids those
quads were decoded *from* are right there in `Log_Cursor` and are thrown away,
so a consumer that wants to identify facts rather than print them has to build
its own dictionary over the decoded text -- re-interning exactly what the log
had already interned and `log_read` had just resolved. Decide whether the seam
should carry the ids.

## Backlog Item Details

### Type
- [x] Tech Debt - Code improvement or refactoring

### Priority
- [x] P2 - Medium (nice to have)

### Technical Debt Impact

- **Current Problems**: `rdfrecord stats` (RECORD-T-0050) is the first consumer
  to hit it and it is measurable. Over `build/scale/bulk` -- 4x10^5 ops, 3.4x10^5
  asserts, 8.1x10^4 terms, 16.5 MB log -- an optimized build measures:

  | | wall | user | RSS |
  |---|---|---|---|
  | `log_read` walk alone, consumer counts and returns | 0.37 s | 0.09 s | 34.6 MB |
  | + stats' first cut (live set keyed on the quad's rendered text) | 0.91 s | 0.57 s | 135 MB |
  | + stats as shipped (tool-side intern, live set keyed on four `u32`) | 0.61 s | 0.33 s | 82 MB |

  The intern took 53 MB and 0.24 s of user time out of it and is worth having on
  its own terms. What remains -- **47 MB and 0.24 s above the walk** -- is a
  dictionary of 80,879 terms rebuilt by hand beside the one `log_read` owns, plus
  a hash of every term's rendered bytes on every one of 4x10^5 operations, where
  an id comparison would do. For scale: the resident store holds the same content
  in 22.8 MB and boots in 273 ms.

- **Benefits of Fixing**: a counting consumer keys on `[4]u64` with no rendering,
  no hashing of text and no allocation per op, and renders only the terms it
  actually names -- for stats, the distinct graphs and classes rather than all
  80,879. Expected to put stats at roughly the walk's own cost.

- **Risk Assessment**: this is an API question, not a defect, and the surface is
  normative (`doc/api-surface.txt`). The wrong fix re-exports what RECORD-I-0007
  spent three passes making private.

## Acceptance Criteria

- [ ] A decision, recorded: either the seam carries ids, or it does not and the
      reason is written down where the next consumer will find it.
- [ ] If it carries them: `doc/api-surface.txt` and `doc/design/api.md` state the
      new shape, and `rdfrecord stats` is ported onto it as the proving consumer.
- [ ] Whatever is decided, the ids' meaning is stated: they are the **log's**
      first-appearance ids (`Verify_Result.next_term_id`'s space), not the
      resident `Term_ID`s, and the two must not be confused.

## Implementation Notes

### Technical Approach

Three shapes, in increasing order of surface:

1. **Add ids to the existing callback.** `op(data, epoch, kind, q, ids: [4]u64)`,
   0 in the graph slot for the default graph. One field, no new type, and every
   existing consumer breaks at compile time rather than silently -- which for two
   in-tree callers (`Dumper`, `Stats`) is the right cost.
2. **A second, cheaper callback.** `Log_Consumer.op_ids`, called instead of `op`
   when bound, delivering ids and no terms at all. A consumer that only counts
   then pays for **no decode whatsoever** -- which is the larger win, since the
   0.09 s walk includes resolving every term into the per-op arena for a
   consumer that may throw it away. `stats` is exactly that consumer.
3. **A resolver handed to the callback**, so a consumer decodes only the ids it
   decides it needs. Most flexible, most surface, and it puts a lifetime rule on
   a procedure value.

Shape 2 looks strongest and is worth costing first: it is additive, it needs no
existing caller to change, and it makes the decode itself optional rather than
merely the re-interning. Note that shape 2 alone does not make ids *nameable* --
a consumer that counts by id and then wants to print the few it reports still
needs a way to resolve one, which is what pulls shape 3 back in for the tail.

The private seam already has all of this: `Consumer.term` accumulates the
dictionary and `Consumer.op` carries `Fact_Op`'s four `u64`s. RECORD-T-0035 made
both private in favour of `log_read`, for good reason -- the CLI had been
reassembling the format by hand. The gap is that `log_read` replaced a
too-low-level seam with a too-high-level one, and nothing sits between.

### Dependencies

None. RECORD-T-0050 shipped the workaround and is the evidence.

### Risk Considerations

Neither engine consumes `log_read`, so the blast radius is `tool/` and any
future auditor. That makes this cheap to change now and progressively less so.

## Status Updates

*Filed 2026-09-06 from RECORD-T-0050's measurements. Nothing implemented.*
