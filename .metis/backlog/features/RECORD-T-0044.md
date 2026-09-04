---
id: enumerate-a-candidate-window
level: task
title: "Enumerate a candidate window irrespective of visibility: telling \"never asserted\" from \"asserted and since retracted\""
short_code: "RECORD-T-0044"
created_at: 2026-09-04T20:00:00+00:00
updated_at: 2026-09-04T19:47:59.128538+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#feature"
  - "#phase/completed"


exit_criteria_met: true
initiative_id: NULL
---

# Enumerate a candidate window irrespective of visibility: telling "never asserted" from "asserted and since retracted"

## Objective **[REQUIRED]**

**This is a capability gap, and it is blocking a downstream consumer**
(`odin-rdf-app`), which is the difference between this item and
`RECORD-T-0026`. It is filed under the family's convention that a
capability the published interface cannot express becomes an
evidence-backed upstream proposal rather than a backend-specific
workaround.

A consumer reading as-of a pinned epoch needs to distinguish two answers
that are the same absence to `scan_next`:

  - **never asserted** — no fact matching the pattern has existed in this
    store at any epoch;
  - **asserted and since retracted** — a fact matched once, and the epoch
    being read is outside the interval it lived in.

The difference is the whole of a temporal read's "not defined at this
date" against "there is no such thing". A UI that cannot tell them apart
must render a retracted record's history as a zero rather than as an
absence with a beginning, which is the case this consumer's own
demonstrator exists to show.

### What is no longer expressible, and why it was expressible before

`Range` carried the candidate window as public fields through `v0.7.0`:

    Range :: struct {
        snap:     Snapshot,
        order:    Order,
        main:     []Fact_ID,
        delta:    []Fact_ID,
        residual: Pattern,
    }

A consumer walked `main` directly and applied its own tests — the
residual components, `snapshot_derived`, its own graph membership — while
**deliberately not** applying the visibility test, because seeing the
retracted generations was the point. `snapshot_match`'s own doc comment
supports exactly this reading: the window "holds *every generation*", each
`Fact` "carries the interval it lived in as public fields", and "only
`scan_next` applies the visibility test".

`v0.8.0` (`RECORD-I-0009`) replaces the flat arrays with b+tree positions:

    Range :: struct { snap: Snapshot, order: Order, lo, hi: int, residual: Pattern }

That change is **correct and this item does not ask for it to be
reverted.** `doc/api-surface.txt` states that `Range` is one of the
opaque handles — "they are public, their fields are internal" — so the
consumer was reading an internal and the release was entitled to move it.
The gap the change *revealed* is that there is now no supported way to ask
the question at all:

  - `range_iter` + `scan_next` always apply `assert <= epoch < retract`;
  - `Filter.origin` (`Asserted | Derived | Any`) is about **inference**,
    not about time, so `.Any` does not mean "any epoch";
  - `range_len` counts every generation in the window but cannot apply the
    residual, so it answers an upper bound and never a fact;
  - `snapshot_visible` and `snapshot_derived` classify an id a consumer
    already has, and there is no supported way to obtain one;
  - `store_at` would mean binary-searching epochs, from call sites that
    hold a `Snapshot` and no `^Store` — and would turn one windowed read
    into O(log n) index acquisitions.

### The shape asked for, without prescribing it

Anything that yields the ids in a range's window with the visibility test
suppressed and the residual still applied. Two spellings that would each
serve, in the order this consumer would prefer them:

1. **A stated epoch policy on `Filter`**, beside `origin` and `scope` and
   with the same "no valid zero" discipline `RECORD-T-0029` established:

       Epoch_Scope :: enum u8 { Visible = 1, Any = 2 }

   `scan_next` skips the interval test under `.Any` and changes in no
   other respect. This is the smaller change and it keeps one scan
   implementation, one set of residual tests, and one place where a
   consumer states what it wants — which is the property `RECORD-T-0029`
   was argued for.

2. **A separate constructor**, `range_iter_all(r, f) -> Scan`, if mixing
   the two into one `Filter` is judged to make the hot path's branch set
   worse. The consumer does not care which; it cares that the answer does
   not require naming `Range`'s fields.

**Not asked for:** exposing `perm_cursor`/`perm_next` over `Index_Set` as
the supported route. They are reachable today, and using them would be
this consumer reaching around the contract a second time — the same
mistake at a lower level, and one that would break again on the next
index change.

## Acceptance Criteria

- [x] A consumer holding a `Snapshot` and a `Pattern` can enumerate every
      generation matching that pattern — visible at the pinned epoch or
      not — with the residual components applied, through published names,
      without naming a field of `Range`, `Scan` or `Index_Set`.
- [x] Each yielded id can still be classified: `snapshot_fact` gives the
      interval, `snapshot_derived` the origin. (Both already do; this is
      here so the pairing is stated rather than assumed.)
- [x] The visible-only path is unchanged in behaviour and unregressed in
      cost — a consumer that states the existing policy pays nothing for
      the new one.
- [x] `doc/api-surface.txt` covers the addition, and `Range` stays opaque:
      the point of the item is that the question is answerable **without**
      reading its fields.

## Implementation Notes

### Evidence

The consumer's own measurement rule is "time the real thing on real data",
so no cost claim is made here. What is offered instead is the frequency:
this read is on a **miss path only** — it runs where the ordinary visible
read has already answered "nothing", so it is paid once per miss and never
once per hit. It is not a hot path and does not need to be a fast one.

### Why this is not the consumer's own layer

By the family's three-way test, this is not policy, not IRI minting, not
status mapping and not configuration. It is a question about what the
**store** holds across epochs, answerable only from the index, and the
store is the one component that knows the answer. The consumer can state
the question and cannot compute it.

### Relationship to RECORD-A-0005

None that is adverse. The snapshot contract — acquired when needed,
released before the response goes, never held across think-time — is
untouched: this is one more way to read *through* a snapshot already held,
not a second acquisition and not a longer-lived one.

## Status Updates

- **2026-09-04 — taken up; the shape is decided by the design document,
  and it is the consumer's second spelling.** `api.md` §12.6 already
  answers this question: *"The entry point is separate from `Match`,
  deliberately"* — `History(p, f) Range`, "every generation matching the
  pattern, ignoring visibility. Origin still applies, and is still
  required" — and it rejects the flag-on-`Filter` spelling by name:
  "expressing that as a flag on `Filter` would mean some combination of
  options makes `Match` silently return retracted facts. That is the kind
  of thing that produces a wrong answer in an audit years later, so it
  gets its own name." The consumer's option 1 (`Epoch_Scope` on `Filter`)
  is exactly that combination; option 2 is §12.6 as written, and
  the document was never implemented on this point. So:
  - `snapshot_history(snap, p) -> Range` — the same prefix window
    `snapshot_match` computes, over the order `choose_order` picks, with a
    private `all` flag set inside the opaque `Range`. `range_iter` carries
    it into `Scan`; `scan_next` skips the interval test under it and
    changes in no other respect — one scan implementation, one set of
    residual tests, as the consumer asked.
  - `snapshot_match` cannot return a retracted generation under any
    `Filter`, which is the property §12.6 was protecting; `range_len` on a
    history range is the same count it always was.
  - Cost on the visible path: one predictable branch per candidate.
  - Tests: the read oracle re-run with the interval test dropped, every
    pattern × epoch × origin × scope, plus the consumer's own case pinned
    by hand — `(alice, knows, bob)` at epoch 2 is *absent* to `match` and
    *two generations* to `history`, `[1,2)` and `[3,live)`; `{s = 9}` is
    absent to both.
  - Documents: `api.md` §12.6 amended with the Odin name; `api-surface.txt`
    +1; vision Current State.

- **2026-09-04 — filed.** Found by `odin-rdf-app` when adopting `v0.8.0`:
  one call site, on a miss path, which had been reading `Range.main`. The
  consumer's own fault for reading an internal, and it is not asking for
  the internal back — it is asking for the question to have a published
  answer. Nothing else in that consumer broke on `v0.8.0`; every other
  read goes through `range_iter`/`scan_next` and is unaffected.

- **2026-09-04 — built, tested, documented; unreleased on `main`.**
  `record/read.odin`: `Range.all` and `Scan.all` (internal fields of opaque
  handles), `snapshot_history(snap, p) -> Range`, a file-private `window`
  shared with `snapshot_match_as`, and `scan_next` guarding its interval test
  with `if !sc.all`. `record/read_test.odin`: `test_read_history` — the
  visible oracle with the epoch test dropped, 13 patterns × 5 epochs × 3
  origins × 3 scopes, `range_len` equal to the match range's on every one,
  every visible id present in the history and every history id visible
  exactly when `snapshot_visible` says so; then the consumer's case by hand:
  `(alice, knows, bob)` at epoch 2 is absent to `snapshot_exists` and two
  generations to `snapshot_history`, `[1,2)` and `[3,live)`, neither visible,
  neither derived; `{s = 9}` absent to both. `make check` green, surface at
  74 names; `make test` green on both passes (94 + 11 + 1, then 101
  optimized). Documents: `api.md` §12.6 amended (built as written; the
  paragraph refusing the `Filter` flag was the decision), `api-surface.txt`
  +`snapshot_history`, vision Current State, family CLAUDE.md. Not measured:
  the consumer's own rule is "time the real thing", and the visible path's
  change is one predictable branch per candidate. **The consumer needs a tag
  to pin** — cutting `v0.9.0` is the owner's call.

- Acceptance: enumerate every generation through published names without
  naming a field of `Range`/`Scan`/`Index_Set` — yes, `snapshot_history` +
  `range_iter` + `scan_next`; classification by `snapshot_fact` and
  `snapshot_derived` — stated in the doc comment and tested; visible path
  unchanged — the oracle suite is untouched and green; `api-surface.txt`
  covers it and `Range` stays opaque — yes.