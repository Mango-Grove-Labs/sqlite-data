# Project Progress

- **Project:** sqlite-data (Mango fork of pointfreeco/sqlite-data)
- **Target milestone:** Open patch work done — stop here for review
- **Status:** `in-progress`
- **Updated:** 2026-08-15

---

## Reference docs (the router — `docs/` files don't auto-load)

- **Fork contract (patch catalog · rebase procedure · consumer rule):** `MANGO-PATCHES.md` — fills the OVERVIEW / architecture / ROADMAP-prose roles for this repo; read it before touching any patch
- **PRD (intent):** `docs/PRD.md` — placeholder; a fork has no product PRD (see the file for where intent lives)
- **Journal (past — append-only):** `docs/JOURNAL.md`
- **Decisions log:** `docs/DECISIONS.md`
- **Upstream docs:** `README.md` (untouched upstream text — never edit)
- **Active surface:** none — SPM package at repo root; build/test contract: `swift test` (full suite twice at each rebase, per `MANGO-PATCHES.md` § Rebase procedure)

---

## Roadmap

- [x] **Phase 1 — Patch stack on upstream 1.6.6**
  - [x] 1.1 Patch 1 — park + re-enqueue CASCADE child on `.referenceViolation` save, never local-delete
  - [x] 1.2 Patch 2 — report every silently-dropped failed save with its CKError
  - [x] 1.3 Patch 3 — bound the `swift-structured-queries` range (the 1.0(12) sync outage) + decode tripwire tests
- [x] **Phase 2 — Retarget onto upstream 1.7.0**
  - [x] 2.1 Rebase the stack as `mango/patches-1.7`
  - [x] 2.2 Patch 5 — a failed `deleteLocalData()` clear throws, never reports-and-continues
  - [x] 2.3 Patch 6 — an account-availability transition parks the change for retry, never drops it
  - [x] 2.4 Patch 7 — mirror the server `userModificationTime` into a column (+ the 41.2a characterization)
- [x] **Phase 3 — Retarget onto upstream 1.9.0**
  - [x] 3.1 Rebase the stack as `mango/patches-1.9` (consumer branch)
  - [x] 3.2 Patch 4 — a failed CKAsset download parks for retry, never writes NULL
- [ ] **Phase 4 — Open library work**
  - [ ] 4.1 Bound the remaining unbounded `from:` ranges in `Package.swift` (GRDB is the largest gap) — owed per `MANGO-PATCHES.md` § patch 3; full suite twice
  - [ ] 4.2 Patch 8 — a failed metadata read in `nextRecordZoneChangeBatch` parks/retries; only a genuinely absent record leaves the queue (`MANGO-PATCHES.md` § 8)
  - [ ] 4.3 `tearDownSyncEngine` drops triggers with `drop(ifExists: true)` so a failed `deleteLocalData()` clear is retryable in-process (`MANGO-PATCHES.md` § patch 5 known limitation)
- [ ] 🏁 **MILESTONE: Open patch work done** ← stop for review

---

## Current Status

- **Current phase / sub-phase:** 4.1 — Bounded-range audit
- **State:** not-started
- **Last completed:** 3.2 — Patch 4, asset-download park (stack of 7 patches + guards green on `mango/patches-1.9`, verified 2026-08-10)
- **Build:** green · **Tests:** green (as of 2026-08-10) · **Simulator-verified:** n/a

---

## Next Concrete Action

> Implement 4.1: in `Package.swift` (and `Package@swift-6.0.swift`), bound each remaining unbounded `from:` dependency to the minor the 1.9.0 base tag's own `Package.resolved` pins (GRDB first: declared `from: "7.6.0"`, resolves 7.11.0), per the patch-3 rationale in `MANGO-PATCHES.md`; run the full suite twice; update the § patch 3 "Owed" paragraph; consumers' pins are unaffected until bumped in lockstep.

---

## Open Decisions (reversible — defaults chosen, proceeding)

- **What fills OVERVIEW/architecture/ROADMAP in a fork repo** → chose **`MANGO-PATCHES.md` stays the single intact reference doc** → DECISIONS.md § 2026-08-15 — /adopt: fork-shaped doc contract
- **Monorepo surface layout** → chose **waived — the upstream-shaped tree is load-bearing for rebases** → DECISIONS.md § 2026-08-15 — /adopt: fork-shaped doc contract
- **PRD** → chose **placeholder pointing at the MANGO-PATCHES preamble + consumer incident records** → DECISIONS.md § 2026-08-15 — /adopt: fork-shaped doc contract

---

## Needs You (irreversible / load-bearing — halts the run)

- _none_

---

## Assumptions & Risks

- Fork discipline: never edit upstream text (README, `SyncEngineDelegate.swift` doc example, `Examples/`) — divergence costs a rebase conflict for no behavior gain.
- Patch work is consumer-driven: read the consuming app's incident record (MonteSprout `docs/incidents/…`) before changing or reviewing a patch.
- Every retarget must follow `MANGO-PATCHES.md` § Rebase procedure including the per-patch vacuity guards — a skipped guard can silently drop a patch.
- Consumers pin by revision in lockstep (same SHA, same SSH URL form); pushes here are inert until pins bump — never bump pins as a side effect of other work (`/mango-update` owns that).
- Assumed in-sync at adoption: suite last verified green 2026-08-10; re-verify before starting 4.x.

---

## How to Resume

This file is the handoff. A fresh session should: read this top-to-bottom →
do **Next Concrete Action** → on completion, check off the roadmap item,
**overwrite** **Current Status** + **Next Concrete Action** (the outgoing
narrative goes into a new `docs/JOURNAL.md` entry, not stacked here), add any
new **Open Decisions** one-liners (full rationale → `docs/DECISIONS.md`),
commit (with `PROGRESS.md` + `docs/JOURNAL.md`), then continue or stop at the
milestone. If **Needs You** is non-empty, STOP and surface those items.
