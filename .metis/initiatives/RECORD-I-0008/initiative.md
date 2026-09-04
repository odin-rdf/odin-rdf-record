---
id: attestation-the-chain-proves
level: initiative
title: "Attestation: the chain proves integrity, not authenticity — the seal cross-check, the anchor, and the signing seam"
short_code: "RECORD-I-0008"
created_at: 2026-09-02T21:24:05.630043+00:00
updated_at: 2026-09-02T21:24:05.630043+00:00
parent: RECORD-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/discovery"


exit_criteria_met: false
estimated_complexity: L
initiative_id: attestation-the-chain-proves
---

# Attestation: the chain proves integrity, not authenticity Initiative

## Context **[REQUIRED]**

`README.md` opens with "A tamper-evident RDF **system of record**" and
`log.md` §1 goal 2 is "Be tamper-evident, and provably so by a third party."
An adversarial review on 2026-09-02 asked whether that holds. **The chain
itself holds, and is stronger than most claims of the kind** — term
definitions live *inside* it (§5.2), which closes the bbolt design's gap
where editing a dictionary entry rewrote the meaning of every fact naming
it and every hash still verified; the header's redundant fields are checked
against the walk's own counters rather than only their CRC
(`RECORD-T-0003`); the position rule refuses to launder mid-file damage as
a torn tail; and a second implementation agrees verdict for verdict over a
29-case corpus.

**What does not hold is anything the chain is not keyed to.** Three
findings, each reproduced against running code.

### 1. A sealed segment's seal record is entirely unvouched

A probe rewrote a seal's `finalHash` to `0xAA…` and its `lastEpoch`,
`recordCount` and `lastFactID` to `0xFF…`, then recomputed the frame CRC as
any editor of the file would. **`verify` returned `.None`, no tear.** The
Python verifier agrees: `check_seal` (`rdflog_verify.py:173`) checks length
arithmetic and nothing else.

The corpus has `sealed-bitflip-seal → corrupt`, but that catches only
*accidental* damage, because the CRC fails. The one class the hash chain
exists to catch — a recomputed-CRC edit — is tested for commit bodies
(`chain-broken-prev`, `chain-broken-hash`) and untested for the seal,
which has no chain coverage at all.

This matters because §5.4 designates the seal as the signature anchor
(`sigLen`/`sig`, "optional signature over finalHash") and §2 designates
sealed segments as the archival unit, "countersigned as a unit". **A
signature over `finalHash` today attests a value nothing binds to the
segment's contents.** A full walk still catches a rewritten sealed segment
via segment *n+1*'s header base hash — but §3 explicitly invites isolated
per-segment verification, and that reader has no check at all. It is the
same argument `RECORD-T-0003` already made for the header fields, applied
to the one field the format offers to sign.

### 2. Tail rollback is undetectable, and the open path destroys the witness

Truncating the open segment at a record boundary drops the last epoch with
no tear: verify clean, `last_epoch` 4 → 3. That much is *owned* —
`log.md:420` says a chain "proves that what remains was not altered, never
that nothing was removed from the end", and the corpus lists
`tail-cut-at-boundary → clean` as expected. The named mitigation is the
externally published head hash.

But a local witness exists — the `HEAD` file — and `writer.odin:185` says
"HEAD stays advisory (it is rewritten here, never read)". `writer_open`
calls `write_head_file` unconditionally, so **reopening a rolled-back store
stamps the new head over the old one.** `tool/main.odin:142` has a
stale-HEAD warning that would have fired; it can never fire after a
restart. The one mechanism in the repository that looks like a backstop is
vacuous by construction.

### 3. The chain is unkeyed, so history can be rewritten wholesale

`.metis/initiatives/RECORD-I-0008/forge.py` — ~120 lines of Python written
from `log.md`, importing `crc32c`/`be32` from *our own verifier* — rewrites
a 3-segment store (two of them sealed) so that an asserted fact reads as
retracted, and both reference verifiers report it clean:

```
$ python3 forge.py forged-store
forged  e9c935a4… 5   (ops rewritten: [(1, 0)])
$ python3 tests/verify/rdflog_verify.py forged-store
clean e9c935a46e047d27429f246074d730fa54a54f8c52b78185503f9ef58cca3bf6 5
$ ./build/record verify forged-store
head: e9c935a4…   epoch: 5   segments: 3
$ ./build/record head forged-store          # no staleness warning
$ diff <(record dump store) <(record dump forged-store)
< <http://example.org/a> <http://example.org/b> "5"^^xsd:integer .
> # retract: <http://example.org/a> <http://example.org/b> "5"^^xsd:integer .
```

`RECORD-T-0003`'s header cross-checks caught the *first* attempt — flipping
an assert to a retract shifts the fact-ID counter — which is that check
doing real work. It is not a key.

So what the chain provides today is **integrity, not authenticity**: it
detects modification by anything that cannot also recompute — bad sectors,
torn writes, a careless edit, a buggy writer, a truncated copy — and
nothing at all against write access to the directory. Goal 2 is half-met:
a third party really can verify without our code, but what they prove is
"internally consistent", not "this is the history that was written".

### The design named this and did not build it

`architecture.md:1104`:

> Publishing the head hash externally (or countersigning it) upgrades this
> from tamper-*evident* to tamper-*evident-and-attributable*, which is
> usually what a certification auditor is after. **This is a genuinely
> cheap thing to get right at the start and a genuinely expensive thing to
> retrofit.**

There is no publication path, no key, and the `sig` slot is
reserved-and-empty (`encode.odin:608`, "v1 writers pass none"). This
initiative is that sentence being acted on while it is still cheap.

### What makes it cheap now

- **No format change.** §5.4's `sigLen`/`sig` is already spent, already
  length-prefixed, already decoded and borrowed by `seal_decode`.
  `seal_encode` writes `sig` "as given". A store writing an empty sig and
  one writing a real sig are both format version 2. Key ID and algorithm
  ride inside the sig blob, which the format calls opaque; the custody
  handoff is an environment note (§5.5), which exists to record exactly
  this kind of environment change and whose payload the document already
  anticipates growing.
- **The hook idiom exists.** `Validator` (`apply.odin:139`) is the
  precedent and its doc comment states the rule: wired once at
  `store_open`, never per call, "so no entrance can skip the gate"; nil is
  "the consumer's stated posture rather than a per-caller escape".
- **`core:crypto` has `ed25519`, `ecdsa`, `hmac` and `mldsa`**, so signing
  costs no external dependency and the stance in `CLAUDE.md` is intact.

What is *not* cheap later is the anchor comparison: switching on a check
that can **fail an open** is a breaking operational change once stores
exist in the field. Done before v1, it is on from day one and no
deployment ever newly fails.

## Goals & Non-Goals **[REQUIRED]**

**Goals:**

- **Every redundant field the format carries is checked against the walk.**
  The seal joins the header; `forged-clean` and `seal-lies` join the fault
  corpus; both verifiers still agree verdict for verdict.
- **The open path compares before it overwrites.** A head that disagrees
  with the anchor is surfaced the way a `Tear` is surfaced — returned,
  never swallowed — and `HEAD` is not rewritten until it has been read.
- **A consumer can sign and anchor without this package holding a key.**
  `Attestor` on the write side, `Attest_Check` on the read side, both in
  the `Validator` idiom, both defaulting to off.
- **The claim in `README.md`, `vision.md` and `log.md` §1 states its own
  trust model**, so a reader learns the scope from us rather than from an
  adversarial review.
- No format version bump. Both engines compile with no source change.

**Non-Goals:**

- **This package will not hold a key, choose an algorithm, or talk to a
  network.** It offers seams. `RECORD-A-0006`'s stance for validation,
  applied to attestation.
- **Not an HMAC/keyed chain.** Verification would require the secret, so a
  third party could not verify without gaining forge capability — which
  contradicts goal 2 — and migrating a store would mean transporting
  forge capability to the new host. Per-segment signatures with a public
  verification key are the shape that survives both.
- **Not encryption at rest**, and nothing that makes a store unreadable on
  a different machine: migration must stay a byte copy.
- Not key management, rotation policy, or a witness service. Those are the
  consumer's, and the seams are what let them exist.

## Alternatives Considered **[REQUIRED]**

**Do nothing; the docs already say the mitigation is external.** True of
`log.md` §5.4, and false of `README.md`, which claims "Nothing is ever
deleted or rewritten" — a property of our writer, not of the format under
an adversary. Rejected: the repository's stated value proposition is
independent verifiability, and a reader cannot calibrate what the
verification is worth.

**Ship signing first, cross-check later.** Rejected on ordering grounds and
this is the reason the seal cross-check is task one: a signature over a
`finalHash` that nothing binds to the segment's content is not merely
incomplete, it is *convincing* theater. The cross-check must land first or
the signature makes the system's assurances worse.

**HMAC over the chain.** See Non-Goals. Rejected twice over — third-party
verification and machine migration.

**Rely on WORM storage for sealed segments**, per §2. Kept, but not
sufficient alone: object-lock metadata is a property of the storage object
and does not survive the copy that a machine migration is, whereas a
signature does. It also does nothing until the seal is cross-checked, since
a WORM-frozen segment can still be re-attested by an editable seal.

## Implementation Plan **[REQUIRED]**

1. **`RECORD-T-0036` — the seal is cross-checked.** Four equalities at
   `open.odin:389`; the same in `rdflog_verify.py`; `seal-lies` and
   `forged-clean` in the fault corpus. No new API, no format change, no
   consumer impact. **First, because everything else is worth less without
   it.**
2. **`RECORD-T-0037` — the open path compares rather than overwrites.**
   The anchor comparison in `boot.odin` after `recover()` and *before*
   `writer_create`/`writer_open` rewrite `HEAD`; a disagreement surfaced
   like a `Tear`; `verify` gains the check as a defaulted trailing
   parameter so every existing call site is source-compatible.
3. **`RECORD-T-0038` — the `Attestor` and `Attest_Check` seams.**
   `sign_seal` in `rotate()` (`writer.odin:370`), where the `Seal` literal
   is already built and `seal_encode` already writes `sig` as given;
   `verify_seal` in `walk_segment`'s `.Segment_Seal` case; `anchored` at
   rotation rather than per epoch, so commit latency is never coupled to a
   round trip. `doc/api-surface.txt` updated in the same commit — the
   mechanism from `RECORD-I-0005` working as designed.
4. **`RECORD-T-0039` — the claim, scoped.** `README.md`, `vision.md` and
   `log.md` §1 goal 2 state the trust model; `forge.py` becomes a
   maintained corpus artifact rather than a scratch file. Amend rather than
   rewrite, per the family convention.

**Open question for the owner, before task 3:** whether attestation gets
its own ADR alongside `RECORD-A-0006` — *"signing is a hook; the store
holds no key"* — or whether `RECORD-A-0006` is amended to cover both hooks.
Not decided here.

**Exit:** no redundant field in the format is unchecked; a rolled-back or
forged store fails an open against an anchor, and `forge.py` is a corpus
case proving it; a consumer can wire a signer and a witness without this
package linking crypto or a network; the top-level claim states its own
scope; format version unchanged at 2; both engines green with no source
change.

## Status

**2026-09-02 — filed, discovery.** Findings 1–3 reproduced against running
code; probes for 1 and 2 were temporary in-package tests and were removed,
`forge.py` is kept beside this document as the standing evidence for 3.
Nothing implemented.
