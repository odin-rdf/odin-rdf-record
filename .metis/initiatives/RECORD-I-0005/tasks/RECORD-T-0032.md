---
id: make-api-and-the-43-symbols-the
level: task
title: "make api, and the 43 symbols the test suites hold public"
short_code: "RECORD-T-0032"
created_at: 2026-09-01T11:03:06.434295+00:00
updated_at: 2026-09-01T11:19:50.849897+00:00
parent: RECORD-I-0005
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: RECORD-I-0005
---

# make api, and the 43 symbols the test suites hold public

## Parent Initiative

[[RECORD-I-0005]]

## Objective

Make the boundary hold after this initiative ends, and then examine the largest
remaining leak: 43 symbols exported not because a consumer needs them but
because a test lives in a different package.

## Acceptance Criteria

- [ ] `make api` generates the exported set from `odin doc record -short`, diffs
      it against `doc/api-surface.txt`, and fails on any difference — an addition
      as loudly as a removal.
- [ ] `make api` runs as part of `make check`, so CI carries it on all runners.
- [ ] Its failure message says what to do: if the change is intended, update
      `doc/api-surface.txt` in the same commit.
- [ ] Each of the 43 `tests/*`-held symbols is classified: moves in-package,
      stays public with a stated reason, or is already covered by
      `RECORD-T-0033`'s format-layer question.
- [ ] Where a suite moves in-package, `make test` still measures what it measured
      — and where it cannot, the reason is recorded rather than the move forced.

## Implementation Notes

### Technical Approach

The 43 come from `tests/scale`, `tests/proof`, `tests/tool` and `tests/ingest`,
all separate packages. `@(private)` is package-scoped, so `record/*_test.odin`
keeps full access — the question is only which suites genuinely need to be
outside.

`tests/scale`'s hand-built-store cases (`store_init`,
`store_build_permutations`, `store_publish`, `store_fact`) are the clearest
candidates: they are unit tests of the projection, not scale measurements. The
obstacle is that `make test` runs `tests/scale` optimized and separately on
purpose — the measurement gates the vision's sub-second boot criterion, and a
debug harness would measure the harness. So the split is likely *within*
`tests/scale`: the builder cases move in-package, the measurement stays where it
is and keeps its flags. Check that before assuming it.

`tests/proof` is a different matter: it drives the format layer against the
Python verifier, and its symbols are the same ones `tool/` needs. That overlap is
evidence for `RECORD-T-0033`, and this task should hand it over rather than
solve it twice.

### Dependencies

`RECORD-T-0031` — the golden file is only meaningful once the surface is the
intended one.

### Risk Considerations

A check that fails for the wrong reason gets disabled. `make api` must not fire
on formatting, ordering, or an `odin doc` version difference — extract names and
sort, do not diff the raw output. Note that `-doc-format` is broken in
`dev-2026-08:8412dc37a` (`docs_writer.cpp(268)` assertion, reproducible on
`core/strings`), so the textual output is the only available input and the
extraction must be robust to its layout.

## Status Updates
### 2026-09-01 — `make api` holds the boundary; the suites keep 43 names, and mostly must

**`make api` exists and `make check` ends with it**, so all three CI runners
carry it. It runs `tests/api/api_surface.py check`, which diffs the names
`odin doc record -short` reports against `doc/api-surface.txt` and fails on any
difference, in either direction, naming each one. Failure text points at the
remedy: *if this change to the public interface is intended, update
doc/api-surface.txt in the same commit*.

Verified it actually fails, rather than assuming: removing the `@(private)`
lines from `crc32c.odin` produces

```
  + CRC32C_POLY  (exported, not in the surface file)
  + crc32c  (exported, not in the surface file)
  + crc32c_table_init  (exported, not in the surface file)
make: *** [api] Error 1
```

`odin doc` is the input rather than the source parser, deliberately: it is the
compiler's own account of what is reachable, so a declaration that quietly stops
being `@(private)` shows up whether or not anything uses it yet. `python3` is
guarded for the same way `test` guards it.

### The 43, classified — and the hypothesis this task was given is refuted

The initiative supposed that `tests/scale`'s hand-built-store cases were "unit
tests wearing a suite's clothes" and could move in-package. **Measured, that
frees one symbol.**

`measure_boot` — the ISMS-scale measurement that gates the vision's sub-second
boot criterion, and the reason `make test` runs `tests/scale` separately with
`-o:speed` — **hand-builds a store itself**. It needs `Loader`, `loader_init`,
`loader_consumer`, `loader_destroy`, `store_init`, `store_build_permutations`,
`store_build_term_index`, `store_publish`, `store_destroy`, `recover`,
`EPOCH_CHUNK_SIZE` and `FACT_CHUNK_SIZE`, because it measures the boot *phases*
separately and so must drive them one at a time rather than call `store_open`.
Of the 11 held symbols `test_scale_resident_build` names, 10 are needed by
`measure_boot`, by the rest of the suite, or by `tests/ingest`. Moving it frees
`fact_component` and nothing else — not worth splitting a suite and letting the
two copies of the build sequence drift.

The classification, by where the names live:

| group | count | disposition |
| --- | --- | --- |
| log/format layer (`encode`, `term`, `writer`, `open`) | 23 | leaves with `RECORD-T-0033`, if it happens |
| projection builders (`resident`, `load`, `permute`, `snapshot`, `termindex`) | 20 | stays; structural to the measurement suite |

Per-suite: `tests/readme` holds nothing. `tests/tool` (5) and `tests/ingest` (2)
hold only names another suite also holds, so moving either frees nothing.
`tests/proof` has 11 exclusive names, all format layer. `tests/scale` has 14
exclusive, all projection.

### What this hands to RECORD-T-0033, quantified

If the format layer moves to a `record/log` subpackage, **`record`'s surface
loses 36 names**: the 23 above plus all 13 of section 2. 121 becomes 85 — 65
store API and 20 projection names held by `tests/scale` and `tests/ingest`. That
is the number the decision is worth, and it is larger than section 2 alone
suggested, because `tests/proof` reaches the same layer `tool/` does.

`doc/api-surface.txt`'s section 3 comment now records this outcome, so the file
says why those names are there rather than leaving it to be re-derived.

### Acceptance criteria

- [x] `make api` diffs and fails on any difference, both directions.
- [x] Runs as part of `make check`.
- [x] Failure message says what to do.
- [x] All 43 classified: 23 to `RECORD-T-0033`, 20 stay with a stated reason.
- [x] No suite moved — the move that looked available yields one symbol, and the
      reason is recorded rather than the move forced.