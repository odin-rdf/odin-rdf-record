---
id: the-scale-pass-in-ci-measures-a
level: task
title: "The scale pass in CI measures a wall-clock budget with two test threads on a shared runner, and it flaked at 1007 ms"
short_code: "RECORD-T-0045"
created_at: 2026-09-04T20:40:00+00:00
updated_at: 2026-09-04T20:11:58.511473+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#tech-debt"
  - "#phase/completed"


exit_criteria_met: true
initiative_id: NULL
---

# The scale pass in CI measures a wall-clock budget with two test threads on a shared runner, and it flaked at 1007 ms

## Objective

`make test`'s optimized scale pass asserts `boot_ms < 1000` in
`measure_boot` (`record/scale_test.odin`), the vision's sub-second
criterion. On 2026-09-04 the ubuntu runner measured the hand-edited boot at
**1007 ms** on `eb270c1` (run 33913321449) and failed the `v0.9.0` release
commit; the previous green run on `975693b` had **941 ms** for the same
test, and a rerun of the failed job passed. The commit between them touched
`scan_next` and nothing on the boot path.

Two things make the number noisier than the criterion it stands for:

- **`odin test` runs two threads by default**, so the boot is timed while
  another scale test — bulk apply, commit latency — runs beside it. On the
  dev machine that inflates boot by ~50% (296 vs 193 ms, RECORD-I-0009's
  measurements were taken solo with `-define:ODIN_TEST_THREADS=1`).
- **A shared runner is 3–5× the dev machine** (recover+replay+build 784 ms
  there against 282 ms hand-edited boot locally), leaving a 6% margin under
  a budget written for production hardware.

## Acceptance Criteria

- [x] Every wall-clock budget in `record/scale_test.odin` is a **warning,
      not a gate**: verify, replay, boot, commit max and commit mean go
      through one file-private `budget` helper that `log.warnf`s when a
      figure is over and fails nothing. Counts, verdicts and the byte
      accounting are still asserted.
- [x] The file header states the decision and where the discipline moved.
- [x] `make check` and the optimized scale pass green.

## Decision (owner, 2026-09-04)

The clocks become warnings. "It takes the time it takes and sometimes the
CI runners are slow." The criterion is about the production system, not the
dev machine or a CI runner, so the discipline moves to where it means
something: **an official release is measured on production hardware**, and
the wake time may later be reported from inside the store — a notification
hook on `store_open` when a wake runs over budget — which would be a small
API addition and is not built here. Not taken: running the scale pass
single-threaded (the reported figure would be closer to the documented one,
but a warning's number is informational either way), and raising the
constant.

## Status Updates

- 2026-09-04 — filed from the `v0.9.0` release (`RECORD-T-0044`). Not a
  code regression: the failing job was re-run and passed, and the tag was
  cut on the green rerun.
- 2026-09-04 — done. Five assertions became one helper's warnings; `make
  check` green, the optimized pass 101/101. A slow runner now prints a
  `[WARN]` line carrying the figure and the budget and the build stays
  green.