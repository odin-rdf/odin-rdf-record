---
id: the-tools-verify-dump-head
level: task
title: "The tools: verify, dump, head"
short_code: "RECORD-T-0005"
created_at: 2026-08-19T17:21:14.137245+00:00
updated_at: 2026-08-19T19:38:33.135528+00:00
parent: RECORD-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: RECORD-I-0001
---

# The tools: verify, dump, head

## Parent Initiative

[[RECORD-I-0001]]

## Objective

The auditor's read surface (`log.md` §12 question 6): one CLI with
`verify`, `dump`, and `head`, built with the format rather than after it —
`dump` in particular carries a load-bearing part of §11.2's readability
argument, since the answer to "binary is unreadable" is a dump tool, and
that answer must exist.

## Acceptance Criteria

- [x] One main package at the location RECORD-T-0001 decided.
      `verify <dir>` runs the full chain verification, prints the head
      hash and last epoch, and exits non-zero on any halting verdict.
      `head <dir>` prints the derived head and the advisory `HEAD` file's
      content, warning on mismatch. `dump --format=nquads|json <dir>`
      replays with a dictionary-building consumer and emits every fact
      operation with terms resolved.
- [x] N-Quads emission reuses the `rdf:` collection's emitters rather than
      hand-formatting terms; JSON is one operation per line, carrying op
      kind, epoch, and the epoch's actor/reason/wall.
- [x] Retractions are marked distinctly in both formats — a retract is an
      *event*, not a quad in the graph — with the chosen representation
      documented in the tool's doc comment.
- [x] Derived-op kinds (`0x11`/`0x12`) are dumped correctly even though
      RECORD-A-0002 means our writer never emits them: the tool reads the
      format, not our writer's habits.
- [x] A Makefile target builds the tool; the README's Commands section is
      updated; a test drives the built binary over a known log and asserts
      its output.
- [x] `make check` and `make test` green.

## Implementation Notes

### Technical Approach

`dump` is RECORD-T-0004's replay with a second consumer — one reader, two
consumers is the design test the seam was shaped for. The tool holds no
logic the library lacks; it is argument parsing around published calls.

### Dependencies

RECORD-T-0004.

### Risk Considerations

Output formats become de-facto contracts. Keeping N-Quads emission on the
parser repo's emitters means the format is the W3C's, not ours; the JSON
shape is ours and should be minimal for exactly that reason.

## Status Updates **[REQUIRED]**

### 2026-08-19 — design settled; a format collision found and decided

**Found**: log.md §5.3 says "the default graph gets sentinel ID 1", but §5.2's
first-appearance rule (as implemented since T-0001) assigns dictionary ids
from 1 — the first interned term IS id 1. Nothing interpreted G until dump,
so the collision was latent. **Decided with the user: the sentinel is 0.**
Zero already means "none" for actor and reason, and an absent graph name is
the default graph — consistent; dictionary ids stay 1-based and every
existing byte (golden vectors included) stays valid. log.md §5.3 amended
with a dated note. Consequences in code: `DEFAULT_GRAPH :: 0`; commit_encode
and replay accept G == 0, and refuse an *inlined* G (every inlined term is a
literal, and a graph label is never a literal).

**Plan**:
- `record/term.odin` — the §3.2 canonical-encoding decoder (enc → rdf.Term,
  borrowing; datatype/namespace ids resolved through a caller callback;
  split-IRI concat is the one allocation) and `inline_term` (inlined id →
  literal, lexical written into a caller buffer). Lives in the library, not
  the tool: the resident store's Term(id) needs the same decoder next
  initiative. First use of the `rdf:` collection inside `record`.
- `tool/` — one main package, binary `build/record`, subcommands
  `verify` (exit 0 clean / 2 torn / 1 halting), `head` (derived head vs
  advisory HEAD, warn on mismatch), `dump --format=nquads|json` (a second
  consumer on T-0004's seam; dictionary-building; terms resolved).
- N-Quads: asserts are plain statement lines via `rdf/quads.emit`; retracts
  and derived ops are the same emitted line behind a `# retract:` /
  `# assert-derived:` / `# retract-derived:` marker, so a strict N-Quads
  parser of the dump sees only asserted, underived statements — and the
  dump is documented as a log dump, not a graph export.
- JSON: one op per line (JSON Lines), ours and minimal: op kind, epoch,
  wall (decimal string — u64 ns exceeds a JSON number's 2^53 precision),
  actor/reason (term strings or null), s/p/o (N-Triples term strings),
  g (term string or null for the default graph). Notes and seals are not
  dumped in v1 — dump emits fact operations, documented.
- Makefile `tool` target; `tests/tool` drives the built binary over a known
  log via os2 process exec and asserts output; README Commands updated.

### 2026-08-19 — complete

`make check` and `make test` green: 31 record tests plus the end-to-end
tool test (exact stdout, stderr, and exit codes for all subcommands and
both dump formats). Delivered as planned above, plus:

- `record/term.odin` — the §3.2 codec landed in the library with its own
  unit tests (every tag, every inline kind, dates verified against an
  independent implementation across 0001-01-01..9999-12-31, refusals).
  `record` now imports `rdf:rdf` — the repo's declared dependency, used
  for the first time.
- The sentinel-0 amendment rippled exactly as predicted: log.md §5.3
  amended; `DEFAULT_GRAPH :: 0`; commit_encode and replay accept G == 0
  and refuse an inlined G; one encode-refusal test updated (g = 0 was
  asserted refused, now it is the default graph) and three added
  (default graph encodes; inlined G refused; undefined named graph
  refused). Golden vectors untouched, as promised.
- The end-to-end log covers the acceptance's hard cases: inlined integer,
  language literal, named + default graph, attributed epoch (actor as a
  term object in JSON), a retract behind `# retract:`, and an
  assert-derived op — written through the writer (commit_encode accepts
  all four kinds; RECORD-A-0002 is Apply's policy, not the format's) and
  dumped behind `# assert-derived:`.
- Torn-store behavior asserted end-to-end: verify exits 2 twice in a row
  on the same injured store — reported, never repaired.

For T-0006: the Python verifier must mirror verify only (the tools add no
verdicts); dump output is now a de-facto contract pinned by exact-string
tests in tests/tool.