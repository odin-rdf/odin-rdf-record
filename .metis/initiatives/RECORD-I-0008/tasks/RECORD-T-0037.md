---
id: the-open-path-compares-before-it
level: task
title: "The open path compares before it overwrites: the anchor, and HEAD read before it is rewritten"
short_code: "RECORD-T-0037"
created_at: 2026-09-02T21:25:52.751515+00:00
updated_at: 2026-09-02T21:25:52.751515+00:00
parent: RECORD-I-0008
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0008
---

# The open path compares before it overwrites

## Parent Initiative

[[RECORD-I-0008]]

## Objective **[REQUIRED]**

Give the open path an anchor to check the log against, and stop it
destroying the only local witness it already has.

## The problem, reproduced

Truncating the open segment **at a record boundary** drops the last epoch
with no tear at all: `verify` returns `.None`, `Tear_Kind.None`,
`last_epoch` 4 → 3. This is expected and owned — `log.md:420`, and the
corpus pins `tail-cut-at-boundary → clean`. A chain proves what remains was
not altered, never that nothing was removed from the end.

What is not owned is the second half. `writer_open` calls
`write_head_file(w)` unconditionally (`writer.odin:233`), and its own
comment says HEAD is "rewritten here, never read" (`writer.odin:185`). So
reopening a rolled-back store **stamps the rolled-back head over the
previous one**, and `tool/main.odin:142`'s stale-HEAD warning — which would
have fired — can never fire after a restart. A probe confirmed the
overwrite.

The consequence is operational: the one mechanism in the repository that
looks like a rollback backstop is vacuous, and the failure is silent.

## Acceptance Criteria **[REQUIRED]**

- [ ] `Attest_Check`'s `expect` half exists and is honoured: an anchor
      supplies an expected `(head, epoch)`, and the open path compares the
      recovered `Verify_Result` against it **before** anything writes.
- [ ] The comparison lives in `boot.odin` after `recover()` returns and
      **before** the `writer_create` / `writer_open` calls, because both
      rewrite `HEAD`. Getting this ordering wrong reproduces the bug.
- [ ] A disagreement is surfaced, never swallowed — the `Tear` precedent
      (`boot.odin`: "A recovery event is surfaced in `tear`, never
      swallowed"). A distinct verdict, not a reused one: an anchor
      mismatch is neither corruption nor a tear.
- [ ] A *lower* epoch than the anchor is distinguishable from an unrelated
      head at the same epoch. The first is a rollback, the second is a
      different store; an operator needs to know which.
- [ ] With no anchor wired, behaviour is exactly as today — the
      `Validator` posture: nil means the consumer has stated one.
- [ ] `verify` takes the check as a **defaulted trailing parameter**, so
      every existing call site is source-compatible and `make api` sees an
      addition rather than a break. The CLI's `record verify` is the
      auditor's entry point and should be able to pass one.
- [ ] Tests: rollback-at-boundary caught against an anchor; forged store
      caught against an anchor; clean store with a matching anchor opens;
      no anchor behaves as today. All on `Mem_FS`.
- [ ] `make check` green; `doc/api-surface.txt` updated in the same commit.

## Design notes and open questions

- **Where the anchor comes from is the consumer's business.** The local
  `HEAD` file is the weakest possible one — an attacker who can rewrite
  segments can rewrite it — but it is not worthless: it catches restoring
  from a stale backup, a partial copy, and a half-finished migration,
  which are the likelier real events. A remote witness is the strong form.
  Same seam either way.
- **Open question for the owner:** should reading the local `HEAD` as a
  default anchor be built in, or must every anchor be supplied? Built-in
  is a behaviour change to `store_open` that can fail an open, which is
  precisely the kind of change that gets expensive after v1 — an argument
  for deciding it now, either way.
- **Migration.** This is also the migration guard: a migration must be
  head-hash-preserving, and this check is that property made structural
  rather than procedural. Note in whatever runbook exists that the head
  must be captured **before** the store is opened on the destination.
- Do not make the anchor check part of `verify`'s chain walk. `verify`
  answers "were these bytes altered"; the anchor answers "is this the
  history we published". Keep the verdicts separable, the same way
  `Open_Error`'s replay-only members are kept separate from the walk's.

## Status

**2026-09-02 — todo.** Blocked on nothing; sequenced after
[[RECORD-T-0036]] only because that one is smaller and unblocks the
signing seam.
