---
id: empty-section-3-the-suites-move-in
level: task
title: "Empty section 3: the suites move in-package and the 43 go private"
short_code: "RECORD-T-0034"
created_at: 2026-09-01T11:32:37.230493+00:00
updated_at: 2026-09-01T11:39:13.624957+00:00
parent: RECORD-I-0007
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: RECORD-I-0007
---

# Empty section 3: the suites move in-package and the 43 go private

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
### 2026-09-01 — section 3 is empty. `record.` offers 81 names, down from 121

**43 → 0.** `record` now exports **81** names and keeps **114** private, of 195
declarations. Every one of the 43 that existed only because a test suite sat
outside the package is `@(private)`.

### What moved

`tests/proof`, `tests/scale` and `tests/tool` are now `record/proof_test.odin`,
`record/scale_test.odin` and `record/tool_test.odin` — moved with `git mv`, so
the history follows. Package clause changed, `import rec "../../record"`
dropped, `rec.` qualifiers stripped, and every non-`@(test)` top-level
declaration marked `@(private = "file")`, which is the house convention for test
helpers and what keeps `WALL`, `append_framed`, `splitmix` and `BIN` from
colliding with the identically-named helpers already in `record/*_test.odin`.

`tests/ingest` and `tests/readme` stayed out and had to: both import
`record/ingest`, which imports `record`, so in-package they are an import cycle.
Neither is a loss — `tests/readme` held nothing, and `tests/ingest` held only
`store_fact` and `dict_bytes`, on two adjacent lines of the replay-equivalence
check. Those are now `snapshot_fact` and `snapshot_bytes` over two acquired
snapshots, with `snapshot_terms` in place of `len(dict.off)`. **A suite outside
the package should be asking the questions a consumer can ask**, so this is
better than what it replaced, not a workaround for it.

### The scale measurement, kept intact

`tests/scale` ran optimized and separately for a reason: it gates the vision's
sub-second boot criterion, and it asserts against wall-clock budgets that a
debug build would blow. In-package it would have run in the ordinary debug pass
and failed.

Its seven `@(test)` procedures are now behind `when #config(RECORD_SCALE,
false)`, and `make test` gained a second pass:
`odin test record $(TEST_FLAGS) -define:RECORD_SCALE=true -o:speed`. Verified:
the default pass compiles **83** tests, the scale pass **90**, and the
measurement reports what it did before — bulk-loaded boot 239 ms, hand-edited
310 ms, permutation sort 51 ms, commit latency mean 42 ms.

**Only the tests are guarded, not the helpers.** Two mechanics forced that, both
checked in a scratch package rather than assumed: `import` is a syntax error
inside a `when` block ("Cannot use 'import' within a 'when' statement"), and an
unused import is a compile error under `-vet` — so wrapping the whole file would
have left eight imports dangling in the default build. An unused *procedure* is
not an error, so leaving the helpers compiled costs nothing and keeps every
import used. `make check` gained a `-define:RECORD_SCALE=true` pass so the
guarded code is still vetted.

### One shadowing trap worth recording

Stripping `rec.` merged two distinct types. `scale_test.odin` declares its own
file-private `Quad` (four `u64`s, the generator's) *and* used `rec.Quad` (four
`Term_ID`s, the store's) in `mirror_consumer`. Unqualified they became one name
and the file stopped compiling. The local one is `Gen_Quad` now. It was the only
such collision — checked across all three files against every package-level
name, not found by luck.

### A finding that goes the other way: the surface was under-inclusive

Porting `tests/ingest` onto the public API failed with **`'snapshot_bytes' is not
exported by 'rec'`**. It had been marked private in `RECORD-T-0031` because no
consumer names it — but `api.md` §12 names the read API as *Match, Iter,
Resolve, **Bytes**, Term*, and its doc comment is a consumer contract. The
closure method in `RECORD-T-0030` is derived from current consumer usage plus
inference, and **that misses documented API that nothing calls yet**.

Reviewed the other 74 private names for the same defect. Three were promoted
back: `snapshot_bytes`, `snapshot_visible` ("the one visibility test in the
system"), `snapshot_derived`. Four `store_*` look-alikes stayed private —
`store_derived`, `store_epoch_meta`, `store_note_at` are the pre-snapshot
internals their `snapshot_*` counterparts wrap, and `store_merge_term_index` is
a build step. Section 1 is 65 + 3 = **68**.

Under-exporting is as wrong as over-exporting, and the surface file now says so
in its header.

### Verification

- `make check`: all packages, both the ordinary and the `RECORD_SCALE` build.
- `make test`: 83 default + 90 optimized, all green; scale figures unmoved.
- Documentation check: **6 dangling references, all opaque-handle fields**
  (`Store -> Dict/Env_Note/Index_Set/Writer`, `Snapshot -> Index_Set`,
  `Mem_FS -> Mem_File`). No procedure signature dangles.
- odin-rdf-shacl: green, `git status` clean, `pin: 7503 reads, as pinned`.
- odin-rdf-sparql: green, `git status` clean, W3C survey **byte-identical** to
  the pre-`RECORD-I-0005` baseline, bench `all assertions passed`.

### Acceptance criteria

- [x] Section 3 emptied: 43 → 0.
- [x] All suites still run; scale still measures optimized at its own flags.
- [x] No consumer source change; suites and read pins unmoved in both engines.
- [x] `make api` green at 81.