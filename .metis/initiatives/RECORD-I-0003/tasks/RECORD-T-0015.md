---
id: apply-preconditions-candidate
level: task
title: "apply: preconditions, candidate, rollback, commit, publish — and the memory File_Ops"
short_code: "RECORD-T-0015"
created_at: 2026-08-20T11:47:09.367193+00:00
updated_at: 2026-08-20T11:47:09.367193+00:00
parent: RECORD-I-0003
blocked_by:
  - "RECORD-T-0013"
  - "RECORD-T-0014"
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
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

- [ ] The public surface as the initiative's Detailed Design §1 fixes
      it: `Op_Kind`, `Op`, `Mode`, `Changeset`, `Apply_Error`,
      `Apply_Error_Kind` (`None, Empty, Not_Live, Already_Live,
      Unsupported_Term, Rejected, Writer, Epoch_Exhausted`),
      `Resident_Op`, `apply`. `Op` is `{ kind: Op_Kind, using quad:
      rdf.Quad }` — decided at decomposition: the parser's own quad
      type, with `rdf.Graph_Label` making a literal graph
      unrepresentable (so there is no `.Bad_Graph`), and `using` so
      `op.subject`, `op.graph`, `op.triple` read directly, as
      `rdf.Quad` itself does under the family's `-vet -strict-style`.
- [ ] `mem_ops` / `Mem_FS` promoted from `tests/scale` beside
      `writer_posix.odin` as the seam's second implementation, with the
      doc comment saying tests and scratch, never data anyone keeps;
      `tests/scale` uses the promoted one. `OFS` stays test-private.
- [ ] Preconditions, in op order, each naming its op index: `.Empty`
      for zero ops (decision 6); `.Not_Live` for a retract of a quad not
      live at head-plus-earlier-ops; `.Already_Live` for an assert of one
      that is; assert→retract of one quad in one epoch is legal and
      yields a fact with interval `[E, E)`; retract→assert yields a new
      generation. Head is consulted through `snapshot_exists` over the
      published SPO order (`api.md` §6: no resident live-quad map); the
      changeset's own effects through a transient map freed with the
      call.
- [ ] Candidate build: facts appended with `assert = E+1`; retracted
      facts' `retract` set to `E+1` by atomic store; pending terms
      appended to the arena past the published `n_terms`; permutations
      rebuilt; the term index merged; a candidate `Index_Set` with
      `epoch = E+1` built but not installed. A `Snapshot{E+1, candidate}`
      is what the hook (T-0016) receives.
- [ ] Commit: `commit_encode` from the intern's `[]Term_Def` and the
      resolved ops, actor/reason as ids (0 for nil), wall = the
      writer's clock in Unix ns UTC; `writer_commit` appends and fsyncs;
      then `store_publish` installs the candidate under the mutex. Epoch
      = published + 1; `LIVE_EPOCH` refused as `.Epoch_Exhausted` before
      any mutation.
- [ ] Rollback on `.Rejected` (T-0016) or `.Writer`: `n_facts` back,
      every touched `retract` restored to `LIVE_EPOCH`, the dictionary
      truncated to the published `n_terms` (arena cursor and `off`;
      chunks allocated by this apply freed), the candidate freed, the
      transient maps freed. After rollback the projection is
      byte-identical to a store that never saw the changeset — tested
      by comparison, not asserted.
- [ ] `apply` is single-writer: documented as not safe against itself;
      a writer failure leaves the store fail-stop, as the `Writer` is.
- [ ] Tests: the error taxonomy, one minimal changeset per kind
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
- [ ] `log.md` §7.1 amended, dated: "apply to unpublished state,
      validate, fsync, publish" — nothing a published reader can
      observe changes before the durability boundary.
- [ ] Contract-level doc comments; `make check` and `make test` green.

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
