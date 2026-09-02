# MANGO-PATCHES — the Mango Grove Labs sqlite-data fork

This fork (`Mango-Grove-Labs/sqlite-data`) is the **org-wide vehicle for library-level fixes**
to [pointfreeco/sqlite-data](https://github.com/pointfreeco/sqlite-data). It is fully
API-compatible with upstream — patches change behavior or the dependency manifest and never
alter an upstream-declared symbol. **One sanctioned exception class: additive,
default-implemented API** (so far the two `SyncEngineDelegate` hooks of patches 12 and 13; patch 14's
defaulted `carriedServerModificationTime:` parameter is internal, not consumer-visible) — code
written against upstream compiles unchanged, and the new surface is consumed by **MangoSync**, the
org's wrapper package, never imported directly by an app. Library bugs get fixed **here**, never
re-implemented or shadowed in an app or wrapper package.

**Consumer branch: `mango/patches-1.12`** — upstream tag `1.12.0` + the patches below.
(Previous: `mango/patches-1.10` = tag `1.10.0`, `mango/patches-1.9` = tag `1.9.0`,
`mango/patches-1.6` = tag `1.6.6` — same stack, kept intact; consumer pins on them stay valid.
Rebased onto 1.12.0 on 2026-09-02; only the manifests conflicted (retuned per step 5 — the 1.12
base swaps `xctest-dynamic-overlay` for `swift-issue-reporting` 2.x in its tools-6.4 manifest and
adds the `Package@swift-6.1.swift` fallback, so consumers must move their own Point-Free
generation in the same update). Upstream 1.10.0→1.12.0 touches the `@Fetch*` observation layer,
statement caching, UUID/string decoding, collations, and tests — of `Sources/SQLiteData/CloudKit/`
only `CloudKitSharing.swift` (share saves route via `database(for:)`, upstream #409) and the
`DefaultSyncEngine` test scaffold, **neither of which any patch touches** — so all six patched
library files came through the retarget byte-identical to `mango/patches-1.10`.)

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
  the park row as a durable retry ledger. *(Since patch 9 the engine-start rescan re-enqueues the
  never-confirmed child at the next launch, and since 5.3b the park's re-enqueued save also writes
  through the always-on durable ledger — the window now costs a relaunch at most.)*

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
1.9.0 base, `.upToNextMinor(from: "0.35.0")`; on the 1.10.0 base, `.upToNextMinor(from: "0.36.0")`;
on the current 1.12.0 base it is **`.upToNextMinor(from: "0.39.1")`** (1.12.0's own
`Package.resolved` pin — upstream's floor itself moved to 0.39.1). Pre-1.0 minor bumps are breaking by
convention, so same-minor patches stay allowed and **the next minor becomes a deliberate, tested
fork upgrade** (rebase onto an upstream tag that supports it) rather than something a consumer's
resolver decides silently.

⚠️ **This is a class of bug, not a one-off.** Any unbounded `from:` in this manifest can do the
same thing to a consumer. Treat a widened range as a library change requiring the full suite.

**The audit is done (2026-09-02) — every dependency in every manifest is now bounded** (the
1.12.0 base versions the manifest three ways; all three carry the bounds — see the note at the end
of this section). It had been
owed since the 1.6.6 patch: every *other* dependency was still declared `from:` with no ceiling, and
this repo's own `Package.resolved` showed how far they drift — **GRDB was declared `from: "7.6.0"`
and resolved to 7.11.1**, the largest gap in the manifest and the one sitting closest to the storage
layer. Nothing had gone wrong there; the point is that nothing would have told us if it did.
(Tracked as item 8 of the MonteSprout incident; the work happened in this repo.)

Each range is now `.upToNextMinor(from: <the version the base tag's own Package.resolved pins>)`.
The bounds on the current 1.12.0 base (upstream's bare `from:` floor in parentheses):

| dependency | upstream declares | this fork bounds |
| --- | --- | --- |
| GRDB.swift | `from: "7.6.0"` | `.upToNextMinor(from: "7.11.1")` |
| swift-collections | `from: "1.0.0"` | `.upToNextMinor(from: "1.6.0")` |
| swift-concurrency-extras | `from: "1.4.0"` (6.0 manifest: `1.0.0`) | `.upToNextMinor(from: "1.4.1")` |
| swift-custom-dump | `from: "1.3.3"` | `.upToNextMinor(from: "1.7.3")` |
| swift-dependencies | `from: "1.9.0"` | `.upToNextMinor(from: "1.17.1")` |
| swift-issue-reporting (6.4 manifest only) | `from: "2.1.0"` | `.upToNextMinor(from: "2.1.0")` |
| swift-perception | `from: "2.0.0"` | `.upToNextMinor(from: "2.0.12")` |
| swift-sharing | `from: "2.3.0"` | `.upToNextMinor(from: "2.10.1")` |
| swift-snapshot-testing | `from: "1.18.4"` | `.upToNextMinor(from: "1.19.4")` |
| xctest-dynamic-overlay (6.1/6.0 manifests only) | `from: "1.13.0"` | `.upToNextMinor(from: "1.13.0")` |
| swift-docc-plugin | `from: "1.0.0"` | `.upToNextMinor(from: "1.5.0")` |
| swift-tagged | `from: "0.10.0"` | `.upToNextMinor(from: "0.10.0")` |

At the original 2026-09-02 audit (on the 1.10.0 base) the resolved graph was **byte-identical**
before and after: every bound was set to the version already resolved, a pure narrowing of what a
consumer's resolver *may* pick. On a retarget the bounds move WITH the base (rebase procedure
step 5) — that is the "deliberate, tested fork upgrade" the bounds exist to force, and the 1.12.0
retarget was the first one to exercise it. swift-tagged is the one exception to the "read it off
`Package.resolved`" rule — it is trait-gated (`Tagged`, off by default) and so appears in no
resolution of this package; it is bounded at its own declared floor's minor, which pre-1.0 is the
same conservative shape. xctest-dynamic-overlay gets the same treatment for the same reason on a
6.4 toolchain (only the 6.1/6.0 fallback manifests declare it, so a 6.4 resolution never pins it);
on this fork's own 6.1–6.3 toolchain it IS resolved, at 1.13.1, matching the bound's minor.

⚠️ **Consequence, deliberately accepted: this fork now caps the minor of every shared Point-Free
dependency in a consumer's graph.** Verified against a TCA-shaped graph (TCA `from: "1.0.0"` +
swift-dependencies + this fork by path): it still **resolves** — TCA declares its own floors far
below these bounds, so no consumer hits a hard resolution failure — but the resolver can no longer
climb past the bound. (The 1.10-era note that swift-dependencies would be held at 1.14.x, showing
as a downgrade from MonteSproutKit's resolved 1.16.0, is obsolete on the 1.12.0 base: the bound is
now 1.17.x, *ahead* of that resolution — the pin will move up, not down.) That is the
intended trade: the failure mode of a bound that is too tight is a **loud** resolution error or a
visible pin move at `/mango-update` time; the failure mode of no bound is silent data loss in the
field. If a consumer ever *needs* a newer minor, the fix is a retarget here (retune, suite twice,
bump pins) — never a widened range in the app.

**Every fallback manifest carries the bounds too.** `Package@swift-6.0.swift` gained them
2026-08-15 (it had declared `swift-structured-queries` as a bare `from:` for the whole 1.9 line —
inert on the toolchains anything here builds with, but the identical hole, and nothing was watching
it). The 1.12.0 base added `Package@swift-6.1.swift`, and that one is **not** inert: the live
`Package.swift` now needs tools 6.4, so on the 6.1–6.3 toolchains this fork currently builds with,
the 6.1 fallback is the manifest that actually resolves — it carries the full bound set, including
`xctest-dynamic-overlay` (the pre-2.0 issue-reporting package the 6.1/6.0 manifests still use where
the 6.4 manifest declares `swift-issue-reporting` 2.x). Step 5 of the rebase procedure checks all
three manifests, and `ManifestBoundsTests` watches all three.

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

Known limitation — **closed by patch 16** (2026-09-02):

- **A failed clear could not be retried in-process.** `tearDownSyncEngine()` dropped its triggers
  with a bare `drop()` (no `IF EXISTS`), and nothing re-creates them until a fresh `SyncEngine.init`
  — `start()` doesn't, and the only other `setUpSyncEngine` call is the one inside the write that
  just rolled back. A second `deleteLocalData()` therefore threw
  `no such trigger: sqlitedata_icloud_after_primary_key_change_on_…` out of *teardown*, before it
  ever reached the clearing write, masking the original cause; recovery was an app relaunch, not a
  retry. Under upstream this was unreachable in practice because the first failure was silent and
  nobody retried; patch 5 is what puts a caller in a position to try again. Verified by
  reproduction 2026-07-25, and now pinned as a **green** guard by
  `DeleteLocalDataFailureTests.failedClearIsRetryableInProcess`. See § 16.

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
- **In-memory until serialized — closed by 5.3b.** Originally: the re-enqueued change lived in
  CKSyncEngine's state, so a process death before its next serialization lost the retry (the 1.0(16)
  matrix proved the relaunch did NOT heal on the 1.9 base). Since 5.3b the park's re-enqueue writes
  through the always-on durable ledger — save and delete halves both — and the start drain re-enqueues
  it after any crash; § 9's rescan additionally covers the never-confirmed and stamped-mirror-behind
  shapes.
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

### 8. A read failure in the send path is parked, never mistaken for a deletion

*MonteSprout incident 2026-07-18, item "the guard is arguably wrong" — the amplifier behind the
1.0(12) outage; implemented 2026-09-02 on `mango/patches-1.10`.*

`nextRecordZoneChangeBatch` builds every outgoing record from two reads — the record's `SyncMetadata`
row, then the user-table row itself — and upstream ran both through `withErrorReporting(…) ?? nil`,
dropping the pending change on `nil`. That `nil` is reached by **two different facts**: "the read
threw" and "there is no such row". Conflating them is what turned the 0.33.1 decode bug into six
days of *silent, unrecoverable* data loss rather than a visible error — the record left the upload
queue permanently, its shape never changed, and nothing ever put it back.

Patch 3 removed the trigger that era actually hit. This patch removes the amplifier, so the next
read failure — a schema change, a corrupt row, a lock timeout, a cancellation — costs a retry
instead of the record: on a **throw**, the provider returns `nil` for this batch while leaving the
`.saveRecord` in CKSyncEngine's state *and* in 5.3b's durable ledger, so the very next send retries
it (and a process death in between is covered by the ledger's start drain). Only a genuinely absent
row still runs `state.remove(pendingRecordZoneChanges:)` + `clearPersistedPendingRecordZoneChanges`
— an absent row really is a deletion, and a record that never leaves the queue is its own bug.

Both reads are patched, not just the metadata one the incident hit: they sit two statements apart in
the same closure with the identical shape, and a corrupt user row (the decode class the incident
*was*) fails at the second.

⚠️ **The distinction cannot be recovered at the call site.** `withErrorReporting`'s
optional-returning overload **flattens `R??` to `R?` itself** (xctest-dynamic-overlay
`ErrorReporting.swift`), so upstream's `?? nil` was a no-op and no unwrapping there could tell the
two apart. Both sites are therefore written as an explicit `do`/`catch` that re-reports through
`reportIssue(error, .sqliteDataCloudKitFailure)` — identical telemetry, minus the flattening. Never
"simplify" them back onto `withErrorReporting`: it silently restores the outage shape.

Known limitation (same shape as patch 1's, deliberately): a **permanently** unreadable row re-enters
the batch builder on every send round and reports each time, with no cap. A cap is a data-affecting
policy the consumer chooses; loud-and-retrying beats silent-and-gone.

Guard: `ReadFailureParkTests` injects each failure as a corrupt row — a garbage
`_lastKnownServerRecordAllFields` blob (`NSKeyedUnarchiver` rejects it) for the metadata read, an
unparseable `dueDate` string for the user-table read — and asserts the change is still queued, the
ledger row still present and the server still stale, then that the repaired send delivers the edit.
`anAbsentMetadataRowStillLeavesTheQueue` pins the boundary that must not drift. Vacuity-verified in
the 5.3a style (neutralize in place, not `git revert`): re-adding the drop to either `catch` turns
that branch's test red and leaves the other green.

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

Scope notes (the rescan's own bounds; both closed by the 5.3 follow-ups below):

- **The rescan itself never touches deletes** (`NOT _isDeleted` — its no-op-update idiom emits a *save*
  per selected row; a tombstone would resurrect). A stranded DELETE is covered by the 5.3b ledger
  instead.
- **Mirror-behind is inert where acks stay slim.** On real CloudKit a confirmed row's mirror stays NULL
  (F2 amendment), so the mirror-behind half fires only where acks carry stamps; the never-confirmed half
  is the rescan's field workhorse — and the slim-acked-edit shape is covered by the 5.3b ledger.

**5.3 follow-ups (both landed 2026-08-15, from the consumer review of this patch):**

- **5.3a — the legacy `-1` sentinel loop.** Pre-amendment rows hold mirror `-1`, which this patch's
  predicate selects at every start while a slim ack never repairs it: an upgraded device would
  blanket-reupload its whole dataset per launch. Fixed by the metadatabase migration `"Mango: null the
  legacy -1 mirror sentinels"` (registered after patch 7's, name byte-stable) — junk becomes honest
  unknown, real stamps and never-confirmed NULLs untouched. Guarded by `LegacySentinelMigrationTests`
  (a genuine pre-upgrade ledger built via the migration-prefix `upTo:` test hook, red-verified without
  the migration) plus the every-start loop characterization.
- **5.3b — the durable pending ledger is ALWAYS-ON.** Upstream wrote the `PendingRecordZoneChange`
  table only while the engine was stopped and wiped it at every start after draining — so a change made
  while running lived solely in CKSyncEngine's memory until its next serialization (the F10 window).
  Now: `didUpdate`/`didDelete` persist on every local change (still via a Task — the trigger cannot
  write re-entrantly from inside the user's transaction, so a crash before the Task lands degrades to
  the old behavior, never worse) · every sent outcome clears its rows, matched by decoding (the archiver
  blob is not byte-stable) · the failure handlers' re-enqueues (patches 1 and 6) write through, making
  the parks crash-durable · the batch builder's drop-forever sites clear (an absent record must leave
  the ledger too, or the start drain resurrects it each launch) · the start wipe is gone — rows persist
  until resolution and the drain's duplicates are absorbed by the engine state's set semantics. The
  fetch-side unsynced drain stays on `UnsyncedRecordID` (already durable, deliberately not duplicated).
  Guarded by `DurablePendingLedgerTests`, kill-restart-shaped for both S5 shapes the rescan cannot see
  (a killed edit on a slim-acked NULL-mirror row · a killed DELETE) plus the clears-on-resolution
  lifecycle contract. Known cost (accepted): the persist runs one small async write per changed row,
  so a bulk operation (a wide cascade delete) pays a burst of tiny ledger writes that upstream paid
  only while stopped — batching this into the trigger itself is upstream's own standing TODO.

- **`EngineStartRescanTests`** — pins the patched contract kill-restart-shaped (`stop()` discards the
  engines and their in-memory pending state, the same loss a force-quit produces, while the durable
  table stays empty because the engine was running): a killed never-confirmed save is re-enqueued at
  start and lands; a killed unsent edit is re-enqueued via the mirror and catches up; and the boundary —
  an in-sync row and a slim-ack NULL-mirror confirmed row are NOT re-enqueued (targeted, never blanket).
  Reverting the patch sends the two rescan tests red (verified 2026-08-15) and leaves the boundary test
  green.

### 10. Lock contention on the metadatabase must be waited out, never fatal

*Found reviewing the 1.10.0 retarget (2026-08-15); implemented the same day on `mango/patches-1.9`.
It is the fix for the two `AccountLifecycleTests` failures 5.3b left behind and the retarget recorded
as "pre-existing and unexplained".*

The metadatabase file has **two writers**: the library's own connection (`defaultMetadatabase`) and the
host's connection, which reaches the same file through the attached `sqlitedata_icloud` schema. Before
5.3b the host side wrote there rarely; **since 5.3b it writes on every local change** — the always-on
pending ledger runs through `userDatabase.write` — so the two contend routinely rather than never.

Neither side was set up to survive that:

- **The library's connection** is built from a fresh `Configuration()`, which copies only
  `observesSuspensionNotifications` from the host's and therefore leaves GRDB's default
  `busyMode = .immediateError` in place. A few milliseconds of ordinary contention became an outright
  `SQLITE_BUSY`.
- **The ledger writes** go through the host's connection, whose busy behavior the library does not own.
  A host that never hardened it (upstream's default; MangoSync hardens to `.timeout(5)`) fails
  instantly — and the first fix makes that *more* likely, because the library's connection now waits
  for the lock and then takes it instead of giving up.

Either failure is swallowed by the `withErrorReporting` around the persist, so the row silently loses
the durability 5.3b exists to give it — degrading to exactly the pre-5.3b behavior patch 9's F10 fix
was written to prevent — plus one reported issue per occurrence in the host's telemetry.

The patch, both halves in `CloudKit/Internal/MetadatabaseBusyMode.swift` (a **new Mango-owned file**, so
the cost inside upstream's own files is one line at each of three call sites):

- `mangoMetadatabaseBusyMode(inheriting:)` — inherit whatever the host chose (a `.timeout`, or a
  `.callback` the host means), and upgrade only the `.immediateError` default to `.timeout(5)`. An
  internal database the library solely owns has no reason to prefer an instant failure to a bounded wait.
- `mangoRetryingTransientContention(_:)` — bounded retries (25/50/100 ms) around the persist and the
  clear, for `SQLITE_BUSY`/`SQLITE_LOCKED` only; anything else rethrows immediately. Mirrors the
  host-side idiom in MangoSync's `Fetch.loadRetrying`. The sleeps use `Task.sleep`, **not**
  `\.continuousClock` — this runs inside the library's own persist `Task` and the suite injects a
  `TestClock` that nothing advances, so riding that clock would hang the suite instead of retrying.

Known limitation (accepted): retries are bounded, so a pathologically long writer still ends in the
swallowed-failure path. That is the pre-existing behavior, not a new one.

- **`MetadatabaseBusyModeTests`** — pins the decision (default upgraded, host's own choice inherited
  verbatim), that waiting *actually happens* (a second connection holds the write lock for 250 ms and
  the metadatabase write survives it), and the wiring (an engine built the ordinary way ends up with a
  waiting connection). Neutralizing `mangoMetadatabaseBusyMode` to return its argument sends three of
  the four red; the inheritance test stays green by construction.
- **`AccountLifecycleTests.signInUploadsLocalRecordsToCloudKit_SkipExistingCloudKitRecords`** and
  **`createSharedRecordWhileSoftLoggedOut`** are the end-to-end guard: they fail with
  `SQLite error 5: database is locked` on the 5.3b base and pass with this patch. Their history is the
  reason the rebase procedure now says an unexplained failure is a finding, not a baseline: they were
  first recorded as "pre-existing, fails the same way on the previous branch" — true, and misleading,
  because 5.3b had introduced them one commit earlier. **A failure that also fails on the previous
  branch is pre-existing; that is not the same as being upstream's.** Running them against a clean
  checkout of the base tag (where they pass) is what separates the two.

### 11. `deleteShare` must read the root record from the record's own database, never `privateCloudDatabase`

*MonteSprout Phase 51.1 — participant readiness; evidence: the consumer's
`docs/research/2026-08-17-collaboration-readiness-audit.md` § 5.4.*

When a `cloudkit.share` record's deletion arrives in a fetch (the owner stopped sharing, or the
participant tapped `UICloudSharingController`'s "Remove Me"), `handleFetchedRecordZoneChanges`
routes it to `deleteShare(shareRecordID:)`, which re-fetches the share's **root record** to
refresh the metadata and clear the cached share. Upstream reads that root record from
`container.privateCloudDatabase` unconditionally — but on a **participant** device the root
record lives in a zone owned by someone else, i.e. in the **shared** database. The read throws
`.zoneNotFound`, the call site's `withErrorReporting` swallows it into a reported issue, and the
stale share (with its participant list) stays cached in `SyncMetadata.share` forever. Every
participant-side share teardown hits this; it is why "Remove Me" silently fails.

The patch is one line: route through `container.database(for: rootRecordID)` (the existing
owner-name router the asset re-fetch path already uses) instead of `privateCloudDatabase`.
Owner-side behavior is unchanged — an owned zone's `ownerName` is `CKCurrentUserDefaultName`,
which routes to the private database exactly as before.

Known limitation (accepted): on real CloudKit a participant who was *removed* may have already
lost read access to the shared zone by the time the deletion is processed — the re-fetch then
throws there too, and the share stays cached until the zone purge that follows deletes the whole
metadata row. The patch fixes the mechanism the library controls (the wrong database); the
real-device teardown ordering is 51.14's device pass to observe.

- **`ParticipantShareDeletionTests`** — accepts an externally-owned share (the `acceptShare`
  idiom), then delivers the share record's deletion on the shared engine and asserts the cached
  share is cleared, the server record stays known, no issue is reported, and the local row
  survives (the share cache is the only thing touched). Red-verified pre-patch 2026-08-17: the
  wrong-database read surfaces as the recorded `.zoneNotFound` (CKError 26) issue plus the stale
  cached share.

### 12. A zone deletion/purge notifies the delegate before the local purge

*MonteSprout Phase 51.1 — the prerequisite for any revocation UX; same evidence base as § 11.*

`handleFetchedDatabaseChanges` reacts to a zone-level `.deleted`/`.purged` event by hard-deleting
every local row in that zone (and, downstream, the FK cascades a consumer schema hangs off those
rows). For a participant whose share was revoked this is **silent annihilation**: upstream's
`SyncEngineDelegate` has exactly one method (`accountChanged`), so no event fires, nothing can be
shown to the user, and nothing can be cleaned up alongside the purge (a consumer's private-table
rows cascade away locally while their CKRecords orphan in the consumer's own private zone).

The patch adds one **additive, default-implemented** delegate method — the fork's first public
API addition (see the preamble; MangoSync's `SharedZoneLifecycle` is the consumer):

```swift
func syncEngine(
  _ syncEngine: SyncEngine,
  willDeleteRecordsInZone zoneID: CKRecordZone.ID,
  scope: CKDatabase.Scope,
  reason: CKDatabase.DatabaseChange.Deletion.Reason
) async
```

Called once per `.deleted`/`.purged` zone **before** the purge write, while the zone's rows are
still readable — so the consumer can snapshot what it needs (a room name for the notice) and
schedule its own cleanup. Observe-only: the purge runs regardless (the zone is already gone
server-side). It fires for both scopes — a consumer distinguishes via `scope` (`.shared` = a
zone shared with the current user); `.encryptedDataReset` re-uploads rather than deletes and
does not notify. The default implementation is a no-op, so upstream-shaped delegates compile
and behave unchanged.

- **`ZonePurgeDelegateTests`** — a shared-zone purge delivers exactly one notice (zone, owner,
  `.shared`, purge) and a probe run *inside* the hook still sees the zone's rows, while the rows
  are gone after the handler returns; and `.encryptedDataReset` stays silent with rows intact.
  Red-verified pre-patch 2026-08-17 (zero notices; the boundary test green by construction).

⚠️ **Patch 12 alone does not deliver the revocation it was built for — see patch 13.** On real
CloudKit a revoked participant never receives a zone deletion; the whole hook was reached only by
the purge case (a zone the owner deleted outright).

### 13. A revoked participant is told by RECORD deletions, not a zone deletion

*MonteSprout Phase 55.2b — the fix round the first two-account device session forced; evidence:
the consumer's `docs/research/2026-08-23-two-account-session-findings.md` finding **F13**.*

Patch 12 hangs the revocation signal off `handleFetchedDatabaseChanges`, on the assumption that
losing access to someone else's record arrives as a zone deletion/purge. Instrumented on hardware
over three consecutive revocations, it does not. The zone belongs to the **owner** and survives; the
participant's shared engine gets `fetchedDatabaseChanges: ✅ Modified zone` followed by
`fetchedRecordZoneChanges: 🗑️ Deleted <rootRecordType> <root>`, `🗑️ Deleted cloudkit.share`. So
`willDeleteRecordsInZone` never fired, the library hard-deleted the root record (and the consumer
schema's `ON DELETE CASCADE` took the entire hierarchy with it) with **no event of any kind**, and
the notice the consumer builds on that hook could not be minted. Patch 12's hook was only ever
reachable for the zone-purge case — an owner deleting a whole zone — which is not what stopping a
share does.

The patch adds a **second** additive, default-implemented delegate method — the fork's only other
API addition after patch 12's — and fires it from the top of `handleFetchedRecordZoneChanges`
(`notifyRevokedShareTeardown`), once per zone, ahead of every local delete below it:

```swift
func syncEngine(
  _ syncEngine: SyncEngine,
  willDeleteSharedRootRecords rootRecordIDs: [CKRecord.ID],
  inZone zoneID: CKRecordZone.ID
) async
```

**Why a new method rather than reusing the zone hook — the review's own finding.** The obvious fix
(fire `willDeleteRecordsInZone` for the share's zone) is wrong, and destructively so. One owner zone
holds **every** hierarchy that owner shares out of it, so a participant given two records from the
same zone sees them in ONE shared zone; revoking one says nothing about the other. A zone-granular
notice would tell a consumer to sweep the record it still has — announcing a loss that did not
happen and deleting the local rows it hangs off that record (in MonteSprout: a co-teacher's own
private notes about a classroom she still has). The signal has to name the roots that actually went.
The default implementation is therefore a **no-op, never a forward to the zone hook**, for the same
reason: silence until a consumer adopts is recoverable, a zone-wide sweep is not.

Three properties carry the correctness, each with a test that fails without it:

- **`.shared` scope only.** The identical pair of deletions reaches the **owner's private** engine
  when *she* stops sharing. Notifying there tells a lead her own room was taken away — the exact
  mirror of the bug. Nothing else separates the two events.
- **Roots only, never any row in the zone.** A deletion is a teardown only if it *is* a root this
  device holds a share for, or *is* that root's cached `cloudkit.share`. Anything else — the owner
  deleting one child row inside a still-shared room — is silent.
- **Both halves, because CloudKit may split the pair across fetch batches.** If only the root
  arrives, the notice must be minted then: by the time the share's deletion turns up in a later
  batch the record and everything readable about it are already gone, which is the same silent
  annihilation one batch further along.

The shared-root set is read from `SyncMetadata.where(\.isShared)` and matched in Swift (the share is
an archived blob — the same reason `deleteShare` reads it that way). Observe-only, like patch 12: the
deletions run regardless. An unreadable metadatabase reports through `withErrorReporting` and
notifies nothing — there is no honest partial answer, since both halves are identified by that read.

- **`SharedRecordRevocationDelegateTests`** — the revocation pair notifies once, naming the root,
  with a probe *inside* the hook proving the row is still readable and gone after it returns; a
  root-only batch still notifies; **one of two rooms in a zone names only the revoked root** while
  the other room's rows survive; an ordinary child deletion in a still-shared zone stays silent; and
  the owner's own unshare (same two records, private scope) stays silent. Red-verified pre-patch
  2026-08-23 (positive tests at zero notices). ⚠️ The negative tests are **green by construction
  pre-patch**, so each was separately proven non-vacuous by mutating the shipped patch: dropping the
  scope guard reddens the owner's-unshare test; matching by zone instead of by root reddens both the
  child-deletion test and the two-rooms test. An earlier draft of the private-scope test deleted an
  *unshared* record and passed with the scope guard deleted — the share is created in it on purpose.

**Consumer notes (not library concerns).** (a) Patch 13 is **inert until a consumer implements the
new method** — MangoSync's `SharedZoneLifecycle` and its host both need the record-granular shape,
so bumping the pin alone does not restore a revocation notice. (b) A participant who leaves
voluntarily produces this same event shape, so a host that shows "you were removed from X" will show
it after her own tap unless it suppresses the notice for a leave it initiated.

### 14. A write the SYNC ENGINE performed is not a user modification

*MonteSprout Phase 55.2b-2 — the second cut blocker from the first two-account device session;
evidence: the consumer's `docs/research/2026-08-23-two-account-session-findings.md` finding **F4**
(iPhone 0 → 180 unsent edits the moment a room was shared; iPad 174 → 354 on the next relaunch —
both ≈ the device's entire row set, while a Console three-way count proved the data intact).*

The user tables' `after_update` trigger maintains the metadata row, and it is the one metadata
trigger with **no `isSynchronizing` guard** — deliberately, because the zone/parent columns it keeps
must follow the server. But it also stamped `userModificationTime = currentTime()`, and that fires
for the sync engine's own apply write just as it does for a user's edit. So applying a fetched record
left the local stamp at the **wall clock** while patch 7's mirror was stamped from the **server
record**, permanently behind it. Every already-present row the server re-delivered then satisfied
`serverUserModificationTime < userModificationTime` forever. Sharing is what made that the whole
device: it re-delivers every record in the zone.

Two halves, each independently guarded:

- **The trigger stamps only a user's write.** `userModificationTime` becomes
  `CASE WHEN isSynchronizing THEN userModificationTime ELSE currentTime() END` — the guard is on that
  one column rather than on the trigger, so the zone/parent maintenance above it is untouched. This
  also makes the ledger agree with the engine: a sync-applied write enqueues no save (the metadata
  callback trigger is `!isSynchronizing`), so it must not read as one waiting.
- **The mirror records the stamp the server record CARRIED.** `upsertFromServerRecord` forces the
  record's stamp up to the local one (`serverRecord.userModificationTime =
  metadata.userModificationTime`) so the merged row can be re-uploaded; mirroring *that* would
  declare an **already-unsent
  local edit settled** the moment any server record for its row arrived — the first fix alone opens
  exactly that hole. The pre-force value is captured and passed to `setLastKnownServerRecord`, whose
  new `carriedServerModificationTime:` parameter defaults to nil so every save-ack caller keeps
  reading the record itself (there it *is* the server's copy verbatim).

**A repair migration, for the same reason 5.3a needed one.** Rows applied under the old trigger hold
a mirror stranded behind a wall-clock stamp, and patch 9's start rescan selects exactly that
predicate — so an upgraded device would re-enqueue its whole downloaded dataset on **every launch**,
the 5.3a loop rebuilt out of two individually-correct patches. `Mango: null mirrors stranded by the
pre-patch-14 apply path` nulls them: at upgrade time a behind-mirror cannot be told from a genuine
unsent edit, so junk becomes honest **unknown** rather than an invented "in sync" stamp (patch 7's
rule). The true positives it also clears are not unguarded — 5.3b's durable pending ledger carries a
stranded save across the launch, and the mirror re-fills on that row's next apply. A NEW migration,
never an edit to a released one.

- **`UnsentUpdateVisibilityTests`** gains three: a re-delivered record leaves the count at 0 with the
  mirror still describing the server's copy; an edit made **after** an apply still counts 1 (the
  discriminator keeps discriminating); and an **already-unsent** edit survives an older server record
  arriving for the same row (the merge keeps the local value and the count stays 1).
  **`LegacySentinelMigrationTests`** gains the upgrade case (stranded → NULL; a *level* mirror and a
  never-confirmed NULL untouched).
- **Guards, verified 2026-08-23 in the 5.3a style — neutralize the mechanism in place, never revert
  the commit.** Restoring the bare `$currentTime()` in the trigger reddens the first two and only
  those (plus `TriggerTests`' generated-SQL snapshot, expected); dropping the
  `carriedServerModificationTime ??` reddens the already-unsent test and only that; `WHERE 0` in the
  migration reddens the migration test while 5.3a's stays green. ⚠️ The 5.3a fixture's non-sentinel
  row was moved to a **level** mirror (60/60): a behind-mirror there is nulled by this migration
  further down the migrator and said nothing about 5.3a's `= -1` specificity either way.
- ⚠️ **Rebase note.** Same class as patch 7 — re-record `TriggerTests`' inline snapshot after a
  rebase (13 `userModificationTime = …` lines), and keep this migration registered second-to-last
  (patch 15's took the last slot).

**Residual — closed by patch 15.** A row that arrived by **fetch** carries a real mirror stamp; edit
it, upload it, and nothing *in the ack* can level the mirror again — real CloudKit's save ack carries
no encrypted fields, and patch 7's F2 rule (never invent a stamp) correctly refuses it. That row read
as an unsent edit after its edit had landed, and patch 9 re-enqueued it once per launch. Patch 14
shrank the loop from *every fetched row* to *fetched-and-locally-edited* rows; § 15 below closes it,
by keeping the stamp the **sent** record carried across the batch → ack boundary.

### 15. The stamp the SENT record carried survives to its ack

*MonteSprout Phase 55b.7 — patch 14's residual, tracked here as Phase 10.2. Not a cut blocker: it
costs a bounded re-upload of rows the server already holds, never data.*

Patch 14 left one shape standing. A mirror that sits **behind** its row's local stamp can only be
levelled by something that knows the stamp on the server's copy, and there are exactly two candidates:
a fetch (which carries it, and is what levels a re-delivered row) or the save ack. Real CloudKit's
save ack has no encrypted fields on it at all, so it carries no stamp — and patch 7's F2 rule rightly
refuses to invent one from the `?? -1` getter fallback. So a row that arrived by fetch, was edited
locally and had that edit accepted by the server kept reading as an unsent edit forever, and patch 9's
start rescan re-enqueued it once per launch.

The stamp is not unknown, though. **This device stamped the record it sent**, in the batch builder,
which is the one place that knows. The patch writes it down there and moves it on the outcome:

- **`sentUserModificationTime` (INTEGER, nullable)**, a new metadata column. `nil` = nothing in
  flight. `nextRecordZoneChangeBatch` writes it for every record in the batch it is about to return —
  read off `batch.recordsToSave` rather than accumulated inside the record provider, so only records
  that actually made the batch are recorded and the whole batch costs one write.
- **The stamp comes off the RECORD, not the metadata row.** `CKRecord.userModificationTime`'s setter
  takes a `max`, so an outgoing record built on an all-fields archive can carry a stamp *higher* than
  `metadata.userModificationTime`. What is on the wire is what the server will hold. A record with no
  stamp at all records nothing — absent stays unknown, never `-1` (patch 7's rule again).
- **A successful ack moves it into the mirror; a failed save discards it.** The move is
  `coalesce(max(mirror, sent), sent, mirror)` — a `max`, never a plain assignment, because the mirror
  must not move backwards: a fetch landing in the same window can already have put a *newer* server
  copy's stamp there. It runs **after** `refreshLastKnownServerRecord`, so an ack that *does* carry
  its encrypted fields still wins on its own merits and the `max` leaves it alone.
- **The window is the point.** A further local edit can land between batch build and ack (see
  `editBetweenBatchAndSentRecordZoneChanges`). It bumps `userModificationTime` and not the sent
  stamp, so the row still reads unsent after the ack — which is the truth: its newest bytes are not
  on the server, and the trigger has already enqueued the save that will take them there.
- **A new migration with no backfill.** At upgrade time nothing this process could know about is in
  flight, and `NULL` already says exactly that. A NEW migration, never an edit to a released one.

⚠️ **Side effect worth knowing: the NULL-mirror slim-ack shape largely goes away in the field.** § 7's
F2 amendment left every slim-acked row with a `NULL` mirror ("unknown"), which is why §§ 9 and 5.3b
describe an edit to such a row as *structurally invisible* to the start rescan — `NULL < x` is never
true — leaving the durable pending ledger as its only guard. On real CloudKit those rows now come out
of their ack with a **real** mirror, because they went through the batch builder first, so a later
edit to one is mirror-behind and the rescan does see it. That is a gain, not a new risk: the stamp is
one this device put on the wire, never the `?? -1` invention F2 forbids. 5.3b's ledger stays the
guard for the shape patch 15 cannot reach — a change that dies **before** its ack. The tests in
`EngineStartRescanTests` / `DurablePendingLedgerTests` still exercise the NULL-mirror shape because
they inject an ack with no batch build; their comments say so.

- **`UnsentUpdateVisibilityTests`** replaces the residual's characterization with its inversion,
  `aSlimAckLevelsTheMirrorFromTheStampTheSentRecordCarried`, and adds
  `anEditBetweenTheBatchAndTheAckIsStillUnsent` (the window) and `aSettledOutcomeLeavesNothingInFlight`
  (the column's invariant, read as SQL, for both an ack and a refusal).
- ⚠️ **Harness limitation, stated in the inversion test.** A mocked record has no `modificationDate`
  — nothing can give it one, it is a read-only system field — so `refreshLastKnownServerRecord`'s
  "is this newer than what I have" guard always answers yes and **the mock's batch build levels a
  confirmed row's mirror optimistically**, which real CloudKit's does not. The inversion therefore
  reaches the behind-mirror state through a **fetch that lands while the save is in flight** (patch
  14's carried stamp puts the older server copy's stamp back in the mirror) rather than through the
  field's own ordering. Same state, reached by real code paths; do not "simplify" that fetch away.
- **Guards, verified 2026-08-23 in the 5.3a style — neutralize the mechanism in place, never revert
  the commit.** Dropping the batch-build call reddens the inversion and the invariant test and only
  those; emptying the ack-side move's ID list reddens the same two; emptying the failure clear's list
  reddens the invariant test alone. Levelling from the row's **current** `userModificationTime`
  instead of the sent stamp reddens the window test — and also, in the other two suites,
  `aStamplessSaveAckNeverInventsAMirrorStamp`, `aKilledEditOnASlimAckedRowIsReEnqueuedAtStart` and
  `confirmedRowsAreNotRescannedAtStart`, because that naive form *is* the F2 invention patches 7 and
  9 exist to prevent.
- ⚠️ **Rebase note.** Same class as patches 7 and 14 — the column appears in every `SyncMetadata`
  dump, so re-record the inline snapshots after a rebase (12 test files carry them today), and keep
  this migration registered **last**.

### 16. Teardown's trigger drops are idempotent, so a failed clear is retryable in-process

*Closes patch 5's known limitation — no consumer incident; the defect is the one patch 5 made
reachable, and this repo's own reproduction (2026-07-25) is the evidence.*

Upstream's `tearDownSyncEngine()` drops both families of sync trigger with a bare
`DROP TRIGGER` — the per-table ones (`dropTriggers`) and `SyncMetadata`'s callback triggers.
`DROP TRIGGER` on an absent trigger is an error, so teardown is **not idempotent**, and since patch
5 that is reachable: a failed `deleteLocalData()` rolls its write back, the rollback undoes the
`setUpSyncEngine(writableDB:)` that re-creates the triggers, and this teardown's drop — a prior,
already-committed write — stands. The caller patch 5 exists to inform then fixes the cause and calls
again, and upstream's second call died *in teardown* on
`no such trigger: sqlitedata_icloud_after_primary_key_change_on_…`, before it ever reached the
clearing write. The original cause was masked and the only recovery was an app relaunch.

The patch: `drop(ifExists: true)` at both sites (`SyncEngine.tearDownSyncEngine()`'s callback-trigger
loop and the per-table `dropTriggers`). A present trigger is dropped exactly as before; an absent one
is a no-op, so the retry reaches the clear and `setUpSyncEngine(writableDB:)` re-installs the
triggers on the way out. Two lines, no behavior change on any path where the triggers exist.

Accepted trade, stated: the drop no longer *reports* a trigger that should have existed but didn't.
Nothing was ever built on that throw — it names an absent trigger, not a roster mismatch, and every
call site treats teardown's success as the precondition for what follows.

- **Guard: `DeleteLocalDataFailureTests.failedClearIsRetryableInProcess`** — sabotage a rostered
  table, first `deleteLocalData()` throws (patch 5), un-sabotage, second call **clears for real**
  (rows gone, metadatabase empty, engine restarted). Neutralize either `ifExists: true` in place and
  it goes red on `no such trigger`; both halves verified independently 2026-09-02, and each is
  load-bearing on its own.

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
- **`ManifestBoundsTests`** — the guard for the bound itself, added with the 2026-09-02 audit. Parses
  both manifests as **text** (behavior tests structurally cannot see a range) and asserts (a) no
  dependency is declared with a bare `from:`, and (b) every bound's floor is the minor
  `Package.resolved` pins, so a retarget that forgets to retune goes red. Vacuity-checked both ways:
  reverting GRDB to `from: "7.6.0"` in `Package.swift` reddens the live-manifest test *and* the
  floor-match case for `Package.swift`; doing the same in `Package@swift-6.0.swift` reddens the 6.0
  test and only that manifest's floor-match case. Trait-gated dependencies (swift-tagged) are absent
  from `Package.resolved` and are skipped by (b) by design — (a) still covers them.

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

### Test commits — the 1.10.0 base (no library behavior change, not a Mango patch)

- **`TriggerTests` snapshot re-record.** Tag 1.10.0 ships a *stale* inline snapshot: it raised its
  `swift-structured-queries` floor to 0.36.0, which fixed a redundant paren pair in `IN (…)`
  subquery rendering, but the tag's own recorded SQL still carries the old `IN ((WITH …)))` form.
  `triggers()` therefore fails on **vanilla 1.10.0** — verified against a clean checkout of the tag,
  so it is upstream's defect, not the patch stack's. Upstream fixed it the same day in
  [#522](https://github.com/pointfreeco/sqlite-data/commit/f4bf8e9) ("Re-record snapshots"), which
  is on `main` and **in no release tag**. We take *only* that commit's two `TriggerTests.swift`
  lines, verbatim. Deliberately **not** taken: the rest of #522, which is an unrelated
  `$foo.set(…)` → `.taskLocal($foo, …)` test-API migration that collides with our patched test
  files. Drop this re-record at the first upstream tag that contains #522.
  **Dropped as planned at the 1.12.0 retarget (2026-09-02):** 1.11.0 is the first tag containing
  #522, so the carried lines became upstream's own (the merge deduplicated them — `TriggerTests`
  came through with no fork-side diff) and the rest of #522's `.taskLocal` migration arrived with
  the base. The in-repo `TestLocals` helper still accepts the old `$foo.set(…)` form, so the Mango
  test files (`ZonePurgeDelegateTests`, `SharedRecordRevocationDelegateTests`) keep it — migrate
  them only if upstream ever removes `.set` from `TestLocals`.

## Guard executability — read before trusting step 4

Guard rot is real and it is now the majority of them. Status as re-verified on the 1.10.0 retarget
(2026-08-15):

- **Clean and red as documented — four:** **patch 4, the patch-7 F2 amendment, 5.3a, 5.3b**. Their
  library-source revert applies without conflict (5.3a via its own unregister-the-migration method),
  and each went red on exactly the tests step 4 names, with the documented neighbours staying green.
  These four are the ones you can still trust as written.
- **Red, but only after resolving a conflict — patch 1.** Its `SyncEngine.swift` revert does **not**
  apply cleanly: a bare `git revert` leaves the file unmerged and a 3-way reverse-apply leaves
  conflict markers. Resolving in favour of the revert does produce exactly the documented red (all
  three assertions on `cascadeChild_isParkedAndReEnqueued_notDeleted`, the other two tests green) —
  but that resolution can revert adjacent patch content in the same region, so the red is not
  attributable to patch 1 alone. Treat it as suggestive, not as a clean guard.
- **Inconclusive — patches 5, 6, 7 and 9.** A bare revert conflicts (5, 6, 7) or reverse-applies to
  a no-op (9), because 5.3a/5.3b later rewrote the same `SyncEngine` regions.

None of this is rebase damage: the identical reverts behave the same way on `mango/patches-1.9`,
checked side by side. The step-4 text for the broken five was last truly verified 2026-08-10, before
5.3a/5.3b landed.

**Owed: rewrite the five rotted guards** (patches 1, 5, 6, 7, 9) in the 5.3a style — neutralize the
specific mechanism in place rather than reverting the commit, which is the only approach that stays
stable as later patches touch the same regions. Until then, the load-bearing anti-drop check is
the **byte-identity check**: upstream has never touched `CloudKit/SyncEngine.swift`,
`CloudKit/Internal/Metadatabase.swift` or `CloudKit/SyncMetadata.swift`, so after any retarget

```
git diff <previous mango branch> <new mango branch> -- Sources/SQLiteData/CloudKit/
```

must be **empty**. That is a direct refutation of the exact risk step 4 exists for — patch 6's
removed case-list codes, 5.3b's removed start wipe — and it caught nothing amiss on this retarget.

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
doesn't, consider filing it. Re-checked at the 1.10.0 retarget (2026-08-15): upstream **still**
declares it unbounded (`from: "0.36.0"`), so patch 3 is still ours to carry. Not reported so far.

## Consumer rule

- **Pin by revision** (`.package(url: "git@github.com:Mango-Grove-Labs/sqlite-data.git",
  revision: "<sha>")`) — never by branch or version range.
- **All Mango apps pin the *same* revision AND the same URL string** (the SSH form above). SPM
  unifies dependencies by package identity — if two `Package.swift`s in one graph (e.g. an app +
  MangoSync) pin mismatched revisions *or* different URL forms (https vs SSH), resolution
  fails. Bump in lockstep, always.

## Rebase procedure (new upstream release `1.X.Y`)

**Form of the retarget (how every one has actually been executed — 1.9, 1.10, 1.12):** the stack
is NOT rebuilt by cherry-picking onto the tag. The new branch continues the existing linear patch
line: cut `mango/patches-1.X` **at the previous branch's tip**, land the upstream
`<old-tag>..<new-tag>` diff as **one single-parent commit** (`git merge --no-commit <tag>` for the
3-way content, then commit the index with `git commit-tree <tree> -p HEAD`, never a two-parent
merge commit), resolving conflicts per step 3's traps. This keeps every historical patch SHA an
ancestor (old consumer pins stay valid by construction) and makes the **byte-identity check**
(step 4 / Guard executability) the proof that no patch was dropped. Step 3's ordered cherry-pick
list is the fallback form if the linear line is ever abandoned — and, always, the map of which
patch owns which region when a conflict does hit.

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
   site)**, **the 5.3a sentinel-nulling migration commit (metadatabase schema — keep its migration
   registered after patch 7's, name byte-stable; also carries the `package`/`upTo:` migrate hook its
   test needs)**, **the 5.3b always-on-ledger commit (didUpdate/didDelete persist + the
   handleSentRecordZoneChanges clears + the batch-builder clears + the removed start wipe — the wipe
   removal is the piece a conflict resolved by taking upstream silently reverts)**, **patch 10 (the
   metadatabase busy mode + the ledger-write retries — its logic lives in the Mango-owned
   `CloudKit/Internal/MetadatabaseBusyMode.swift`, so only the three one-line call sites can conflict)**,
   **patch 11 (the one-line `database(for:)` routing in `deleteShare`)**, **patch 12 (the
   `willDeleteRecordsInZone` delegate hook — protocol method + default impl in
   `SyncEngineDelegate.swift`, notify loop at the top of `handleFetchedDatabaseChanges`; a conflict
   resolved by taking upstream's `SyncEngineDelegate.swift` silently drops the whole API)**,
   **patch 13 (the record-deletion revocation notice — the second `SyncEngineDelegate` method +
   default impl in `SyncEngineDelegate.swift`, `notifyRevokedShareTeardown` plus its one call at the
   top of `handleFetchedRecordZoneChanges`; same conflict trap as patch 12, and without it patch 12
   is an API that fires for nothing a participant ever sees)**, **patch 14 (the `isSynchronizing`
   guard on `SyncMetadata.update`'s `userModificationTime` in `Internal/Triggers.swift`, the
   `carriedServerModificationTime` capture + parameter across `upsertFromServerRecord` and
   `setLastKnownServerRecord`, and its repair migration — metadatabase data-only, keep it registered
   LAST and its name byte-stable; also re-record `TriggerTests`' generated-SQL snapshot, which the
   trigger half changes on 13 lines)**,
   **patch 15 (the `sentUserModificationTime` column + its two `SyncEngine` helpers —
   `recordSentUserModificationTimes` at the end of `nextRecordZoneChangeBatch`,
   `levelMirrorsFromSentStamps` on the ack, the discard on a refused save — and its repair migration,
   metadatabase data-only, registered LAST, after patch 14's, name byte-stable)**,
   **patch 8 (the two `do`/`catch` read-failure parks inside `nextRecordZoneChangeBatch`'s record
   provider; a conflict resolved by taking upstream restores `withErrorReporting(…) ?? nil`, which
   compiles fine and silently reinstates the drop — check both reads)**,
   **patch 16 (the two `drop(ifExists: true)` calls — `tearDownSyncEngine()`'s callback-trigger loop
   and the per-table `dropTriggers`; a conflict resolved by taking upstream restores the bare
   `drop()` on both, which compiles fine and silently re-breaks the in-process retry — check both)**,
   the test
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
   - **5.3a is checked differently** — a bare revert of its commit also removes the `package`/`upTo:`
     migrate hook, so the restored test file fails to *compile* (loud, but not a red assertion).
     The meaningful check: unregister only the `"Mango: null the legacy -1 mirror sentinels"`
     migration block → `swift test --filter LegacySentinelMigrationTests` must go **red** on
     `theUpgradeNullsLegacySentinelsAndPreservesRealStamps` (the `-1` survives the upgrade); restore
     → green. The loop characterization (`aLegacySentinelLoopsTheRescanOnEveryStart`) stays green
     either way — it pins the mechanism, not the fix.
   - `git revert --no-commit <5.3b sha>` → `swift test --filter DurablePendingLedgerTests` must go
     **red** on all three tests (`aKilledEditOnASlimAckedRowIsReEnqueuedAtStart`,
     `aKilledDeleteIsReEnqueuedAtStart`, `theLedgerClearsOnResolution` — the ledger is never written
     while the engine runs); `git reset --hard` → green.

   - Neutralize `mangoMetadatabaseBusyMode` to `return hostBusyMode` (a bare revert of patch 10 also
     deletes its test file) → `swift test --filter MetadatabaseBusyMode` must go **red** on
     `aDefaultHostConfigurationStillGetsABoundedBusyTimeout`,
     `aHeldWriteLockIsWaitedOutRatherThanFailingImmediately` and
     `theEnginesMetadatabaseConnectionWaitsForALock`, while `theHostsOwnBusyTimeoutIsInheritedVerbatim`
     stays green (it pins the other half); restore → green.
   - Neutralize patch 11 in place (put `deleteShare`'s root-record read back on
     `container.privateCloudDatabase`) → `swift test --filter ParticipantShareDeletionTests` must go
     **red** on `aShareDeletionOnAParticipantClearsTheCachedShare` (a recorded `.zoneNotFound` issue
     plus the stale cached share); restore → green. (Neutralize-in-place from the start — this patch
     shares `SyncEngine.swift` with the five whose bare reverts already rot.)
   - Neutralize patch 8 in place (re-add `state.remove(pendingRecordZoneChanges:)` +
     `clearPersistedPendingRecordZoneChanges` to either `catch` in `nextRecordZoneChangeBatch`'s
     record provider) → `swift test --filter ReadFailureParkTests` must go **red** on
     `aFailedMetadataReadParksTheRecord` for the metadata `catch` and on
     `aFailedRecordReadParksTheRecord` for the user-row `catch` — each branch takes down only its own
     test, and `anAbsentMetadataRowStillLeavesTheQueue` stays green either way (it pins the boundary);
     restore → green.
   - Neutralize patch 16 in place (put either `drop(ifExists: true)` back to a bare `drop()` —
     `tearDownSyncEngine()`'s callback-trigger loop or the per-table `dropTriggers`) → `swift test
     --filter DeleteLocalDataFailureTests` must go **red** on `failedClearIsRetryableInProcess`
     (`no such trigger: …` out of the retry's teardown), while `failedClearThrows` and
     `directCallClearsAndRestarts` stay green; restore → green. Both halves redden it independently
     (verified 2026-09-02).
   - Neutralize patch 12 in place (delete the notify loop at the top of
     `handleFetchedDatabaseChanges`) → `swift test --filter ZonePurgeDelegateTests` must go **red** on
     `aSharedZonePurgeNotifiesTheDelegateBeforeDeletingLocalRows` (zero notices), while
     `anEncryptedDataResetDoesNotNotifyTheDelegate` stays green (it pins the boundary); restore →
     green.

   A rebase that skips these can silently drop a guard. **Before running any of them, read
   "Guard executability" above** — of the pre-Phase-8 guards only five still revert cleanly
   (patch 10's is the fifth); patches 8, 11, 12 and 16 are **neutralize-in-place by definition** (above)
   and don't rot the same way. The byte-identity check described there is the check that actually
   rules out a dropped patch.

   ⚠️ **Run every guard at the branch TIP, by neutralizing the mechanism in place — never by checking
   out a mid-stack commit.** The stack is not buildable commit-by-commit: patch 3 replays with the
   *previous* base's bound and is only retuned in the final commit (step 5), so every intermediate
   commit resolves a `swift-structured-queries` minor the new base's source does not compile against.
   Bisecting the stack fails at the compiler, not at a test.
4b. **Baseline the suite on the previous branch — and prove a "pre-existing" failure is upstream's.**
   Run the full suite on the outgoing `mango/patches-*` branch and diff the failure lists; a failure
   present on both is pre-existing. **Pre-existing is not the same as upstream's** — it only means the
   cause landed before this rebase, which includes our own last patch. Run any such failure against a
   **clean checkout of the base tag**: if it passes there, it is ours, and it is a finding, not a
   baseline. That distinction is exactly what the 1.10.0 retarget got wrong (the two
   `AccountLifecycleTests` failures were 5.3b's, one commit old — now fixed by patch 10), and it is
   what proved `TriggerTests.triggers()` genuinely *was* upstream's stale snapshot.
5. **Manifest check (required):** retune **every** bound in **every** manifest — `Package.swift`,
   `Package@swift-6.1.swift` (since the 1.12.0 base), and `Package@swift-6.0.swift` — to the new
   base tag's own `Package.resolved` pins — the new upstream tag's tested minors, not the previous
   branch's literals. Since 2026-09-02 that is the whole
   dependency list, not just `swift-structured-queries` (§ 3's table). **`ManifestBoundsTests` is
   the automated half of this check**: it fails if any dependency is declared with a bare `from:`,
   and it fails if a bound's floor no longer matches the `Package.resolved` pin — so a rebase that
   forgets to retune goes red instead of shipping. It reads the manifests as text, which is the only
   thing that can catch this: **no behavior test can**, because the suite resolves via this repo's
   own `Package.resolved` and stays green on any version, which is exactly how the original outage
   reached the field. What still needs the eye is the *judgment* — that the new floor is the version
   the new base is genuinely tested against. Two 1.12-era wrinkles: which fallback manifest is
   *live* depends on the toolchain (on 6.1–6.3, `Package@swift-6.1.swift` is the one that actually
   resolves; `Package@swift-6.0.swift` stays inert everywhere we build but drifts silently — it
   spent the whole 1.9 line unbounded before anyone looked), and the committed `Package.resolved`
   is **toolchain-shaped**: re-resolving on a 6.1–6.3 toolchain swaps the tag's
   `swift-issue-reporting` pin for `xctest-dynamic-overlay` (and drops the 6.4-graph-only pins),
   which is expected — commit the resolution this fork's own toolchain produces, since that is what
   the suite runs against.
6. Full `swift test` green (known-intermittent issues aside), twice. "Green" means no unexplained
   failure — see 4b before writing one off.
7. Push the branch; update consumers' `Package.swift` `revision:` pins in lockstep.
