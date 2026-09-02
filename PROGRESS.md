# Project Progress

- **Project:** sqlite-data (Mango fork of pointfreeco/sqlite-data)
- **Target milestone:** Open patch work done — **reached** (Phase 4 closed by patch 16); stop for review
- **Status:** `milestone-reached` — every box on the roadmap is checked. Patches 1–16 now sit on **`mango/patches-1.12`** (upstream 1.12.0; the 2026-09-02 `/mango-update` retarget). Consumers still pin `mango/patches-1.10` revisions until their own coordinated `/mango-update` (sqlite-data pin + TCA ≥ 1.26 / IssueReporting 2.x together — see DECISIONS § 1.12.0 retarget).
- **Updated:** 2026-09-02

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
- [x] **Phase 4 — Open library work**
  - [x] 4.1 Bound the remaining unbounded `from:` ranges in both manifests → all 11 bounded to the base tag's `Package.resolved` pins, guarded by `ManifestBoundsTests`
  - [x] 4.2 Patch 8 — a failed read in `nextRecordZoneChangeBatch` parks/retries → both reads in the record provider, not only the metadata one
  - [x] 4.3 Patch 16 — `tearDownSyncEngine` drops triggers with `drop(ifExists: true)`, closing patch 5's known limitation (both drop sites, each load-bearing)
- [x] 🏁 **MILESTONE: Open patch work done** ← stop for review
- [ ] **Phase 5 — Consumer fix round: the 1.0(16) matrix findings (F2 + F10)** _(jumps the queue ahead of Phase 4 — release-blocking for MonteSprout; evidence: the consumer's `docs/incidents/2026-08-15-device-matrix-1.0.16.md`; scope prose: `MANGO-PATCHES.md` § 7 defect note + § 9 Planned)_
  - [x] 5.1 Patch 7 amendment — F2: slim-ack `?? -1` mirror false-positive → reproduced red first, then guarded (a stampless ack leaves the mirror untouched) [model: fable]
  - [x] 5.2 Patch 9 — F10: engine-start targeted rescan (never-confirmed + mirror-behind; stranded DELETEs deliberately out of scope) [model: fable]
  - [x] 5.3a migration nulling the legacy `-1` mirror sentinels — upgraded-ledger test red-verified via the new migration-prefix `upTo:` hook [model: fable]
  - [x] 5.3b always-on durable pending ledger — kill-restart guards red-verified for both S5 shapes; start wipe removed, clears on resolution [model: fable]
- [x] 🏁 **MILESTONE: Consumer-clearing patches done** ← stop; MonteSprout adopts ALL Phase-5 work in ONE `/mango-update` (its 48.3), then cuts 1.0(17)
- [x] **Phase 6 — Retarget onto upstream 1.10.0** _(unplanned; done on request 2026-08-15)_
  - [x] 6.1 Rebase the stack as `mango/patches-1.10` (28 commits; only patch 3 conflicted)
  - [x] 6.2 Patch 3 retune to `.upToNextMinor(from: "0.36.0")` — 1.10.0's own `Package.resolved` pin
  - [x] 6.3 Take upstream's `TriggerTests` snapshot re-record (tag 1.10.0 ships a stale snapshot; fixed upstream in #522, unreleased)
  - [x] 6.4 Review + commit the retarget, push `mango/patches-1.10`
- [x] **Phase 7 — Patch 10, from the review of the 1.10.0 retarget** _(the two `AccountLifecycleTests` failures 6.4 recorded as "pre-existing and unexplained" were 5.3b's own; root-caused in review, not by a new report)_
  - [x] 7.1 Patch 10 — metadatabase lock contention is waited out, never fatal (busy-mode inheritance + bounded ledger-write retries), and the guards + rebase procedure that let it hide; landed on `mango/patches-1.9`, cherry-picked here with the 6.0 manifest bound retuned to this base's `0.36.0`
- [x] **Phase 8 — Sharing participant readiness (MonteSprout Phase 51.1)** _(red-first; evidence: the consumer's `docs/research/2026-08-17-collaboration-readiness-audit.md` § 5)_
  - [x] 8.1 Patch 11 — participant `deleteShare` routes the root-record read through `database(for:)`, never `privateCloudDatabase`
  - [x] 8.2 Patch 12 — `willDeleteRecordsInZone(scope:reason:)` delegate hook fires before a zone purge (the fork's first additive-API patch; MangoSync is the consumer)
- [x] **Phase 9 — The revocation event shape (MonteSprout Phase 55.2b)** _(red-first; evidence: the consumer's `docs/research/2026-08-23-two-account-session-findings.md` § F13)_
  - [x] 9.1 Patch 13 — a revoked participant is told by RECORD deletions, not a zone deletion → the fork's second additive delegate method, `willDeleteSharedRootRecords:inZone:` (review rejected reusing the zone hook: one owner zone holds several shared hierarchies)
- [x] **Phase 10 — The ledger's false positive on applied records (MonteSprout Phase 55.2b-2)** _(red-first; evidence: the consumer's `docs/research/2026-08-23-two-account-session-findings.md` § F4)_
  - [x] 10.1 Patch 14 — a write the sync engine performed is not a user modification → the `isSynchronizing` guard on the trigger's `userModificationTime`, the mirror taking the stamp the server record CARRIED, and the repair migration patch 9's rescan needs
  - [x] 10.2 Patch 15 — the slim-ack residual → the stamp the SENT record carried is written down at batch build and moved into the mirror by its ack _(`MANGO-PATCHES.md` § 15)_

---

## Current Status

- **Current phase / sub-phase:** none in flight — Phase 4 complete, the "Open patch work done" milestone reached
- **State:** milestone-reached
- **Last completed:** 4.3 — patch 16. Both trigger drops in teardown are now `drop(ifExists: true)` (the per-table `dropTriggers` loop and `SyncMetadata`'s callback triggers), so a `deleteLocalData()` that failed and rolled back can be **retried in-process** once the cause is fixed instead of dying in teardown on `no such trigger`. Closes patch 5's known limitation. Red-first guard `DeleteLocalDataFailureTests.failedClearIsRetryableInProcess`; each `ifExists` vacuity-verified by neutralizing it in place — both halves are load-bearing.
- **Build:** green · **Tests:** green — **371 tests, ZERO failures** on `mango/patches-1.12` (2026-09-02, full suite ×2; the retarget added upstream's 16 new tests) · **Simulator-verified:** n/a
- ⚠ **The fork now caps the minor of every shared Point-Free dependency in a consumer's graph.** Nothing fails to resolve (TCA's own floors sit far below these bounds — verified against a TCA-shaped scratch graph), but the bounds move WITH the base at each retarget: on the 1.12 base swift-dependencies is bounded at 1.17.x (the 1.10-era "held at 1.14.x downgrade" note is obsolete — MonteSproutKit's 1.16.0 now moves UP). Intended trade — loud at `/mango-update` time beats silent in the field. If a consumer genuinely needs a newer minor, retarget here; never widen the range app-side.
- ⚠ **A permanently unreadable row now retries forever** (patch 8, same accepted shape as patch 1): it re-enters the batch builder and reports once per send round, and a consumer's "waiting to upload" count stays non-zero for it. That is the deliberate trade against the silent drop; a cap is the consumer's policy call, not the library's.
- ⚠ **A rebase that takes upstream's `tearDownSyncEngine` silently re-breaks patch 16** — both drops must stay `drop(ifExists: true)` (teardown's callback-trigger loop AND the per-table `dropTriggers`); the bare form compiles fine and only shows up as a failed `deleteLocalData()` retry.
- ⚠ **Never route either read in `nextRecordZoneChangeBatch`'s provider back through `withErrorReporting`** — its optional-returning overload flattens `R??` to `R?`, which compiles fine and silently restores the 1.0(12) outage shape.
- ⚠ **Every other standing per-patch trap lives in `MANGO-PATCHES.md`, not here** — the stamp read off the RECORD not the metadata row (§ 15), the harness's missing `modificationDate` (§ 15), the migrations kept byte-stable and registered LAST (§ 14–15 + § Rebase procedure), and why patches 12 and 13 stay separate hooks and each is inert until a consumer adopts it (§ 12–13). Read that file before touching any patch.

---

## Next Concrete Action

> **Stop for review — the roadmap holds no unchecked work.** The 1.12.0 retarget is done here
> (2026-09-02); the next concrete action lives in the CONSUMER repos: a coordinated `/mango-update`
> that moves the sqlite-data pin onto `mango/patches-1.12` (MangoSync's declared `revision:` first,
> apps in lockstep after) **together with** the TCA ≥ 1.26 / IssueReporting 2.x generation bump —
> the 1.10-based pin and new-generation TCA cannot coexist in one graph (DECISIONS § 1.12.0
> retarget). The one standing debt here, if you
> want work without a trigger: **rewrite the five rotted vacuity guards** (patches 1, 5, 6, 7, 9) in
> the neutralize-in-place style — `MANGO-PATCHES.md` § Guard executability.
>
> ⚠ Patches 13, 14, 15 and 16 are **inert for MonteSprout until it bumps its pin** (still `d84eeaa`,
> the patch-14 tip) — that bump is `/mango-update`'s job in that repo, never a side effect of work here.
>
> **Settled 2026-08-16: the consumer base is `mango/patches-1.10` @ `e18249a`** — decided by action
> (MangoSync 0.7.2 pins it, every Mango app bumped in lockstep to the same revision and SSH URL, per
> `MANGO-PATCHES.md` § Consumer rule); 1.0(17) therefore also takes upstream's `@FetchOne`
> auto-observation and `StrictDecoding` trait.
>
> **Standing constraint for any future pin move: never ship off a pre-patch-10 revision** — 5.3b's
> ledger write goes through the host's connection, and without patch 10 a contended write is
> swallowed, so the durability the device matrix exists to verify would be silently absent under
> exactly the bulk-write conditions the S5 step tests.

---

## Open Decisions (reversible — defaults chosen, proceeding)

- **Upstream 1.10.0's stale `triggers()` snapshot** → chose **take only #522's two `TriggerTests` lines, not the whole commit; drop at the first tag containing #522** → DECISIONS.md § 2026-08-15 — 1.10.0 retarget. **Closed 2026-09-02:** the 1.12.0 retarget retired the carry as planned (1.11.0 ships #522)
- **How a retarget proves no patch was dropped, now that 5 of 9 guards have rotted** → chose **the byte-identity check on `Sources/SQLiteData/CloudKit/` is load-bearing; rewriting the rotted guards stays owed** → DECISIONS.md § 2026-08-15 — 1.10.0 retarget

---

## Needs You (irreversible / load-bearing — halts the run)

- _none_

## Assumptions & Risks

- Fork discipline: never edit upstream text (README, `SyncEngineDelegate.swift` doc example, `Examples/`) — divergence costs a rebase conflict for no behavior gain.
- Patch work is consumer-driven: read the consuming app's incident record (MonteSprout `docs/incidents/…`) before changing or reviewing a patch.
- Every retarget must follow `MANGO-PATCHES.md` § Rebase procedure including the per-patch vacuity guards — a skipped guard can silently drop a patch.
- Consumers pin by revision in lockstep (same SHA, same SSH URL form); pushes here are inert until pins bump — never bump pins as a side effect of other work (`/mango-update` owns that).
- The Phase-5 fixes are proven against the mock, and adoption is now done (base `mango/patches-1.10` @ `e18249a`, 2026-08-16) — but the real proof is still outstanding: the consumer's 1.0(17) **device-matrix re-run on hardware**, including the S5 step this whole phase exists for. The 2026-08-16 re-verification was the test suite, not the matrix. Treat the milestone as provisional until the matrix comes back clean; it is tracked consumer-side (MonteSprout), not here.

---

## How to Resume

This file is the handoff. A fresh session should: read this top-to-bottom →
do **Next Concrete Action** → on completion, check off the roadmap item,
**overwrite** **Current Status** + **Next Concrete Action** (the outgoing
narrative goes into a new `docs/JOURNAL.md` entry, not stacked here), add any
new **Open Decisions** one-liners (full rationale → `docs/DECISIONS.md`),
commit (with `PROGRESS.md` + `docs/JOURNAL.md`), then continue or stop at the
milestone. If **Needs You** is non-empty, STOP and surface those items.
