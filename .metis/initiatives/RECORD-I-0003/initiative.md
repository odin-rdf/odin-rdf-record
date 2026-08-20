---
id: apply-the-write-path-and-the-seam
level: initiative
title: "Apply: the write path, and the seam the sibling ports bind"
short_code: "RECORD-I-0003"
created_at: 2026-08-20T11:04:11.758988+00:00
updated_at: 2026-08-20T17:30:00.000000+00:00
parent: RECORD-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/completed"


exit_criteria_met: true
estimated_complexity: M
initiative_id: apply-the-write-path-and-the-seam
---

# Apply: the write path, and the seam the sibling ports bind Initiative

## Context

The third implementation initiative under `RECORD-V-0001`. `RECORD-I-0001`
made the log real (format v1, the verifying reader, replay) and
`RECORD-I-0002` made the projection real (the resident build, six
permutations, refcounted snapshots, the §12 read API, `store_open` with
writer resume — boot 246–325 ms, 23–26 MB resident, measured 2026-08-20).
What the store still cannot do is **accept a change expressed in RDF
terms**: `writer_commit` takes pre-encoded `Term_Def`s and ids, there is
no term encoder, no intern, and no entrance that checks `log.md` §5.3's
live-quad rules before bytes are written. Every test that writes does so
by hand-encoding. This initiative is `Apply` — the one write path the
vision names — and it is the gate on everything downstream.

**Why now, and why the title names the siblings.** On 2026-08-20 the
family decided to move odin-rdf-shacl and odin-rdf-sparql off
odin-rdf-store and onto this repository (superseding the "second store
beside, not a replacement" stance in the vision, the README and the
family CLAUDE.md — amended in the last task here). Both siblings' suites
load their W3C corpora through the store's `load_turtle`; neither can
begin its port until a store can be filled from parser output. The
survey of what they consume (recorded in the family session of
2026-08-20) found the read side already covered: `store_latest`/`store_at`
for the transaction, `snapshot_match` + `range_iter` + `scan_next` for
`match`, `snapshot_resolve` for `find_term`, `snapshot_term` for
`lookup_term`. The write side is the whole gap.

**The stance, stated once so it governs every decision below.** The
family's choice is that *the siblings adapt to this store, not the
reverse*: this repository changes as little as `Apply` itself requires,
at the siblings' expense. The public API stays small because the
consuming application's simplicity is a purpose of the rewrite
(`architecture.md`'s premises, `api.md` §1), and the internals stay as
plain as I-0002 left them. Concretely, four things the port survey
surfaced were ruled **not** record changes (one of them, the loaders,
later admitted as a subpackage — see its note and decision 7):

- *Kind from id.* odin-rdf-store's tagged `Term_ID`s let the engines
  read IRI/blank/literal off the id (`store.id_kind`, eleven call
  sites). Here a dictionary id's kind is the first byte of
  `snapshot_bytes(id)` and an inlined id is always a literal — one arena
  read, no allocation, derivable by the sibling adapter from the
  exported `TERM_TAG_*` constants. No `snapshot_kind` is added.
  *(Reversed at the design gate, decision 8: that answer couples every
  consumer to the canonical encoding's tag layout, a far larger contract
  than a three-value enum. `snapshot_kind` is added.)*
- *A consumer-reserved id range.* sparql names query-computed terms
  above `store.SENTINEL_CONSUMER_FIRST`. The port plan keeps the engines
  at their 64-bit `Term_ID` width and widens this store's `u32` at the
  seam, so everything above 2³² is the engine's — nothing here to
  reserve. (For the record: ids with bit 31 set and tag 0, other than
  `MATCH_DEFAULT_GRAPH`, can never name a term — `api.md` §3 — but no
  contract is made of it until a consumer needs one.) *(Revised at the
  design gate, decision 10: the range is stated in `api.md` §3 and named
  by a constant — a paragraph, no code — because the port's second
  phase retires the 64-bit vocabulary and will need it said.)*
- *Format loaders in the core.* A Turtle/TriG/N-Quads document becomes
  `[]Op` in a few dozen lines over the parser's `parser_next`, and the
  `record` package does not learn four formats to provide them — it
  keeps importing `rdf` alone. *(Revised at the design gate, decision 7:
  the loop is provided after all, as the opt-in subpackage
  `record/ingest`, because it is a pure translation that touches no
  store state and its one subtle policy — blank-node scoping — is the
  thing three consumers would otherwise each get wrong.)*
- *Triple terms and literal base direction.* The canonical encoding
  (`architecture.md` §3.2, carried in the chain) has no tag for either,
  and the format is frozen at first write. 20 of sparql's vendored data
  files use `<<…>>`; shacl's use none. The encoder here **refuses** such
  terms with a typed error rather than guessing, and the gap is
  recorded on sparql's side as a backend limit. Reopening the encoding
  is a format-version decision (`RECORD-A-0007`, if ever) driven by the
  consuming application, not by a test corpus.

What *is* this repository's to do, because `Apply` cannot be correct
without it, is recorded in I-0002's handoff and taken up here: the
`by_term` reader/writer race (handoff 1), the acquire/publish window
(handoff 2), the live-quad check over the SPO permutation rather than a
resident map (handoff 3), and the term encoder `probe_encode` already
mostly is (handoff 5).

Inherited and ready: `writer_commit` (append → fsync → acknowledge,
crash-swept), `Commit`/`Term_Def`/`Fact_Op`, `store_publish` and the
published-epoch discipline, `store_build_permutations` (radix,
45–57 ms at 3.4×10⁵ facts), `probe_encode` and `res_inline_encode` in
`read.odin`, the `OFS` full-fidelity fake for crash tests, the ISMS
generator and the Python verifier for proof.

## Goals & Non-Goals

**Goals:**

- **One entrance: `apply(s, changeset)`** (`log.md` §7.1 steps 1–5 as one
  call, `api.md` §12's write surface, the vision's "there is one write
  path"). A changeset is asserts and retracts of `rdf.Term` quads plus
  actor and reason as terms and a validation `Mode`; the result is the
  committed epoch or one typed error naming the offending op.
- **Intern and encode.** Terms to ids: the inline encoding first
  (`RECORD-A-0001`), then the published dictionary, then new
  definitions carried in the commit — datatype IRIs interned before the
  literals that reference them (§3.2's ordering rule), language tags
  lowercased, unsupported terms refused.
- **The preconditions as caller errors** (`log.md` §5.3, §8): every
  retract names a live quad, every assert a non-live one, evaluated
  against head *and* against earlier ops of the same changeset
  (assert-then-retract inside one epoch is legal — the read tests
  already craft it), an inlined or literal graph component refused,
  `LIVE_EPOCH` never issued (handoff 6). Checks are binary searches
  over the published SPO permutation — the `api.md` §6 decision — not
  a resident map.
- **Apply, then publish, with rollback.** Resident mutation happens in
  writer-private, epoch-bounded state no reader can observe; a refused
  or failed apply restores the projection exactly; a successful one is
  published only after the fsync. The candidate state *is* the overlay
  view `RECORD-A-0006` part 2 promised — a `Snapshot` pinned at the
  unpublished epoch, no new type.
- **The validation hook** (`RECORD-A-0006`): wired once at `store_open`,
  invoked on every changeset with the candidate snapshot and the
  resolved ops, `Enforce` aborting before step 1, `Record` committing
  and reporting. A nil hook is the consumer's stated posture.
- **`record/ingest`** (decision 7): four pure procedures turning a
  parsed Turtle, N-Triples, TriG or N-Quads document into `[]Op` —
  assert or retract, with caller-supplied blank-node prefixing — so the
  siblings' suites and the application fill a store without each
  writing the loop. A subpackage, so the core's imports do not change.
- **Two read-API procedures the spec or `apply` already implies**
  (decisions 8 and the `exists` note): `snapshot_kind` — IRI, blank
  node or literal from an id without decoding — and `snapshot_exists`,
  `api.md` §12.5's layer-2 existence test, which is `apply`'s live-quad
  check made public.
- **An in-memory `File_Ops`** (decision 9): `tests/scale`'s `Mem_FS`
  promoted beside the posix ops, for tests and scratch stores in this
  repository and every consumer's suite — never for data anyone keeps.
- **Lock-free reads stay lock-free, and become provably safe under a
  live writer**: the `by_term` race and the acquire/publish window are
  closed, not narrowed.
- **Replay equivalence as the standing proof**: a store built by *N*
  applies and a store booted from the log those applies wrote are the
  same projection, fact for fact and term for term.

**Non-Goals:**

- Triple terms and base direction — see the stance above. Format
  loaders *in the core* likewise; the subpackage is in scope
  (decision 7), an `apply_turtle`-style shortcut that hides the epoch
  boundary is not. (`snapshot_kind` and the consumer id range were
  non-goals in the draft and are in scope since decisions 8 and 10.)
- The rest of `api.md` §12.5–12.6 layer 2 — `Count`, `CountDistinct`,
  `GroupBy`, `EntityHistory`, an `epoch_at(wall)` — is the
  application's ask, not the siblings', and belongs to the initiative
  the application drives. Only `exists` lands here, because `apply`
  needs it.
- Graph enumeration (`GRAPH ?g {}` is a scan-and-dedup on this store by
  `RECORD-A-0004`, which the sparql engine already performs itself),
  term ordering for `ORDER BY` (`api.md` §12.8), and an export direction
  for `ingest` — each waits for evidence from the ports or the
  application.
- Reasoning and materialization; derived ops (`0x11`/`0x12`) are encodable
  but no path produces them; the `"derived":"none"` environment note
  stands.
- The delta permutation structure (`RECORD-A-0005` v1 is flat
  copy-on-write; the rebuild per commit is measured here and the ADR's
  review trigger is re-read, nothing more).
- Batching, group commit, any throughput work — the premise is
  human-paced writes; bulk import is one changeset, one epoch, one fsync.
- Multi-writer anything (`log.md` §10). `apply` is not thread-safe
  against itself and says so.
- The "prefix context" the design README lists among the edit-surface
  asks. It is unowned — the vision never captured it — and a prefix map
  is consumer data (a graph of declarations) or parser state, not store
  state. Recorded here so it stops being mentioned as pending.
- Publication of the repository and a release tag are operational and
  the owner's; the last task lists what the siblings' CI will need from
  one, no more.

## Detailed Design

`api.md` §12 and `log.md` §7.1/§8 remain the specification; as in the
two initiatives before, a discovered divergence amends the document.
What the documents leave to the implementation, with the lean for each
— decided and recorded in the first task that touches it:

**1. The public surface.** The smallest set that states everything
`Apply` needs to know, in the family's procedure-set style:

```odin
Op_Kind   :: enum u8 { Assert, Retract }
Op        :: struct { kind: Op_Kind, using quad: rdf.Quad }  // rdf.Quad{using triple, graph: Graph_Label}; graph nil = default graph
Mode      :: enum u8 { Enforce, Record }
Changeset :: struct { ops: []Op, actor, reason: rdf.Term, mode: Mode }  // actor/reason nil = none (id 0)

Apply_Error :: struct { kind: Apply_Error_Kind, op: int }  // op: index of the offending op, -1 if none
Apply_Error_Kind :: enum {
    None, Empty, Not_Live, Already_Live, Unsupported_Term,
    Rejected,            // Enforce: the validator said no
    Writer,              // the writer failed (detail on the Store); the store is fail-stop from here
    Epoch_Exhausted,     // u32 epochs; the writer refuses LIVE_EPOCH
}

apply :: proc(s: ^Store, c: Changeset) -> (epoch: u32, conforms: bool, err: Apply_Error)

Validator :: struct {
    check: proc(data: rawptr, candidate: Snapshot, ops: []Resident_Op, allocator: runtime.Allocator) -> bool,
    data:  rawptr,
}
Resident_Op :: struct { kind: Op_Kind, s, p, o, g: u32 }

store_open :: proc(dir, ops: File_Ops, validator := Validator{}, ...)   // the one signature change
```

Nothing else is added to the read side. `conforms` is meaningful only
with a validator wired; the validator owns its report (it has `data`),
the store never interprets one. `Op` embeds the parser's `rdf.Quad`
(decided 2026-08-20, closing the draft's open detail): TriG and N-Quads
`parser_next` return one, Turtle and N-Triples return the `rdf.Triple`
it embeds, and the TriG/N-Quads emitters take one — so ingest is a
struct literal, export is direct, and any consumer already holding
triples feeds `apply` without an adapter type. `rdf.Graph_Label` is
`union { IRI, Blank_Node }` with nil the default graph, so a literal (and
therefore an inlined) graph component is *unrepresentable* — `log.md`
§5.3's graph rule is enforced by the type at the caller's compile time,
and the draft's `.Bad_Graph` error kind is gone. Replay's own rejection
of an inlined `G` stays, since a log can still be forged. `record`'s
resident `Quad` (four `u32`s) and `rdf.Quad` never meet in code; prose
says "resident quad" where both appear.

**2. Where the candidate lives, and what the hook sees.** `log.md` §7.1
orders encode → write → fsync → apply → publish, and `RECORD-A-0006`
says "nothing may touch the real structures before the fsync". Read for
their purpose — durability at step 3, visibility at step 5 — both are
satisfied by a narrower rule: *nothing a published reader can observe*
changes before the fsync. The writer appends the changeset's facts
(assert = E+1), sets `retract = E+1` on the facts it retracts (an
atomic store, invisible to any reader at ≤ E by the visibility test),
appends new dictionary entries past the published `n_terms`, rebuilds
the permutations over the enlarged fact table, and builds the
candidate `Index_Set` — all of it bounded away from readers by
`n_facts`, `n_terms` and the epoch test, which is exactly what those
bounds exist for. The validator receives `Snapshot{epoch = E+1, idx =
candidate}` — the post-state, through the ordinary read API, no
overlay machinery. Then encode, append, fsync, and publish the same
set. On a refusal or a writer failure the writer rolls back in
writer-private state: `n_facts` back, each touched `retract` restored
to `LIVE_EPOCH`, the dictionary truncated to the published high-water
mark, the candidate set freed. The amendment to `log.md` §7.1 and the
ADR's wording records this reading: "apply to unpublished state,
validate, fsync, publish". It is the simplest design that gives the hook
an honest view, and it adds no second representation of anything.

**3. The `by_term` race (handoff 1) — lean: no resident map at all.**
`api.md` §4 says the map is needed only on the write path, but §12.7's
`Resolve` probes it on the read path, and Odin maps are not concurrent.
The lean: the `Index_Set` gains a sorted `[]u32` of dictionary ids
ordered by canonical encoding, built once at boot and *merged* per
commit (the handful of new ids into a fresh array — an O(n) copy,
~320 KB at 8×10⁴ terms, a fraction of the permutation rebuild already
paid per commit under `RECORD-A-0005`). `snapshot_resolve` becomes a
binary search comparing arena bytes (~17 probes), published atomically
with everything else a reader touches — correct by construction, the
way §13.8 made `n_terms` correct. The writer interns against the
published array plus a transient per-changeset map of the terms it is
adding (bulk loads define 10⁵ terms in one epoch; a linear pending list
would be quadratic). `Dict.by_term` is deleted, and with it ~3.5 MB of
the measured footprint and one structure with no ownership story. The
alternative — an immutable published map beside a pending map, each
with its own publication discipline — keeps the O(1) probe at the cost
of two maps and a protocol; it is the recorded fallback if the binary
search ever measures as a problem on the resolve-heavy paths (the
siblings resolve every ground term once per query or session, not per
row). Amends `api.md` §4 and §12.7. One consequence checked rather than
assumed: replay's `log.md` §5.2 self-check (`dict_add` refusing a
duplicate encoding with `.Duplicate_Term`) is today a probe of this map,
so deleting it moves that check to a *transient* replay map dropped at
the end of boot — the same lifetime the live-quad map already has — or
to an adjacent-equal pass over the sorted index once built. Either keeps
the check; neither leaves a map resident.

**4. The acquire/publish window (handoff 2) — lean: a mutex on acquire
and publish, not a retire list.** `store_at` can increment the count of
a set a concurrent publish has just freed. A retire list defers the
free by one publish and *narrows* the window to "a reader preempted
between two instructions for one commit interval"; it does not close
it. A mutex taken by `store_latest`/`store_at` and by the publish step
closes it outright, and it is on the *acquire* path — once per request
— not on the read path: `snapshot_match`, `range_iter`, `scan_next` and
`snapshot_resolve` stay exactly as lock-free as they are. The
refcounts stay for release (a snapshot outlives the publish that
superseded its set, and frees it on the last release). This is an
amendment to `RECORD-A-0005`'s text and to `snapshot.odin`'s package
comment, with the reason: fewer moving parts than deferred reclamation
and a proof instead of a bound.

**5. The live-quad check (handoff 3).** `snapshot_exists(head, pattern)`
in all but name: a prefix range over SPO with the graph residual, at
the published epoch, `Origin.Any`. Intra-changeset: ops are checked in
order against head *and* a transient map of this changeset's own
effects, so assert→retract of one quad in one epoch resolves, and
assert→assert is `.Already_Live` at the second. The replay-time map in
`load.odin` stays replay-only, as `api.md` §6 decided.

**6. Intern (handoff 5).** `probe_encode` is promoted from file-private
to the package's encoder and shared by `snapshot_resolve` and `apply`.
Its caveat stands: it emits full IRIs only, never the split form
(tag `0x06`), so every IRI this writer defines is full and the read-side
probe stays correct. A typed literal's datatype is interned first; a
language tag over 255 bytes, a triple term, a literal with a base
direction are `.Unsupported_Term`.

**7. The writer inside the store.** `store_open` already resumes a
`Writer`; `apply` uses it. Epoch = published + 1; `LIVE_EPOCH` is
refused at the source. Wall time is the writer's clock, Unix
nanoseconds UTC (`api.md` §2.4: evidence, not proof). A writer error
marks the store fail-stop, as the writer already is.

## Design decisions — 2026-08-20, at the design gate

Six questions the draft left as leans were put to the owner and decided.
Recorded here so the tasks inherit answers, not leans; each names the
document it amends.

1. **Resident mutation happens before the fsync.** The overlay view is
   the candidate `Snapshot` at E+1 (Detailed Design §2). `log.md` §7.1
   and `RECORD-A-0006` are amended to say what they meant: *nothing a
   published reader can observe* changes before the durability
   boundary, and nothing is published before it. Rollback must be
   exact and is tested as such.
2. **`Dict.by_term` is deleted.** The sorted id index in the `Index_Set`
   is the only term lookup on the read side; the writer uses it plus a
   transient per-changeset map; replay's §5.2 self-check uses a
   transient map dropped at boot's end (Detailed Design §3). Amends
   `api.md` §4 and §12.7. The published-map alternative is not pursued.
3. **A mutex on acquire and publish.** Not a retire list. The owner's
   framing: the workload is ~99:1 read-heavy, and the lock is on the
   per-request acquire, never on match/iter/resolve — so readers pay
   one uncontended lock per request and the read path stays exactly as
   lock-free as it is. Amends `RECORD-A-0005`'s "lock-free" sentence to
   make the acquire/read distinction explicit.
4. **Blank-node labels are interned as given.** Identity is global
   within a store because retract-by-value (`log.md` §5.3) needs stable
   labels. Per-document scoping is the consumer's loader loop's job
   (odin-rdf-store's loaders did the same, per load); record offers no
   minting helper — `snapshot_resolve` lets a consumer check a label is
   unused, and a helper is added only on evidence.
5. **`Record` mode leaves no trace in the chain, and that is accepted for
   v1.** `apply` returns `conforms`; the epoch is an ordinary epoch; a
   consumer that wants the verdict durable writes its report as facts
   in the same or a following changeset. `RECORD-A-0006` already leaves
   the quarantine-graph question on the consumer's side; the store's
   documentation says plainly that the log does not record that a
   judge objected.
6. **An empty changeset is refused** (`.Empty`). A reason-only marker
   epoch is encodable and may one day be wanted; refusing now is
   reversible, accepting now is not.
7. **The parse-to-ops helpers are provided, as `record/ingest`.** Raised
   by the owner after the six above: the helpers are an *addition*, not
   complexity in the store — a pure function from parser output to a
   value `apply` already accepts, touching no resident structure and no
   invariant; deleting them would change nothing in the store. What
   they remove is the same loop written three times (the application,
   the shacl suite, the sparql suite) and the one policy in it that
   odin-rdf-store needed a dedicated `Load_Scope` to get right. Three
   conditions keep it simple. *Placement*: a subpackage importing
   `record` and the four format packages, so a consumer that never
   ingests documents links no parser and `record`'s own imports stay
   `rdf` alone. *Shape*: procedures returning `[]Op`, never a
   `Changeset` — the caller sets actor, reason and mode, may
   concatenate documents into one epoch, and the store never decides
   "one document, one epoch":

   ```odin
   package ingest   // record/ingest
   turtle   :: proc(src: []byte, graph: rdf.Graph_Label, allocator: runtime.Allocator, kind := record.Op_Kind.Assert, blank_prefix := "") -> (ops: []record.Op, err: Error)
   ntriples :: // same signature
   trig     :: proc(src: []byte, allocator: runtime.Allocator, kind := record.Op_Kind.Assert, blank_prefix := "") -> (ops: []record.Op, err: Error)   // graphs from the document
   nquads   :: // same as trig
   ```

   The procedures are named by format alone — `ingest.turtle(src, …)`,
   `ingest.trig(src, …)` — because the package name already says what
   is happening and the return type says what comes back; a
   `changeset_from_*` would misdescribe the result (a document
   supplies ops, never actor, reason or mode), and `ops_from_*`
   repeated the type. `kind` makes "retract this document" free — the only retract shape
   a document can express, and the one an application wants for
   "unload this source". *Blank nodes*: `blank_prefix` is prepended to
   every label in the document (the application passes its upload id, a
   harness its test name; empty means labels as written) — deterministic,
   no counter, no store access, and the labels in the log are exactly
   what the caller can predict, which keeps retract-by-value nameable
   later (decision 4). Terms borrow from `src` per `RDF-A-0001`: the
   caller keeps the buffer alive until `apply` returns, and `apply`
   copies what it interns. The name is `ingest`, not `load`, because
   `load.odin` is replay's `Loader` — the `Consumer` that builds the
   projection from the record — and this package loads nothing: it
   translates. Not added: a `Changeset` builder type, an
   `apply_turtle` shortcut, a `tool` subcommand — each is policy and
   each is one line in the consumer once `ingest.turtle` and its siblings exist.
8. **`snapshot_kind` is added.** The draft's sibling-side answer — read
   `snapshot_bytes(id)[0]` against `TERM_TAG_*`, inlined ids are
   literals — was wrong on its own terms: it makes every consumer
   depend on the canonical encoding's tag layout (`architecture.md`
   §3.2), the contract that breaks in every consumer the day a tag is
   added, to avoid a three-value enum. `snapshot_kind(snap, id) ->
   Term_Kind {IRI, Blank, Literal}` is ~10 lines over structures that
   exist (inline flag → literal; else one arena byte), allocation-free,
   and the application's UI needs it for every term it renders. It
   *shrinks* what consumers touch. Lives in `read.odin` with the rest of
   layer 1. With it lands `snapshot_exists(snap, p, f) -> bool` — in the
   spec since `api.md` §12.5, not built in I-0002, and `apply`'s
   live-quad check in all but name, so it becomes a public procedure
   rather than a private helper.
9. **An in-memory `File_Ops` is promoted into the package.**
   `tests/scale`'s `Mem_FS`/`mem_ops` moves beside `writer_posix.odin`
   as the seam's second implementation. It adds no type — `File_Ops`
   is the type, and the seam exists for exactly this. Every consumer's
   suite opens throwaway stores (shacl's 98 cases, sparql's ~500, the
   application's), darwin's `F_FULLFSYNC` costs 5–20 ms per epoch, and
   this repository's own `apply` tests want it first; the alternative
   is the same 100 lines in three repositories. Its doc comment says
   plainly what odin-rdf-store said of `open_ephemeral`: tests and
   scratch, never data anyone keeps. The `OFS` crash fake stays
   test-private — it models failure, this models a disk.
10. **The consumer id range is stated, not coded.** Phase 2 of the port
    retires the siblings' 64-bit `store:store` vocabulary, and then the
    engines need this store to *say* which `u32` values can never name
    a term. The answer exists by construction — inline flag set, tag 0:
    `0x8000_0001 ..= 0x8FFF_FFFF` — and tag 0 is frozen-invalid by
    `RECORD-A-0001`, so stating it forecloses nothing. One paragraph in
    `api.md` §3 and a named constant (`CONSUMER_ID_FIRST`, or the
    range as a pair); no runtime, no check — the store never sees these
    ids, they live in consumers' rows. `MATCH_DEFAULT_GRAPH`
    (`0x8000_0000`) is excluded from the range by being the value below
    it.

## Testing Strategy

- **Replay equivalence** (the initiative's proof): after *N* random
  changesets through `apply`, `store_open` the same directory in a
  second store and compare fact table, dictionary, epoch table and all
  six permutations; run on every `make test`, on `OFS`.
- **Both verifiers over apply-written logs**: the fault corpus gains
  apply-written cases, and the Python verifier must agree verdict for
  verdict, head hash and epoch included — unchanged by construction,
  which is the point of checking.
- **Precondition taxonomy**: each `Apply_Error_Kind` produced by a
  minimal changeset, `.Empty` included, and the intra-changeset cases; a refused
  apply leaves the projection byte-identical to before (compared
  against a store that never saw it).
- **Crash sweep across apply** with `OFS`'s operation budget at every
  cut point: no acknowledged epoch lost, no partial record read, and
  after recovery + resume the next `apply` continues the chain.
- **Hook semantics**: `Enforce` refusal writes nothing and rolls back;
  `Record` commits and reports; a hook that reads the candidate sees
  the post-state and not the head; a hook that resolves a term added by
  the changeset finds it; a `Record`-mode epoch replays identically
  to an `Enforce`-mode one that conformed (decision 5, pinned).
- **Blank-node identity**: the same label in two changesets is one
  node; a retract naming it resolves (decision 4, pinned).
- **Reader/writer torture**: threads acquiring, matching, resolving and
  releasing snapshots while the writer applies and publishes; run long
  enough to cross many publishes; `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`.
- **Kind and existence**: `snapshot_kind` over every tag and every
  inline type against the decoded term's variant; `snapshot_exists`
  against the brute-force oracle the match tests already use, at head
  and under a historical epoch.
- **The memory `File_Ops`**: the apply tests and the replay-equivalence
  test run on it as well as on `OFS`; a store written through it
  verifies under both verifiers when its bytes are flushed to a real
  directory (the `tests/scale` path today).
- **Ingest**: each `ingest` procedure over the parser repo's own conformance
  inputs for that format; `blank_prefix` scoping (two documents with
  `_:b0` under different prefixes are two nodes, under the same prefix
  one); `kind = .Retract` unloading exactly what `.Assert` loaded; and a
  store filled through `ingest` + `apply` round-tripped through
  `dump --format=nquads` and re-ingested to the same projection — the
  cross-implementation verifier runs over that log too.
- **Scale**: commit latency at ISMS scale (the 45–57 ms rebuild baseline
  plus the term-index merge), the footprint delta from deleting
  `by_term`, and a bulk load of the ISMS corpus through `apply` in one
  epoch compared with the generator's output.

## Alternatives Considered

- **A separate overlay type for the hook** (`RECORD-A-0006`'s literal
  reading): a second read surface that must agree with the first in
  every corner — the two-access-paths failure `api.md` §12 exists to
  avoid. The candidate snapshot gives the hook the real API.
- **Keeping the replay live-quad map resident** for the duplicate check:
  `api.md` §6 already rejected it — 19 MB per tenant to save 19 probes
  a few times a second.
- **Epoch-based or hazard-pointer reclamation** for the acquire window:
  correct, and far more machinery than a mutex on a path that runs once
  per request.
- **A published immutable map + pending map** for `by_term`: see §3;
  kept as the fallback.
- **A triple-term tag**: a change to this repository for a sibling's
  convenience, and a format-version decision besides; the stance rules
  it out. **`snapshot_kind`**, **a stated consumer range** and **format
  loaders in the core** were first rejected on the same ground and then
  admitted at the design gate (decisions 8, 10, 7) — the distinction
  being that each adds no invariant to the store, and the first two
  *remove* coupling consumers would otherwise carry.
- **Consumers deriving kind from `TERM_TAG_*`**: rejected by decision 8;
  it leaks the encoding.
- **An `apply_turtle` shortcut or a `Changeset` builder** in
  `record/ingest`: hides the epoch boundary or grows a type for a
  one-line composition; `[]Op` is the whole interface.
- **A hook parameter on `apply`** instead of on `store_open`: rejected
  by `RECORD-A-0006` — every caller choosing its own judge is the
  skip-the-gate failure.

## Implementation Plan

Sequenced so each step is testable before the next. Decomposed
2026-08-20 into RECORD-T-0013 … T-0018, one per step; dependencies are
in each task's `blocked_by`:

1. **The encoder and intern** (RECORD-T-0013): promote `probe_encode`; the pending-term
   map; datatype-first ordering; `.Unsupported_Term` and `.Empty`; unit tests against
   the golden vectors (the bytes must equal what the Python verifier
   already accepts).
2. **The term index and the acquire mutex** (RECORD-T-0014): the sorted id array in
   `Index_Set`, `snapshot_resolve` over it, `by_term` deleted and
   replay's self-check moved to a transient map; the
   mutex on acquire/publish; the reader/writer torture test;
   `snapshot_kind` and `snapshot_exists` (decision 8); `api.md`
   §4/§12.5/§12.7 and `RECORD-A-0005` amended.
3. **`apply`** (RECORD-T-0015): the memory `File_Ops` promoted first (decision 9, the
   tests need it); preconditions, candidate build, rollback, commit,
   publish; the taxonomy tests, the crash sweep, replay equivalence,
   the corpus cases for the Python verifier; `log.md` §7.1 amended.
4. **The validation hook** (RECORD-T-0016): `Validator` on `store_open`, `Enforce`/`Record`,
   the hook tests; `RECORD-A-0006` gains its "as built" signatures.
5. **`record/ingest`** (RECORD-T-0017): the four `ingest` procedures, the
   blank-prefix rule, the ingest tests above; `doc/design/README.md`'s
   package map gains the subpackage. Depends on step 3 only.
6. **Measurement and the record** (RECORD-T-0018): commit latency and footprint at ISMS
   scale; `RECORD-A-0005`'s review trigger re-read against the number;
   the consumer id range stated in `api.md` §3 with its constant
   (decision 10);
   README, `.metis/vision.md` and the family CLAUDE.md amended — the
   "second store beside, not a replacement" paragraphs stand with a
   dated note; and a list, for the owner, of what the siblings' CI
   needs from a published repository (a tag to pin; POSIX-only noted
   for their Windows leg).

Exit: `make test` green; a store that accepts changesets through one
entrance, refuses what `log.md` §5.3 forbids with a typed error, gives a
wired validator the post-state before any byte is durable, and whose
apply-written log verifies under both verifiers and replays to the same
projection — at which point the odin-rdf-shacl port initiative (on its
side) is unblocked, and the odin-rdf-sparql port after it.
## Status — 2026-08-20: all six tasks complete; the numbers, what the siblings need, their handoff

Drafted, decided at the design gate, decomposed and implemented in one
day. T-0013 (the encoder and intern, numbering proven through the real
writer), T-0014 (the term index and the acquire mutex; the set's list
copies, a divergence from `api.md` §13.8 discovered and closed; a
three-way string quicksort after a 56 ms comparison-sort measurement —
7 ms), T-0015 (`apply`, the memory `File_Ops`, the writer inside the
store, rollback exact by comparison, the crash sweep, replay equivalence
on both seams), T-0016 (the `Validator` as built; decision 5 tested by
replay), T-0017 (`record/ingest` over the W3C suites by reference; the
ops own their terms, a `base` for Turtle/TriG — both forced by the
parser's contract), T-0018 (below). 72 record tests, 7 ingest, 2 proof,
8 scale, the tool and the README example green; `make check` green.

**The numbers (optimized build, Apple Silicon dev machine, memory seam —
the production seam adds the disk's fsync per commit):**

| | measured |
|---|---|
| one commit, 1–2 ops, at 4×10⁵ facts / 5×10⁴ terms | **31–35 ms** (means over two runs; min 30.5, max 36.2, 24 commits each) |
| — of which the six-permutation rebuild (`RECORD-A-0005` flat copy-on-write) | ~all; term-index merge, list copies, encode are the remainder |
| transient allocation per commit | up to 18.6 MB |
| bulk load: the ISMS corpus as one changeset (4×10⁵ ops) | **222–267 ms**, one epoch, 14.7 MB of log |
| resident after the bulk load | **21.2 MB** (facts 9.2, permutations 9.2, arena 2.0, term index + offsets 0.39) |
| resident booted from the generator's logs (T-0012's shapes) | **20.0 / 23.0 MB**, from 22.9 / 25.9 before T-0014 (−2.9 MB) |
| boot from those logs | 205 / 272–278 ms (term index 7 ms of it) |
| replay equivalence, crash sweep, both verifiers over apply-written logs | green on every `make test` |

`RECORD-A-0005`'s review trigger, re-read against 31–35 ms: it does not
fire; the delta structure stays deferred (annotated in the ADR). The
hand-edited shape was not run as 2×10⁵ commits — at ~33 ms each that is
nearly two hours, and the number wanted is per commit, not per corpus;
the measurement is 24 commits after the bulk load, each timed.

**What the siblings' CI needs from a published repository (the owner's
to do; listed here, not done here — *published and tagged 2026-08-20:
`odin-rdf/odin-rdf-record`, `v0.1.0` at `e29764e`; the family CLAUDE.md's
record section carries the port handoff that goes beyond the list below*):**

- A repository under the organization and a tag to pin — the family
  pins consumers to tags (`odin-rdf-store@v0.6.0`, `odin-rdf-parser@v0.1.0`
  today), so `odin-rdf-record@v0.1.0` is the shape; CI checks it out
  beside the consumer as `../odin-rdf-record`.
- `-collection:record=../odin-rdf-record` in each consumer's `Makefile`
  and the same entry in its `ols.json`; a consumer must also keep
  `rdf:` declared, since this repository's sources import it (the
  family's collections-resolve-in-the-importer rule).
- **POSIX only**: there is no Windows `File_Ops`. A consumer's Windows CI
  leg either supplies its own `File_Ops` or — for test suites — uses
  `mem_file_ops`, which is platform-free; the posix file is
  `#+build linux, darwin`, so a Windows build of `record` compiles
  without it and `store_open` works over `Mem_FS`.
- `make test` here needs `python3` (the cross-implementation verifier);
  the library does not.

**Handoff for the sibling port initiatives (on their side; the survey
of 2026-08-20 condensed, with what this initiative added):**

1. *The read-API mapping.* `store_latest`/`store_at` for the
   transaction (a snapshot is a value: acquire, use, release);
   `snapshot_match` + `range_iter` + `scan_next` for `match` — the
   pattern is four `u32`s, 0 unbound, `MATCH_DEFAULT_GRAPH` for the
   default graph in G, `Filter{origin = .Any}` for what the store
   recorded (origin must be stated); `snapshot_resolve` for `find_term`;
   `snapshot_term` / `snapshot_bytes` for `lookup_term`;
   `snapshot_exists` for the existence probes; `snapshot_kind` for
   `store.id_kind` (eleven call sites in sparql, eight in shacl) — IRI,
   Blank, Literal, never the tag byte; `snapshot_epoch_meta` for the
   transaction's who/when/why.
2. *The 64-bit widening rule.* The engines keep their 64-bit `Term_ID`;
   this store's ids are `u32` and are widened at the seam, so everything
   above 2³² is the engine's today. Phase 2 retires the `store:store`
   vocabulary, and then the engine's own values go in
   `CONSUMER_ID_FIRST ..= CONSUMER_ID_LAST` (`0x8000_0001 ..=
   0x8FFF_FFFF`) — `api.md` §3, amended.
3. *The write side.* `apply(s, Changeset{ops, actor, reason, mode})`;
   `Op{kind, using quad: rdf.Quad}` — the parser's quad, so a harness
   builds ops with a struct literal or through `ingest.turtle` and its
   siblings. `load_turtle(ds, src, graph)` becomes `ingest.turtle(src,
   graph, allocator, blank_prefix = <test name>)` + `apply` +
   `ops_destroy`; `blank_prefix` is the `Load_Scope`. The ops own their
   terms; `base` resolves relative IRIs.
4. *The Validator shacl binds.* `Validator{check: proc(data, candidate:
   Snapshot, ops: []Resident_Op, allocator) -> bool, data}` on
   `store_open`; `session_init_txn` becomes a `check` over the
   candidate — the post-state through the ordinary read API, the
   pre-state a `store_latest` away; `Enforce` refuses before a byte is
   written, `Record` commits and reports; the log does not record the
   verdict (decision 5) — a report that must be durable is facts.
5. *The memory `File_Ops` for the suites.* `Mem_FS` + `mem_file_ops`
   replaces `open_ephemeral`: ~300 call sites in shacl, ~170 in sparql,
   almost all open + load + close. `store_close` releases both halves.
6. *The triple-term limit sparql must record.* The frozen format has no
   tag for triple terms or base direction; `apply` refuses them with
   `.Unsupported_Term` at the op. 20 of sparql's vendored data files
   use `<<…>>` — a recorded backend limit on sparql's side, not a
   format-version decision taken for a test corpus.
7. *Two things the survey did not know.* The read path's safety under a
   live writer rests on the set's list copies (every list a reader
   indexes is the published set's, never the store's) and on
   `Fact.retract` being the one field loaded atomically; and a
   `Snapshot` handed to a `Validator` carries no reference of its own
   and must not be retained.

**Exit criteria: met.** `make test` green; a store that accepts
changesets through one entrance, refuses what `log.md` §5.3 forbids with
a typed error naming the op, gives a wired validator the post-state
before any byte is durable, and whose apply-written log verifies under
both verifiers and replays to the same projection. The odin-rdf-shacl
port initiative is unblocked on its side, and the odin-rdf-sparql port
after it; publication and the first tag are the owner's *(done 2026-08-20:
`v0.1.0`)*.

## Session handoff — 2026-08-20, before implementation begins

Written at the end of the session that drafted this initiative, for the
session that implements it. Everything decided is above; this section
holds what was *learned* and is not recorded anywhere else.

**1. Start with RECORD-T-0013, and read these first.** The Design
decisions section (ten items) and the task's acceptance criteria. Then
the code the task touches: `record/read.odin` (`probe_encode` at the
file's end is the encoder-to-be; `res_inline_encode`,
`canonical_integer`, `canonical_date` are its inline gate;
`INLINE_LEXICAL_MAX` is 16), `record/term.odin` (the decoder and
`TERM_TAG_*` — confirm they are exported; this session assumed so),
`record/encode.odin` (`Commit`, `Term_Def`, `Fact_Op`, `commit_encode`
takes `next_term_id` and assigns definition ids sequentially — the
intern's pending ids must match that numbering exactly).
`probe_encode` resolves a typed literal's datatype through
`snapshot_resolve`; the intern must resolve it through published *or
pending*, which is the one place the promoted encoder differs from the
probe.

**2. Three facts about the existing code that shape T-0014/T-0015, found
by reading, not yet in any document.** (a) `store_publish`
(`snapshot.odin`) both *builds* the `Index_Set` and *installs* it in
one procedure, asserting `len(s.ord[o]) == n_facts` and moving `s.ord`
into the set; T-0015 needs it split into build-candidate and install,
because the hook runs between them. (b) `dict_add` appends to
`chunks`/`used`/`off`; rollback must restore `used[c]`, truncate `off`,
and free chunks allocated during the failed apply — safe because chunks
never move and readers are bounded by the published `n_terms`.
(c) `store_at` carries a retry loop for the acquire window; T-0014
removes it with the mutex rather than keeping both.

**3. The sibling survey, condensed — T-0018's handoff will need it and
the siblings' initiatives do not exist yet.** sparql's core imports
`store:store` as *vocabulary only* in 7 files (`Term_ID` ×112,
`UNBOUND` ×51, `Match_Pattern`, `Encoded_Quad`, `WILDCARD`,
`DEFAULT_GRAPH`, `id_kind` ×3, `SENTINEL_CONSUMER_FIRST`), never
`kvstore`; binding is parapoly `$MATCH/$NEXT/$DESTROY` on
`Exec(D, It)` (`sparql/exec.odin:628`) plus runtime seams
`Term_Loader`/`Term_Finder`/`Triple_Reader`; `sparql/kvstore/eval.odin`
is 492 lines consuming 11 kvstore names. shacl's core imports `store`
in 10 files (`id_kind` ×8); compile is the same parapoly shape
(`shacl/query.odin:30`), validate is a runtime `Access` struct of four
verbs (`shacl/validate.odin:48`); `shacl/kvstore` is 807 lines
consuming 16 names (`load_turtle`, `find_graph_label` among them).
Test harnesses: ~170 call sites in sparql (15 files), ~300 in shacl
(20 files), almost all `open_ephemeral` + `load_turtle` + `close`. CI
pins `odin-rdf-store@v0.6.0` and `odin-rdf-parser@v0.1.0`. The port
plan: keep the engines at 64-bit `Term_ID`, widen record's `u32` at the
seam so store sentinels and computed-term ids sit above 2³²; shacl
first, sparql second; `snapshot_kind` replaces `id_kind`;
`session_init_txn` becomes a `Validator`. 20 of sparql's vendored data
files use triple terms — a sparql-side recorded limit.

**4. Family documents that now disagree with this initiative, on
purpose until T-0018.** The family `CLAUDE.md`, `README.md` and
`.metis/vision.md` still say "a second store beside odin-rdf-store, not
a replacement". The owner's decision of 2026-08-20 supersedes that;
T-0018 amends all three with dated notes, old text standing. A session
that notices the contradiction should not "fix" it earlier.

**5. Process notes that cost this session time.** Metis: a document
file written directly must keep its frontmatter's closing `---` or the
index silently drops it (check with `list_documents`); `edit_document`
refuses after any external write — edit the file directly or
`read_document` first. The shell's working directory resets to the
workspace root between calls — use absolute paths into the repo. Odin:
`using quad: rdf.Quad` in `Op` is expected to pass `-vet -strict-style`
because `rdf.Quad` itself uses `using triple`; verify at T-0015 and, if
it does not, drop `using` and keep the field (`op.quad.subject`) — the
decision is the type, not the sugar. I-0002's toolchain notes (os2-shaped
`core:os`, `#sparse` enumerated arrays, never many real fsyncs in a
test) still apply.

**6. Spelling decided in passing.** `Changeset` is one word — the VCS
and Ecto sense the founding documents use — beside the split
`Index_Set`; say so in the type's doc comment so it is not re-litigated.
