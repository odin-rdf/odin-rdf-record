---
id: stats-says-less-graphs-counted
level: task
title: "stats says less: graphs counted rather than listed, and the head epoch not printed twice"
short_code: "RECORD-T-0052"
created_at: 2026-09-06T21:35:00.000000+00:00
updated_at: 2026-09-06T21:35:00.000000+00:00
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

# stats says less: graphs counted rather than listed, and the head epoch not printed twice

## Objective

Two output lines removed from `rdfrecord stats` on the consumer's reading of a
real store: the per-graph census becomes a count, and the head epoch stops being
printed beside the commit count it always equals.

## Backlog Item Details

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P2 - Medium (nice to have)

### Business Justification
- **User Value**: the deployment gets one named graph per organizational
  workspace, named by a UUID that says nothing, so the graph census was hundreds
  of lines of identifiers standing above the part anyone reads. Class counts feed
  licensing decisions and are what the command is for.
- **Effort Estimate**: S

## Acceptance Criteria

- [x] `graphs:` is a header figure beside `facts:`; no per-graph list in either
      format, and JSON's `"graphs"` is a number where it was an array.
- [x] `epoch:` is gone; `epochs:` carries both meanings.
- [x] `test_tool_stats` asserts the new plain and JSON output byte for byte.

## Implementation Notes

**Graphs.** The distinct-graph set is still built -- that is what a count *is* --
so only the printing went, along with `census_label`. Restoring the list behind a
flag is ~5 lines if anyone asks.

**The epoch.** The head epoch and the commit count are the same number and the
format guarantees it: `open.odin` refuses a commit whose epoch is not
`last_epoch + 1` (`.Epoch_Gap`) and `last_epoch` starts at 0, so epochs are
contiguous 1..N. `epochs:` carries both meanings -- the count, and the coordinate
`head` reports and `store_at` takes.

They are still *computed* independently, from the chain and from the walk's own
commit deliveries, and a disagreement prints on stderr as a defect in this
package rather than a finding about the log: `log_read`'s flush path for an epoch
that defines terms and has no ops is exactly where one would hide.

**A note against a natural mis-statement of that rule**, since it came up while
deciding this: "HEAD cannot move without a commit" is not quite true. An
environment note is a chain link too -- `writer_note` hashes over the current head
and replaces it (`writer.odin:292-301`) -- so a boot whose environment differs
moves HEAD with no new epoch. A **seal** is the opposite: a summary, not a link,
leaving the head unchanged (`writer.odin:308-309`). Neither disturbs the
equality, because notes and seals arrive on their own callbacks and never on
`commit`.

## Status Updates

**2026-09-06 — done**, in the same commit. `make check` and `make test` green.
Reading the note's payload while writing the paragraph above turned up
[[RECORD-T-0053]]: it claims format 1 on a format 2 store.
