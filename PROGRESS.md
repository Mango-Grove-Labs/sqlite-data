# Project Progress

- **Project:** sqlite-data (Mango fork of pointfreeco/sqlite-data)
- **Target milestone:** Consumer-clearing patches done — **re-opened by consumer review 2026-08-15**: 5.3 added (legacy `-1` mirror loop = adoption blocker; durable park = the S5-edit gap)
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
- [ ] **Phase 5 — Consumer fix round: the 1.0(16) matrix findings (F2 + F10)** _(jumps the queue ahead of Phase 4 — release-blocking for MonteSprout; evidence: the consumer's `docs/incidents/2026-08-15-device-matrix-1.0.16.md`; scope prose: `MANGO-PATCHES.md` § 7 defect note + § 9 Planned)_
  - [x] 5.1 Patch 7 amendment — F2: slim-ack `?? -1` mirror false-positive → reproduced red first, then guarded (a stampless ack leaves the mirror untouched) [model: fable]
  - [x] 5.2 Patch 9 — F10: engine-start targeted rescan (never-confirmed + mirror-behind; stranded DELETEs deliberately out of scope) [model: fable]
  - [x] 5.3a migration nulling the legacy `-1` mirror sentinels — upgraded-ledger test red-verified via the new migration-prefix `upTo:` hook [model: fable]
  - [ ] 5.3b always-on durable pending ledger — `didUpdate`/`didDelete` write `PendingRecordZoneChange` while running too; sends/acks clear; the existing start drain re-enqueues; patch-6 parks write through — covers the stranded-edit + stranded-DELETE shapes [model: fable]
- [ ] 🏁 **MILESTONE: Consumer-clearing patches done** ← stop; MonteSprout adopts ALL Phase-5 work in ONE `/mango-update` (its 48.3), then cuts 1.0(17)

---

## Current Status

- **Current phase / sub-phase:** 5.3b — the always-on durable pending ledger
- **State:** not-started (5.3a shipped 2026-08-15: the sentinel-nulling migration + the
  migration-prefix `upTo:` test hook; the adoption-blocking loop is closed at upgrade time)
- **Last completed:** 5.2 — Patch 9, engine-start targeted rescan (kill-restart guard red-verified pre-patch; full suite green twice, 2026-08-15)
- **Build:** green · **Tests:** green (2026-08-15) · **Simulator-verified:** n/a

---

## Next Concrete Action

> Implement 5.3b (⚠ [model: fable]): make the durable `PendingRecordZoneChange` ledger **always-on** —
> `didUpdate`/`didDelete` write it while the engine runs too (today: only when stopped, see the
> `guard isRunning` branches in SyncEngine.swift), sends/acks clear the matching rows, the existing
> start drain (`enqueueLocallyPendingChanges`) re-enqueues, and patch-6 parks write through it.
> Red-first kill-restart tests for BOTH S5 shapes (stranded edit on a slim-acked NULL-mirror row ·
> stranded DELETE); patch 9's boundary test stays green (no blanket). Watch the clear-on-ack path:
> rows must not accumulate forever, and a clear that outruns the ack loses the crash protection.
> Full suite twice; MANGO-PATCHES § 6/§ 9 updated; then the milestone re-closes and MonteSprout 48.3
> adopts everything in ONE `/mango-update`.
> _(Phase 4 resumes after Phase 5, starting at 4.1 — bound the unbounded ranges, GRDB first.)_

---

## Open Decisions (reversible — defaults chosen, proceeding)

- **What fills OVERVIEW/architecture/ROADMAP in a fork repo** → chose **`MANGO-PATCHES.md` stays the single intact reference doc** → DECISIONS.md § 2026-08-15 — /adopt: fork-shaped doc contract
- **Monorepo surface layout** → chose **waived — the upstream-shaped tree is load-bearing for rebases** → DECISIONS.md § 2026-08-15 — /adopt: fork-shaped doc contract
- **PRD** → chose **placeholder pointing at the MANGO-PATCHES preamble + consumer incident records** → DECISIONS.md § 2026-08-15 — /adopt: fork-shaped doc contract
- **Stranded DELETEs excluded from the start rescan** → chose **live rows only** (stands for the rescan predicate; the delete shape is covered at write time by 5.3b's ledger instead) → DECISIONS.md § 2026-08-15 — 5.2: stranded deletes stay out of the start rescan

---

## Needs You (irreversible / load-bearing — halts the run)

- _none_

---

## Assumptions & Risks

- Fork discipline: never edit upstream text (README, `SyncEngineDelegate.swift` doc example, `Examples/`) — divergence costs a rebase conflict for no behavior gain.
- Patch work is consumer-driven: read the consuming app's incident record (MonteSprout `docs/incidents/…`) before changing or reviewing a patch.
- Every retarget must follow `MANGO-PATCHES.md` § Rebase procedure including the per-patch vacuity guards — a skipped guard can silently drop a patch.
- Consumers pin by revision in lockstep (same SHA, same SSH URL form); pushes here are inert until pins bump — never bump pins as a side effect of other work (`/mango-update` owns that).
- The Phase-5 fixes are proven against the mock; the real proof is the consumer's 1.0(17) device-matrix re-run after adoption — treat the milestone as provisional until that comes back clean.

---

## How to Resume

This file is the handoff. A fresh session should: read this top-to-bottom →
do **Next Concrete Action** → on completion, check off the roadmap item,
**overwrite** **Current Status** + **Next Concrete Action** (the outgoing
narrative goes into a new `docs/JOURNAL.md` entry, not stacked here), add any
new **Open Decisions** one-liners (full rationale → `docs/DECISIONS.md`),
commit (with `PROGRESS.md` + `docs/JOURNAL.md`), then continue or stop at the
milestone. If **Needs You** is non-empty, STOP and surface those items.
