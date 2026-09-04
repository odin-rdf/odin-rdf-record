#!/usr/bin/env python3
"""Adversarial demonstration: rewrite a record store's history so that
both reference verifiers report it clean.

Uses nothing but the format specification in doc/design/log.md — the
same public information an auditor has. No key, because there is none.
"""
import hashlib, os, struct, sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from rdflog_verify import crc32c, be32, be64, HASH_SIZE, HEADER_SIZE  # their own code

KIND_EPOCH, KIND_SEAL, KIND_NOTE = 0x01, 0x02, 0x03


def segments(store):
    out, n = [], 1
    while True:
        p = os.path.join(store, "%06d.rlog" % n)
        if not os.path.exists(p):
            return out
        out.append(p)
        n += 1


def frames(data):
    """Yield (offset, body) for every framed record after the header."""
    off = HEADER_SIZE
    while off + 8 <= len(data):
        ln = be32(data, off)
        body_start, body_end = off + 8, off + 8 + ln
        if ln == 0 or body_end > len(data):
            return
        yield off, body_start, body_end
        off = body_end


def commit_ops_span(body):
    """Locate the fact-op array inside an epoch commit (log.md 5.1-5.3)."""
    n_terms, n_ops = be32(body, 33), be32(body, 37)
    p = 41
    for _ in range(n_terms):
        p += 8 + 4 + be32(body, p + 8)
    return p, n_ops


def forge(store, mutate):
    head = b"\x00" * HASH_SIZE
    last_epoch, fact_count, changed = 0, 0, []

    for path in segments(store):
        data = bytearray(open(path, "rb").read())
        seg_start_head = head
        seg_first_epoch = last_epoch + 1
        seg_first_fact = fact_count
        records = 0

        for off, bs, be_ in frames(data):
            body = data[bs:be_]
            kind = body[0]

            if kind == KIND_EPOCH:
                start, n_ops = commit_ops_span(body)
                for i in range(n_ops):
                    o = start + i * 33
                    new = mutate(be64(body, 1), bytes(body[o:o + 33]))
                    if new is not None:
                        body[o:o + 33] = new
                        changed.append((be64(body, 1), i))
                    if body[o] in (0x01, 0x11):
                        fact_count += 1
                # Re-chain: prevHash then hash, exactly as par. 6 defines them.
                body[-2 * HASH_SIZE:-HASH_SIZE] = head
                body[-HASH_SIZE:] = hashlib.sha256(bytes(body[:-HASH_SIZE])).digest()
                head = bytes(body[-HASH_SIZE:])
                last_epoch = be64(body, 1)
                records += 1

            elif kind == KIND_NOTE:
                body[-2 * HASH_SIZE:-HASH_SIZE] = head
                body[-HASH_SIZE:] = hashlib.sha256(bytes(body[:-HASH_SIZE])).digest()
                head = bytes(body[-HASH_SIZE:])

            elif kind == KIND_SEAL:
                # Not chained at all (par. 5.4), so this is cosmetic —
                # but keep the summary self-consistent anyway.
                body[1:9] = struct.pack(">Q", last_epoch)
                body[9:17] = struct.pack(">Q", records)
                body[17:21] = struct.pack(">I", fact_count)
                body[21:53] = head

            data[bs:be_] = body
            data[off + 4:off + 8] = struct.pack(">I", crc32c(bytes(data[off:off + 4]) + bytes(body)))

        # The segment header. The walk cross-checks first_epoch and
        # first_fact_id against its own counters (RECORD-T-0003), so a
        # forger recomputes those from the rewritten history as well.
        data[16:24] = struct.pack(">Q", seg_first_epoch)
        data[24:28] = struct.pack(">I", seg_first_fact)
        data[32:64] = seg_start_head
        data[28:32] = struct.pack(">I", crc32c(bytes(data[0:28])))
        open(path, "wb").write(bytes(data))

    # And the advisory witness, which the store rewrites at every open anyway.
    with open(os.path.join(store, "HEAD"), "w") as f:
        f.write("%s %d\n" % (head.hex(), last_epoch))
    return head, last_epoch, changed


if __name__ == "__main__":
    store = sys.argv[1]

    def mutate(epoch, op):
        # Turn the first assert we meet into a retract: the fact was
        # never true, and the record now says so.
        if op[0] == 0x01:
            mutate.done = getattr(mutate, "done", 0) + 1
            if mutate.done == 1:
                return bytes([0x02]) + op[1:]
        return None

    head, ep, changed = forge(store, mutate)
    print("forged  %s %d   (ops rewritten: %s)" % (head.hex(), ep, changed))
