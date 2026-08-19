---
id: the-log-of-record-format-write
level: initiative
title: "The log of record: format, write path, verification, tooling"
short_code: "RECORD-I-0001"
created_at: 2026-08-19T17:15:24.558917+00:00
updated_at: 2026-08-19T17:15:24.558917+00:00
parent: RECORD-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/discovery"


exit_criteria_met: false
estimated_complexity: M
initiative_id: the-log-of-record-format-write
---

# The log of record: format, write path, verification, tooling Initiative

## Context

The first implementation initiative under `RECORD-V-0001`. `doc/design/log.md`
specifies the on-disk format completely, and the six phase-0 ADRs are decided
(2026-08-19) — in particular `RECORD-A-0001` froze the inline-term encoding
this initiative's writer must enforce, and `RECORD-A-0002`/`RECORD-A-0003`
settled what the log carries. This slice is deliberately self-contained: it
needs no resident store, no snapshot API, and no validator — a replay
*consumer* interface is its only forward-looking seam. It also carries the
repository's entire value proposition (independent verifiability), which is
why it comes first and why its acceptance includes the cross-implementation
proof rather than deferring it.

## Goals & Non-Goals

**Goals:**

- **The format, exactly as `log.md` specifies it**: segment files with the
  64-byte header and base-hash chaining (§3), uniform record framing with
  CRC-32C (§4), the three record kinds — epoch commit with term definitions
  and fact operations, segment seal, environment note (§5) — and the SHA-256
  hash chain over commits and notes (§6). Big-endian throughout. A byte
  written by this code must be predictable from the document alone.
- **The write path** (§7.1): single writer; encode → append → fsync →
  acknowledge; segment rotation with the directory fsync; the advisory
  `HEAD` file. The writer enforces encoding-level invariants — the epoch
  counter's gap-free increment, `RECORD-A-0001`'s inline range, term
  definitions in first-appearance order. The *live-quad* preconditions of
  §5.3 (no retract of a non-live quad, no duplicate assert) need resident
  state and belong to `Apply` in a later initiative; this layer records
  what it is given.
- **Recovery** (§7.2): torn-tail detection and truncation with the position
  rule — a CRC failure anywhere but the final record of the open segment
  halts as corruption, never truncates — and the truncation is surfaced as
  an event, not swallowed.
- **Verification** (§6): full chain verification in one sequential pass,
  run at every open, with typed errors distinguishing torn, corrupt,
  chain-broken, and epoch-gap.
- **Replay as a record reader**: stream validated records — term
  definitions, fact ops, environment notes — to a consumer interface. The
  resident store (next initiative) is the eventual consumer; a
  counting/collecting consumer serves this initiative's tests.
- **Tooling** (§12 q6): `verify`, `dump` (N-Quads and JSON), `head` — the
  auditor's read surface, built with the format rather than after it.
- **The independent verifier**: a second implementation written from
  `log.md` alone in another language (Python), vendored under `tests/`,
  run by `make test` against real segments — the vision's "afternoon claim"
  made executable, and the check that the document and the code agree.

**Non-Goals:**

- The resident store, permutations, dictionary arena, snapshot API — the
  next initiative, consuming this one's replay stream.
- `Apply`, preconditions against live state, validation — after that.
- Segment signatures (§5.4's `sigLen` stays present and zero; §12 q3 is a
  key-custody decision that does not block the format), head-hash
  publication (§12 q4 — operational, external), and anything §10 rules out
  (compression, encryption, random access, compaction).

## Detailed Design

`log.md` **is** the design; this initiative implements it as written, and a
divergence discovered during implementation is fixed by amending the
document (with an ADR if it changes a decision), never by quietly diverging.
What the document leaves to the implementation, to be decided in the first
task and recorded:

- **Package layout**: whether the log lives inside `record` or as a
  `record/log` subpackage, and where the CLI tool sits (a `cmd/` or `tool/`
  main package — the family has both patterns; pick one and say why).
- **CRC-32C availability**: `core:hash` must be checked for Castagnoli
  support; if only IEEE is available, the polynomial table is ~30 lines and
  belongs beside the framing code with a test vector from the spec.
- **SHA-256** via `core:crypto` — verify the streaming interface fits the
  hash-the-body-prefix rule in §6.
- **Typed errors** for the verification taxonomy, in the family's
  procedure-set style.
- **The consumer interface** for replay — narrow enough that the next
  initiative can bind the resident store to it without this initiative
  guessing at resident types.
- **The environment note's v1 content** — format version, and the
  derived-facts regime declaration per `RECORD-A-0002` (no reasoner exists
  yet; the note must still say so, so the first log is self-describing).

## Testing Strategy

- **Round-trip units** per record kind: encode → decode identity, including
  the §5.2 `id == next expected` self-check and §5.3's alignment note (no
  casting a record to `[]u64`).
- **Fault injection as the centerpiece**: truncate a valid log at *every*
  byte offset of its tail record and assert recovery truncates exactly to
  the last durable record; flip one bit in a sealed segment and assert
  verification halts; write a `len == 0` and an over-`MaxRecordSize` frame
  and assert both read as torn, not empty.
- **Write-path ordering**: simulate a crash between each step of §7.1 and
  assert no acknowledged epoch is lost and no unacknowledged epoch is
  visible after recovery.
- **Cross-implementation**: the Python verifier over segments the Odin
  writer produced, and over the fault-injection corpus — both
  implementations must agree on every verdict.
- **Scale**: a repo-local synthetic generator producing an ISMS-shaped log
  (~4×10⁵ ops, ~10⁵ terms) for the replay-throughput measurement against
  the vision's sub-second criterion. `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`
  throughout, per family convention.

## Alternatives Considered

Recorded once, in the specification, not restated here: `log.md` §11
rejects bbolt, JSON Lines, protobuf/CBOR/Avro, SQLite, and WAL-plus-
checkpoints, each with its reasons. SQLite is the documented fallback if
the ~250 lines of durability code prove more troublesome than expected
(§11.4) — that clause is this initiative's escape hatch and its existence
is part of why the initiative is sized M rather than L.

## Implementation Plan

Sequenced so every step is testable before the next begins; decomposition
into tasks happens at the ready gate:

1. **Encoding**: record bodies, framing, hashes — pure functions, no I/O.
2. **The segment writer**: append path, fsync discipline, rotation, `HEAD`.
3. **The open path**: header validation, chain verification, torn-tail
   recovery.
4. **Replay**: the record reader and consumer interface.
5. **Tools**: `verify`, `dump`, `head`.
6. **The proof layer**: the Python verifier, the fault-injection corpus,
   the scale measurement.

Exit: `make test` green including the cross-implementation suite; replay
and verification of the synthetic ISMS-scale log measured under one second;
the README's status section updated from "design" to reflect a real format
version 1.