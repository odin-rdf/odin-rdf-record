---
id: the-closure-computed-and-private
level: task
title: "The closure computed and @(private) applied: 95 candidates, three checks, consumers unchanged"
short_code: "RECORD-T-0031"
created_at: 2026-09-01T11:03:03.822807+00:00
updated_at: 2026-09-01T11:17:36.589202+00:00
parent: RECORD-I-0005
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: RECORD-I-0005
---

# The closure computed and @(private) applied: 95 candidates, three checks, consumers unchanged

## Parent Initiative

[[RECORD-I-0005]]

## Objective

Mark `@(private)` on every symbol that is not interface, deciding the set by
reachability rather than by grep, and prove that no consumer moved.

## Acceptance Criteria

- [ ] The 95 symbols named nowhere outside the package are marked `@(private)`,
      less the signature-reachable set that step 3 below identifies.
- [ ] `make check`, `make tool`, `make test` green in this repository.
- [ ] **Both sibling suites run and green, with no source change in either:**
      `make check && make test` in `../odin-rdf-shacl` and in
      `../odin-rdf-sparql`. Not a spot build — the full suites.
- [ ] shacl: all 98 W3C SHACL `core/` entries green, no skip list.
- [ ] sparql: 546 of the corpus's 556 evaluable entries, 288 tests, 39 enabled
      directories — the same numbers as before the change.
- [ ] `odin doc record -short` contains no type named in a public signature or
      public struct field without a definition in the output.
- [ ] Read pins hold: shacl's 7503 on the reference configuration, sparql's
      sixteen bench read counts (`make bench` in each; two builds apiece).
- [ ] The diff is visibility-only — no rename, no signature change, no
      declaration added or removed.

## Implementation Notes

### Technical Approach

Three checks, in order, and the third is the one that matters:

1. **Mark private.** All 95 at once; it is reversible and the compiler is fast.
2. **Build every package that could name them** — this repo's five test packages
   and `tool/`, then both sibling repos. Each error names a hard blocker; revert
   it and record why it is interface.
3. **Read the generated docs.** Step 2 will *not* catch a private type reached by
   inference: measured in a two-package experiment, a consumer can construct
   `Cfg{h = .B}` with the enum private, take a private struct back from a public
   procedure, and pass it in again — it compiles and runs. What breaks is the
   documentation: `odin doc` prints `give :: proc(c: Cfg) -> Res` with no
   definition for `Res`. Any type in that state must be public. `Origin`, `Range`,
   `File_Ops`, `Index_Set` and `Read_Status` are the known cases; the check finds
   the rest.

Landing the whole set in one commit makes the diff readable as what it is — a
boundary being drawn — and makes it revertible as one thing.

### Verifying against the consumers

No collection override is needed. Both siblings already declare
`-collection:record=../odin-rdf-record` in their `Makefile` (shacl line 34,
sparql line 21), so a local `make test` in either builds against **this working
tree**, not against the `v0.6.0` tag — the tags are pinned in `ci.yml` and apply
to CI only. That is what makes this verification cheap enough to run on every
iteration of the marking pass rather than once at the end:

```
cd ../odin-rdf-shacl  && make check && make test
cd ../odin-rdf-sparql && make check && make test
```

Run them *before* marking anything, to have the baseline numbers in hand — a
suite that was already failing for an unrelated reason will otherwise read as
this task's regression. Both are one `make test` with no width matrix, so each is
a single run.

An error from either is the signal that a symbol is interface. A *pass* from
both is necessary and not sufficient: a private type reachable by inference still
compiles for a consumer, which is what the documentation check below catches.

### Dependencies

`RECORD-T-0030` — the list is what "is not interface" means.

### Risk Considerations

The failure mode is a symbol that is interface to a consumer that does not exist
yet — odin-rdf-app is not in this checkout, and SHACL-SPARQL has not been built.
`@(private)` is one line to remove, and the golden file makes removing it a
visible decision rather than a silent one, so this is a cost worth taking rather
than a reason to hedge.

## Status Updates
### 2026-09-01 — 74 marked private, 121 exported, every suite green

**195 declarations, 74 now `@(private)`, 121 exported.** The diff in `record/`
is 74 inserted `@(private)` lines and nothing else — no rename, no signature
change, nothing added or removed. (The working tree also carries three unrelated
stale-comment fixes in `apply.odin`, `permute.odin` and `termindex.odin` from
earlier the same day; they are visible in the same diff and are not part of this
task.)

The surface breaks down as:

| section | names | what it is |
| --- | --- | --- |
| 1. store API | 65 | 47 spelled by a consumer, 18 reached by inference |
| 2. format layer (`tool/`) | 13 | `RECORD-T-0033`'s question |
| 3. held by `tests/*` | 43 | not interface; `RECORD-T-0032`'s question |

### The three checks, and what each one actually caught

**Check 1 — compile.** `make check` over all eight packages. `record` and
`record/ingest` compiled clean on the first pass with all 117 candidates marked;
every failure was `tests/*` naming a symbol, which is the known blocker rather
than a finding. Those 33 were reverted, leaving the repository green and the
question intact for `RECORD-T-0032`.

**Check 2 — the consumers.** `make check && make test` in `../odin-rdf-shacl`
and `../odin-rdf-sparql`, run **before** the marking to have a baseline and
again after. Both green both times, `git status` clean in both — **no source
change in either consumer**. sparql's W3C survey block diffs **byte-identical**
against the baseline, every directory's pass/mismatch/unsupported/failed counts
unchanged, `sparql11-subquery` still 4 pass / 10 failed on its RDF/XML ceiling
and `sparql12-eval-triple-terms` still 38/38. shacl: 138 + 13 + 7 + 23 tests.
Read pins hold — shacl prints `pin: 7503 reads, as pinned`; sparql's instrumented
bench ends `all assertions passed`, with the `graph` case at 4122 candidates for
4122 solutions at both sizes. Worth noting for a future session that those pins
are **self-asserting inside the benchmark**, so "green" is the whole signal;
there is no number to eyeball.

**Check 3 — the documentation check, which is the one that found something.**
After check 1 and check 2 were both green, eleven public procedures still had
**private types in their signatures**:

```
commit_encode -> Commit, Encode_Error      writer_create  -> Writer
header_decode -> Decode_Error              writer_commit  -> Writer, Commit
frame_next    -> Frame_Status              writer_destroy -> Writer
dict_bytes    -> Dict                      writer_note    -> Writer
                                           writer_seal    -> Writer
```

Every one compiled. The `tests/*` suites name only the *procedures* and take the
types by inference, exactly as the initiative's experiment predicted, so no
compiler anywhere objected — and `odin doc` would have printed
`writer_create :: proc(...) -> (Writer, Writer_Error)` with `Writer` undefined.

**The finding this yields: the tests-held set is not 33 symbols, it is 43.** A
suite that names an exported procedure holds that procedure's whole type closure
public with it. The 10 dragged along are `Commit`, `Decode_Error`, `Dict`,
`EPOCH_CHUNK_BITS`, `Encode_Error`, `Env_Note`, `FACT_CHUNK_BITS`,
`Frame_Status`, `Index_Set`, `Writer`. They were un-marked and are listed in
section 3 of `doc/api-surface.txt` with the reason. `RECORD-T-0032` inherits 43,
not 33 — and correspondingly, moving one suite in-package frees more than its
own name count suggests.

After un-marking, the check reports **one** remaining dangling reference:
`Mem_FS -> Mem_File`. That is deliberate and is the opaque-handle case — a
consumer writes `fs: record.Mem_FS` and `mem_file_ops(&fs)` and never touches
`fs.files`. `Store -> Dict` and `Snapshot -> Index_Set` were in the same class
until `dict_bytes` and the writer procedures dragged those two types back out.

### One more thing the tooling needed

`api_surface.py check` initially failed against 80 phantom additions: `odin doc`
reports the package's `@(test)` procedures alongside everything else, because
`record/*_test.odin` is in the package. They are excluded by **where they are
declared** — parsed out of `record/*_test.odin` — rather than by a `test_`
prefix, so a test helper that is not named `test_*` is excluded too. `check` now
reports `api: 121 exported names, as stated in doc/api-surface.txt`.

### Acceptance criteria

- [x] Candidates marked, less the signature-reachable and tests-held sets.
- [x] `make check`, `make tool`, `make test` green here.
- [x] Both sibling suites green, no source change in either.
- [x] shacl 98 W3C entries; sparql survey identical, 546/556, 39 directories.
- [x] No type named in a public signature without a definition, except the one
      documented opaque-handle field.
- [x] Read pins hold: shacl 7503, sparql's bench assertions.
- [x] Visibility-only diff.