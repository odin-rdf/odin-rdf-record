---
id: the-cli-installs-as-rdfrecord-make
level: task
title: "The CLI installs as rdfrecord: make install, and the name it carries on PATH"
short_code: "RECORD-T-0048"
created_at: 2026-09-06T12:26:46.277134+00:00
updated_at: 2026-09-06T12:27:17.864435+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#feature"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: NULL
---

# The CLI installs as rdfrecord: make install, and the name it carries on PATH

## Objective

`make install` builds an optimized `tool/` and places it in `~/.local/bin` as
**`rdfrecord`**. The name is the point: vsuite-be's `make install` puts
`rdfgen`, `rdfcheck`, `rdffmt` and `rdfseed` on PATH, and `record` is too
common a word to own there. The binary this repository builds is `rdfrecord`
everywhere now — `build/rdfrecord`, the usage banner, the README — so the
installed name and the built name are the same thing rather than a rename
happening at install time.

## Type
- [x] Feature — New functionality or enhancement

## Acceptance Criteria

- [x] `make tool` builds `build/rdfrecord`; the debug binary the suite drives
      keeps that path.
- [x] `make install` builds `-o:speed` into `build/rdfrecord-release` and
      installs it as `$(INSTALL_DIR)/rdfrecord`, `INSTALL_DIR ?= $(HOME)/.local/bin`.
- [x] `tool/main.odin`'s usage banner says `rdfrecord`.
- [x] README's Commands block and CLI section name `rdfrecord` and `make install`.
- [x] `make test` and `make check` green; `record.test_tool` and the
      `tests/ingest` dump round trip find the renamed binary.

## Implementation Notes

### Technical Approach

Three call sites hold the path and all locate it by `#directory` since
RECORD-T-0047, so the rename is a string: `record/tool_test.odin`'s `BIN`,
`tests/ingest/ingest_test.odin`'s `BIN`, and the Makefile's `tool` recipe
(now a `BIN :=` variable so the two Makefile uses cannot drift).

`install` does not depend on `tool`, and deliberately writes a different
path: the installed tool is an auditor's, built `-o:speed`, and it must not
replace the debug binary the test suite asserts exit codes against.
`install -m 0755` rather than `cp` — a running binary is replaced rather
than written through, and the mode is stated rather than inherited from
`build/`'s umask. This mirrors vsuite-be's install target, including the
`INSTALL_DIR=/usr/local/bin` escape for a system install.

There is nothing else to install: this repository is a library and the CLI
is its only executable.

### Dependencies

None. Not a format, API or source change to the library — `doc/api-surface.txt`
is untouched and both engines are unaffected.

## Status Updates

**2026-09-06 — done.** Makefile `install` target and the rename landed.
`make test` green (94 record, 11 tests/ingest, 1 tests/readme, 101 in the
optimized scale pass); `make check` green at 74 exported names as stated.
`make install` verified end to end: `~/.local/bin/rdfrecord` runs and prints
the new banner.