---
id: the-resident-store-replay-built
level: initiative
title: "The resident store: replay-built projection and the snapshot read API"
short_code: "RECORD-I-0002"
created_at: 2026-08-19T20:02:06.582341+00:00
updated_at: 2026-08-19T20:02:06.582341+00:00
parent: RECORD-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/discovery"


exit_criteria_met: false
estimated_complexity: M
initiative_id: the-resident-store-replay-built
---

# The resident store: replay-built projection and the snapshot read API Initiative

## Context

The second implementation initiative under `RECORD-V-0001`, consuming what
`RECORD-I-0001` built (completed 2026-08-19): the log of record is real —
format version 1, the verifying reader, and the replay consumer seam that
was shaped *for this initiative to bind*. Two consumers already run on
that seam (the collecting test consumer and the dump tool); the resident
store is the third and the reason it exists.

`doc/design/api.md` is the specification for everything here, the way
`log.md` was for the log: the resident layout (§2–§5), the 32-bit ID
scheme `RECORD-A-0001` froze (u32, bit 31 the inline flag, 28-bit
payloads — replay's translation from the 64-bit on-disk ids is a pure
re-tag that cannot fail, because T-0004's replay already refuses
anything outside the frozen range), and the layered read API (§12).
The relevant ADRs are decided: `A-0004` six triple orders with `G` as
residual tiebreaker, no graph-first permutations; `A-0005` snapshots are
refcounted resources with flat copy-on-write permutation maintenance in
v1; `A-0002` replay ends with a materialization pass — vacuous in this
initiative, since no reasoner exists yet, but the `Derived` field and the
origin filter are format, not future.

Inherited and ready to use: the term codec (`record/term.odin`, built for
the dump tool with `Term(id)` named as its second consumer), the
`Verify_Result` resume counters the open path already returns, and the
ISMS-scale generator in `tests/scale` for the boot-time measurement.

## Goals & Non-Goals

**Goals:**

- **The resident structures, built by replay** (api.md §2, §4): the
  pointer-free fact table (`Assert`/`Retract` epoch interval, origin,
  positional `FactID` counting asserts), the chunked dictionary arena
  (blob + offsets + a by-term map whose keys are zero-copy views), the
  epoch table (wall, actor, reason per epoch — §2.4's "who is total"),
  and environment notes keyed by the epoch they follow. The binding is a
  `Consumer` on RECORD-T-0004's seam and nothing else — replay stays the
  only load path and the only recovery path.
- **Resident replay semantics**: the 64→32-bit id re-tag; retract
  resolution to the currently-live fact (`log.md` §8 — a retract of a
  quad that is not live, or a duplicate assert of one that is, is a
  *replay error* here, with the transient live-quad map as scaffolding);
  the §5.2 dictionary self-check already enforced by the reader.
- **The six permutations** (§5, `A-0004`): sorted `[]FactID`, built once
  at the end of replay by sorting, `G` residual everywhere.
- **Snapshots** (§12.1, `A-0005`): refcounted acquire/use/release,
  `Latest()` and `At(epoch)`, and the published-epoch discipline —
  `log.md` §7.1's steps 4–5, the apply/publish halves the writer task
  deliberately left to this layer.
- **The read API, layers 0–2** (§12): `Match(Pattern)` as prefix ranges
  over the permutations; `Iter` with the filter set (origin, graphs,
  live-at-epoch); `Resolve(term)` with the fast reject; `Bytes(id)` and
  `Term(id)` over the arena and the existing codec.
- **Boot, end to end**: `recover` → `replay` into the resident build →
  permutation sort → **writer resume** from the verified state — the
  writer today only creates brand-new stores, so this adds the
  open-existing seam (`File_Ops` grows an append-to-existing operation)
  and `writer_open` from a `Verify_Result`, with the crash sweep extended
  across a restart.
- **The measurement**: full boot (verify + replay + build) at ISMS scale
  against the vision's sub-second criterion, and resident memory against
  api.md's ~30 MB shape, on the deterministic generator.

**Non-Goals:**

- **`Apply`** — the write path (changesets, interning, the live-quad
  preconditions as *caller* errors rather than replay errors, `log.md`
  §7.1 steps 1–5 as one call) and the validation hook (`A-0006`,
  `Enforce`/`Record`): the initiative after this one, where bind.md's
  asks land.
- Reasoning and materialization (no reasoner exists; the pass is a seam,
  not a feature), SPARQL/SHACL binding, anything HTTP.
- Head-hash publication (`log.md` §12 q4, operational), the large-literal
  blob store (§12 q2), and everything `log.md` §10 rules out.

## Detailed Design

`api.md` **is** the design, on the same terms `log.md` was for
RECORD-I-0001: implemented as written, and a discovered divergence amends
the document (with an ADR if it changes a decision), never quietly the
code. What the document leaves to the implementation, to be decided in
the first tasks and recorded:

- **The store's public shape** — one `Store` type in the `record` package
  (the package-boundary decision of RECORD-T-0001 stands: consumers
  import `record` and nothing else), with `store_open(dir, ops)` as the
  boot path (`recover` → `replay` → build → resume) and snapshots as the
  only read handle.
- **The writer-resume seam** — `File_Ops` needs an open-existing-for-
  append operation (`create` deliberately refuses existing paths), and
  `writer_open` needs to decide what it trusts: everything comes from the
  just-verified `Verify_Result`, which is derived state, so resume trusts
  the walk and nothing else — HEAD stays advisory.
- **The transient live-quad map** — `log.md` §8 leaves open whether it is
  dropped after replay or kept for the writer's duplicate-assert check.
  `Apply` (next initiative) is the consumer that would keep it; the
  decision here is measurement-shaped (~20 MB at scale) and should be
  recorded either way.
- **Snapshot lifetime mechanics** — `A-0005` fixes acquire/use/release
  and refcounting; the single-writer/N-reader memory model (atomics on
  the published epoch, per `log.md` §7.1 step 5) is this initiative's to
  implement and document precisely.
- **`EntityHistory` and the epoch-attribution queries** (api.md §12.6) —
  in or out of scope is a decompose-time call; the epoch table it needs
  is in scope regardless.

## Testing Strategy

- **Replay-build equivalence**: the resident build is a third consumer on
  a proven seam — its counts and contents are checked against the same
  writer state the T-0004 collecting consumer already validates, then
  against `Match` results term by term.
- **Replay-error taxonomy**: retract-of-non-live and duplicate-assert
  logs (writable today — the writer records what it is given) must fail
  resident replay with typed verdicts, and must still `verify` clean —
  the same judged-vs-altered split T-0004's tests pin.
- **Snapshot discipline**: a reader at epoch E sees exactly the facts
  live at E, across retracts and re-asserts (`[Assert, Retract)`
  intervals); `At(historical)` answers identically before and after
  later epochs exist; release ordering torture-tested.
- **Boot crash sweep across restart**: every crash state of the writer
  sweep, opened by `store_open`, must resume and commit further epochs;
  the recovered-then-resumed log must verify clean and replay to the sum
  of both runs.
- **Match conformance**: prefix-range semantics for every pattern shape
  against a brute-force scan oracle over the fact table, at both epoch
  and filter extremes.
- **Scale**: `tests/scale` grows the boot-time and resident-memory
  measurement (sub-second boot; the ~30 MB shape of api.md).
  `ODIN_TEST_FAIL_ON_BAD_MEMORY=true` throughout, per family convention.

## Alternatives Considered

Recorded once, in the specifications and ADRs, not restated here:
`api.md` §6 (why the live-quad table should not exist at runtime), §7
(why permutations are flat arrays, with the alternatives table), §3.2
and `RECORD-A-0001` (the 32-bit resident scheme and its measurement
gate), `RECORD-A-0004` (why six orders and not eight), `RECORD-A-0005`
(refcounted snapshots over epoch-pinned GC schemes). The standing escape
hatch from `log.md` §11.4 (SQLite as the fallback container) does not
apply here — the resident layer has no durable form at all, which is the
design.

## Implementation Plan

Sequenced so every step is testable before the next begins; decomposition
into tasks happens at the ready gate. The likely shape:

1. **The resident build**: dictionary arena, fact table, epoch table,
   notes — a `Consumer` binding with the re-tag and the replay-error
   taxonomy (retract resolution via the transient live map).
2. **Permutations**: the six sorts with `G`-residual comparators,
   measured at scale.
3. **Snapshots and publication**: refcounting, `Latest`/`At`, the
   published-epoch discipline.
4. **Match/Iter/Resolve/Bytes/Term**: the read API over the structures,
   with the brute-force oracle suite.
5. **Writer resume and `store_open`**: the open-existing seam, boot end
   to end, the cross-restart crash sweep.
6. **The measurement**: boot time and resident memory at ISMS scale;
   numbers recorded here, and the family CLAUDE.md re-read for claims
   this initiative falsifies.

Exit: `make test` green; a store that boots from its own log, serves
epoch-pinned reads through snapshots, and resumes its writer — with boot
measured under one second at ISMS scale and the resident footprint
recorded.