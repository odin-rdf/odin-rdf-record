---
id: empty-section-2-a-log-reading-seam
level: task
title: "Empty section 2: a log-reading seam for the CLI, and four names promoted to API"
short_code: "RECORD-T-0035"
created_at: 2026-09-01T11:32:40.670926+00:00
updated_at: 2026-09-01T11:48:03.125057+00:00
parent: RECORD-I-0007
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: RECORD-I-0007
---

# Empty section 2: a log-reading seam for the CLI, and four names promoted to API

*This template includes sections for various types of tasks. Delete sections that don't apply to your specific use case.*

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[RECORD-I-0007]]

## Objective **[REQUIRED]**

{Clear statement of what this task accomplishes}

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

{Delete this section when task is assigned to an initiative}

### Type
- [ ] Bug - Production issue that needs fixing
- [ ] Feature - New functionality or enhancement  
- [ ] Tech Debt - Code improvement or refactoring
- [ ] Chore - Maintenance or setup work

### Priority
- [ ] P0 - Critical (blocks users/revenue)
- [ ] P1 - High (important for user experience)
- [ ] P2 - Medium (nice to have)
- [ ] P3 - Low (when time permits)

### Impact Assessment **[CONDITIONAL: Bug]**
- **Affected Users**: {Number/percentage of users affected}
- **Reproduction Steps**: 
  1. {Step 1}
  2. {Step 2}
  3. {Step 3}
- **Expected vs Actual**: {What should happen vs what happens}

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: {Why users need this}
- **Business Value**: {Impact on metrics/revenue}
- **Effort Estimate**: {Rough size - S/M/L/XL}

### Technical Debt Impact **[CONDITIONAL: Tech Debt]**
- **Current Problems**: {What's difficult/slow/buggy now}
- **Benefits of Fixing**: {What improves after refactoring}
- **Risk Assessment**: {Risks of not addressing this}

## Acceptance Criteria

**[REQUIRED]**

- [ ] {Specific, testable requirement 1}
- [ ] {Specific, testable requirement 2}
- [ ] {Specific, testable requirement 3}

## Test Cases **[CONDITIONAL: Testing Task]**

{Delete unless this is a testing task}

### Test Case 1: {Test Case Name}
- **Test ID**: TC-001
- **Preconditions**: {What must be true before testing}
- **Steps**: 
  1. {Step 1}
  2. {Step 2}
  3. {Step 3}
- **Expected Results**: {What should happen}
- **Actual Results**: {To be filled during execution}
- **Status**: {Pass/Fail/Blocked}

### Test Case 2: {Test Case Name}
- **Test ID**: TC-002
- **Preconditions**: {What must be true before testing}
- **Steps**: 
  1. {Step 1}
  2. {Step 2}
- **Expected Results**: {What should happen}
- **Actual Results**: {To be filled during execution}
- **Status**: {Pass/Fail/Blocked}

## Documentation Sections **[CONDITIONAL: Documentation Task]**

{Delete unless this is a documentation task}

### User Guide Content
- **Feature Description**: {What this feature does and why it's useful}
- **Prerequisites**: {What users need before using this feature}
- **Step-by-Step Instructions**:
  1. {Step 1 with screenshots/examples}
  2. {Step 2 with screenshots/examples}
  3. {Step 3 with screenshots/examples}

### Troubleshooting Guide
- **Common Issue 1**: {Problem description and solution}
- **Common Issue 2**: {Problem description and solution}
- **Error Messages**: {List of error messages and what they mean}

### API Documentation **[CONDITIONAL: API Documentation]**
- **Endpoint**: {API endpoint description}
- **Parameters**: {Required and optional parameters}
- **Example Request**: {Code example}
- **Example Response**: {Expected response format}

## Implementation Notes **[CONDITIONAL: Technical Task]**

{Keep for technical tasks, delete for non-technical. Technical details, approach, or important considerations}

### Technical Approach
{How this will be implemented}

### Dependencies
{Other tasks or systems this depends on}

### Risk Considerations
{Technical risks and mitigation strategies}

## Status Updates **[REQUIRED]**

*To be added during implementation*
### 2026-09-01 — section 2 is empty. `record.` offers 73 names, all of them API

**13 → 0.** `record` exports **73** names, and `doc/api-surface.txt` is now a
single list with no exceptions section. Typing `record.` offers the API and
nothing else.

### The seam: `log_read`, the decoded counterpart to `replay`

`replay` delivers a log at the level the format speaks — term ids, a dictionary
the caller must accumulate itself, and `Fact_Op`s of four `u64`s — because that
is what the resident build needs. Anything that wants to *look at* a log rather
than load it wants quads, and the package offered no way to get them. So the CLI
built one: it kept its own `[dynamic][]byte` dictionary, wrote its own
`Resolve_Iri`, and called `term_decode` per component. Nine format internals
were exported for that one caller.

`record/logread.odin` is that loop, once, inside the package:

```odin
Log_Consumer :: struct {
	data:   rawptr,
	commit: proc(data: rawptr, epoch, wall: u64, actor, reason: rdf.Term) -> bool,
	op:     proc(data: rawptr, epoch: u64, kind: Op_Kind, q: rdf.Quad) -> bool,
	note:   proc(data: rawptr, last_epoch: u64, payload: []byte) -> bool,
}

log_read :: proc(dir: string, ops: File_Ops, c: Log_Consumer, allocator) ->
	(r: Verify_Result, tear: Tear, err: Open_Error)
```

The walk is `replay`'s, so verification, the torn-tail rule and the
judged/altered split are untouched. Every field of the consumer may be nil — a
caller counting epochs binds `commit` alone and pays nothing to decode terms it
will not look at. **A term handed to a callback is valid for that call**: ids
decode into a per-op scratch released when the callback returns, which is what
keeps a dump of a 38 MB log flat in memory. `record dump` produces byte-identical
output through it.

Made private: `term_decode`, `inline_term`, `Resolve_Iri`, `Resolve_Term`,
`TERM_TAG_IRI`, `INLINE_FLAG`, `Fact_Op`, `DEFAULT_GRAPH`, and — since
`log_read` is now the way to walk a log — `replay` and `Consumer` too. Still
exported and moved into the API proper: `verify`, `Verify_Result`, `HASH_SIZE`.
Checking a log's chain without opening it is this repository's stated value
proposition, and those three are how a third party does it.

### The bug the port surfaced, which is a real ordering fact about the format

First version resolved `actor` and `reason` inside the `commit` callback. The
dump round-trip went from 11 statements to **0**, with `.Consumer_Abort` and an
empty message.

**A commit record carries its term definitions after the header that names the
attribution, and an epoch's actor is typically defined by that very epoch** —
`apply` interns it last, after the ops. Replay delivers `commit` → `term`… →
`op`…, so at the moment `commit` fires, the actor's id is not in the dictionary
yet. The old CLI never hit this because it resolved attribution lazily, at op
time, when printing.

`log_read` now holds the epoch and fires `commit` just before the epoch's first
op, by which time every definition has arrived — and flushes a still-pending
commit at the note, at the next commit, and at end of walk, so an ops-less
commit is still delivered. `record/logread_test.odin` asserts the actor and
reason arrive resolved, which is what pins this.

### A capability the seam fixes on the way past

The CLI called `term_decode(enc, dump_resolve, d, allocator = ...)` — **no
`resolve_term`**, so a triple term's components could not be chased and
`record dump` failed on any RDF 1.2 log written since `v0.4.0`. `log_read`
supplies both resolvers and recurses, so triple terms dump correctly. Pinned by
`test_log_read_decodes_what_apply_wrote`, which applies one and reads it back.

Not a feature, and not scope creep: it is the same loop written once and
correctly instead of once per caller, which is the argument for the seam.

### Verification

- `make check`: all packages, both builds, `api: 73 exported names`.
- `make test`: 85 default + 92 optimized, green; dump round-trip green.
- Documentation check: 6 dangling, all opaque-handle fields, unchanged.
- `record dump` in both formats against a real log: correct, with attribution.
- odin-rdf-shacl and odin-rdf-sparql: green, `git status` clean, survey
  byte-identical, 8 read pins `as pinned`, sparql bench `all assertions passed`.

### Acceptance criteria

- [x] Section 2 emptied: 13 → 0; nine internals private, `replay`/`Consumer`
      private too, three promoted to API.
- [x] The seam exposes existing capability, not new capability.
- [x] `tool/` ported; output unchanged.
- [x] `doc/api-surface.txt` is one section; `make api` green at 73.
- [x] No consumer source change; pins unmoved.