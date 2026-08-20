---
id: the-validation-hook-validator-on
level: task
title: "The validation hook: Validator on store_open, Enforce and Record"
short_code: "RECORD-T-0016"
created_at: 2026-08-20T11:47:10.803015+00:00
updated_at: 2026-08-20T11:47:10.803015+00:00
parent: RECORD-I-0003
blocked_by:
  - "RECORD-T-0015"
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0003
---

# The validation hook: Validator on store_open, Enforce and Record

## Parent Initiative

[[RECORD-I-0003]]

## Objective

`RECORD-A-0006` as built: a `Validator` — procedure plus context
pointer — wired once at `store_open`, never per call; invoked by
`apply` on every changeset with the candidate snapshot (the post-state,
through the ordinary read API — decision 1) and the resolved ops; under
`.Enforce` a refusal aborts before any byte is written, under `.Record`
the epoch commits and `conforms` reports. The store never interprets a
report; the validator owns it. Record's log does not record that a
judge objected (decision 5), and the documentation says so.

## Acceptance Criteria

- [ ] `Validator :: struct { check: proc(data: rawptr, candidate:
      Snapshot, ops: []Resident_Op, allocator) -> bool, data: rawptr }`;
      `store_open` gains `validator := Validator{}` — the one signature
      change — and a nil `check` means no validation, the consumer's
      stated posture.
- [ ] `apply` calls the hook between candidate build and encode, once
      per changeset, with `Snapshot{epoch = E+1, idx = candidate}`. The
      hook may call `store_latest` for the pre-state (apply does not
      hold the mutex during validation) and must release what it
      acquires; it runs on the writer's thread and blocks the writer,
      documented.
- [ ] `.Enforce` + false → `.Rejected`, rollback, nothing appended;
      `.Record` + false → commit, `conforms = false`; either mode + true
      → commit, `conforms = true`. `conforms` is documented as
      meaningful only with a validator wired.
- [ ] Tests: a hook that reads the candidate sees the post-state and
      not the head (an asserted quad exists, a retracted one does not);
      a hook that resolves a term the changeset defines finds it; a
      hook that reads the head through `store_latest` sees the
      pre-state; an `Enforce` refusal leaves the projection
      byte-identical and the log unchanged; a `Record`-mode epoch
      replays identically to an `Enforce`-mode one that conformed
      (decision 5, pinned); the candidate snapshot passed to the hook is
      invalid after `apply` returns (the hook must not retain it —
      asserted by the release discipline).
- [ ] `RECORD-A-0006` gains an "As built" section with the signatures,
      the candidate-snapshot reading of part 2, and decision 5 stated
      plainly; the README's write-path paragraph says a nil validator
      is the consumer's posture and that the log does not carry the
      verdict.
- [ ] Contract-level doc comments; `make check` and `make test` green.

## Implementation Notes

### Technical Approach

Small by design: the hook is one call at one site in `apply`, and the
rollback path T-0015 built is what `.Rejected` uses. The shape-catalogue
and TBox-epoch caching `A-0006` part 3 mentions are odin-rdf-shacl's
(it compiles from a snapshot and caches by the shapes graph's epoch);
nothing here names `sh:`.

### Dependencies

RECORD-T-0015.
