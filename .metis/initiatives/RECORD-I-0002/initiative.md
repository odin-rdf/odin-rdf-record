---
id: the-resident-store-replay-built
level: initiative
title: "The resident store: replay-built projection and the snapshot read API"
short_code: "RECORD-I-0002"
created_at: 2026-08-19T20:02:06.582341+00:00
updated_at: 2026-08-19T20:16:59.089059+00:00
parent: RECORD-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/active"


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

## Session handoff — 2026-08-19, before implementation begins

Context that existed only in the decomposition session, recorded so the
implementing session does not rediscover it:

**1. The environment note is unowned — now assigned to T-0011.** It fell
between the initiatives: RECORD-I-0001's Detailed Design listed "the
environment note's v1 content" as a decision to make and record, and no
task recorded it — the tests write a placeholder `{"format":1}`. And
`log.md` §7.1 specifies *when* it is written: at startup, when any of the
environment differs from the last such record — which makes it
`store_open`'s job. T-0011 has gained the acceptance criterion. The v1
content decision (format version; the RECORD-A-0002 derived-facts regime
declaration — "no reasoner, none logged" — so the first real log is
self-describing) should be made there and recorded in the task, amending
`log.md` §5.5 if it constrains the payload.

**2. The test-scaffolding map, and what T-0011's cross-restart sweep
needs.** Three fakes exist, deliberately different: `writer_test.odin`'s
`Fake_FS` (file-private, *operation budget* crash model, synced/linked
durable views via `fake_durable`); `fakefs_test.odin`'s `OFS`
(package-private, byte-level, read/truncate/remove — no budget, no
durability model); `tests/scale`'s `Mem_FS` (throughput only). The
cross-restart sweep needs budget + durable views + the read side in one
fake. T-0003 deferred exactly this composition because none existed. The
options, in preference order from the session: (a) extend `OFS` with a
budget and synced/linked tracking, making it the one full-fidelity fake
and eventually retiring `Fake_FS` into it; (b) lift `Fake_FS` to
package-private and add the read side. Either way, the durable-view
semantics to preserve: nothing if the directory entry never synced,
otherwise the synced bytes plus optionally half of the unsynced tail.

**3. The consumer-failure idiom, and where T-0007's error types live.**
The seam reports a refusing consumer as `.Consumer_Abort` only; the
consumer carries its own diagnosis — the tool's `Dumper.fail` field is
the established precedent (set the detail, return false, report after
the abort). T-0007's retract-of-non-live and duplicate-assert can either
follow that idiom (a builder-owned error enum behind `.Consumer_Abort`)
or extend `Open_Error` the way the replay-only verdicts did. Session
lean: **builder-owned**. The replay-only `Open_Error` members judge what
any conforming log must satisfy; live-quad discipline is a *this-store*
semantic (`log.md` §8 calls it a replay error, but a foreign consumer
may legitimately tolerate it), and the CLI's verdict surface should not
grow store-internal cases. Decide in T-0007 and record.

## Status — 2026-08-20: all six tasks complete; the gate's numbers

The store boots. Every task completed and committed the day after the
initiative was drafted: T-0007 (resident build; the ISMS generator
gained a real writer's disciplines, drifting the T-0006 corpus to
80,879 terms / 16.5–37.9 MB), T-0008 (six permutations, radix-sorted
after a 535 ms comparison-sort measurement — 39–57 ms optimized),
T-0009 (refcounted snapshots with real reclamation; publication's
memory model documented at the code), T-0010 (the §12 read API,
oracle-proven; api.md §12.2's Pattern-G collision with the sentinel
amendment discovered and amended — MATCH_DEFAULT_GRAPH), T-0011
(store_open, writer resume byte-identical to an unbroken writer, the
cross-restart sweep, ENV_NOTE_V1 = `{"format":1,"derived":"none"}`
amended into log.md §5.5), T-0012 (the gate below).

**The gate (optimized build, Apple Silicon dev machine, ISMS corpus:
4×10⁵ ops, 80,879 terms, 340,145 facts):**

| | bulk-loaded (10³ epochs) | hand-edited (2×10⁵) |
|---|---|---|
| full boot (`store_open`) | **246 ms** | **325 ms** |
| — recover+replay+build | 189 ms | 274 ms |
| — permutation sort | 46 ms | 45 ms |
| resident footprint | **22.9 MB** | **25.9 MB** |
| — fact table / permutations | 7.9 / 7.8 MB | 7.9 / 7.8 MB |
| — arena / by-term map+rest | 3.0 / 3.5 MB | 3.0 / 3.5 MB |
| — epoch table | 0.12 MB | 3.12 MB |
| transient boot peak | 50.0 MB | 73.6 MB |

Boot is 3–4× inside the vision's sub-second criterion. The footprint
is api.md §10's budget met item by item (~26–29 MB at 4×10⁵ facts;
ours is 340k facts — scaled, it lands on the estimate; the epoch
table's 3.2 MB hand-edited figure is exact). Method: a tracking
allocator as the store's allocator (true bytes, not arithmetic), with
per-structure walks; `make test` runs tests/scale optimized because a
debug harness measures the harness.

**One finding, investigated rather than shrugged at:** the transient
peak is dominated by the whole-segment read buffer — these logs are
one 16.5/37.9 MB segment at the default 64 MB target, held during the
walk alongside the live-quad map — not by the live map alone as api.md
§6 expected. Peak ≈ resident + segment buffer + live map; the
sequencing that keeps the sort scaffolding from stacking on the live
map is implemented (boot destroys the Loader first). If wake storms
ever matter, the levers are a smaller segment target or streaming/mmap
reads through File_Ops; recorded here, not acted on.

Linux production numbers remain to be taken when a production host
exists (the standing dev-machine caveat). Exit criteria: met —
`make test` green end to end, the store boots from its own log, serves
epoch-pinned reads, resumes its writer. README and the family
CLAUDE.md amended per the release convention.

## Session handoff — 2026-08-19, before implementation begins (historical)

**4. Toolchain notes that cost compile round-trips.** This machine's
Odin (homebrew 2026-08): `core:os` is the os2-shaped API —
`read_entire_file_from_path(path, allocator) -> (data, err)`,
`process_exec(Process_Desc{command = []string{...}}, allocator)`,
`os.to_writer(os.stdout)`, `os.open(path, {.Write, .Append})`.
Enumerated arrays over `Op_Kind` need `#sparse` (its values are
non-contiguous) — the tool uses switch procedures instead. And the
reason `tests/scale` generates through `Mem_FS` and flushes whole files
to disk afterwards: F_FULLFSYNC on darwin costs ~5–20 ms per sync, so a
per-epoch fsync at 2×10⁵ epochs would run for an hour — any test that
writes many epochs through the real posix ops is a bug in the test.