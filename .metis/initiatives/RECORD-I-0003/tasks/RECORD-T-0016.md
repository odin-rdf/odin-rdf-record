---
id: the-validation-hook-validator-on
level: task
title: "The validation hook: Validator on store_open, Enforce and Record"
short_code: "RECORD-T-0016"
created_at: 2026-08-20T11:47:10.803015+00:00
updated_at: 2026-08-20T15:50:00.000000+00:00
parent: RECORD-I-0003
blocked_by:
  - "RECORD-T-0015"
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: true
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

- [x] `Validator :: struct { check: proc(data: rawptr, candidate:
      Snapshot, ops: []Resident_Op, allocator) -> bool, data: rawptr }`;
      `store_open` gains `validator := Validator{}` — the one signature
      change — and a nil `check` means no validation, the consumer's
      stated posture.
- [x] `apply` calls the hook between candidate build and encode, once
      per changeset, with `Snapshot{epoch = E+1, idx = candidate}`. The
      hook may call `store_latest` for the pre-state (apply does not
      hold the mutex during validation) and must release what it
      acquires; it runs on the writer's thread and blocks the writer,
      documented.
- [x] `.Enforce` + false → `.Rejected`, rollback, nothing appended;
      `.Record` + false → commit, `conforms = false`; either mode + true
      → commit, `conforms = true`. `conforms` is documented as
      meaningful only with a validator wired.
- [x] Tests: a hook that reads the candidate sees the post-state and
      not the head (an asserted quad exists, a retracted one does not);
      a hook that resolves a term the changeset defines finds it; a
      hook that reads the head through `store_latest` sees the
      pre-state; an `Enforce` refusal leaves the projection
      byte-identical and the log unchanged; a `Record`-mode epoch
      replays identically to an `Enforce`-mode one that conformed
      (decision 5, pinned); the candidate snapshot passed to the hook is
      invalid after `apply` returns (the hook must not retain it —
      asserted by the release discipline).
- [x] `RECORD-A-0006` gains an "As built" section with the signatures,
      the candidate-snapshot reading of part 2, and decision 5 stated
      plainly; the README's write-path paragraph says a nil validator
      is the consumer's posture and that the log does not carry the
      verdict.
- [x] Contract-level doc comments; `make check` and `make test` green.

## Implementation Notes

### Technical Approach

Small by design: the hook is one call at one site in `apply`, and the
rollback path T-0015 built is what `.Rejected` uses. The shape-catalogue
and TBox-epoch caching `A-0006` part 3 mentions are odin-rdf-shacl's
(it compiles from a snapshot and caches by the shapes graph's epoch);
nothing here names `sh:`.

### Dependencies

RECORD-T-0015.

## Implementation record — 2026-08-20

Small, as planned: `Validator` and the call site in `apply.odin`,
`Store.validator`, `store_open`'s `validator := Validator{}` parameter,
two tests in `apply_test.odin`, the README's write-path note and
`RECORD-A-0006`'s "As built" section. 72 record tests, tool, proof,
scale green; `make check` green.

1. **Parameter order is the initiative's**: `store_open(s, dir, ops,
   validator := Validator{}, target_size := …, allocator := …)`. Callers
   that passed `target_size` or `allocator` positionally now name them.
2. **The candidate snapshot carries no reference of its own.** The set's
   one reference is the store's, and it is installed or released when
   the hook returns; a hook that retains the snapshot holds a dangling
   set after a refusal and an unowned one after a success. Tested on
   the success side by identity (`store_latest().idx` is the retained
   candidate's set); documented as the contract on the failure side.
3. **`Resident_Op`s are built only when a hook is wired** — no allocation
   on the unvalidated path.
4. **Decision 5 is tested by replay**: a `Record`-mode non-conforming
   epoch and an `Enforce`-mode conforming one, replayed from their logs,
   produce the same projection (walls aside); the applied store equals
   its own replay walls included.
5. **`Store.validator` is set before anything else in `store_open`**, so
   even the startup note's boot path cannot observe a store without it;
   nothing in the open path calls it.
6. The shape catalogue and the TBox-epoch key (ADR part 3) remain
   odin-rdf-shacl's; nothing here names `sh:`.

