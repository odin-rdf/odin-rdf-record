---
id: 001-windows-is-not-supported-the-store
level: adr
title: "Windows is not supported: the store is POSIX only and its consumers inherit that"
number: 1
short_code: "RECORD-A-0011"
created_at: 2026-09-01T12:15:13.959820+00:00
updated_at: 2026-09-01T12:15:13.959820+00:00
decision_date: 2026-09-01
decision_maker: Greger Olsson
parent: 
archived: false

tags:
  - "#adr"
  - "#phase/decided"


exit_criteria_met: false
initiative_id: NULL
---
---

# ADR-11: Windows is not supported

## Context

This repository has been **POSIX only by design** since it was founded — one of
its two recorded departures from family convention. `posix_file_ops` is
`#+build linux, darwin`, Linux is the production environment, darwin is
development (F_FULLFSYNC with an fsync fallback), and there has never been a
Windows `File_Ops`. The deployment shape the whole family is designed against —
~200 processes per physical machine, each embedding a store — is a Linux shape.

What was never settled is what that means **above** the store. odin-rdf-shacl
and odin-rdf-sparql each ran a `windows-latest` CI leg, and it passed, because
their suites open every store over the platform-free memory seam (`Mem_FS` +
`mem_file_ops`) and never touch a real directory. So the family's position was
that a Windows build compiles and its tests pass, while the store underneath it
cannot keep a single byte on that platform.

**`v0.7.0` made the contradiction concrete.** `RECORD-T-0034` moved the proof,
scale and tool suites into package `record`, where `@(private)` could reach the
43 names they had been holding public. Those suites call `posix_file_ops`, and
**Odin's `_test.odin` is a naming convention rather than a build tag** — such
files are part of the package for every consumer that imports it. Both engines'
Windows legs went red on the pin bump; ubuntu and macos passed everywhere. This
repository's own CI could not have caught it, being POSIX only by construction,
and it is precisely the kind of thing the family's walk-the-consumers rule
exists to find.

Two ways out. Tag the three files `#+build linux, darwin`, as
`writer_posix_test.odin` has since `RECORD-T-0002`, and keep the Windows legs
green. Or stop claiming the platform.

## Decision

**Windows is not supported, from odin-rdf-record upward.** The
`windows-latest` leg is removed from odin-rdf-shacl and odin-rdf-sparql; this
repository never had one. The three moved test files stay untagged, so package
`record` genuinely does not compile on Windows — an honest failure rather than a
half-built one.

**odin-rdf-parser keeps its Windows leg and its Windows support.** It is a pure
library with no platform dependency, independently usable, and has nothing
underneath it to constrain. Anyone who wants to parse RDF on Windows still can;
what they cannot do is store it here.

The retired odin-rdf-store is not touched.

## Alternatives Analysis

**Tag the three files and keep Windows green.** One line each, and the CI stays
as it was. Rejected: it buys a Windows build that compiles and passes tests
while the store it is built on cannot host anything there. The green runners
were asserting a capability the layer below deliberately lacks — a cost with no
claim behind it, and a claim nobody wants to make.

**Supply a Windows `File_Ops` and support the platform properly.** The honest
alternative, and the only one that would make the green legs mean something. It
is real work — `CreateFile`/`WriteFile`/`FlushFileBuffers` semantics, a
different fsync story, a crash sweep on a filesystem with different atomicity
guarantees — for a deployment nobody is planning. Not rejected on merit;
declined for want of a consumer. If one appears, this ADR is the starting point
and `File_Ops` is already the seam.

**Keep the legs and let them stay red.** Never a real option: a permanently red
check trains everyone to ignore checks.

## Rationale

A test matrix is a claim about what is supported. Keeping a Windows leg green
by tagging test files would have kept the claim while the thing it claims —
that you can run this store on Windows — has never been true and is not planned
to become true. Removing the leg makes the matrix say what the design already
said.

The asymmetry with odin-rdf-parser is the point rather than an inconsistency:
platform support belongs to the layer that touches the platform. The parser
touches none, so it keeps Windows. The store is a file format and an fsync
discipline, so it is POSIX, and everything built on it inherits that.

## Consequences

### Positive

- The matrices say what is true. Two runners each, everywhere above the parser.
- No `#+build` tags on the moved suites, so the package's platform requirement
  is a compile error rather than a silently-degraded build.
- A third of the CI minutes above the parser, and the family's slowest leg gone.

### Negative

- **Package `record` no longer compiles on Windows at all**, where before
  `v0.7.0` it compiled without its posix file. Anyone experimenting there loses
  even a type-check. This is a real regression in reach, taken deliberately.
- odin-rdf-shacl and odin-rdf-sparql are POSIX-only libraries now, which is a
  narrowing of two independently-usable packages neither of which needs POSIX
  for anything of its own.
- Nothing checks Windows compilation, so the state cannot be recovered by
  accident — restoring it means reinstating a runner and finding whatever has
  rotted meanwhile.

### Neutral

- No format change, no API change, no source change in either engine beyond
  their CI files and documentation.

## Review Triggers

- A consumer wants durable storage on Windows — then write a Windows
  `File_Ops` and reinstate the legs; the seam exists and this ADR is the
  starting point.
- odin-rdf-parser grows a platform dependency — then its Windows leg needs the
  same argument applied to it, and the asymmetry above stops being principled.
- Odin gains a real distinction between test files and package files — then the
  `_test.odin` half of the problem disappears, though the store's POSIX
  requirement does not.
