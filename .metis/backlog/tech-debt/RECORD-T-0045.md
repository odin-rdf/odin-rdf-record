---
id: the-scale-pass-in-ci-measures-a-wall-clock-budget
level: task
title: "The scale pass in CI measures a wall-clock budget with two test threads on a shared runner, and it flaked at 1007 ms"
short_code: "RECORD-T-0045"
created_at: 2026-09-04T20:40:00.000000+00:00
updated_at: 2026-09-04T20:40:00.000000+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#tech-debt"
  - "#phase/backlog"


exit_criteria_met: false
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

- [ ] The scale pass measures what the criterion says: single-threaded
      (`-define:ODIN_TEST_THREADS=1` on the scale pass in the Makefile is
      the smallest change, and it is what every reported figure was already
      measured with), and the assertion's margin on the ubuntu runner is
      known rather than guessed — state it in the test's log line.
- [ ] Decide, and record in the test, whether the budget is a *CI gate* or a
      *measurement*: a gate wants a runner-aware bound (or a `RECORD_SCALE`
      run that logs and never fails on time), a measurement wants the solo
      run and the number in the log. Do not simply raise the constant.

## Status Updates

- 2026-09-04 — filed from the `v0.9.0` release (`RECORD-T-0044`). Not a
  code regression: the failing job was re-run and passed, and the tag was
  cut on the green rerun.
