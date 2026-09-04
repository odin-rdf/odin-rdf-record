---
id: the-attestor-and-attest-check
level: task
title: "The Attestor and Attest_Check seams: sign at rotation, verify at the seal, hold no key"
short_code: "RECORD-T-0038"
created_at: 2026-09-02T21:26:22.024846+00:00
updated_at: 2026-09-02T21:26:22.024846+00:00
parent: RECORD-I-0008
blocked_by: ["RECORD-T-0036"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: RECORD-I-0008
---

# The Attestor and Attest_Check seams

## Parent Initiative

[[RECORD-I-0008]]

## Objective **[REQUIRED]**

Let a consumer sign sealed segments and anchor the head **without this
package holding a key, choosing an algorithm, or touching a network**.
`RECORD-A-0006`'s stance for validation, applied to attestation.

## Blocked by

[[RECORD-T-0036]] — hard ordering, not a preference. §5.4 offers `sig` as a
signature "over finalHash"; until `finalHash` is cross-checked against the
walk, a signature over it attests a value nothing binds to the segment's
content. Shipping this first would make the system's assurances *worse* by
making an empty attestation look like a real one.

## The seams

Two structs, because signing happens on the write path inside a `Store`
while checking happens in `verify`, which an auditor calls with no store at
all. Both in the `Validator` idiom (`apply.odin:139`): `proc` + `data:
rawptr`, wired once, defaulted to off, nil meaning "the consumer's stated
posture rather than a per-caller escape".

```odin
Attestor :: struct {
    sign_seal: proc(data: rawptr, final_hash: [HASH_SIZE]u8, last_epoch: u64,
                    allocator: runtime.Allocator) -> ([]byte, bool),
    anchored:  proc(data: rawptr, head: [HASH_SIZE]u8, epoch: u64) -> bool,
    data:      rawptr,
}

Attest_Check :: struct {
    verify_seal: proc(data: rawptr, final_hash: [HASH_SIZE]u8, last_epoch: u64,
                      sig: []byte) -> bool,
    expect:      proc(data: rawptr) -> (head: [HASH_SIZE]u8, epoch: u64, known: bool),
    data:        rawptr,
}
```

`expect` is [[RECORD-T-0037]]'s half and lands there; this task adds the
other three.

## Acceptance Criteria **[REQUIRED]**

- [ ] `Attestor` wired at `store_open` beside `validator`, defaulted, and
      stored on the `Store` — the same "wired here and only here" comment
      the validator carries, for the same reason.
- [ ] `sign_seal` called in `rotate()` (`writer.odin:370`) where the `Seal`
      literal is already built with `final_hash = w.head`. **`seal_encode`
      needs no change** — `encode.odin:608` already writes `sig` as given.
      One call site covers both triggers, since `writer_seal` delegates to
      `rotate`.
- [ ] A signer that fails is a **writer failure**, not a swallowed one: an
      unsigned seal in a store configured to sign is a gap in the archive.
      Contrast `write_head_file`, whose failure is deliberately swallowed
      (`writer.odin:23`) — say in the doc comment why these differ.
- [ ] `verify_seal` called in `walk_segment`'s `.Segment_Seal` case, after
      [[RECORD-T-0036]]'s equalities. A seal carrying a signature that does
      not verify is `.Corrupt`; a seal carrying *no* signature when the
      check expects one is the consumer's policy to state — decide and
      document which, do not leave it implicit.
- [ ] `anchored` called **at rotation, not per epoch.** Rationale worth
      recording: rotation is already the rare, expensive,
      fsync-the-directory event and the seal is already the archival unit,
      whereas a per-epoch witness couples commit latency to a round trip —
      against the "~200 processes per physical machine, CPU frugality is a
      first-order requirement" constraint in `CLAUDE.md`.
- [ ] The sig blob carries a **key ID and an algorithm identifier**. §5.4
      calls `sig` opaque, so a small envelope inside it needs no format
      change and lets verification survive key rotation — which machine
      migration forces, since a TPM- or HSM-bound key cannot move.
- [ ] A key rollover writes an **environment note** (§5.5) naming the new
      key id: the note exists to record environment state the record
      depends on, its payload is documented as growing, and it is *inside*
      the chain — so custody handoff is part of the record rather than an
      out-of-band table.
- [ ] Tests wire a fake signer with no crypto at all — the `data: rawptr`
      shape makes this free, as the `Validator` tests show. At least one
      test signs with `core:crypto/ed25519` to prove the seam fits a real
      algorithm and that no external dependency is needed.
- [ ] `doc/api-surface.txt` updated in the same commit; `log.md` §5.4 and
      `api.md` amended to describe the seams (amend, don't rewrite).
- [ ] Both engines compile with no source change; format version stays 2.

## Open question for the owner

Whether attestation gets its own ADR alongside `RECORD-A-0006` — *"signing
is a hook; the store holds no key"* — or whether `RECORD-A-0006` is amended
to cover both hooks. The decision is the same either way; this is about
where it is recorded. **Ask before writing either.**

## Explicitly out of scope

Key management, rotation policy, a witness service, and any network code.
The point of the seam is that those live outside this package. Also out of
scope: hashing the seal into the chain — §5.4's asymmetry stands.

## Status

**2026-09-02 — todo.** Blocked by [[RECORD-T-0036]].
