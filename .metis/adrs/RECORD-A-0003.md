---
id: 001-large-literals-stay-in-the-log
level: adr
title: "Large literals stay in the log, uncapped, in v1"
number: 1
short_code: "RECORD-A-0003"
created_at: 2026-08-19T15:55:44.764283+00:00
updated_at: 2026-08-19T17:09:56.407049+00:00
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

# ADR-1: Large literals stay in the log, uncapped, in v1

**Status: accepted 2026-08-19.** `log.md` §12 question 2. That document leans toward a
content-addressed blob store above ~64 KB; this ADR proposes the opposite
for v1, and says why the lean does not survive contact with the design's
own thesis.

## Context

A term definition is length-prefixed with a `u32` (`log.md` §5.2), so a
document-sized literal can be stored inline — the 32 KB ceiling was a B+tree
artifact and died with the B+tree. The worry is that large opaque blobs
inflate the file that must be verified on every start and sit in a log whose
value is being readable. The alternative is a content-addressed blob store
beside the log, with the hash as the term.

## Decision

**Every literal lives in the log, whatever its size, in v1.** No threshold,
no blob store, no second durable representation. `MaxRecordSize` (64 MiB,
`log.md` §4) is the only bound. Consumers whose users upload documents are
advised — in the API documentation, not enforced — to model an upload as a
reference (a content hash, a filename, an external location) rather than as
a literal carrying megabytes, because an RDF term is an identifier-sized
thing; but that is application modelling advice, not a store mechanism.

## Rationale

The design's organizing property is *one record, everything else derived* —
it is the stated reason checkpoints were rejected (`log.md` §11.5) and
`mmap`-ed caches were rejected (`api.md` §9). A blob store is a second
durable representation with every disease those rejections name: it can be
missing, disagree, or be tampered with independently, and the chain then
covers a hash while the bytes it names live outside the tamper evidence's
custody. Deferring it is also the cheap direction to be wrong in: adding a
blob store later is additive (a new term convention plus a directory), while
removing one means rewriting history, which the format forbids.

## Consequences

### Positive
- One durable representation; `verify` covers every byte the dataset
  depends on.
- No custody, backup, or garbage-collection story for a second store.

### Negative
- Verification and replay cost grow with literal bytes; a tenant who stores
  many large documents as literals pays for them on every wake.
- Dictionary arena residency grows the same way (`api.md` §4) — large
  literals are resident today because the dictionary is.

### Neutral
- Nothing in the format changes either way; this is writer policy plus
  documentation.

## Review Triggers

- Measured replay or verification time breaching the wake budget with
  literal volume as the cause.
- A consumer with a real need for values past `MaxRecordSize`, which no
  inline policy can serve.