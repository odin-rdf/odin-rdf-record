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
- [ ] **HEAD stops being advisory.** `write_head_file` becomes
      write-temp + `rename` + directory fsync, and its failure is no
      longer swallowed, because an anchor that can be half-written fails
      opens that nothing is wrong with. `writer.odin:442`'s doc comment
      ("a failure is swallowed, because the commit it trails is already
      durable") is amended, not deleted — it was right for an advisory
      file and is wrong for a load-bearing one.
- [ ] The default anchor is **read-then-compare-then-write**: `boot.odin`
      reads `HEAD` before `writer_create`/`writer_open` touch it, compares,
      and only then lets the writer stamp it. A store with no `HEAD` (a
      fresh one, or one from before this change) opens as today.

## Design notes and open questions

- **Where the anchor comes from is the consumer's business.** The local
  `HEAD` file is the weakest possible one — an attacker who can rewrite
  segments can rewrite it — but it is not worthless: it catches restoring
  from a stale backup, a partial copy, and a half-finished migration,
  which are the likelier real events. A remote witness is the strong form.
  Same seam either way.
- ~~**Open question for the owner:** should reading the local `HEAD` as a
  default anchor be built in, or must every anchor be supplied?~~
  **Answered 2026-09-06 — built in.** See *A signed HEAD* below; the
  argument that decided it is that HEAD is truncate-rewritten every
  commit, so an attacker who arrives after the fact does not have the
  older one. Built-in is still a behaviour change to `store_open` that
  can fail an open, which is why it lands before v1 rather than after.
- **Migration.** This is also the migration guard: a migration must be
  head-hash-preserving, and this check is that property made structural
  rather than procedural. Note in whatever runbook exists that the head
  must be captured **before** the store is opened on the destination.
- Do not make the anchor check part of `verify`'s chain walk. `verify`
  answers "were these bytes altered"; the anchor answers "is this the
  history we published". Keep the verdicts separable, the same way
  `Open_Error`'s replay-only members are kept separate from the walk's.

## A signed HEAD: what it buys, and what it does not (2026-09-06)

Raised in session: if `HEAD` carried a signature produced by the same
[[RECORD-T-0038]] seam as the seal, could an attacker still remove commits
from the tail? Worth writing down, because the first answer given was too
dismissive and the correction is the interesting part.

**The dismissal was wrong about the case that matters most.** The standard
objection to signing local state is replay: a signature says "the writer
once asserted this", never "this is the latest", so an attacker rolls the
store back to epoch 3 and presents the genuinely-signed `(H3, 3)` that was
current then. That objection assumes the attacker *has* that artifact —
and `write_head_file` is an `O_TRUNC` rewrite on every commit
(`writer.odin:280`, `:302`), so at epoch 5 the epoch-3 content is gone
from the directory. An attacker whose access begins at epoch 5 cannot
sign a `(H3, 3)` and never saw one. Truncating the log then leaves a
store whose HEAD says 5 and whose walk says 3, which this task's
comparison catches.

So a signed HEAD **bounds rollback to epochs the attacker observed a HEAD
for**, where today it is free. That is a real property, it is cheap
because the seam already exists, and it is the smash-and-grab case — the
stolen backup, the borrowed drive, the contractor with an afternoon.

**What it does not close is the persistent adversary**, which is the usual
threat model for history rewriting. Reading HEAD is strictly weaker than
the write access the attack already needs, so anyone able to truncate at
epoch 3 *while epoch 3 is current* can pocket that signed HEAD and present
it months later. Anything retaining old file contents does the same for
them: a backup, a ZFS or btrfs snapshot, a replicated volume. And every
truncation point corresponds to a genuine historical head, so there is
always a real signature to have captured — nothing is ever forged.

Two structural notes so this is not re-litigated:

- Freshness cannot come from inside the write domain. It needs a witness
  outside it, a hardware monotonic counter, or WORM storage for the
  sealed segments (§2, kept as partial in [[RECORD-I-0008]]'s
  Alternatives). This is the sealed-storage-without-a-counter result and
  it is not specific to this format.
- Making HEAD append-only instead of truncating does **not** help on its
  own. It relocates the same tail-truncation problem one file up.

**Decision: build it, and state the bound.** The local HEAD anchor is read
and compared by default (the acceptance criteria above), the signature is
an optional layer on top via [[RECORD-T-0038]]'s `Attestor`, and
[[RECORD-T-0039]] words the claim as *bounding* rollback rather than
preventing it — the same discipline as pinning `forged-clean` to what is
true rather than what is comfortable. A signed HEAD also makes the
published anchor self-authenticating in transit, which an external witness
wants anyway: the auditor learns it came from the writer rather than from
whoever handed them the drive.

Two costs to carry into implementation. HEAD must stop being advisory —
temp-file, rename, directory fsync, failure reported — which is why that
is an acceptance criterion now. And signing per commit puts the signer on
the commit path, where [[RECORD-T-0038]] deliberately kept it at rotation:
fine for a local or TPM-held key, not for a network HSM, so the HEAD
signature must be independently configurable from the seal signature
rather than implied by wiring an `Attestor`.

## Status

**2026-09-02 — todo.** Blocked on nothing; sequenced after
[[RECORD-T-0036]] only because that one is smaller and unblocks the
signing seam.

**2026-09-06 — the local-HEAD open question is answered** (built in, read
before write) and the signed-HEAD analysis is recorded above. Still todo;
scope grew by the durability change to `write_head_file`.
