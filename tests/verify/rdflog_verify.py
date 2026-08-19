#!/usr/bin/env python3
"""An independent verifier for the rdflog format, format version 1.

Written from doc/design/log.md ALONE — the constraint this file exists
to prove (RECORD-T-0006): the repository's value proposition is that a
third party can verify the chain from the format specification without
running its binary, and this is that third party's afternoon, made
executable. It deliberately reads no Odin source; every constant cites
the section of log.md it comes from, so a reviewer checks this file
against the document, not against the implementation it cross-examines.

Standard library only. CRC-32C is not in it; the table is ~15 lines and
is part of the afternoon (§6: "framing, CRC-32C, SHA-256, big-endian
integers").

Usage: rdflog_verify.py <store-dir>

Output, one line on stdout:
    clean <head-hex> <last-epoch>
    torn-tail <segment> <offset> <head-hex> <last-epoch>
    torn-header <segment> 0 <head-hex> <last-epoch>
    <verdict>                       -- a halting verdict, one word

where a halting verdict is one of: no-store, io-error, bad-header,
base-hash-mismatch, corrupt, chain-broken, epoch-gap. For the torn
verdicts, head and epoch describe the log as recovery would leave it
(§7.2); this verifier repairs nothing. Exit code: 0 clean, 2 torn,
1 halt — the same contract as the Odin tool, so harnesses can compare.
"""

import hashlib
import os
import struct
import sys

# §3: fixed 64-byte header, magic, version 1. §4: 8-byte frame overhead,
# MaxRecordSize 64 MiB. §5.1/§5.5/§6: two 32-byte hashes close a chained
# body. §5.3: a fact operation is 33 bytes.
MAGIC = b"RDFLOG\x00\x00"
VERSION = 1
HEADER_SIZE = 64
HASH_SIZE = 32
FRAME_OVERHEAD = 8
MAX_RECORD_SIZE = 64 * 1024 * 1024
OP_SIZE = 33

# §4: the body's first byte is the record kind; 0x04..0x7F reserved, and
# an unknown kind in a sealed segment must fail, never skip.
KIND_EPOCH = 0x01
KIND_SEAL = 0x02
KIND_NOTE = 0x03

# §5.3: op kinds; the high nibble carries origin. §5.3 amended
# 2026-08-19: G == 0 is the default graph. (Values are otherwise the
# replayer's business, not the verifier's — §6 checks the chain.)
OP_KINDS = {0x01, 0x02, 0x11, 0x12}
OP_ASSERTS = {0x01, 0x11}  # fact IDs count asserts (§5.3: positional)

# CRC-32C, the reflected Castagnoli polynomial (§4 names CRC-32C; the
# check value crc32c(b"123456789") == 0xE3069283 is the standard one).
_TABLE = []
for _n in range(256):
    _c = _n
    for _ in range(8):
        _c = (_c >> 1) ^ 0x82F63B78 if _c & 1 else _c >> 1
    _TABLE.append(_c)


def crc32c(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for b in data:
        crc = _TABLE[(crc ^ b) & 0xFF] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFF


assert crc32c(b"123456789") == 0xE3069283


def be32(b, off):
    return struct.unpack_from(">I", b, off)[0]


def be64(b, off):
    return struct.unpack_from(">Q", b, off)[0]


class Halt(Exception):
    """A halting verdict (§7.2: corruption or tampering, never truncated)."""

    def __init__(self, verdict):
        self.verdict = verdict


class Verifier:
    """§6's Verify: one sequential pass, walking segments in order."""

    def __init__(self):
        self.head = b"\x00" * HASH_SIZE  # zero for segment 1 (§3)
        self.last_epoch = 0
        self.fact_count = 0  # asserts seen; the fact-ID high-water (§5.3)

    def check_header(self, data, seg_no, final):
        """§3's fixed 64 bytes, plus the cross-checks of the §6 amendment
        (2026-08-19): segment number, first epoch, and first fact ID are
        verified by equality against the walk's own state, the same way
        the base hash is. Returns "husk" for §7.2's rotation-crash husk
        (amendment: a final segment whose header never became durable)."""
        short = len(data) < HEADER_SIZE
        bad = short or data[0:8] != MAGIC or be32(data, 28) != crc32c(data[0:28])
        version_only = (
            not bad and be32(data, 8) != VERSION
        )  # a valid header of a future format: never a husk
        if bad or version_only:
            if final and len(data) <= HEADER_SIZE and not version_only:
                return "husk"
            raise Halt("bad-header")
        if be32(data, 12) != seg_no:
            raise Halt("bad-header")
        if be64(data, 16) != self.last_epoch + 1:
            raise Halt("bad-header")
        if be32(data, 24) != self.fact_count:
            raise Halt("bad-header")
        if data[32:64] != self.head:
            # §3: the base hash is checked by equality against the
            # previous segment's head — stronger than any checksum.
            raise Halt("base-hash-mismatch")
        return "ok"

    def check_commit(self, body):
        """§5.1's epoch commit: structure exact, then §6's chain rules —
        epoch contiguity, prevHash equality, hash recomputation."""
        if len(body) < 41 + 2 * HASH_SIZE:
            raise Halt("corrupt")
        n_terms = be32(body, 33)
        n_ops = be32(body, 37)
        tail = len(body) - 2 * HASH_SIZE
        off = 41
        for _ in range(n_terms):  # §5.2: id u64, len u32, payload
            if off + 12 > tail:
                raise Halt("corrupt")
            off += 12 + be32(body, off + 8)
            if off > tail:
                raise Halt("corrupt")
        if tail - off != n_ops * OP_SIZE:
            raise Halt("corrupt")
        for i in range(n_ops):  # §5.3: op kind is the op's first byte
            if body[off + i * OP_SIZE] not in OP_KINDS:
                raise Halt("corrupt")
        epoch = be64(body, 1)
        if epoch != self.last_epoch + 1:
            raise Halt("epoch-gap")  # §5.1: gap-free, strictly increasing
        self.chain(body)
        self.last_epoch = epoch
        for i in range(n_ops):
            if body[off + i * OP_SIZE] in OP_ASSERTS:
                self.fact_count += 1

    def check_note(self, body):
        """§5.5's environment note: it carries the chain, advances no
        epoch. lastEpoch is redundant and is the replayer's check."""
        if len(body) < 13 + 2 * HASH_SIZE:
            raise Halt("corrupt")
        if 13 + be32(body, 9) + 2 * HASH_SIZE != len(body):
            raise Halt("corrupt")
        self.chain(body)

    @staticmethod
    def check_seal(body):
        """§5.4's segment seal: read, never chained — a summary. Its
        structure must still decode; its values are trusted by nothing."""
        if len(body) < 57 or 57 + be32(body, 53) != len(body):
            raise Halt("corrupt")

    def chain(self, body):
        """§6: hash = SHA-256(body minus the trailing hash); prevHash is
        the 32 bytes before it and must equal the running head."""
        if body[-2 * HASH_SIZE : -HASH_SIZE] != self.head:
            raise Halt("chain-broken")
        if hashlib.sha256(body[: -HASH_SIZE]).digest() != body[-HASH_SIZE:]:
            raise Halt("chain-broken")
        self.head = body[-HASH_SIZE:]

    def walk_records(self, data, final):
        """§4's framing and §7.2's taxonomy under the position rule.
        Returns (None) for a clean segment or the tear offset."""
        off = HEADER_SIZE
        while True:
            rest = len(data) - off
            if rest == 0:
                return None
            if rest < FRAME_OVERHEAD:
                # §7.2 amended: 1..7 trailing bytes are a partial frame
                # header — torn, not clean end.
                if final:
                    return off
                raise Halt("corrupt")
            length = be32(data, off)
            torn_shape = length == 0 or length > MAX_RECORD_SIZE or rest - FRAME_OVERHEAD < length
            body_end = off + FRAME_OVERHEAD + length
            if not torn_shape and be32(data, off + 4) != crc32c(data[off : off + 4] + data[off + 8 : body_end]):
                # §7.2 amended: a CRC-failed frame whose extent ends
                # before the file does cannot be a torn append — the
                # writer is fail-stop — so it is evidence, and halts.
                if body_end < len(data):
                    raise Halt("corrupt")
                torn_shape = True
            if torn_shape:
                if final:
                    return off
                raise Halt("corrupt")
            body = data[off + FRAME_OVERHEAD : body_end]
            kind = body[0]
            if kind == KIND_EPOCH:
                self.check_commit(body)
            elif kind == KIND_NOTE:
                self.check_note(body)
            elif kind == KIND_SEAL:
                self.check_seal(body)
            else:
                # §4: an unknown kind fails, never skips — and its CRC
                # just verified, so it is never torn either (§7.2
                # amended).
                raise Halt("corrupt")
            off = body_end


def verify(store):
    v = Verifier()
    seg_no = 1
    try:
        data = read_segment(store, seg_no)
    except FileNotFoundError:
        return ("no-store",)
    while True:
        try:
            nxt = read_segment(store, seg_no + 1)
        except FileNotFoundError:
            nxt = None
        final = nxt is None
        husk = v.check_header(data, seg_no, final)
        if husk == "husk":
            return ("torn-header", seg_no, 0, v.head, v.last_epoch)
        tear = v.walk_records(data, final)
        if tear is not None:
            return ("torn-tail", seg_no, tear, v.head, v.last_epoch)
        if final:
            return ("clean", v.head, v.last_epoch)
        data = nxt
        seg_no += 1


def read_segment(store, seg_no):
    # §2: segments numbered from 1, zero-padded to six digits. The first
    # absent file ends the log; numbering is contiguous.
    with open(os.path.join(store, "%06d.rlog" % seg_no), "rb") as f:
        return f.read()


def main():
    if len(sys.argv) != 2:
        print("usage: rdflog_verify.py <store-dir>", file=sys.stderr)
        return 1
    try:
        r = verify(sys.argv[1])
    except Halt as h:
        print(h.verdict)
        return 1
    except OSError:
        print("io-error")
        return 1
    if r[0] == "clean":
        print("clean %s %d" % (r[1].hex(), r[2]))
        return 0
    if r[0] in ("torn-tail", "torn-header"):
        print("%s %d %d %s %d" % (r[0], r[1], r[2], r[3].hex(), r[4]))
        return 2
    print(r[0])
    return 1


if __name__ == "__main__":
    sys.exit(main())
