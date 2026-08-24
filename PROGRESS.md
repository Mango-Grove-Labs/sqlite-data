# Project Progress

- **Project:** sqlite-data (Mango fork of pointfreeco/sqlite-data)
- **Target milestone:** Consumer-clearing patches done — reached (5.3a + 5.3b closed the re-open); stop for review (then Phase 4 → "Open patch work done")
- **Status:** `milestone-reached` (Phase-5 milestone stands; the 1.10.0 retarget + patch 10 also landed on `mango/patches-1.10`, now the adopted consumer base; Phase 8 — patches 11/12 for MonteSprout 51.1 — Phase 9 — patch 13 — and Phase 10 — patches 14 + 15, for its 55.2b/55b.7 — landed on top)
- **Updated:** 2026-08-23

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
  - [ ] 4.1 Bound the remaining unbounded `from:` ranges in `Package.swift` (GRDB is the largest gap) — owed per `MANGO-PATCHES.md` § patch 3; full suite twice _(the `Package@swift-6.0.swift` structured-queries half landed with patch 10 on 2026-08-15; GRDB and the rest still open)_
  - [ ] 4.2 Patch 8 — a failed metadata read in `nextRecordZoneChangeBatch` parks/retries; only a genuinely absent record leaves the queue (`MANGO-PATCHES.md` § 8)
  - [ ] 4.3 `tearDownSyncEngine` drops triggers with `drop(ifExists: true)` so a failed `deleteLocalData()` clear is retryable in-process (`MANGO-PATCHES.md` § patch 5 known limitation)
- [ ] 🏁 **MILESTONE: Open patch work done** ← stop for review
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

- **Current phase / sub-phase:** Phase 10 COMPLETE — patches 14 (10.1) and 15 (10.2) both in
- **State:** milestone-reached (the Phase-5 milestone stop still stands; the retarget, patch 10 and Phases 8–10 were requested outside this repo's roadmap and do not move it)
- **Last completed:** 10.2 — patch 15, the stamp the SENT record carried survives to its ack. The batch builder writes `sentUserModificationTime` for every record in the batch it returns; a successful ack moves it into the mirror with `coalesce(max(mirror, sent), sent, mirror)`, a refused save discards it. Guarded 5.3a-style: dropping the batch-build call or emptying the ack move reddens the inversion + invariant tests; emptying the failure clear reddens the invariant test alone; levelling from the row's *current* stamp instead of the sent one reddens the window test **and** three existing F2/F10 tests — that shortcut is the invention patches 7 and 9 exist to prevent.
- **Build:** green · **Tests:** green — **348 tests, ZERO failures** on this branch (2026-08-23) · **Simulator-verified:** n/a
- ⚠ **The stamp is read off the RECORD in the batch, never off the metadata row** — `CKRecord.userModificationTime`'s setter takes a `max`, so an outgoing record can carry a higher stamp than its metadata, and what is on the wire is what the server holds.
- ⚠ **The harness cannot reproduce the field's ordering.** A mocked record has no `modificationDate` (read-only system field — nothing can set one), so `refreshLastKnownServerRecord`'s newer-than-mine guard always answers yes and the mock's batch build levels a confirmed row's mirror optimistically; real CloudKit's does not. Patch 15's inversion test reaches the behind-mirror state through a fetch that lands while the save is in flight — do not "simplify" that fetch away.
- ⚠ **Patch 15 narrows the NULL-mirror slim-ack shape in the field, it does not delete the rule.** Batch-built rows now leave their ack with a real mirror, so patch 9's rescan gains the "edit to a slim-acked row" shape; NULL is still "unknown, never a trigger", and 5.3b's ledger is still the only guard for a change that dies before its ack.
- ⚠ **Both repair migrations are data-only but they are still NEW migrations** — never edit a released one; keep names byte-stable, patch 15's registered **last**, patch 14's second-to-last.
- ⚠ **Patch 13 is INERT until a consumer implements `willDeleteSharedRootRecords:inZone:`** — a pin bump alone restores no revocation notice. MangoSync's `SharedZoneLifecycle` and its host both need the record-granular shape; that adoption is MonteSprout's own 55.2b slice. The shipped pin `c97c703` is the Phase-8 tip.
- ⚠ **Patch 12 alone is inert for the case it was written for.** Real CloudKit never deletes a revoked participant's zone, so that hook only ever fires for a zone the owner deleted or purged outright. Never read it as the revocation signal.
- ⚠ **Never make patch 13's default implementation forward to patch 12's hook.** One owner zone holds every hierarchy she shares out of it, so a zone-wide notice for the loss of one hierarchy makes a consumer destroy local data for records it still has. That is why the two hooks stay separate.

**The two `AccountLifecycleTests` failures this file previously carried as "pre-existing and
unexplained" are fixed and explained.** They were not upstream's and not the retarget's: 5.3b's
always-on ledger made the host connection write to the metadatabase on every local change, and neither
that connection nor the library's own was configured to wait for a lock. Both tests pass on a clean
checkout of tag 1.10.0 and on a 5.3b revert — which is what identified the cause. Patch 10 is the fix;
`MANGO-PATCHES.md` § 10 carries the mechanism, and rebase step 4b now separates "pre-existing" from
"upstream's" so the next one cannot hide the same way.

---

## Next Concrete Action

> **Resume with 4.1** — the base question that sat here is settled (see below), and nothing in this
> repo is open or release-blocking: Phase 10 closed with patch 15, so the patch stack has no known
> residual. ⚠ Patches 13, 14 and 15 are **inert for MonteSprout until it bumps its pin** (still
> `d84eeaa`, the patch-14 tip) — that bump is `/mango-update`'s job in that repo, never a side effect
> of work here.
>
> **Settled 2026-08-16: the consumer base is `mango/patches-1.10` @ `e18249a`.** Decided by action —
> MangoSync 0.7.2 pins it and every Mango app has been bumped in lockstep to that same revision and
> SSH URL, per `MANGO-PATCHES.md` § Consumer rule. This overtook the earlier "ship 1.0(17) off 1.9"
> recommendation; 1.0(17) therefore also takes upstream's `@FetchOne` auto-observation and
> `StrictDecoding` trait, which is why its device-matrix re-run covers more than a pin bump would.
>
> **Standing constraint for any future pin move: never ship off a pre-patch-10 revision.** 5.3b's
> ledger write goes through the host's connection, and without patch 10 a contended write is
> swallowed — the durability the device matrix exists to verify would be silently absent under
> exactly the bulk-write conditions the S5 step tests.
>
> Next actual work: 4.1 — bound the remaining unbounded `from:` ranges in
> `Package.swift` **and `Package@swift-6.0.swift`** to the minors the base tag's own
> `Package.resolved` pins (GRDB first: declared `from: "7.6.0"`, resolves 7.11.1), per the patch-3
> rationale; full suite twice; update `MANGO-PATCHES.md` § patch 3 "Owed". The structured-queries
> half of that audit landed with patch 10.

---

## Open Decisions (reversible — defaults chosen, proceeding)

- **What fills OVERVIEW/architecture/ROADMAP in a fork repo** → chose **`MANGO-PATCHES.md` stays the single intact reference doc** → DECISIONS.md § 2026-08-15 — /adopt: fork-shaped doc contract
- **Monorepo surface layout** → chose **waived — the upstream-shaped tree is load-bearing for rebases** → DECISIONS.md § 2026-08-15 — /adopt: fork-shaped doc contract
- **PRD** → chose **placeholder pointing at the MANGO-PATCHES preamble + consumer incident records** → DECISIONS.md § 2026-08-15 — /adopt: fork-shaped doc contract
- **Upstream 1.10.0's stale `triggers()` snapshot** → chose **take only #522's two `TriggerTests` lines, not the whole commit; drop at the first tag containing #522** → DECISIONS.md § 2026-08-15 — 1.10.0 retarget
- **How a retarget proves no patch was dropped, now that 5 of 9 guards have rotted** → chose **the byte-identity check on `Sources/SQLiteData/CloudKit/` is load-bearing; rewriting the rotted guards stays owed** → DECISIONS.md § 2026-08-15 — 1.10.0 retarget

---

## Needs You (irreversible / load-bearing — halts the run)

- _none_

Both prior bullets resolved 2026-08-16. **Base = `mango/patches-1.10` @ `e18249a`** — decided by
action (MangoSync 0.7.2 pins it, every Mango app bumped in lockstep to the same revision + SSH URL).
Not forced by patch 10 — that landed on **both** bases (`mango/patches-1.9` @ `869c362`,
`mango/patches-1.10` @ `e18249a`); the choice was the owner's, and its consequence is that 1.0(17)
also takes upstream's `@FetchOne` auto-observation and `StrictDecoding` trait. The
**two `AccountLifecycleTests` failures were never pre-existing** — they were 5.3b's metadatabase lock
contention, root-caused and fixed by patch 10 (consumer re-verified 2026-08-16: full suite ×2, zero
failures).

---

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
