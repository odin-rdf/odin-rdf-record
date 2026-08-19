---
id: 001-derived-facts-are-not-logged-in-v1
level: adr
title: "Derived facts are not logged in v1"
number: 1
short_code: "RECORD-A-0002"
created_at: 2026-08-19T15:55:43.342393+00:00
updated_at: 2026-08-19T17:09:55.036474+00:00
decision_date: 
decision_maker: 
parent: 
archived: false

tags:
  - "#adr"
  - "#phase/decided"


exit_criteria_met: false
initiative_id: NULL
---

# ADR-1: Derived facts are not logged in v1

**Status: accepted 2026-08-19.** `log.md` §12 question 1 and `architecture.md` A.8.5,
which both documents deliberately left open. The format supports either
answer; this ADR proposes one for v1.

## Context

Op codes `0x11`/`0x12` (assert/retract, derived) exist so that inferred
facts *can* be epoch records (`log.md` §5.3). Logging the OWL 2 RL closure
makes replay a pure read but can multiply the log severalfold — a closure is
often several times the asserted fact count — and it puts the reasoner's
conclusions inside the record an auditor reads. Not logging them means
replay ends with a materialization pass, and the reproducibility of derived
facts rests on the environment note (`log.md` §5.5) identifying the engine
and rule set that produced them.

## Decision

**Derived facts are not logged in v1.** The log holds only what was stated.
Replay ends with a forward-materialization pass (`architecture.md` A.4's
eager strategy); the environment note records the store format version,
reasoner version, and rule set identifier and hash, so any closure is
attributable to the software that produced it; ops `0x11`/`0x12` remain
defined and reserved in the format. The choice is declared in the
environment note, as `log.md` §8 recommends, so a log is self-describing
about which regime produced it.

## Rationale

- The record's value proposition is *what was recorded*.
  `architecture.md` A.5 is emphatic that an auditor must never see an
  inference presented as a record; that rule is easiest to honor when
  inferences structurally cannot appear in the log.
- Size: `log.md` §9's 18–41 MB budget holds; logging closures could not
  promise that.
- Cost: full re-materialization at the target scale is seconds
  (`architecture.md` A.4), paid at open — which the eviction model already
  budgets as a wake cost.

## Consequences

### Positive
- The log stays small, and `verify` reads only human assertions.
- No writer machinery for keeping logged inferences consistent with the
  rule set that derived them.

### Negative
- Open/wake cost includes materialization, on the user-facing wake path.
- Re-deriving a *historical* closure requires the rule set in effect at
  that epoch to still be runnable — the environment note makes it
  identifiable, not available. Old rule sets must be retained as artifacts.

### Neutral
- Resident derived facts still carry origin (the derived bitset,
  `api.md` §2.2) and `Origin` stays required at every API surface; nothing
  about the read side changes with this decision.

## Review Triggers

- Whoever owns the audit relationship requires inferences to be part of the
  tamper-evident record — the format is ready; flip the regime, declare it
  in the environment note.
- Materialization cost grows past the wake budget (measured, not assumed).