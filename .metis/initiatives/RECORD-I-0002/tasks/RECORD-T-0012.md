---
id: the-resident-measurement-boot-time
level: task
title: "The resident measurement: boot time and memory at ISMS scale"
short_code: "RECORD-T-0012"
created_at: 2026-08-19T20:10:55.154675+00:00
updated_at: 2026-08-20T00:13:56.812066+00:00
parent: RECORD-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: RECORD-I-0002
---

# The resident measurement: boot time and memory at ISMS scale

## Parent Initiative

[[RECORD-I-0002]]

## Objective

The initiative's exit gate, mirroring RECORD-T-0006's role: full boot —
`store_open`, verification through resident build through permutation
sort to a served snapshot — timed at ISMS scale in both of `log.md` §9's
epoch shapes against the vision's sub-second criterion, and the resident
footprint measured against api.md's ~30 MB shape. Numbers recorded in
RECORD-I-0002's status, the README amended, and the family CLAUDE.md
Current State re-read for claims this initiative falsifies — the
release convention, executed rather than remembered.

## Acceptance Criteria

- [x] `tests/scale` grows a full-boot measurement: `store_open` on the
      bulk-loaded and hand-edited ISMS logs, timed end to end and broken
      down (verify+replay+build vs permutation sort), asserted under one
      second with the numbers logged.
- [x] Resident memory measured — arena bytes, fact table, permutations,
      the by-term map, and the live-quad map if it was kept — with the
      method documented, and compared against api.md's budget; a
      material divergence is investigated, not shrugged at.
- [x] Read-path sanity at scale: a handful of `Match` shapes on the
      booted store return oracle-checked results (wired through the
      T-0010 suite, not duplicated).
- [x] Numbers recorded in RECORD-I-0002's status; the README's status
      section amended (the resident store exists; `Apply` is what
      remains); the family CLAUDE.md odin-rdf-record section re-read and
      amended with a dated note.
- [x] `make check` and `make test` green.

## Implementation Notes

### Technical Approach

The generator, the two epoch shapes, and the timing scaffolding all
exist from RECORD-T-0006; this task points them at `store_open` instead
of `verify`/`replay` and adds the memory accounting. Dev-machine numbers
(Apple Silicon) are what get recorded, with the standing note that Linux
production numbers are taken when a production host exists.

### Dependencies

Every other task in the initiative — this is the gate.

### Risk Considerations

The number most likely to surprise is the by-term map's overhead (api.md
§4 prices the arena, and Odin's map internals differ from the document's
Go arithmetic). If the footprint diverges materially from the budget,
the finding goes to the initiative's status and, if it changes a
decision, to an ADR — not into silent acceptance.

## Status Updates **[REQUIRED]**

### 2026-08-20 — implemented; the gate passes; `make check` and `make test` green

**The numbers** (optimized build, Apple Silicon dev machine; full table
in RECORD-I-0002's status): full boot **246 ms bulk-loaded / 325 ms
hand-edited** (recover+replay+build 189/274, sort 46/45) — 3–4× inside
the sub-second criterion; resident **22.9 / 25.9 MB** against api.md
§10's ~26–29 MB budget, met item by item (fact table 7.9, permutations
7.8, arena 3.0, by-term map+rest 3.5, epoch table 0.12/3.12 — the
hand-edited epoch figure is api.md §2.4's 3.2 MB estimate, exact).

**Method.** `tests/scale` gained `measure_boot`: gen_store, one settle
boot (writes the startup note so the measured boot is a steady-state
wake, the latency api.md §8 puts user-facing), then `store_open` timed
under a `mem.Tracking_Allocator` as the store's allocator — resident
is true bytes held, and the peak captures the transient replay map and
sort scaffolding for free, measured rather than derived. Per-structure
walks give the breakdown; the by-term map is the tracker's remainder.
Read-path sanity: the head's live count through Match equals the
generator's own live set (the full oracle stays T-0010's test). The
phase breakdown is timed over the same store at store_open's own two
seams.

**One harness decision:** `make test` now runs tests/scale at
`-o:speed` (Makefile restructured, with the reason in a comment): the
debug harness missed the gate at 1093 ms hand-edited while the
optimized build passes at 325 ms — a debug harness measures the
harness, not the store. `make check` still vets tests/scale.

**The finding the risk note predicted, plus one it did not.** The
by-term map came in at ~3.5 MB for 81k terms — inside api.md §4's ~7 MB
dictionary total (arena 3.0 + map 3.5 + offsets 0.3), no divergence.
The surprise was the **transient boot peak: 50.0 / 73.6 MB**,
dominated by the whole-segment read buffer (these logs are one
16.5/37.9 MB segment at the default 64 MB target, held during the walk
alongside the live-quad map) — not the live map api.md §6 expected.
Investigated, explained, recorded in the initiative status with the
levers (smaller segment target; streaming/mmap reads) left unpulled.

**The release convention, executed:** numbers recorded in
RECORD-I-0002's status; README status section rewritten (the store
boots; Apply is what remains) and its family-table snapshot row
corrected to RECORD-A-0005's refcounted resource; the family CLAUDE.md
odin-rdf-record section re-read, its heading updated, and a dated
amendment added covering all six tasks, the corpus drift, and both
measurement notes. Linux production numbers remain a standing caveat
until a production host exists.