# Project Progress

- **Project:** sqlite-data (Mango fork of pointfreeco/sqlite-data)
- **Target milestone:** Consumer-clearing patches done — reached (5.3a + 5.3b closed the re-open); stop for review (then Phase 4 → "Open patch work done")
- **Status:** `milestone-reached` (Phase-5 milestone stands; a 1.10.0 retarget also landed on `mango/patches-1.10`)
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
  - [x] 5.3b always-on durable pending ledger — kill-restart guards red-verified for both S5 shapes; start wipe removed, clears on resolution [model: fable]
- [x] 🏁 **MILESTONE: Consumer-clearing patches done** ← stop; MonteSprout adopts ALL Phase-5 work in ONE `/mango-update` (its 48.3), then cuts 1.0(17)
- [x] **Phase 6 — Retarget onto upstream 1.10.0** _(unplanned; done on request 2026-08-15)_
  - [x] 6.1 Rebase the stack as `mango/patches-1.10` (28 commits; only patch 3 conflicted)
  - [x] 6.2 Patch 3 retune to `.upToNextMinor(from: "0.36.0")` — 1.10.0's own `Package.resolved` pin
  - [x] 6.3 Take upstream's `TriggerTests` snapshot re-record (tag 1.10.0 ships a stale snapshot; fixed upstream in #522, unreleased)
  - [x] 6.4 Review + commit the retarget, push `mango/patches-1.10`

---

## Current Status

- **Current phase / sub-phase:** Phase 6 complete — `mango/patches-1.10` is committed and pushed
- **State:** milestone-reached (the Phase-5 milestone stop still stands; the retarget was requested outside the roadmap and does not move it)
- **Last completed:** 6.4 — reviewed, committed and pushed the retarget (guard-rot correction applied to `MANGO-PATCHES.md` in the same pass)
- **Build:** green · **Tests:** see below · **Simulator-verified:** n/a

**Test state on `mango/patches-1.10` (full suite, run twice, 2026-08-15):** 329 tests, **2 failures**,
both **pre-existing** — `AccountLifecycleTests.signInUploadsLocalRecordsToCloudKit_SkipExistingCloudKitRecords`
and `AccountLifecycleTests.createSharedRecordWhileSoftLoggedOut`. Verified pre-existing by running the
full suite on `mango/patches-1.9`, where they fail the same way (the filtered-run diffs are
byte-identical between the two branches). They surface either as
`SQLite error 5: database is locked` at `SyncEngine.swift:669` (full runs) or as an empty-result
snapshot mismatch (filtered runs) — i.e. load-sensitive, and unrelated to the retarget.

⚠️ **This contradicts the "Tests: green (2026-08-15)" line this file carried before.** Nothing in the
1.10.0 work touched those tests, and no dependency pin moved (`Package.resolved` changed only its
`originHash`). Either the earlier green runs dodged a flake, or something in the local environment
drifted after they were recorded. **Unresolved — worth a look before the next consumer adoption**,
since a load-sensitive failure in the account-lifecycle path is exactly the class of thing the
Phase-5 work exists to make trustworthy.

---

## Next Concrete Action

> **Decide which base MonteSprout 1.0(17) adopts.** `mango/patches-1.10` is pushed, but pushing a
> fork branch is inert: every consumer still pins `mango/patches-1.9` revisions and those stay valid
> until a pin moves, which only `/mango-update` does.
>
> Decide before adopting: whether MonteSprout's 1.0(17) should adopt the Phase-5 work off
> `mango/patches-1.9` (as already planned in its 48.3) or off the newer 1.10.0 base. Those are the
> same patch behavior on different upstream bases — adopting 1.10.0 also pulls upstream's
> `@FetchOne` auto-observation and `StrictDecoding` trait, which is a bigger consumer change than a
> pin bump. Recommend: ship 1.0(17) off 1.9 as planned, adopt 1.10.0 in a later, separate bump.
>
> Still open afterwards, unchanged: 4.1 — bound the remaining unbounded `from:` ranges in
> `Package.swift` **and `Package@swift-6.0.swift`** to the minors the base tag's own
> `Package.resolved` pins (GRDB first: declared `from: "7.6.0"`, resolves 7.11.1), per the patch-3
> rationale; full suite twice; update `MANGO-PATCHES.md` § patch 3 "Owed".

---

## Open Decisions (reversible — defaults chosen, proceeding)

- **What fills OVERVIEW/architecture/ROADMAP in a fork repo** → chose **`MANGO-PATCHES.md` stays the single intact reference doc** → DECISIONS.md § 2026-08-15 — /adopt: fork-shaped doc contract
- **Monorepo surface layout** → chose **waived — the upstream-shaped tree is load-bearing for rebases** → DECISIONS.md § 2026-08-15 — /adopt: fork-shaped doc contract
- **PRD** → chose **placeholder pointing at the MANGO-PATCHES preamble + consumer incident records** → DECISIONS.md § 2026-08-15 — /adopt: fork-shaped doc contract
- **Upstream 1.10.0's stale `triggers()` snapshot** → chose **take only #522's two `TriggerTests` lines, not the whole commit; drop at the first tag containing #522** → DECISIONS.md § 2026-08-15 — 1.10.0 retarget
- **How a retarget proves no patch was dropped, now that 5 of 9 guards have rotted** → chose **the byte-identity check on `Sources/SQLiteData/CloudKit/` is load-bearing; rewriting the rotted guards stays owed** → DECISIONS.md § 2026-08-15 — 1.10.0 retarget

---

## Needs You (irreversible / load-bearing — halts the run)

- **Which base MonteSprout 1.0(17) adopts** — `mango/patches-1.9` (as planned in its 48.3) or the new
  1.10.0 base. Recommendation above: stay on 1.9 for 1.0(17); take 1.10.0 as its own later bump.
- **Two pre-existing `AccountLifecycleTests` failures** contradict this file's previous "Tests: green"
  claim. Not caused by the retarget (they fail identically on `mango/patches-1.9`) and not a blocker
  for it, but they are unexplained and sit in the account-lifecycle path. See Current Status.

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
