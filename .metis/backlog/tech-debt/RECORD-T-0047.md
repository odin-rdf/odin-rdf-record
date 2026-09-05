---
id: three-record-tests-depend-on-the
level: task
title: "Three record tests depend on the working directory, so they fail in a consumer's -all-packages run"
short_code: "RECORD-T-0047"
created_at: 2026-09-05T21:26:56.279988+00:00
updated_at: 2026-09-05T21:31:11.311639+00:00
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

# Three record tests depend on the working directory, so they fail in a consumer's -all-packages run

## Objective

**Filed by a consumer** (`odin-rdf-app`), under the family's convention that
what the published repository does to a consumer is reported here with
evidence rather than worked around there.

Three tests in `record` locate what they need **relative to the process's
working directory** rather than to their own source file, so they pass only
when run from this repository's root. A consumer whose suite is one binary --
`odin test <main> -all-packages`, the form `odin-rdf-app`'s own `Makefile`
uses -- compiles `record`'s tests into that binary and runs them from its
own directory, where the three fail every time:

- `record.test_cross_implementation` and
  `record.test_cross_implementation_apply` (`record/proof_test.odin`) run
  `PY :: "tests/verify/rdflog_verify.py"` through `python3`, a path relative
  to the cwd. From elsewhere python reports
  `can't open file '<cwd>/tests/verify/rdflog_verify.py'`, its stdout is
  empty, and every case fails as "implementations disagree -- odin
  `<verdict>`, python `""`".
- `record.test_tool` (`record/tool_test.odin`) runs `BIN :: "build/record"`,
  which is this repository's `make tool` output and exists nowhere else.

Their scratch directories (`build/proof/...`, `build/tool-test`) are
relative too; those are only litter under the consumer's `build/`, not a
failure, and are mentioned for completeness.

**Not a defect in what the tests check.** Both verifiers agree the moment
the script is found; the CLI's output is exactly what `test_tool` asserts
once the binary exists. The defect is where the tests look.

## Backlog Item Details

### Type
- [x] Tech Debt - Code improvement or refactoring

### Priority
- [x] P2 - Medium (nice to have)

### Technical Debt Impact
- **Current Problems**: a consumer's `make test` ends `N tests, 3 failed`
  with a non-zero exit on a tree whose own tests all pass. Its only choices
  today are to read past the summary, to enumerate every test it *does*
  want through `ODIN_TEST_NAMES` (an include-only filter, which is the
  fragile thing letting the compiler collect the tests exists to avoid), or
  to give up the single binary and loop `odin test` per package.
- **Benefits of Fixing**: `-all-packages` over `record` is green anywhere,
  which is what a library's tests being carried along by a consumer's build
  should mean.
- **Risk Assessment**: left alone, every consumer learns that three red
  lines are normal, and a fourth is the one that matters.

## Evidence

Checkout `v0.9.0-3-g4fd47d8`, macOS, 2026-09-05. The same three, filtered,
from two directories:

```sh
# From this repository's root, after `make tool`: all three pass.
$ odin test record -define:ODIN_TEST_NAMES=record.test_cross_implementation,record.test_cross_implementation_apply,record.test_tool \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -collection:rdf=../odin-rdf-parser -out:/tmp/record-test
Finished 3 tests in 734.577ms. All tests were successful.

# From ../odin-rdf-app, through a one-line main that @(require)-imports
# "record:record", the way its Makefile's test target does: all three fail.
$ odin test testmain -all-packages -define:ODIN_TEST_NAMES=record.test_cross_implementation,record.test_cross_implementation_apply,record.test_tool \
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -collection:rdf=../odin-rdf-parser -collection:record=../odin-rdf-record -out:/tmp/app-test
[ERROR] [proof_test.odin:463:test_cross_implementation()] no-store: implementations disagree — odin "no-store", python "" (stderr ".../Python: can't open file '/.../odin-rdf-app/tests/verify/rdflog_verify.py': [Errno 2] No such file or directory\n")
Finished 3 tests in 584.589ms. All tests failed.
 - record.test_cross_implementation       	sealed-trailing-bytes: implementations disagree — odin "corrupt", python "" (...)
 - record.test_cross_implementation_apply 	apply-written torn: odin "torn-tail 3 380 acda5f...", python ""
 - record.test_tool                       	expected code to be 1, got 0
```

The full record suite from a consumer's directory: 3 failed of the
package's tests, the other record tests green.

## The ask

Two things, both already the family's practice elsewhere:

1. **Locate the script by the source file, not the cwd.** The three sibling
   repositories' W3C harnesses all do `SUITE_ROOT :: #directory + ".."`
   (`odin-rdf-parser/tests/w3c/harness/harness_test.odin`,
   `odin-rdf-shacl/tests/w3c/harness/suite.odin`,
   `odin-rdf-sparql/tests/w3c/harness/dataset.odin`). The same one line
   here -- `PY :: #directory + "../tests/verify/rdflog_verify.py"` -- makes
   both proof tests find the verifier from any directory. The scratch
   `STORE`, `CASE_DIR` and `APPLY_STORE` can stay relative or follow suit.
2. **Let the CLI test say when the CLI is not there.** `test_tool` checks a
   binary only `make tool` produces; from a consumer there is no such
   binary and never will be. Either the test moves beside the CLI it tests
   (`tool/`, which nobody's `-all-packages` reaches through `record:`), or it
   returns early with a `log.warn` when `#directory + "../build/record"` is
   absent, so that a missing build is reported as what it is rather than as
   `expected code to be 1, got 0`.

Not asked: that `python3` be optional. A consumer that carries `record`'s
tests carries their preconditions, and a missing interpreter failing loudly
is right; only the path is wrong.

## Acceptance Criteria

- [x] `odin test <a main that @(require)-imports "record:record"> -all-packages`,
      run from any directory outside this repository, is green for every
      `record` test -- with `build/record` absent.
- [x] `make test` here is unchanged in what it proves: both verifiers still
      compared over every corpus case, the CLI still asserted byte for byte.
- [x] The proof-layer header (`record/proof_test.odin`) says where the
      verifier is found and why it is not the cwd.

## Status Updates

- 2026-09-05 -- filed by the consumer. Evidence above. Until this lands the
  consumer's test target documents the three as known and reads its summary
  as "green means these three only"; its pin moves to the tag that carries
  the fix.

- 2026-09-05 -- done, two constants and a guard. `PY` is
  `#directory + "../tests/verify/rdflog_verify.py"` and `BIN` is
  `#directory + "../build/record"`, both with a comment saying why they
  are not the cwd; `test_tool` returns early with a `log.warn` when that
  binary is absent, since from a consumer there is no CLI to assert and a
  missing build is not a failing one. The scratch directories (`STORE`,
  `CASE_DIR`, `APPLY_STORE`, `DIR`) stay relative deliberately -- they are
  the runner's litter, and anchoring them would have this package write
  into its own checkout from a consumer's build.

  Verified both ways. From a scratch directory outside this repository,
  through a one-line main that `@(require)`-imports `record:record`:
  **109 tests, all successful** -- and with `build/record` moved aside,
  `test_tool` logs `... is absent -- \`make tool\` builds it; skipping the
  CLI test` and the run stays green. Here, `make test` is 101 tests green
  (the CLI still asserted byte for byte, `make test` depending on `tool`)
  and `make check` clean, the surface unchanged at 74 names.