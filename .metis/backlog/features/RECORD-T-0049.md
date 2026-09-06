---
id: encryption-at-rest-stays-out-of
level: task
title: "Encryption at rest stays out of the format: File_Ops is the seam, and a decrypt step keeps the proof layer honest"
short_code: "RECORD-T-0049"
created_at: 2026-09-06T13:44:25.546950+00:00
updated_at: 2026-09-06T13:44:25.546950+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#feature"


exit_criteria_met: false
initiative_id: NULL
---

# Encryption at rest stays out of the format

## Objective

**A note, not a change.** `log.md` §10 and `.metis/vision.md:360` already
decided that this format carries no encryption, and [[RECORD-I-0008]]
restated it as a non-goal on 2026-09-02. This records *why the question
keeps coming back*, what the honest argument for the other side is, and
where the seam is for a consumer who needs encryption anyway — so the next
session that asks reaches an answer rather than re-deriving one.

Nothing here is scheduled. If it is ever built, it is built by a consumer,
outside this repository.

## Type
- [x] Feature — the capability a consumer will ask for; filed as evidence

## The standing decision

`log.md` §10:

> **No compression, no encryption.** Encryption at rest, if required,
> belongs at the filesystem or volume layer, where it does not interfere
> with a third party's ability to verify the chain.

That clause is load-bearing and the reason survives re-derivation
(2026-09-06): `tests/verify/rdflog_verify.py` is ~270 lines of **stdlib**
Python, and Python's standard library has no AEAD. In-format encryption
therefore forces the independent verifier to take an external crypto
dependency, and "a third party can reimplement this from `log.md` alone
with nothing installed" quietly stops being true — which is goal 2 of §1
and the repository's stated value proposition.

Two more costs, both already named elsewhere: it would be a **format
version 3**, and a version does not read its predecessor (§10's own rule,
exercised once at `v0.4.0`); and it breaks [[RECORD-I-0008]]'s non-goal
that **migration stays a byte copy**, since a TPM- or HSM-bound key makes
a copied store useless on the destination host.

## The honest argument for the other side

Recorded because it is good, and because dismissing it is how this gets
re-opened badly.

**Fail-safe by default.** Volume encryption protects the disk and protects
no *copy*. Everything leaving a mounted filesystem is plaintext: an `scp`
of a store directory, a backup job reading through the mount, a
misconfigured bucket, a support engineer zipping a directory to reproduce
a bug. In-format encryption means plaintext never exists as a file, so
carelessness cannot leak it — and careless copies are a commoner breach
path than stolen drives. This is an operational argument, not a
cryptographic one, and it is the strongest one available.

**Encrypted in transit when a store is sent for external validation.**
This half does *not* survive scrutiny, and the reason is worth keeping:
external validation is the one workflow where the bytes must become
plaintext at the far end anyway. The auditor needs the key to verify, so
the ciphertext protected the transfer only against someone without it —
which an encrypted transport, or an `age`/PGP envelope to the auditor's
own public key, already does with per-recipient keys and no coupling to
the log format. Handing over the store's DEK also hands over the key to
every copy and backup under it, where an envelope's blast radius is one
tarball, and post-audit rotation would mean re-encrypting everything.
The right pairing for an audit trip is [[RECORD-T-0038]]'s **seal
signature** (authenticity, verifiable with a public key, no secret shared)
inside a transport envelope.

## The route, if a consumer needs it

**`File_Ops` is the seam and it already exists.** It is injectable
(`posix_file_ops`, `mem_file_ops`), it sees byte ranges rather than
records, and **both directions go through it** — the writer appends
through `append`/`sync`, and `verify`/`recover` read whole segments
through `ops.read` (`open.odin:139`, `:160`). An encrypting implementation
covers the write path, the boot path and the auditor's `verify` uniformly,
with **no format change and no version bump**.

The access pattern is what makes this cheap, and it is worth stating
because it is unusual: the log is read *in full, sequentially* at boot and
appended-to at commit, so there is no random access into ciphertext — no
sector-tweakable cipher, no read-modify-write, no partial-block handling.

Three design notes for whoever builds it:

- **Use a length-preserving stream cipher** (XChaCha20 or AES-CTR) keyed
  by segment number and file offset. The hash chain already provides
  integrity, so encryption owes only confidentiality; an AEAD would expand
  each record and fight the framing, while length-preservation keeps
  offsets, §7.2's torn-tail position rule and the CRCs exactly as
  specified.
- **`HEAD` is the nonce hazard.** Segments are append-only, so each offset
  is written once and offset-derived counters are safe. `HEAD` is an
  `O_TRUNC` rewrite at offset 0 on every commit (`writer.odin:280`,
  `:302`) — same key, same counter, different plaintext, which is
  keystream reuse. Either leave `HEAD` plaintext (it is a hash and an
  epoch, and [[RECORD-T-0037]] is making it a *published* anchor, so it is
  the least secret thing in the directory) or give it a fresh random nonce
  stored alongside.
- **Ship a documented decrypt step** — `rdfrecord decrypt <dir> <out>`,
  or the consumer's equivalent — producing the plaintext layout `log.md`
  specifies. This is what keeps the proof layer honest: the auditor
  decrypts once and runs the stdlib verifier against the exact format the
  document describes, so third-party verifiability survives.

**Do not merge this with [[RECORD-T-0038]]'s signing seam.** Share the
idiom (`proc` + `data: rawptr`, wired once at `store_open`, nil a stated
posture), never the struct. Signing uses an asymmetric private key that
should never leave an HSM or TPM and runs once per rotation; encryption
needs a symmetric DEK in process memory for every byte read and written.
One key for two purposes is the mistake hygiene exists to prevent, and one
`rawptr` holding both means whoever reaches the struct gets both. The
layers differ too — signing at the record layer over `finalHash`,
encryption below the format at the file layer. A consumer who wants them
related passes **the same `data` pointer to both seams** and derives each
key from one KEK with domain-separated labels; the package stays ignorant,
which is `RECORD-A-0006`'s stance holding for a third case.

## Why the seam is also the right commercial boundary

Raised in session (2026-09-06): encryption would be a premium product
feature, with tests and CI running unencrypted. The `File_Ops` route fits
that exactly and **this repository needs no changes for it** — the suites
already open every store over `mem_file_ops`, the default posture is
plaintext, and an encrypting wrapper is a consumer-side implementation of
an already-public struct. The paid part lives in the consuming
application, closed, with no build flag and no encrypted code path in the
open repository. In-format encryption would invert that: the mechanism
would sit here in the open, and the product would be a config knob.

## The one thing that would reopen this

**Selective disclosure** — handing an auditor some epochs and withholding
others. That cannot be done at the file layer, because `File_Ops` sees
bytes and not records, and it is a genuinely different feature from
encryption at rest. If it is ever required, it is a format-level design
question and this note does not answer it.

## Status

**2026-09-06 — filed as a note; nothing scheduled.** From a session
discussion following [[RECORD-I-0008]]'s findings. The decision it records
is `log.md` §10's and predates the discussion; what is new is the
`File_Ops` route, the `HEAD` nonce hazard, the decrypt-step argument, and
the reason the in-transit case is weaker than it first appears.
