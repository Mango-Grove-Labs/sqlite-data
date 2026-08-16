# MANGO-PATCHES — the Mango Grove Labs sqlite-data fork

This fork (`Mango-Grove-Labs/sqlite-data`) is the **org-wide vehicle for library-level fixes**
to [pointfreeco/sqlite-data](https://github.com/pointfreeco/sqlite-data). It is fully
API-compatible with upstream — no app imports a fork-only symbol; patches change behavior or the
dependency manifest, never the public API. Library bugs get fixed **here**, never re-implemented
or shadowed in an app or wrapper package.

**Consumer branch: `mango/patches-1.9`** — upstream tag `1.9.0` + the patches below.
(Previous: `mango/patches-1.6` = tag `1.6.6` + the same stack — kept intact; consumer pins on it
stay valid. Rebased 2026-07-25; only patch 3 conflicted, retargeted per the procedure's step 5.)

## The patches

### 1. Park + re-enqueue CASCADE child on `.referenceViolation` save (never local-delete)

*MonteSprout Phase 27.6c — the data-loss fix.*

A CASCADE parent-reference violation on a **save** means the child's parent hasn't landed in
the CloudKit zone *yet* — not that the child should be destroyed. Upstream's failed-save
handler (`SyncEngine.handleSentRecordZoneChanges`, `.referenceViolation` → `onDelete == .cascade`
branch) local-DELETEs the child, which surfaces as user rows that appear and then vanish (a
local-first data-loss bug; hit in the field by MonteSprout testers). The patch mirrors the
library's own failed-**delete** idiom instead: park the row in `UnsyncedRecordID` and re-enqueue
its `.saveRecord` so it lands once the parent syncs. `setNull`/`setDefault` FK actions keep
upstream behavior.

Deliberate consequence (owner call, 2026-07-11): on a parent that is *permanently* gone, the
child is **kept** as a local orphan rather than silently deleted — data over orphan-avoidance.

Known limitations (accepted; observability planned in the consumer's MangoSync work):

- **Unbounded re-send on a permanently-gone parent.** The park re-enqueues the child's save on
  every failure, so a child whose parent never lands re-sends and re-fails each sync round
  indefinitely (network/battery churn + a patch-2 report per round). No cap by design — a cap
  is a data-affecting policy the consumer must choose deliberately.
- **Crash-window park drop.** The re-enqueued `.saveRecord` lives in CKSyncEngine's in-memory
  state until its next serialization; if the process dies before that, the relaunch's fetch-side
  unsynced drain sees `.unknownItem` for the parked ID (the record never reached the server) and
  clears the park row without re-enqueueing. The child is then local-only with no retry until a
  force-re-upload or account-change re-enqueue. Surface via sync-health trends, don't rely on
  the park row as a durable retry ledger. *(Since patch 9, the engine-start rescan re-enqueues the
  never-confirmed child at the next launch — the window now costs a relaunch, not a manual reupload.)*

### 2. Report every silently-dropped failed SAVE with its CKError

*MonteSprout Phase 27.4d — observability for the invisible failure.*

Upstream abandons several failed-save buckets (`.serverRejectedRequest`, the terminal bucket:
`.badDatabase`/`.quotaExceeded`/…, and `@unknown default`) with no retry **and no signal** — a
record failing there simply never reaches CloudKit, invisibly. The patch adds a
`reportIssue(...)` naming the record type and CKError code on every such drop (diagnostic only —
control flow unchanged, no per-code special-casing). Hosts bridge IssueReporting to their
telemetry (MonteSprout: IssueReporting→Sentry) so the field failure gets a name.

Known noise: benign duplicate-record conflicts can be reported; triage before reacting.

### 3. Bound the `swift-structured-queries` range (the 1.0(12) sync outage)

*MonteSprout incident 2026-07-18 — total, silent loss of outbound sync in a shipped build.*

Upstream declares `swift-structured-queries` as `from: "0.31.0"` — **unbounded**. Tag 1.6.6 is
written and tested against **0.31.1** (its own `Package.resolved` pins exactly that), but a
consumer's SPM graph happily resolves whatever is newest. MonteSprout resolved **0.33.1**, at
which point `SyncMetadata`'s generated column decoding misaligns: the send path fails reading
every pending record's own metadata row with a bogus
`Expected column 14 ("userModificationTime") to not be NULL` (the column is `INTEGER NOT NULL`
in a STRICT table and always holds a value — `QueryCursor` reports `currentIndex - 1`, i.e.
wherever the decoder gave up, so the named column is an artefact of the misalignment).

The failure is catastrophic rather than noisy because `nextRecordZoneChangeBatch` cannot
distinguish "record is gone" from "I failed to read it" and runs
`state.remove(pendingRecordZoneChanges:)` either way — dropping the record from the upload queue
permanently. **MonteSprout TestFlight 1.0(12) uploaded nothing for six days across two testers'
devices** while the app's sync health reported "ok".

The patch: bound the range to the minor the base tag is tested against. On the 1.6.6 base that
was `.upToNextMinor(from: "0.31.1")`; on the 1.7.0 base, `.upToNextMinor(from: "0.33.2")`; on the
current 1.9.0 base it is **`.upToNextMinor(from: "0.35.0")`** (1.9.0's own `Package.resolved`
pin — upstream's floor moved to 0.35.0). Pre-1.0 minor bumps are breaking by
convention, so same-minor patches stay allowed and **the next minor becomes a deliberate, tested
fork upgrade** (rebase onto an upstream tag that supports it) rather than something a consumer's
resolver decides silently.

⚠️ **This is a class of bug, not a one-off.** Any unbounded `from:` in this manifest can do the
same thing to a consumer. Treat a widened range as a library change requiring the full suite.

**Owed: audit the remaining unbounded ranges.** Every other dependency here is still declared
`from:` with no ceiling, and this repo's own `Package.resolved` shows how far they drift —
**GRDB is declared `from: "7.6.0"` and resolves to 7.11.0**, the largest gap in the manifest and
the one sitting closest to the storage layer. Nothing has gone wrong there; the point is that
nothing would tell us if it did. (Tracked as item 8 of the MonteSprout incident, but the work
happens in this repo.)

### 4. A failed `CKAsset` download must be parked for retry, never written as `NULL`

*MonteSprout, observed 2026-07-19 (Sentry 7619718981); mechanism traced Phase 45.4; implemented
2026-08-10 on `mango/patches-1.9`.*

On the fetch path, upstream's `upsert` builder maps a record's unloadable `CKAsset` (`fileURL`
nil, or `dataManager.load` throwing on CloudKit's *temporary* asset file) to a literal `"NULL"` —
silently (only the schema-backfill builder `updateQuery` pairs its emit with a `reportIssue`).
Where the column is `NOT NULL` — as any "the bytes themselves" column will be — SQLite rejects
the row:

```
SQLite error 19: NOT NULL constraint failed: mediaBlobs.data
INSERT INTO "mediaBlobs" ("id","classroomID","data","createdAt") VALUES (?, ?, NULL, ?) ON CONFLICT…
```

The apply is per-record (each record's upsert runs inside its own `withErrorReporting` within the
shared batch write), so nothing else in the batch is poisoned — but upstream's park catch parks
only `SQLITE_CONSTRAINT_FOREIGNKEY`, so the NOT NULL failure rethrows into the reporter and the
record is gone: the change token advances, and a bytes-column record (written once, never edited)
is **never re-delivered**. A permanent local husk, one generic error report. On a *nullable*
column the same failure is worse: the emitted NULL **overwrites existing good bytes**, with zero
telemetry. Either way, a transient download failure becomes something the engine can't distinguish
from a decision — the same shape as patch 1.

The patch: `upsert` throws a dedicated `AssetDataNotLoadable` instead of emitting `NULL`, and the
apply path parks the record in `UnsyncedRecordID` (patch-1 idiom) with a `reportIssue` naming the
record type and column (patch-2 idiom). Parked ids are re-fetched in batches via
`database.records(for:)`, which downloads assets — so a transient failure gets genuine retry
semantics, and a permanently-missing server asset parks visibly (a report per round) instead of
vanishing. A consumer's NOT NULL bytes column stays load-bearing as defense in depth, but
nullability no longer decides between husk and destruction: on a failed load, no SQL is emitted at
all.

Scope note: `updateQuery` (the schema-migration backfill path) keeps upstream behavior — it
re-downloads each asset-bearing record from the server just before building its query, so its
failure window is far narrower, and no park machinery is in reach there. Extend it patch-4-style
if the backfill path ever shows the same husk.

Trigger context: observed on a device that had just crossed CloudKit Development→Production, so
the field trigger may be stale cross-environment asset references rather than a plain download
failure. The consumer carries the fleet-truth instrument either way (MonteSprout 45.4): the data
doctor's `mediaMissingBlobBytes` counts live items older than 24 h with no blob row, so a real
husk anywhere in the fleet surfaces in its `sync.heal` breadcrumb/summary.

Guard: `FailedAssetDownloadParkTests` injects a stale record straight into
`handleFetchedRecordZoneChanges` (the mock's fetch path re-materializes asset data on delivery,
so an end-to-end test can never present an unloadable asset — exactly the well-behaved path that
masked the bug), asserts park-not-husk on first delivery, old-bytes-survive on update, and
land-and-clear on the loadable re-delivery.

Full context: MonteSprout `docs/incidents/2026-07-18-metadata-decode-blocks-all-uploads.md`
§ Addendum + its `docs/DECISIONS.md` § "2026-08-10 — Phase 45.4".

### 5. A failed local clear in `deleteLocalData()` must throw, never report-and-continue

*MonteSprout incident 2026-07-20 (`resetfresh-left-local-data-cross-env`) — the false-success reset.*

Upstream's `deleteLocalData()` wraps its row-clearing write in `withErrorReporting` (and each
per-table `DELETE` in its own inner `withErrorReporting`), so every failure is swallowed into a
reported issue and the method returns as if it succeeded. The write's final statement is
`setUpSyncEngine(writableDB:)` — a throw there **rolls back the entire transaction**, undoing every
delete, while the metadatabase erase in `tearDownSyncEngine()` (a prior, non-transactional step)
stands. One swallowed failure therefore produces: clean return, sync metadata gone, **every user
row still present** — and a caller that treats "didn't throw" as "cleared" (MonteSprout's
`resetFresh`) renders a false-success report over it. Hit in the field 2026-07-20 (intermittent —
the 2026-07-25 forensic re-run on the same device cleared correctly); mechanism proven in-process
by `DeleteLocalDataFailureTests`.

The patch: both `withErrorReporting` wrappers removed — the write's failure **throws** out of
`deleteLocalData()`. On failure the engine deliberately stays stopped: the rollback removed the
sync triggers, so a running engine would silently track nothing. The library's own account-change
call site already wraps this call in `withErrorReporting`, so the automatic sign-out path keeps
upstream's report-only behavior. Consumers that need rows *verified* gone still verify (MangoSync
`SyncReset` step 4 counts rows after this call) — the patch makes failure visible; it cannot make
the clear atomic with the metadata erase.

⚠️ **Consumer note.** `SyncEngineDelegate`'s documented example (`SyncEngineDelegate.swift:55-62`)
calls this from an alert button as `Task { try await syncEngine.deleteLocalData() }` — which
discards precisely the throw this patch exists to surface. That file is untouched upstream text and
stays that way (divergence costs a rebase conflict for no behavior gain), so the correction lives
here: a consumer writing its own delegate must **handle the error**, not fire-and-forget it.

Dropping the *inner* wrapper has a second consequence worth stating: upstream could **commit a
partial clear** (table A's `DELETE` fails and is swallowed, B and C are emptied,
`setUpSyncEngine(writableDB:)` succeeds → the transaction commits with A alone intact). The patch
makes that impossible — any table's failure aborts the write and rolls back every delete. Failure
now always leaves the database *whole*, which is the better position to retry or report from.

Known limitation (an upstream defect the patch doesn't cause but newly makes reachable):

- **A failed clear cannot be retried in-process.** `tearDownSyncEngine()` drops its triggers with a
  bare `drop()` (no `IF EXISTS`, `SyncEngine.swift:994`), and nothing re-creates them until a fresh
  `SyncEngine.init` — `start()` doesn't, and the only other `setUpSyncEngine` call is the one inside
  the write that just rolled back. A second `deleteLocalData()` therefore throws
  `no such trigger: sqlitedata_icloud_after_primary_key_change_on_…` out of *teardown*, before it
  ever reaches the clearing write, masking the original cause. Recovery is an app relaunch, not a
  retry. Under upstream this was unreachable in practice because the first failure was silent and
  nobody retried; patch 5 is what puts a caller in a position to try again. Verified by
  reproduction 2026-07-25 (sabotage → throw → un-sabotage → second call throws `no such trigger`,
  rows still present). A one-line `drop(ifExists: true)` would fix it — deliberately left as future
  work rather than widening this patch.

- **`DeleteLocalDataFailureTests`** — pins the patched contract: `failedClearThrows` (sabotaged
  table → the call throws; rows survive the rollback; metadatabase already erased; engine left
  stopped) + `directCallClearsAndRestarts` (the happy path called directly — prior coverage only
  reached this method through the sign-out handler). Reverting the patch sends `failedClearThrows`
  red (verified 2026-07-25, on the `thrownError != nil` assertion).

### 6. An account-availability transition must park the change for retry, never drop it

*MonteSprout Phase 41.1 — the upload that never resumes.*

Upstream's failed-**save** handler puts `.notAuthenticated` and `.accountTemporarilyUnavailable` in the
terminal "give up silently" bucket (patch 2's bucket), and the failed-**delete** switch abandons them
the same way. So a change that is in flight when iCloud signs out, signs in, or has its per-app toggle
flipped is removed from the queue permanently: the send never happens, and nothing resumes it until an
app relaunch re-enqueues from the metadata ledger. Observed on hardware during MonteSprout's 1.0(15)
device matrix (2026-07-25, Sentry 7633019003): a per-app-toggle window dropped a send, the app's
"Not syncing to iCloud right now" health line lingered past restoration, and the record only landed
after a relaunch.

The patch re-enqueues instead of dropping, on both paths — the patch-1 idiom applied to a different
"a failure the engine can't distinguish from a decision" case:

- **save** → `newPendingRecordZoneChanges.append(.saveRecord(…))`, plus a report worded **"parked a
  failed record save for retry across an account transition"** — deliberately distinct from patch 2's
  "dropped … with no retry" so a host's telemetry can tell an abandoned record from a retried one.
  Metadata is left alone (no `clearServerRecord()`): the server's copy is unknown, not stale.
- **delete** → `state.add(pendingRecordZoneChanges: [.deleteRecord(…)])`. Silent, because upstream
  reports nothing on this path (patch 2 covers saves only) and the branch runs inside the enclosing
  write. Without it, a delete abandoned in a transition leaves the record alive in the zone and the
  next fetch resurrects the row the user deleted.

**Scoped to the two transition codes only.** A genuinely restricted or revoked account
(`.managedAccountRestricted`, `.permissionFailure`, …) keeps upstream's give-up behavior — retrying
those forever is churn that can never succeed. This is also why the retry is *cheap* where patch 1's
is not: CKSyncEngine pauses automatic sync while the account is unavailable, so the parked change
generally waits rather than re-failing every round.

**Not a cross-account leak** (examined 2026-07-25). A parked change cannot follow the user to a
different iCloud account: the pending set is persisted as CKSyncEngine's `stateSerialization` *in the
metadatabase*, and the account-change path's `tearDownSyncEngine()` calls `metadatabase.erase()` — so
the delete-local-data route discards it, while the keep-local-data route re-uploads every local row to
the new account by design anyway.

Known limitations (accepted):

- **A report per retry round.** While a transition lasts, each round that re-fails re-reports. That is
  the deliberate trade against patch 2's invisibility; triage on the wording, not the count.
- **In-memory until serialized.** Same crash-window caveat as patch 1 — the re-enqueued change lives
  in CKSyncEngine's state, so a process death before its next serialization loses the retry and the
  row waits for a relaunch. *(The 1.0(16) matrix proved the relaunch did NOT heal on the 1.9 base —
  that gap is what patch 9 closes: the engine-start rescan re-enqueues the stranded save; a stranded
  transition-window DELETE remains out of its scope, § 9.)*
- **Neither half fixes the host's health signal.** The lingering "not syncing" line is a consumer
  concern (MonteSprout 41.1b), not something the library can clear.

- **`AuthTransitionRetryTests`** — pins the patched contract by injecting failures directly into
  `handleSentRecordZoneChanges` (the `DroppedSaveReportingTests` idiom): both transition codes
  re-enqueue their save, `.notAuthenticated` re-enqueues its delete, and the scope boundary holds in
  both directions (`.quotaExceeded` and `.managedAccountRestricted` still drop, save and delete).
  Reverting the patch sends the three retry tests red and leaves the three boundary tests green
  (verified 2026-07-25).

### 7. Mirror the server record's `userModificationTime` into a column

*MonteSprout Phase 41.2b — make an unsent **edit** countable.*

The characterization below proves the blind spot: every consumer count for "waiting to upload" is derived
from `lastKnownServerRecord`, so an **update to an already-synced row** reads as confirmed while its save is
unsent. The comparison that sees it — the metadata's `userModificationTime` versus the server record's own —
had no SQL form, because that value lives in the record's `encryptedValues` and only the all-fields archive
carries it. Reading it meant unarchiving a `CKRecord` per row.

The patch adds **`serverUserModificationTime` (INTEGER, nullable)** to the metadata table and keeps it beside
the archive. `nil` = never reached the server; equal to `userModificationTime` right after a round trip;
**less than** it exactly while a local edit is unsent. So the probe is an ordinary predicate:

```sql
SELECT count(*) FROM "sqlitedata_icloud_metadata"
 WHERE "lastKnownServerRecord" IS NOT NULL
   AND "serverUserModificationTime" < "userModificationTime"
   AND "_isDeleted" = 0
```

Two properties make the mirror trustworthy rather than another thing to drift:

- **One funnel.** Every write of `lastKnownServerRecord` goes through `setLastKnownServerRecord` (plus the
  single insert in `upsertFromServerRecord`), so both are set in the same statement — including the
  **clearing** case, where a nil record nils the mirror rather than leaving a stamp that would read as "in
  sync" with a server copy that no longer exists.
- **A new migration, never an edit to the released one** — the DEBUG `hasSchemaChanges` assertion exists to
  enforce exactly that. `"Mango: mirror the server userModificationTime"` adds the column and backfills
  `= userModificationTime` for rows that already have a server record. That backfill **assumes those rows are
  in sync at migration time**: we cannot know better without unarchiving every blob, it is right for every
  row that isn't mid-edit, and a wrong guess self-corrects on that row's next round trip.

⚠️ **Rebase note.** This is the first Mango patch that touches the **metadatabase schema**. Keep the
migration registered *after* upstream's, keep its name byte-stable (a rename re-runs it and the `ALTER`
fails), and re-record inline snapshots after a rebase — the column appears in every `SyncMetadata` dump.

- **`UnsentUpdateVisibilityTests`** — pins the mirror end to end (nil before first upload · equal after a
  round trip · behind while an edit is unsent, with the SQL predicate counting exactly 1 · level again once
  it lands) and that clearing the server record clears the mirror, driven through the real
  `.serverRejectedRequest` path. **Read via SQL, never via the archived record** — a mirror test that reads
  the thing being mirrored passes with the patch reverted (caught by the vacuity guard, 2026-07-25).

**F2 amendment (fixed 2026-08-15; found in the field as MonteSprout's 1.0(16) matrix F2):** on real
CloudKit the mirror **false-positived on every uploading device** — each ledger read exactly its own
uploaded-row count as "unsent", forever (four data points, 234/9/1/176; downloaded rows always clean;
`docs/incidents/2026-08-15-device-matrix-1.0.16.md` in the consumer repo). Verified before patching, per
the plan's contract: the suspect reproduced exactly — a save ack **without the encrypted custom fields**
(what real CloudKit delivers; the mocked container echoes full records, which is why the suite stayed
green) flows `handleSentRecordZoneChanges` → `refreshLastKnownServerRecord` → `setLastKnownServerRecord`,
and `CKRecord.userModificationTime`'s `?? -1` getter fallback landed in the mirror. The fix, in the
funnel: **only mirror a stamp the record actually carries** — a stampless record leaves the mirror and
the local-stamp max-bump untouched (unknown stays NULL, never an invented time; a slim re-ack can no
longer stomp a previously-correct stamp), while a nil record still nils the mirror. Same discipline the
fetch path always had (`upsertFromServerRecord`'s top guard). Field consequence: the mirror reads NULL
rather than false-positiving where CloudKit acks stay slim — honest, and exactly what § 9's targeted
rescan predicate needs to not degrade into a blanket reupload. Guarded by the two `aStamplessAck…` /
`aStamplessReAck…` tests in `UnsentUpdateVisibilityTests` (verified red on the unpatched funnel,
2026-08-15, on the `-1` mechanism itself).

### 8. Planned — don't let a read failure masquerade as a deletion

*Not yet implemented. Recorded here so the amplifier isn't forgotten once patch 3 hides it.*

`nextRecordZoneChangeBatch` (SyncEngine.swift:1132-1148) treats a failed metadata read exactly
like a missing record: both fall through to
`state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])`. That conflation is what turned
the 0.33.1 decode bug into six days of *silent, unrecoverable* data loss rather than a visible
error — the record left the queue permanently and no retry ever touched it again.

Patch 3 removes the trigger that was actually hit. It does nothing about the amplifier: any future
read failure — a schema change, a corrupt row, a lock timeout — reproduces the same outage shape.
The fix should follow patch 1's idiom: a read failure **parks or retries**, and only a genuinely
absent record is dropped. Worth doing regardless of root cause (MonteSprout incident, "the guard is
arguably wrong").

(Numbering note: this item briefly shared the number 4 with the asset-park patch while both were
unwritten; the asset patch kept 4 on implementation, this one moved to 8.)

### 9. A stranded row is rescanned at engine start (never a blanket reupload)

*MonteSprout F10 (the 1.0(16) matrix's hard failure); implemented 2026-08-15 on `mango/patches-1.9`.
Evidence + timeline: the consumer's `docs/incidents/2026-08-15-device-matrix-1.0.16.md`.*

The stranding mechanism: while the engine runs, a local write's pending save lives **only in
CKSyncEngine's in-memory state** (the durable `PendingRecordZoneChange` rows are written only while the
engine is *stopped*, and drained at the next start). A process death inside that window loses the change
— and on the 1.9 base nothing at `start()` rescanned the ledger, so the row stayed stranded silently and
permanently: `pending=0` honest-but-blind, recovery only by a manual `forceFullReupload`. Patch 6's
in-memory park shares the window (its "degrades to today's behavior, never worse" note undersold this:
after the force-quit, account restoration demonstrably ran and did not help, and relaunch no longer
healed as it had on the 1.0(15)/1.6.6 base).

The patch: `start()` runs `enqueueStrandedRecordsForCloudKit()` (right after the durable pending-table
drain) — the same no-op-update idiom as the account-change path's `enqueueUnknownRecordsForCloudKit`,
with the **targeted** predicate: live rows (`NOT _isDeleted`) that are **never confirmed**
(`lastKnownServerRecord IS NULL`) or **mirror-behind** (`serverUserModificationTime <
userModificationTime`, patch 7's column — which is why this depends on the § 7 F2 amendment: a flooded
mirror would turn "targeted" into the blanket reupload the consumer explicitly ruled out, and a **NULL
mirror is "unknown", never a trigger** — SQL's `NULL < x` semantics are load-bearing in the predicate).

Deliberate scope bounds (accepted):

- **A stranded DELETE is not rescanned.** A locally-deleted row whose delete died with the process is
  excluded (`NOT _isDeleted` — re-enqueueing it through the no-op-update idiom would emit a *save* and
  resurrect the row). The next fetch round's record delivery or a relaunch-era delete re-issue does not
  exist for this shape either; extend patch-9-style with a delete-aware re-enqueue if the fleet ever
  shows it.
- **The durable park (persisting the park at park time) remains optional hardening, not built** — the
  rescan is the half that heals rows *already stranded in the field*, which a durable park cannot.
  _Promoted to REQUIRED by consumer review (2026-08-15, Phase 5.3): the two bounds above sit exactly on
  the consumer's S5 matrix step. Same review also found the **legacy `-1` sentinel loop** — pre-amendment
  rows hold mirror `-1`, which this patch's predicate selects at every start while a slim ack never
  repairs it: an upgraded device blanket-reuploads its whole dataset per launch. 5.3a ships the nulling
  migration; 5.3b makes the durable `PendingRecordZoneChange` ledger **always-on** (a park-time-only
  persistence could never catch a mid-flight force-quit — the change is in no park handler's hands),
  with patch-6 parks writing through it; this note rewrites when they land._
- **Mirror-behind is inert where acks stay slim.** On real CloudKit a confirmed row's mirror stays NULL
  (F2 amendment), so the mirror-behind half fires only where acks carry stamps; the never-confirmed half
  is the field workhorse.

- **`EngineStartRescanTests`** — pins the patched contract kill-restart-shaped (`stop()` discards the
  engines and their in-memory pending state, the same loss a force-quit produces, while the durable
  table stays empty because the engine was running): a killed never-confirmed save is re-enqueued at
  start and lands; a killed unsent edit is re-enqueued via the mirror and catches up; and the boundary —
  an in-sync row and a slim-ack NULL-mirror confirmed row are NOT re-enqueued (targeted, never blanket).
  Reverting the patch sends the two rescan tests red (verified 2026-08-15) and leaves the boundary test
  green.

### Characterization — what a "waiting to upload" count derived from `lastKnownServerRecord` cannot see

*MonteSprout Phase 41.2a — no library change; a pinned fact consumers build on.*

Every consumer number for "how much is waiting to upload" is derived from the metadata's server record —
MonteSprout's sync doctor counts `lastKnownServerRecord IS NULL AND _isDeleted = 0`, MangoSync's
`UploadTruth.unconfirmed` derives from `hasLastKnownServerRecord`. Both therefore measure **"has this row ever
reached the server"**, not "are this row's current bytes on the server", and the gap between those two is a
real state: an **update to an already-synced row**. The local write trigger bumps `userModificationTime` and
leaves `lastKnownServerRecord` holding the *previous* server version (`Triggers.swift:234`), so an update whose
save never lands leaves every such count reading **0** while the edit is genuinely unsent.

The discriminator that *does* see it — for whoever implements that probe — is the metadata's
`userModificationTime` versus the server record's own. A successful save stamps the server record from the
metadata (`SyncEngine.swift:2052`) and the ack takes the max (`SyncEngine.swift:2554`, in
`extension Updates<SyncMetadata>`), so the two are equal
after a round trip and diverge exactly while an edit is unsent. It must be read from
**`_lastKnownServerRecordAllFields`**: `userModificationTime` lives in `encryptedValues`, which
`lastKnownServerRecord`'s system-fields archive does not carry.

- **`UnsentUpdateVisibilityTests`** — one test, asserting both halves: after a round trip the times agree and
  the count is 0; after a local edit with no sync round the count is **still** 0, the local time has moved past
  the server's, and the engine's own pending set does hold the save.

### Test commits — patch 3 (no library behavior change)

- **`PendingRecordMetadataDecodeTests`** — the tripwire for patch 3. Exercises the send path's
  metadata read for a record awaiting its first upload (root and child, at a realistic wall-clock
  `userModificationTime`) plus an end-to-end "it actually reaches the server" assertion. **Passes
  at 0.31.x; verified 2026-07-18 that all four fail at 0.33.1 with the exact production error and
  query.** Note this suite cannot catch the defect on its own — it runs against the pinned
  resolution, which is precisely why the outage reached the field: the tests and the consuming app
  were in different dependency worlds. To re-check, point `Package.resolved` at 0.33.1 and re-run.

### Test commits — patches 1–2 (no library behavior change)

- **`ReferenceViolationGuardTests`** — pins patch 1 by injecting the failed save directly into
  `handleSentRecordZoneChanges` with the parent still present locally, so SQLite's own
  `ON DELETE CASCADE` can't mask the handler (the end-to-end `ReferenceViolationTests` all
  delete the parent, which is exactly why upstream's suite stayed green through the behavior
  change). Also repairs two tests the patches make stale: `moveReminderToList` (now asserts
  kept-data: the reminder survives, its move to the deleted list reverts) and
  `createTagRemotely…` (expected `.serverRejectedRequest` report wrapped in `withKnownIssue`).
- **PreviewTests repair** — upstream's timer-driven preview tests race a single fixed
  `testClock.advance` against the auto-sync round and fail most filtered serial runs on vanilla
  1.6.6; repaired with a bounded settle loop + `withKnownIssue(isIntermittent:)` for a residual
  mock-atomicity gap (see that commit's message for the full mechanism).

## Why upstream won't take patches 1–2

Reported as [pointfreeco/sqlite-data#485](https://github.com/pointfreeco/sqlite-data/issues/485);
closed with upstream disputing the framing (re-verified 2026-07-10: upstream `main` post-1.6.6
still carries the CASCADE local-delete). The patches are ours to carry indefinitely.

**Patch 6 is the same class** — "a transient failure is not a verdict on the record" — and rests on
field evidence upstream has not seen, so assume we carry it too. Not reported so far; worth filing if
the auth-transition drop is ever reproduced in a form upstream can run.

## Upstream stance on patch 3

Unlike patches 1–2, patch 3 is **not** a disputed behavior change — bounding a range that upstream
left unbounded is a fix upstream would plausibly accept, and if they take it this patch disappears.
Not reported so far. Two things to do at each rebase: check whether the new upstream tag already
bounds `swift-structured-queries` (if so, drop patch 3 rather than re-applying it), and if it still
doesn't, consider filing it. As of 2026-07-18 there is **no upstream tag above 1.6.6**, so there is
nothing newer to move to.

## Consumer rule

- **Pin by revision** (`.package(url: "git@github.com:Mango-Grove-Labs/sqlite-data.git",
  revision: "<sha>")`) — never by branch or version range.
- **All Mango apps pin the *same* revision AND the same URL string** (the SSH form above). SPM
  unifies dependencies by package identity — if two `Package.swift`s in one graph (e.g. an app +
  MangoSync) pin mismatched revisions *or* different URL forms (https vs SSH), resolution
  fails. Bump in lockstep, always.

## Rebase procedure (new upstream release `1.X.Y`)

1. `git remote add upstream https://github.com/pointfreeco/sqlite-data.git` (if absent);
   `git fetch upstream --tags`.
2. Cut `mango/patches-1.X` from tag `1.X.Y`.
3. Cherry-pick, in order: patch 1 (park guard), patch 2 (dropped-save reporting), patch 3
   (the `swift-structured-queries` bound in `Package.swift`), **patch 4 (the asset park —
   `upsert` throws `AssetDataNotLoadable`, the apply path parks instead of emitting `NULL`)**,
   **patch 5 (the throwing
   `deleteLocalData()` clear)**, **patch 6 (auth-transition park-and-retry)**, **patch 7 (the mirrored
   server `userModificationTime` — schema, so keep its migration registered after upstream's) plus its
   F2 amendment commit (the stampless-ack mirror guard in `setLastKnownServerRecord`)**, **patch 9
   (the engine-start targeted rescan — `enqueueStrandedRecordsForCloudKit` + its `start()` call
   site)**, the test
   commits (take them from the tip of the previous `mango/patches-*` branch). Resolve conflicts by **idiom, not line
   number** — the `SyncEngine` error-handling region drifts. Patch 3 conflicts every time, because the
   rebase re-inherits upstream's `from:` declaration — take **ours**, retuned to the new base tag's
   own tested minor (step 5). Patches 1, 4, 5 and 6 all live in
   `SyncEngine`'s error-handling region and are the likeliest to need re-application by idiom; patch 6
   in particular *removes* two codes from each of two upstream case lists, so a conflict resolved by
   taking upstream's list silently reverts it (no compile error — the codes just stop retrying).
4. **Vacuity guard (required), once per behavior patch.** Each patch commit also carries its guard
   tests and this doc's text, so a bare `git revert --no-commit` deletes the test file (a 0-test
   run, not a red one) and conflicts on `MANGO-PATCHES.md` — after the revert, restore everything
   but the library source (`git checkout HEAD -- MANGO-PATCHES.md Tests/`) before running the
   filter (verified the guards this way on the 1.9 rebase, 2026-08-10):
   - `git revert --no-commit <patch-1 sha>` → `swift test --filter ReferenceViolationGuardTests`
     must go **red** on `cascadeChild_isParkedAndReEnqueued_notDeleted` (all three assertions);
     `git reset --hard` → green.
   - `git revert --no-commit <patch-4 sha>` → `swift test --filter FailedAssetDownloadParkTests`
     must go **red** on both tests (the park assertions fail; the husk's NOT NULL constraint error
     surfaces as the recorded issue); `git reset --hard` → green.
   - `git revert --no-commit <patch-5 sha>` → `swift test --filter DeleteLocalDataFailureTests`
     must go **red** on `failedClearThrows` (the `thrownError != nil` assertion); `git reset --hard`
     → green.
   - `git revert --no-commit <patch-6 sha>` → `swift test --filter AuthTransitionRetryTests` must go
     **red** on all three retry tests (`notAuthenticatedSave_…`,
     `accountTemporarilyUnavailableSave_…`, `notAuthenticatedDelete_…`) while the three boundary tests
     stay green; `git reset --hard` → green.
   - `git revert --no-commit <patch-7 sha>` → `swift test --filter UnsentUpdateVisibilityTests` must go
     **red** on `theMirroredServerStampMakesAnUnsentEditCountable` *and*
     `clearingTheServerRecordClearsTheMirror`, while the characterization test
     (`anUnsentUpdateIsInvisibleToEveryNeverConfirmedCount`) stays green — it describes upstream behavior,
     which the patch does not change. `git reset --hard` → green.
   - `git revert --no-commit <patch-7 F2-amendment sha>` → `swift test --filter
     UnsentUpdateVisibilityTests` must go **red** on `aStamplessSaveAckNeverInventsAMirrorStamp` *and*
     `aStamplessReAckPreservesTheEarlierMirrorStamp` (both on the `-1` mechanism), while the other three
     stay green; `git reset --hard` → green.
   - `git revert --no-commit <patch-9 sha>` → `swift test --filter EngineStartRescanTests` must go
     **red** on `aKilledNeverConfirmedSaveIsReEnqueuedAtStart` *and* `aKilledUnsentEditIsReEnqueuedAtStart`
     (the row stays stranded across the restart), while `confirmedRowsAreNotRescannedAtStart` stays
     green; `git reset --hard` → green.

   A rebase that skips these can silently drop a guard.
5. **Manifest check (required):** confirm `Package.swift` still carries an `.upToNextMinor`
   bound for `swift-structured-queries` matching the base tag's own `Package.resolved` pin
   (currently `.upToNextMinor(from: "0.35.0")` on `mango/patches-1.9`) — the new upstream tag's
   tested minor, not the previous branch's literal. **No test can catch a
   dropped patch 3**: the suite resolves via this repo's own `Package.resolved` and stays green on
   any version, which is exactly how the original outage reached the field. Check it by eye.
6. Full `swift test` green (known-intermittent issues aside), twice.
7. Push the branch; update consumers' `Package.swift` `revision:` pins in lockstep.
