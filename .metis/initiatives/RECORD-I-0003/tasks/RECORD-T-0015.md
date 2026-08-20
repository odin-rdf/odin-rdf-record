---
id: apply-preconditions-candidate
level: task
title: "apply: preconditions, candidate, rollback, commit, publish — and the memory File_Ops"
short_code: "RECORD-T-0015"
created_at: 2026-08-20T11:47:09.367193+00:00
updated_at: 2026-08-20T15:20:00.000000+00:00
parent: RECORD-I-0003
blocked_by:
  - "RECORD-T-0013"
  - "RECORD-T-0014"
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: true
initiative_id: RECORD-I-0003
---

# apply: preconditions, candidate, rollback, commit, publish — and the memory File_Ops

## Parent Initiative

[[RECORD-I-0003]]

## Objective

The one write path: `apply(s, changeset) -> (epoch, conforms, err)`.
Intern every term (T-0013); check `log.md` §5.3's rules against head
*and* the changeset's own earlier ops; mutate writer-private,
epoch-bounded resident state into a candidate `Index_Set` no published
reader can observe (decision 1); encode, append, fsync through the
resumed `Writer`; publish under the mutex (T-0014). On any refusal or
failure before the fsync, roll back exactly. The hook call site exists
here and is wired in T-0016. Promoted first, because the tests need it:
the in-memory `File_Ops` (decision 9).

## Acceptance Criteria

- [x] The public surface as the initiative's Detailed Design §1 fixes
      it: `Op_Kind`, `Op`, `Mode`, `Changeset`, `Apply_Error`,
      `Apply_Error_Kind` (`None, Empty, Not_Live, Already_Live,
      Unsupported_Term, Rejected, Writer, Epoch_Exhausted`),
      `Resident_Op`, `apply`. `Op` is `{ kind: Op_Kind, using quad:
      rdf.Quad }` — decided at decomposition: the parser's own quad
      type, with `rdf.Graph_Label` making a literal graph
      unrepresentable (so there is no `.Bad_Graph`), and `using` so
      `op.subject`, `op.graph`, `op.triple` read directly, as
      `rdf.Quad` itself does under the family's `-vet -strict-style`.
- [x] `mem_ops` / `Mem_FS` promoted from `tests/scale` beside
      `writer_posix.odin` as the seam's second implementation, with the
      doc comment saying tests and scratch, never data anyone keeps;
      `tests/scale` uses the promoted one. `OFS` stays test-private.
- [x] Preconditions, in op order, each naming its op index: `.Empty`
      for zero ops (decision 6); `.Not_Live` for a retract of a quad not
      live at head-plus-earlier-ops; `.Already_Live` for an assert of one
      that is; assert→retract of one quad in one epoch is legal and
      yields a fact with interval `[E, E)`; retract→assert yields a new
      generation. Head is consulted through `snapshot_exists` over the
      published SPO order (`api.md` §6: no resident live-quad map); the
      changeset's own effects through a transient map freed with the
      call.
- [x] Candidate build: facts appended with `assert = E+1`; retracted
      facts' `retract` set to `E+1` by atomic store; pending terms
      appended to the arena past the published `n_terms`; permutations
      rebuilt; the term index merged; a candidate `Index_Set` with
      `epoch = E+1` built but not installed. A `Snapshot{E+1, candidate}`
      is what the hook (T-0016) receives.
- [x] Commit: `commit_encode` from the intern's `[]Term_Def` and the
      resolved ops, actor/reason as ids (0 for nil), wall = the
      writer's clock in Unix ns UTC; `writer_commit` appends and fsyncs;
      then `store_publish` installs the candidate under the mutex. Epoch
      = published + 1; `LIVE_EPOCH` refused as `.Epoch_Exhausted` before
      any mutation.
- [x] Rollback on `.Rejected` (T-0016) or `.Writer`: `n_facts` back,
      every touched `retract` restored to `LIVE_EPOCH`, the dictionary
      truncated to the published `n_terms` (arena cursor and `off`;
      chunks allocated by this apply freed), the candidate freed, the
      transient maps freed. After rollback the projection is
      byte-identical to a store that never saw the changeset — tested
      by comparison, not asserted.
- [x] `apply` is single-writer: documented as not safe against itself;
      a writer failure leaves the store fail-stop, as the `Writer` is.
- [x] Tests: the error taxonomy, one minimal changeset per kind
      including the intra-changeset cases; replay equivalence — after N
      random changesets, `store_open` the same log into a second store
      and compare fact table, dictionary, epoch table, term index and
      all six permutations (the initiative's standing proof; runs on
      `OFS` and on `mem_ops`); the crash sweep across `apply` at every
      `OFS` cut point — no acknowledged epoch lost, no partial record
      read, recovery + resume + a further `apply` continues the chain;
      the fault corpus gains apply-written cases and the Python
      verifier agrees verdict for verdict; a bulk load (the ISMS
      corpus as one changeset) succeeds in one epoch.
- [x] `log.md` §7.1 amended, dated: "apply to unpublished state,
      validate, fsync, publish" — nothing a published reader can
      observe changes before the durability boundary.
- [x] Contract-level doc comments; `make check` and `make test` green.

## Implementation Notes

### Technical Approach

Order inside `apply`, fixed by `store_publish`'s assertion and the
rollback story: refuse `.Empty`/`.Epoch_Exhausted` → intern all ops
(collect `Term_Def`s; an `.Unsupported_Term` here costs nothing to
undo) → precondition pass (`snapshot_exists` + changeset map;
nothing mutated yet) → mutate (dict append, fact append, retract
stores) → build permutations + merge term index → candidate set →
[hook, T-0016] → encode + `writer_commit` → publish → free scratch.
Everything before "mutate" fails without rollback; everything after
fails with the one rollback procedure.

Readers are fenced by three bounds and nothing else: `n_facts` (ids
past it are in no published permutation), `n_terms` (ids past it are
refused by `snapshot_bytes`/`resolve`), and the epoch test (a fact with
`assert = E+1` or `retract = E+1` is live-or-not exactly as before to a
reader at ≤ E). Retract stores are atomic; relaxed ordering suffices by
§2.3's monotonicity argument.

The per-commit permutation rebuild is `RECORD-A-0005`'s flat
copy-on-write — 45–57 ms at 3.4×10⁵ facts — measured again in T-0018.

### Dependencies

RECORD-T-0013 (intern), RECORD-T-0014 (term-index merge,
`snapshot_exists`, the mutex).

## Implementation record — 2026-08-20

Landed as `record/apply.odin` (+ `apply_test.odin`), `record/writer_mem.odin`
(the promoted in-memory `File_Ops`), edits to `resident.odin`, `boot.odin`,
`snapshot.odin`, the scale and proof suites, `log.md` §7.1 and
`RECORD-A-0006`. 70 record tests, tool, proof (2), scale (6) green; `make
check` green.

**Measured:** the ISMS-scale bulk load as one changeset — 400,000 asserts,
50,494 terms of every shape, 14.7 MB of log — commits in **one epoch in
222–265 ms** across runs on the memory seam (`-o:speed`; intern + preconditions + fact
append + the six-permutation build + term-index merge + encode; no fsync).
Crash sweep across apply: every cut point of a four-changeset life with
rotation, both partial-page shapes, boot + one more apply + combined-log
replay — green. Replay equivalence after 60 random changesets on both
seams, the log rotating under apply: the applied store and a concurrent
replay of its own log are identical structure for structure, wall clocks
included.

**What was decided in passing, for T-0016/T-0017/T-0018:**

1. **The `Writer` lives in the `Store`.** `apply(s, changeset)` needs it, so
   `store_open` fills `s.writer` and returns `(tear, err, load_err,
   write_err)`; `store_close(s) -> Writer_Error` releases both halves
   (`store_destroy` stays for projections built without a writer). Every
   caller in three suites changed mechanically. `Store.write_err` carries
   the writer's last refusal beside apply's `.Writer`.
2. **`Op.kind` is the format's `Op_Kind`, not a second enum.** The design's
   `Op_Kind :: enum u8 { Assert, Retract }` collides with `encode.odin`'s
   `Op_Kind {Assert=1, Retract=2, Assert_Derived, Retract_Derived}`, whose
   first two members are exactly the ones wanted and whose values are the
   on-disk ones — so `Op`, `Plan_Op`, `Resident_Op` and `Fact_Op` share
   it with no mapping. apply *asserts* `.Assert`/`.Retract`: no path
   produces a derived op (`RECORD-A-0002`), so a derived kind here is a
   programming error, not a caller condition to type. T-0017's `ingest`
   default `record.Op_Kind.Assert` is unaffected.
3. **`.Dict_Overflow` was added to `Apply_Error_Kind`** (the design's list
   plus one): the arena's u32 ceiling is reachable by writing 4 GB of
   literals, and a panic on reachable input is wrong. It rolls back like
   `.Writer` and the store is fail-stop after it in the same sense.
4. **An inlined actor or reason is `.Unsupported_Term` at op -1**: the log
   carries dictionary ids or 0 there (`commit_encode` refuses an inlined
   one), and refusing it early keeps a caller error from surfacing as a
   writer error.
5. **`using quad: rdf.Quad` in `Op` passes `-vet -strict-style`** (handoff
   5's worry did not materialize); struct literals still name the embedded
   field (`Op{kind = k, quad = {triple = {s, p, o}, graph = g}}`), access
   reads `op.subject`.
6. **`store_publish` is split** into `build_index_set` (takes the arrays,
   copies the lists, returns the candidate holding the store's future
   reference) and `install_index_set` (the mutexed swap); `store_publish`
   is the composition. The validator call site (T-0016) sits between them
   in `apply`, marked, with `Snapshot{E, candidate, s}` and the plan's
   resident ops in hand; `.Rejected` takes the same rollback as `.Writer`.
7. **Liveness is one prefix range with the id kept** — `snapshot_exists`
   plus the hit's fact id — because a retract needs the generation to
   close; the changeset's own effects are a `map[Quad]Effect` recording
   live-or-not and, for a pending assert, its index among this
   changeset's appends. A retract of a same-changeset assert closes the
   appended fact (interval `[E, E)`), and is not on the rollback's
   `touched` list, since the fact itself is cut away.
8. **Rollback is a `Mark` of eight high-water marks** and restores chunk
   *lists* too: a fact, arena or epoch chunk this apply opened is freed,
   because `fact_append`/`dict_add`/`epoch_append` open a chunk exactly
   when the id crosses a boundary, and leaving one behind would double
   it on the next apply. Tested with a literal larger than an arena
   chunk, a head retract, new facts and a new epoch in the failing
   changeset, against a store that never saw it — and against a boot
   from the failed store's durable log.
9. **`Mem_FS` keeps a removed file's slot** (blank name) because handles
   are slot indices; `mem_file_ops` / `mem_fs_destroy` mirror
   `posix_file_ops`. The scale suite's private copy is gone.
10. **The wall clock is `time.now()` at apply, not injectable.** Tests
    that compare two separately-written stores compare epochs without
    walls (`same_projection(walls = false)`); every comparison against a
    replay of the same log compares them.

