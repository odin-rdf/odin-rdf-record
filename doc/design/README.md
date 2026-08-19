# The founding documents

These three documents predate the repository and are its specification. They
were written as design work against a Go implementation; the implementation
here is Odin, and the translation notes below govern where the two diverge.
The documents are the living record: amendments happen *in them*, with the
ADRs under `.metis/adrs/` recording each decision and its date, so the spec
and the reasons never sit in two places that can drift.

## Reading order

1. **[`architecture.md`](architecture.md)** — the premises: the data model,
   the workload, dictionary encoding, inlined terms, epochs and MVCC, query
   evaluation, and the appendices on reasoning and justification. Its
   persistence design (bbolt) was superseded by `log.md`; everything else
   stands, and both later documents cite it section by section.
2. **[`log.md`](log.md)** — the on-disk format: segments, record framing, the
   hash chain, term definitions inside the chain, durability and torn-tail
   recovery, replay as the only load path.
3. **[`api.md`](api.md)** — the resident store: the exact layout and width of
   every in-memory structure, the tenant-density cost model, and the layered
   pattern-matching API (§12). §13 derives the API's final shape from the
   first application written against it.

A fourth companion — the edit surface: HTTP, forms, changesets, and where
SHACL validation runs — lives with the consuming application rather than
here, because servers and protocol layers are out of scope family-wide. Its
store-side asks (`Apply`, the validation mode, typed per-quad errors, the
prefix context) are captured in `.metis/vision.md` as v1 scope.

## Odin translation notes

The documents assume Go. Four consequences, none of which change the format
on disk:

- **The GC material is moot.** `api.md` §7 (`GOMEMLIMIT`, `GOGC`,
  `FreeOSMemory`) and the `noscan` argument of §4.1 answer a problem manual
  memory management does not have. The *budget discipline* those sections
  protect — per-tenant RAM as the resource that runs out — still applies.
- **Snapshot reclamation is explicit.** Immutable-snapshot designs lean on a
  collector to reclaim superseded index sets; here reclamation is a design
  decision with its own ADR, not a free property.
- **Delta permutations are deferred.** `api.md` §5.2's main-plus-delta
  structure exists to bound *GC garbage* per commit. With explicit
  allocation, flat copy-on-write permutations are acceptable for v1 at the
  documented write rates; the ADR records the trigger for revisiting.
- **Code sketches are sketches.** Go signatures translate to Odin procedure
  sets in the family's style (`STORE-A-0002`'s convention); `unsafe.String`
  tricks and interface-boxing concerns disappear, the pointer-free layouts
  stay — for cache density, which was always their better half.
