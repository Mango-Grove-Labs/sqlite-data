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

## 2026-08-15 — 5.3b shipped: the always-on durable pending ledger — milestone re-closed

The F10 crash window is closed at the mechanism: `didUpdate`/`didDelete` now persist
every local change to the `PendingRecordZoneChange` table whether or not the engine runs
(still a Task — the trigger can't write re-entrantly; upstream's own TODO), every sent
outcome clears its rows (decode-matched; archiver blobs aren't byte-stable), the failure
handlers' re-enqueues (patches 1/6) write through so the parks are crash-durable, the
batch builder's drop-forever sites clear (else the start drain resurrects an absent
record each launch), and upstream's start-time table wipe is REMOVED — rows persist
until resolution; drain duplicates die in the engine state's set semantics.
`DurablePendingLedgerTests`: all three red-verified pre-patch (killed slim-acked edit ·
killed DELETE · clears-on-resolution). Patch 9's boundary test hardened with ledger
settles (the async persist could race its own ack-clear in the mock's instant round
trips). Known cost accepted: one small async write per changed row (noted in § 9).
Full suite green ×2. Phase 5 complete again — milestone "Consumer-clearing patches
done" re-closed; adoption = MonteSprout 48.3's single `/mango-update`, then 1.0(17) +
the matrix re-run whose S5 step this whole phase exists for.

## 2026-08-15 — Phase 6: retarget onto upstream 1.10.0 (`mango/patches-1.10`)

Requested outside the roadmap ("check and rebase to latest"). Upstream tag **1.10.0** (2026-08-11)
is two commits past our 1.9.0 base: `@FetchOne` primary-key auto-observation (#519) and the
`StrictDecoding` trait (#489). Targeted the tag rather than `upstream/main`, per the procedure;
main carries one further unreleased commit (#522, below).

The rebase was easy for a structural reason worth recording: **1.9.0→1.10.0 touches no CloudKit
source at all** (only `FetchOne`, the `StructuredQueries+GRDB` decoding layer, and docs). All 28
commits replayed with exactly one conflict — patch 3, which conflicts every time by construction.
Afterwards `git diff mango/patches-1.9 mango/patches-1.10 -- Sources/SQLiteData/CloudKit/` is
**empty**: every patched library file came through byte-identical. That is a direct refutation of
the risk step 4 exists for (patch 6's removed case-list codes, 5.3b's removed start wipe), and it
is now written into `MANGO-PATCHES.md` as the load-bearing anti-drop check at a retarget.

Patch 3 retuned to `.upToNextMinor(from: "0.36.0")` — 1.10.0 raised its own floor to 0.36.0 and
still declares it **unbounded**, so the patch is still ours to carry. This retune was not cosmetic:
1.10.0's `Package.resolved` pins 0.36.0, which the old `0.35.0` bound does not admit.

One genuinely new failure, and it was upstream's: `TriggerTests.triggers()` fails on a **clean
checkout of tag 1.10.0**. The 0.36.0 bump fixed a redundant paren pair in `IN (…)` subquery
rendering, but the tag's own inline snapshot still records the old form. Upstream fixed it the same
day in #522 — which is on `main` and in **no release tag**. Took only that commit's two
`TriggerTests.swift` lines; deliberately left the rest of #522, an unrelated
`$foo.set(…)` → `.taskLocal(…)` test-API migration that collides with our patched test files.

Two other failures (`AccountLifecycleTests.signInUploadsLocalRecordsToCloudKit_SkipExistingCloudKitRecords`,
`…createSharedRecordWhileSoftLoggedOut`) are **pre-existing** — the full suite on `mango/patches-1.9`
fails them identically, and the filtered-run diffs are byte-identical across the two branches. They
nonetheless contradict the "green (2026-08-15)" line PROGRESS.md carried, and no pin moved to explain
it (`Package.resolved` changed only its `originHash`). Left unexplained and surfaced under Needs You
rather than quietly absorbed.

Guard findings (step 4), as corrected by this session's own review pass: **four** guards are clean
and went red exactly as documented — patch 4, the patch-7 F2 amendment, 5.3a, 5.3b. **Patch 1 is not
clean**, contrary to the first draft of this entry: its `SyncEngine.swift` revert leaves the file
unmerged (bare `git revert`) or leaves conflict markers (3-way reverse-apply), and it only goes red
after the conflict is resolved in favour of the revert — a resolution that can also revert adjacent
patch content, so the red is not attributable to patch 1 alone. **Patches 5, 6, 7 and 9** are
inconclusive: bare revert conflicts (5, 6, 7) or reverse-applies to a no-op (9), because 5.3a/5.3b
later rewrote the same regions. Confirmed **not** rebase damage by running the identical reverts on
`mango/patches-1.9` — same behavior there. So five of the nine guards have rotted; rewriting them in
the 5.3a style (neutralize the mechanism in place, don't revert the commit) is now recorded as owed,
and the byte-identity check is what actually carries the anti-drop guarantee at a retarget.

Committed and pushed as `mango/patches-1.10`. No consumer is affected by the push: pins still point
at `mango/patches-1.9` revisions and stay valid until `/mango-update` moves them. Left open for the
user: which base MonteSprout 1.0(17) adopts, and the two unexplained pre-existing test failures.

## 2026-08-15 — Patch 10: the metadatabase must wait for a lock (a review finding, not a report)

Found reviewing the 1.10.0 retarget, chasing the one thing it left open: the two
`AccountLifecycleTests` failures it recorded as "pre-existing and unexplained". They are
neither. Both pass on a clean checkout of tag 1.10.0 and pass again when only the 5.3b
commit is reverted at the branch tip — so they are ours, one commit old. "Pre-existing on
the previous branch" had been read as "upstream's"; the distinguishing run (against the
clean base tag) is now step 4b of the rebase procedure.

The mechanism, from the actual failure text (`SQLite error 5: database is locked - while
executing BEGIN IMMEDIATE TRANSACTION`, later at `SyncEngine.swift:669`, inside the
persist's own `withErrorReporting`): the metadatabase file has two writers — the library's
connection and the host's, via the attached `sqlitedata_icloud` schema — and 5.3b turned
host-side writes there from rare into every-local-change. Neither side could survive that.
`defaultMetadatabase` builds from a fresh `Configuration()`, keeping GRDB's default
`busyMode = .immediateError`, and the ledger writes ride the host's connection, whose busy
behavior the library doesn't own. Either failure is swallowed by `withErrorReporting`, so
the row silently loses the durability 5.3b exists to provide — the pre-5.3b behavior patch
9's F10 fix was written to prevent, plus one reported issue per occurrence.

Patch 10 fixes both halves from one new Mango-owned file
(`CloudKit/Internal/MetadatabaseBusyMode.swift`, so upstream files carry three one-line call
sites): inherit the host's busy mode and upgrade only `.immediateError` to `.timeout(5)`;
and bounded 25/50/100 ms retries around the persist and the clear, for
`SQLITE_BUSY`/`SQLITE_LOCKED` only. The retry sleeps use `Task.sleep`, not
`\.continuousClock` — the suite injects a `TestClock` nothing advances, which would hang
rather than retry. Fixing the first half alone made the second half fail *more* (a waiting
connection takes the lock instead of giving it up), which is how the host-side half surfaced.

Guards: `MetadatabaseBusyModeTests` (decision · that waiting actually happens, via a
250 ms held write lock · the wiring through a real engine) — three of four red when the
busy-mode helper is neutralized, the inheritance test green by construction. The two
`AccountLifecycleTests` are the end-to-end guard. Suite: **332 tests, zero failures, four
consecutive full runs** — honestly green for the first time since 5.3b landed.

Carried in the same commit, both from the same review: `Package@swift-6.0.swift` gets patch
3's bound (unbounded for the whole 1.9 line — inert on 6.1+ toolchains, but the identical
hole, and step 5 now checks both manifests), and the rebase procedure gains the two rules
this episode cost us — run guards at the tip only (the stack is not buildable
commit-by-commit: patch 3 replays with the previous base's bound), and an unexplained
failure is a finding, not a baseline.

## 2026-08-16 — Adoption settled: the consumer base is `mango/patches-1.10` @ `e18249a`

Closes the base question Phase 6 left open. Decided by action rather than deliberation: MangoSync
0.7.2 pins `mango/patches-1.10` @ `e18249a`, and every Mango app was bumped in lockstep to that same
revision and SSH URL, as § Consumer rule requires (a mismatched revision *or* URL form anywhere in one
SPM graph fails resolution outright).

This overtook the recommendation recorded a day earlier, which was to ship 1.0(17) off `mango/patches-1.9`
and take 1.10.0 as a separate later bump. Worth recording *why the recommendation was not load-bearing*:
it rested on 1.10 being the bigger consumer change, which is still true — 1.0(17) now also takes
upstream's `@FetchOne` auto-observation and `StrictDecoding` trait — but not on patch 10, which landed
on **both** bases (`mango/patches-1.9` @ `869c362`, `mango/patches-1.10` @ `e18249a`). A draft of this
state file claimed 1.10 was "the only base carrying patch 10"; it was not, and the claim was corrected
in review before it could mislead a future pin decision.

Also closed here: the two `AccountLifecycleTests` failures that Phase 6 committed as "pre-existing and
unexplained". They were neither upstream's nor the retarget's — they were 5.3b's own metadatabase lock
contention, root-caused and fixed by patch 10 (§ 10; its own journal entry carries the mechanism).
Consumer re-verified 2026-08-16: full suite ×2, zero failures.

Still outstanding, and the reason the Phase-5 milestone stays provisional: the 1.0(17) **device-matrix
re-run on hardware**, including the S5 step the durable ledger exists for. The 2026-08-16 verification
was the test suite, not the matrix. Tracked consumer-side.

## 2026-08-17 — Phase 8: patches 11 + 12 (participant readiness for MonteSprout 51.1)

The consumer's collaboration-readiness audit found the two library halves of its participant
story, both fixed here, red-first. **Patch 11** — `deleteShare` re-fetched the share's root
record from `container.privateCloudDatabase` unconditionally; on a participant that record lives
in the shared database, so every participant-side share deletion ("Remove Me", owner unshare)
threw `.zoneNotFound` into a swallowed report and stranded the cached share. One line: route via
`container.database(for:)`. **Patch 12** — a zone `.deleted`/`.purged` event hard-deleted every
local row with no signal; `SyncEngineDelegate` gains `willDeleteRecordsInZone(scope:reason:)`,
called per zone *before* the purge while rows are still readable — the fork's **first additive
public-API patch** (default-implemented; preamble amended; MangoSync's `SharedZoneLifecycle` is
the consumer). Guards: `ParticipantShareDeletionTests` (red pre-patch on the exact `.zoneNotFound`
mechanism) and `ZonePurgeDelegateTests` (red on zero notices; `.encryptedDataReset` boundary
green by construction; an in-hook probe pins the "before purge" timing). Full suite 336/336,
zero failures, twice. Consumers adopt via MonteSprout 51.2b's lockstep bump — the shipped pin
`e18249a` predates Phase 8 deliberately.

## 2026-08-23 — Phase 9: patch 13 (the revocation notice that never fired)

MonteSprout's first two-account device session (its 55.2) proved patch 12 could not do the job it
was built for. A revoked participant is **not** told by a zone deletion — the zone belongs to the
owner and survives. Instrumented over three consecutive revocations, what arrives on her shared
engine is `✅ Modified zone` followed by two record deletions: the hierarchy's root and
`cloudkit.share`. So the hook never fired, the root row was hard-deleted (the consumer's FK cascade
taking the whole classroom with it), and nothing could be shown to the teacher — the silence patch
12 exists to end, one layer down.

**Patch 13** fires from the top of `handleFetchedRecordZoneChanges`, once per zone, ahead of every
delete below it. The first draft reused patch 12's zone hook, which is what the consumer's finding
had recommended; **review killed that**, and the reason is the patch's whole shape: one owner zone
holds every hierarchy that owner shares out of it, so revoking one room in a zone says nothing about
the other room in it — a zone-granular notice tells the consumer to sweep a room the participant
still has, deleting her own private rows about it. So patch 13 adds the fork's second additive
delegate method, `willDeleteSharedRootRecords:inZone:`, naming the roots that actually went; its
default implementation is a no-op rather than a forward to the zone hook, for the same reason.
A deletion counts only if it is a root this device holds a share for, or that root's cached share —
both halves, since CloudKit may split the pair across fetch batches — and only in `.shared` scope,
because the identical pair reaches the **owner's** private engine when she stops sharing.

Guard: `SharedRecordRevocationDelegateTests`, red pre-patch on the positive tests. Its negative tests
are green by construction, so each was proven non-vacuous by mutating the shipped patch — matching by
zone instead of by root reddens both the child-deletion and the two-rooms test; dropping the scope
guard reddens the owner's-unshare test (an earlier draft of which deleted an *unshared* record and
proved nothing). Full suite 341/341. ⚠ Patch 13 is **inert until MangoSync and its host implement
the new method** — a pin bump alone restores no notice; that adoption is MonteSprout's own next slice.

## 2026-08-23 — Phase 10.1: patch 14, a write the sync engine performed is not a user modification

The second cut blocker from MonteSprout's first two-account device session (F4): "Unsent edits"
jumped from 0 to 180 on the lead's iPhone the moment a room was shared, and 174 → 354 on the iPad
after a relaunch — both ≈ the device's entire row set, while a Console three-way count proved the
data intact. The finding guessed "the share/shared-zone paths don't stamp the mirror"; the traced
mechanism was more general and had nothing to do with sharing. The user tables' `after_update`
trigger is the **one** metadata trigger with no `isSynchronizing` guard — deliberately, since the
zone/parent columns it maintains must follow the server — and it also stamped
`userModificationTime = currentTime()`. So the sync engine's own apply write left the local stamp at
the wall clock while patch 7's mirror took the server record's, permanently behind it. Sharing is
merely what made it the *whole* device: it re-delivers every record in the zone.

The fix is two halves, and the second exists because of what the first opens. Guarding the trigger's
one column fixes the count — and then declares an **already-unsent** local edit settled the moment
any server record for its row arrives, because `upsertFromServerRecord` forces the record's stamp up
to the local one so the merged row can be re-uploaded, and the mirror was reading that forced-up
value. So the pre-force stamp is captured and passed down through a new defaulted
`carriedServerModificationTime:` on `setLastKnownServerRecord`; save-ack callers pass nothing and
keep reading the record itself. A repair migration nulls the mirrors the old path stranded — without
it patch 9's start rescan re-enqueues an upgraded device's whole downloaded dataset on **every**
launch, which is 5.3a's loop rebuilt out of two individually-correct patches.

Four new tests (three in `UnsentUpdateVisibilityTests`, one migration case), each guarded 5.3a-style
by neutralizing its own half in place; the 5.3a fixture's non-sentinel row moved to a *level* mirror,
since a behind-mirror there is now nulled further down the migrator. Full suite **346/346**.
⚠ Residual, split out as 10.2: only a fetch can level a mirror, so a fetched-then-locally-edited row
still reads unsent after its edit lands. Patch 14 shrinks patch 9's loop; it does not close it.

## 2026-08-23 — Phase 10.2: patch 15, the stamp the SENT record carried survives to its ack

Patch 14's residual, closed. A mirror sitting behind its row's local stamp can only be levelled by
something that knows the stamp on the server's copy, and real CloudKit's save ack carries no
encrypted fields at all — so a row that arrived by fetch, was edited locally and had that edit
accepted kept reading as an unsent edit forever, with patch 9 re-enqueueing it once per launch. The
missing knowledge was never missing: this device stamped the record it sent. A new nullable metadata
column, `sentUserModificationTime`, is written for every record in the batch the builder is about to
return (read off `batch.recordsToSave` — one write for the batch, and only records that made it), and
the outcome settles it: a successful ack moves it into the mirror with
`coalesce(max(mirror, sent), sent, mirror)`, a refused save discards it. The `max` is the load-bearing
part — a fetch landing in the same window can already have put a newer stamp there, and the mirror
must never move backwards. A further local edit inside the window bumps `userModificationTime` and
not the sent stamp, so such a row still reads unsent, which is the truth.

Two things worth carrying forward. The stamp is read off the **record**, not the metadata row:
`CKRecord.userModificationTime`'s setter takes a max, so the outgoing record can carry a higher stamp
than the metadata, and what is on the wire is what the server holds. And the harness cannot reproduce
the field's ordering — a mocked record has no `modificationDate`, so the mock's batch build levels a
confirmed row's mirror optimistically where real CloudKit's does not; the inversion test reaches the
behind-mirror state through a fetch that lands while the save is in flight, and says so in its
docstring. Three tests (the inversion of `aSlimAckCannotLevelTheMirrorOfAFetchedRow`, the
edit-in-the-window guard, the column's settled-means-empty invariant), each verified by neutralizing
its own half in place; levelling from the row's current stamp instead of the sent one reddens three
existing F2/F10 tests, which is the fork telling you that shortcut is the bug patches 7 and 9 exist
for. New migration registered last, no backfill. Snapshots re-recorded in 12 files (the column shows
in every `SyncMetadata` dump, always `nil` — the settled state). Full suite **348/348**.
⚠ Inert for consumers until a pin bump: MonteSprout still ships patch 14's residual until it adopts.

## 2026-09-02 — Phase 4.1: the rest of the manifest gets a ceiling

The half of patch 3 owed since the 1.6.6 base. Every dependency in both `Package.swift` and
`Package@swift-6.0.swift` is now `.upToNextMinor(from:)` at the version the base tag's own
`Package.resolved` pins — 11 ranges, GRDB (`from: "7.6.0"`, resolving 7.11.1) the widest gap and the
one sitting closest to the storage layer. Floors were read off `Package.resolved`, never invented, so
the resolved graph is byte-identical before and after: this narrows only what a *consumer's* resolver
may pick, which is why a manifest-only change lands safely without a behavior test. swift-tagged is
the lone exception to the read-it-off-resolved rule — trait-gated, so it appears in no resolution and
is bounded at its own declared floor's minor instead.

The eye-check in rebase step 5 became a guard. `ManifestBoundsTests` parses both manifests as **text**
— no behavior test can see a range, since the suite resolves via this repo's own `Package.resolved`
and stays green on any version, which is exactly how the 1.0(12) outage reached the field — and fails
on a bare `from:` or on a floor that has drifted from `Package.resolved`. Vacuity-checked by reverting
GRDB in each manifest in turn: each reddens its own manifest's test plus that manifest's floor-match
case, and nothing else.

Worth carrying forward: **the fork now caps the minor of every shared Point-Free dependency in a
consumer's graph.** A TCA-shaped scratch graph still resolves (TCA's own floors sit far below), but
the resolver can no longer climb past the bound — MonteSproutKit resolves swift-dependencies 1.16.0
today and would be held at 1.14.x, so its next pin bump will show that as a downgrade. Accepted
deliberately: too tight fails loudly at build or `/mango-update` time, too loose fails silently in the
field. The fix for a genuinely-needed newer minor is a retarget here, never a widened range app-side.
Full suite ×2, **351/351**, zero failures.
