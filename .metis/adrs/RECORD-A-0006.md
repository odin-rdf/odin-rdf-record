---
id: 001-validation-is-a-hook-wired-by-the
level: adr
title: "Validation is a hook wired by the consumer, not a dependency"
number: 1
short_code: "RECORD-A-0006"
created_at: 2026-08-19T15:55:48.621551+00:00
updated_at: 2026-08-19T17:09:58.975386+00:00
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

# ADR-1: Validation is a hook wired by the consumer, not a dependency

**Status: accepted 2026-08-19.** Decides how "no epoch commits unvalidated" coexists
with the family's dependency direction, and where the shape catalogue lives.

## Context

The edit-surface companion document requires validation to run *inside*
`Apply`, on the writer, against the post-state of the changeset, before
anything is durable — one write path, one validation point, so no entrance
can skip the gate. But the SHACL implementation is odin-rdf-shacl, and the
family's arrow points the other way: validation engines consume stores,
stores do not import validation engines. `Apply` cannot call odin-rdf-shacl
by name without inverting the family's layering.

## Decision

Three parts:

1. **The validator hook is wired once, at store construction — never per
   `Apply` call.** A procedure (plus context pointer, in the family's
   style) receiving the post-state view and the changed focus terms,
   returning a report; `Apply` invokes it on every changeset. What varies
   per changeset is only the `Mode` field: under `Enforce` a
   non-conforming report aborts before `log.md` §7.1 step 1; under
   `Record` the epoch commits and the report returns with it. A hook
   *parameter* on `Apply` would quietly reintroduce the skip-the-gate
   failure this design exists to prevent — every caller choosing its own
   judge — so the judge is a property of the store, chosen where the store
   is opened. A nil hook at construction means no validation, and that is
   the *consumer's* posture, stated once, not a per-caller escape.
2. **The store owns the overlay view**: a read surface presenting
   head-plus-changeset as if applied, before anything is applied — nothing
   may touch the real structures before the fsync, so only the store can
   provide this honestly. It is part of the published API, usable by any
   hook.
3. **The shape catalogue and the validator live with odin-rdf-shacl.**
   Compiling `sh:` structures is that repository's whole competence; the
   catalogue (`api.md` §13.7) is the front half of its validator with a
   second consumer. This store provides the primitives compilation reads
   (layers 0–2 over the shapes graph) and the TBox-epoch key the catalogue
   caches by; it does not interpret a single `sh:` term itself.

The exact Odin types of the hook, the overlay view, and the report are
deliberately left to the first implementation of the odin-rdf-shacl port —
this ADR fixes who owns what, not signatures.

## Rationale

The single-validation-point property never depended on the store *knowing*
SHACL — it depends on `Apply` being the only write path, which holds
regardless of who supplies the judgment. The hook keeps the family arrow
downward, keeps this store usable with no validator at all (bulk tooling,
tests, non-SHACL consumers), and gives odin-rdf-shacl a seam it can bind
without this repository ever naming it.

## Consequences

### Positive
- Family layering intact; odin-rdf-shacl's port compiles against the
  published snapshot API and nothing else (a vision success criterion).
- Validation always runs when wired, and cannot be skipped by any writer,
  because there is exactly one writer entrance.

### Negative
- "No epoch commits unvalidated" is a property the *consumer* establishes
  by wiring the hook; the store alone guarantees the weaker "no epoch
  commits unjudged when a judge is wired". The documentation must say so
  plainly.
- The overlay view is real implementation work in the store for the
  benefit of an external engine — the price of the layering.

### Neutral
- `Record` mode's question — do findings become facts in a quarantine
  graph? — interacts with RECORD-A-0002 and stays open on the consumer's
  side; nothing in the store blocks either answer.