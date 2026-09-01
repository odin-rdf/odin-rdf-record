#!/usr/bin/env python3
"""The exported surface of package `record`, computed and checked.

RECORD-I-0005. Two commands:

    api_surface.py closure [--consumers DIR ...]
        Recompute the surface from the sources: parse every non-test
        declaration in record/, take the names consumers actually spell, and
        close over public signatures and public value-type fields. Prints the
        classification. This is how doc/api-surface.txt was derived, and how a
        proposed change to it is justified.

    api_surface.py check
        Compare the names exported today against doc/api-surface.txt and exit
        non-zero on any difference. This is what `make api` runs.

Why a closure and not a grep: a consumer writes `r := snapshot_match(...)` and
never names `Range`, so textual search under-reports the surface by about a
third. Traversal stops at the opaque handles -- `Store`, `Snapshot`, `Range`,
`Scan` and their kind -- whose fields are internal even though the handle is
public; Odin has no opaque struct, so that boundary is a decision recorded here
rather than a thing the language enforces.

Why not `odin doc -doc-format`: it aborts the compiler on dev-2026-08
(`src/docs_writer.cpp(268)` assertion, reproducible on core/strings), so the
textual output is the only available input.
"""
import argparse
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SURFACE = os.path.join(ROOT, "doc", "api-surface.txt")

# Handles a consumer holds but never reads a field of. The closure reaches
# them and stops: their internals stay private. Changing this set changes the
# surface, so it belongs in review.
OPAQUE = {
    "Store", "Snapshot", "Writer", "Range", "Scan", "Index_Set", "Dict",
    "Loader", "Intern", "Mem_FS", "Mem_File", "Term_Iter", "Op_Iter",
}

# Names kept public by an explicit decision rather than by reachability.
# LIVE_EPOCH: `Fact` is public (reached through `snapshot_fact`), and
# `Fact.epoch_end == LIVE_EPOCH` is the only way to read a fact's liveness --
# api.md par. 10 documents the sentinel. Nothing spells it today; it is
# exported so that the public struct is interpretable. (RECORD-T-0030)
PROMOTED = {"LIVE_EPOCH"}

DECL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*(::|:=)")
WORD = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\b")


def parse_package(src):
    """Public top-level declarations -> declaration text."""
    out = {}
    for path in sorted(glob.glob(os.path.join(src, "*.odin"))):
        if path.endswith("_test.odin"):
            continue
        lines = open(path).read().split("\n")
        priv, i = False, 0
        while i < len(lines):
            ln = lines[i]
            if ln.startswith("@"):
                priv = priv or "private" in ln
                i += 1
                continue
            m = DECL.match(ln)
            if m:
                text, depth, j = [], 0, i
                while j < len(lines):
                    l = lines[j]
                    text.append(l)
                    depth += l.count("(") + l.count("{") + l.count("[")
                    depth -= l.count(")") + l.count("}") + l.count("]")
                    if depth <= 0:
                        break
                    j += 1
                if not priv:
                    out[m.group(1)] = "\n".join(text)
                priv, i = False, j + 1
                continue
            if ln and not ln.startswith((" ", "\t", "//")):
                priv = False
            i += 1
    return out


def type_refs(name, text, names):
    """Names referenced by a declaration's *type surface*.

    A procedure contributes its signature only, never its body. An enum
    contributes its header only -- its members are declarations, not
    references, and `Apply_Error_Kind.Writer` would otherwise drag in the
    `Writer` type. Comments are stripped: prose naming `verify` is not a
    dependency on it.
    """
    text = "\n".join(re.sub(r"//.*$", "", l) for l in text.split("\n"))
    head = text.split("\n")[0]
    if re.search(r"::\s*enum\b", head):
        text = head
    elif re.search(r"::\s*proc\b", head):
        m = re.search(r"\)\s*(->\s*\(?[^{]*\)?)?\s*\{", text, re.S)
        if m:
            text = text[: m.end() - 1]
    return {w for w in WORD.findall(text) if w in names and w != name}


def spelled_by(consumers, names, aliases=("record", "rec")):
    """Names a consumer tree spells as <alias>.<name>."""
    hit = set()
    for d in consumers:
        if not os.path.isdir(d):
            continue
        for path in glob.glob(os.path.join(d, "**", "*.odin"), recursive=True):
            src = open(path, errors="ignore").read()
            for a in aliases:
                for m in re.findall(rf"\b{a}\.([A-Za-z_][A-Za-z0-9_]*)\b", src):
                    if m in names:
                        hit.add(m)
    return hit


def closure(seed, refs):
    seen, work = set(seed), list(seed)
    while work:
        n = work.pop()
        if n in OPAQUE:
            continue
        for r in refs.get(n, ()):
            if r not in seen:
                seen.add(r)
                work.append(r)
    return seen


def read_surface():
    names = []
    for line in open(SURFACE):
        line = line.strip()
        if line and not line.startswith("#"):
            names.append(line)
    return set(names)


def test_file_names(src):
    """Names declared in record/*_test.odin.

    `odin doc` reports the package's @(test) procedures alongside everything
    else. They are not surface: they exist only in files the compiler includes
    for `odin test`. Excluded by where they are declared rather than by a
    `test_` prefix, so a test helper that is not named `test_*` is excluded too.
    """
    out = set()
    for path in glob.glob(os.path.join(src, "*_test.odin")):
        for line in open(path):
            m = DECL.match(line)
            if m:
                out.add(m.group(1))
    return out


def exported_now():
    """Names `odin doc` reports as exported by package record, less the
    declarations that live in the in-package test files."""
    out = subprocess.run(
        ["odin", "doc", "record", "-collection:rdf=../odin-rdf-parser", "-short"],
        cwd=ROOT, capture_output=True, text=True, check=True).stdout
    names = set()
    for line in out.split("\n"):
        m = re.match(r"\s+([A-Za-z_][A-Za-z0-9_]*)\s*::", line)
        if m:
            names.add(m.group(1))
    return names - test_file_names(os.path.join(ROOT, "record"))


def cmd_closure(args):
    src = os.path.join(ROOT, "record")
    decls = parse_package(src)
    names = set(decls)
    refs = {n: type_refs(n, t, names) for n, t in decls.items()}

    ext = spelled_by(args.consumers, names)
    ingest = spelled_by([os.path.join(src, "ingest")], names)
    tool = spelled_by([os.path.join(ROOT, "tool")], names)
    tests = spelled_by([os.path.join(ROOT, "tests")], names)

    api = closure(ext | ingest, refs) | PROMOTED
    fmt = closure(tool, refs) - api
    private = names - api - fmt

    print(f"exported today:      {len(names)}")
    print(f"store API:           {len(api)}  ({len(api & (ext | ingest))} spelled, "
          f"{len(api - ext - ingest)} reached by inference)")
    print(f"format layer (tool/): {len(fmt)}")
    print(f"private candidates:  {len(private)}  "
          f"({len(private & tests)} held public by tests/, {len(private - tests)} free)")
    if args.verbose:
        for label, s in (("API", api), ("FORMAT", fmt), ("PRIVATE", private)):
            print(f"\n{label}:")
            for n in sorted(s):
                print(f"  {n}")
    return 0


def cmd_check(args):
    want, have = read_surface(), exported_now()
    added, removed = sorted(have - want), sorted(want - have)
    if not added and not removed:
        print(f"api: {len(want)} exported names, as stated in doc/api-surface.txt")
        return 0
    print("api: the exported surface of package `record` does not match "
          "doc/api-surface.txt", file=sys.stderr)
    for n in added:
        print(f"  + {n}  (exported, not in the surface file)", file=sys.stderr)
    for n in removed:
        print(f"  - {n}  (in the surface file, no longer exported)", file=sys.stderr)
    print("\nIf this change to the public interface is intended, update "
          "doc/api-surface.txt in the same commit (RECORD-I-0005).", file=sys.stderr)
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("closure", help="recompute the surface from the sources")
    c.add_argument("--consumers", nargs="*", default=["../odin-rdf-shacl", "../odin-rdf-sparql"])
    c.add_argument("-v", "--verbose", action="store_true")
    c.set_defaults(fn=cmd_closure)
    k = sub.add_parser("check", help="compare today's exports against the surface file")
    k.set_defaults(fn=cmd_check)
    a = ap.parse_args()
    sys.exit(a.fn(a))


if __name__ == "__main__":
    main()
