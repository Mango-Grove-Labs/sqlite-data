# Journal

> Append-only, newest entries last. Created by /adopt 2026-08-15.

## 2026-08-15 — /adopt: repo joins the doc contract

State at adoption: consumer branch `mango/patches-1.9` = upstream tag 1.9.0 + patches 1–7
and their guard tests, full suite verified green 2026-08-10 per the rebase procedure
(previous branches `mango/patches-1.6` / `-1.7` kept intact for existing consumer pins).
No history was evicted — the repo had no PROGRESS.md, no CLAUDE.md, and no status
sections anywhere; `MANGO-PATCHES.md` (patch catalog + rebase procedure + consumer rule)
predates adoption and stays intact at root by decision (see `docs/DECISIONS.md`
§ 2026-08-15). Adoption was purely additive: PROGRESS.md cursor + checklist, this
journal, the decisions log, and a PRD placeholder. Open items collected into Roadmap
phase 4: the owed unbounded-range audit (GRDB first), patch 8 (a read failure must not
masquerade as a deletion), and the `drop(ifExists:)` teardown fix.

## 2026-08-15 — Phase 5 planned: the consumer fix round (no code changed)

Planned from MonteSprout's 1.0(16) device-matrix evidence (its
`docs/incidents/2026-08-15-device-matrix-1.0.16.md`; the matrix failed on S5, build 17
is gated on this). Two slices, jumping the queue ahead of Phase 4: 5.1 = patch 7
amendment for the F2 mirror false-positive (verify-before-patch contractual — the
slim-ack `?? -1` suspect must reproduce in a failing test first), 5.2 = patch 9 for F10
(engine-start targeted re-enqueue REQUIRED — plan-review amendment: it is the only half
that heals already-stranded fleet rows, so "either half suffices" was dropped; durable
park demoted to optional hardening). Docs only: `MANGO-PATCHES.md` § 7 defect note +
§ 9 Planned, PROGRESS Phase 5 + cursor at 5.1, DECISIONS § Phase 5. Both slices tagged
`[model: fable]`.

## 2026-08-15 — 5.1 shipped: patch 7 F2 amendment (the stampless-ack mirror guard)

Verify-before-patch held: two new `UnsentUpdateVisibilityTests` cases injected a slim save
ack (no encrypted custom fields — what real CloudKit delivers; the mock echoes full
records) into `handleSentRecordZoneChanges` and went red on exactly the predicted
mechanism — mirror = `-1` via the `CKRecord.userModificationTime` getter fallback, unsent
count false-positive 1, and a slim re-ack stomping a previously-correct stamp. Fix in the
funnel (`setLastKnownServerRecord`): only mirror a stamp the record carries; stampless →
mirror and max-bump untouched; nil record still nils the mirror — the fetch path's
`upsertFromServerRecord` top guard applied to the save-ack path. Suite: 2 new tests, full
run green ×2. Gotcha for 5.2: on slim-ack devices confirmed rows now keep a NULL mirror —
the targeted rescan must treat NULL as "unknown", never as a rescan trigger, or it
degrades into the ruled-out blanket reupload (recorded in PROGRESS Assumptions & Risks).
MANGO-PATCHES: § 7 defect note rewritten as the landed F2 amendment; rebase procedure
gains its cherry-pick + vacuity-guard entries.

## 2026-08-15 — 5.2 shipped: patch 9 (engine-start targeted rescan) — milestone reached

Mechanism pinned first: while the engine runs, pending saves live only in CKSyncEngine's
in-memory state (the durable `PendingRecordZoneChange` table is written only while
stopped), so a force-quit loses them and nothing at `start()` rescanned the ledger.
`EngineStartRescanTests` reproduces the kill with `stop()`→`start()` (mock engines are
rebuilt fresh, discarding in-memory state) — both rescan tests red pre-patch. The fix:
`enqueueStrandedRecordsForCloudKit()` at start, the account-change path's no-op-update
idiom with the targeted predicate (live rows, never-confirmed OR mirror-behind via
`#sql` so `NULL < x` stays not-selected). Boundary test pins targeted-never-blanket
(in-sync + slim-ack NULL-mirror rows untouched). Stranded DELETEs deliberately excluded
(would re-save the tombstone — DECISIONS § 5.2); durable park not built (optional per
plan). 3 new tests; full suite green ×2. Phase 5 complete — milestone
"Consumer-clearing patches done" reached; adoption = MonteSprout 48.3's single
`/mango-update` pin bump, then 1.0(17) + matrix re-run.

## 2026-08-15 — Consumer review: 5.1/5.2 approved, Phase 5 re-opened as 5.3a/5.3b

The consumer-side review (MonteSprout session) approved both slices but found two
adoption blockers, and the fork-side plan review of that round corrected one mechanism.
5.3a = one-time migration nulling legacy `-1` mirror sentinels: pre-amendment rows hold
`-1`, patch 9 selects `-1 < local` at every start, and the amended funnel (correctly)
never repairs a slim ack — an upgraded device would blanket-reupload its whole dataset
per launch, through the composition of two individually-correct patches. 5.3b = the
always-on durable `PendingRecordZoneChange` ledger (writes while running, clears on
ack/send, drains at start, parks write through) — replacing the review's "park persists
at park time", which could never catch a mid-flight force-quit (no park handler ever
sees it; its own promised stranded-edit test would have stayed red). Milestone
un-checked until 5.3 lands; both boxes tagged `[model: fable]`. Docs only, no code.

## 2026-08-15 — 5.3a shipped: the sentinel-nulling migration

New metadatabase migration `"Mango: null the legacy -1 mirror sentinels"` (registered
after patch 7's, name byte-stable): `-1` mirrors → NULL at upgrade, real stamps and
never-confirmed NULLs untouched. The faithful test needed new infrastructure: a
migration-prefix hook (`migrate(metadatabase:upTo:)`, now `package`) so the test builds a
genuinely PRE-upgrade ledger, seeds legacy rows, and runs the full migrator over them —
a normal engine init has every migration applied before a test can seed anything.
Red-verified by unregistering the migration block (a bare revert would take the hook with
it and fail compilation instead — the vacuity entry documents the difference). Plus the
every-start loop characterization (green either way; pins why 5.3a ships with patch 9).
Gotcha for 5.3b: the loop test's direct `metadatabase.write` produced NO spurious
enqueue — the sync triggers live on the user connection, which 5.3b's ledger writes will
need to account for. 2 new tests; full suite green ×2.
