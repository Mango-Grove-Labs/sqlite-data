# MANGO-PATCHES — the Mango Grove Labs sqlite-data fork

This fork (`Mango-Grove-Labs/sqlite-data`) is the **org-wide vehicle for library-level fixes**
to [pointfreeco/sqlite-data](https://github.com/pointfreeco/sqlite-data). It is fully
API-compatible with upstream — no app imports a fork-only symbol; patches change behavior or the
dependency manifest, never the public API. Library bugs get fixed **here**, never re-implemented
or shadowed in an app or wrapper package.

**Consumer branch: `mango/patches-1.6`** — upstream tag `1.6.6` + the patches below.

## The patches

### 1. Park + re-enqueue CASCADE child on `.referenceViolation` save (never local-delete)

*MontiSprout Phase 27.6c — the data-loss fix.*

A CASCADE parent-reference violation on a **save** means the child's parent hasn't landed in
the CloudKit zone *yet* — not that the child should be destroyed. Upstream's failed-save
handler (`SyncEngine.handleSentRecordZoneChanges`, `.referenceViolation` → `onDelete == .cascade`
branch) local-DELETEs the child, which surfaces as user rows that appear and then vanish (a
local-first data-loss bug; hit in the field by MontiSprout testers). The patch mirrors the
library's own failed-**delete** idiom instead: park the row in `UnsyncedRecordID` and re-enqueue
its `.saveRecord` so it lands once the parent syncs. `setNull`/`setDefault` FK actions keep
upstream behavior.

Deliberate consequence (owner call, 2026-07-11): on a parent that is *permanently* gone, the
child is **kept** as a local orphan rather than silently deleted — data over orphan-avoidance.

Known limitations (accepted; observability planned in the consumer's MangoSyncKit work):

- **Unbounded re-send on a permanently-gone parent.** The park re-enqueues the child's save on
  every failure, so a child whose parent never lands re-sends and re-fails each sync round
  indefinitely (network/battery churn + a patch-2 report per round). No cap by design — a cap
  is a data-affecting policy the consumer must choose deliberately.
- **Crash-window park drop.** The re-enqueued `.saveRecord` lives in CKSyncEngine's in-memory
  state until its next serialization; if the process dies before that, the relaunch's fetch-side
  unsynced drain sees `.unknownItem` for the parked ID (the record never reached the server) and
  clears the park row without re-enqueueing. The child is then local-only with no retry until a
  force-re-upload or account-change re-enqueue. Surface via sync-health trends, don't rely on
  the park row as a durable retry ledger.

### 2. Report every silently-dropped failed SAVE with its CKError

*MontiSprout Phase 27.4d — observability for the invisible failure.*

Upstream abandons several failed-save buckets (`.serverRejectedRequest`, the terminal bucket:
`.badDatabase`/`.quotaExceeded`/…, and `@unknown default`) with no retry **and no signal** — a
record failing there simply never reaches CloudKit, invisibly. The patch adds a
`reportIssue(...)` naming the record type and CKError code on every such drop (diagnostic only —
control flow unchanged, no per-code special-casing). Hosts bridge IssueReporting to their
telemetry (MontiSprout: IssueReporting→Sentry) so the field failure gets a name.

Known noise: benign duplicate-record conflicts can be reported; triage before reacting.

### 3. Bound the `swift-structured-queries` range (the 1.0(12) sync outage)

*MontiSprout incident 2026-07-18 — total, silent loss of outbound sync in a shipped build.*

Upstream declares `swift-structured-queries` as `from: "0.31.0"` — **unbounded**. Tag 1.6.6 is
written and tested against **0.31.1** (its own `Package.resolved` pins exactly that), but a
consumer's SPM graph happily resolves whatever is newest. MontiSprout resolved **0.33.1**, at
which point `SyncMetadata`'s generated column decoding misaligns: the send path fails reading
every pending record's own metadata row with a bogus
`Expected column 14 ("userModificationTime") to not be NULL` (the column is `INTEGER NOT NULL`
in a STRICT table and always holds a value — `QueryCursor` reports `currentIndex - 1`, i.e.
wherever the decoder gave up, so the named column is an artefact of the misalignment).

The failure is catastrophic rather than noisy because `nextRecordZoneChangeBatch` cannot
distinguish "record is gone" from "I failed to read it" and runs
`state.remove(pendingRecordZoneChanges:)` either way — dropping the record from the upload queue
permanently. **MontiSprout TestFlight 1.0(12) uploaded nothing for six days across two testers'
devices** while the app's sync health reported "ok".

The patch: `.upToNextMinor(from: "0.31.1")`. Pre-1.0 minor bumps are breaking by convention, so
0.31.x patches stay allowed and **0.32+ becomes a deliberate, tested fork upgrade** (rebase onto
an upstream tag that supports it) rather than something a consumer's resolver decides silently.

⚠️ **This is a class of bug, not a one-off.** Any unbounded `from:` in this manifest can do the
same thing to a consumer. Treat a widened range as a library change requiring the full suite.

**Owed: audit the remaining unbounded ranges.** Every other dependency here is still declared
`from:` with no ceiling, and this repo's own `Package.resolved` shows how far they drift —
**GRDB is declared `from: "7.6.0"` and resolves to 7.11.0**, the largest gap in the manifest and
the one sitting closest to the storage layer. Nothing has gone wrong there; the point is that
nothing would tell us if it did. (Tracked as item 8 of the MontiSprout incident, but the work
happens in this repo.)

### 4. Planned — don't let a read failure masquerade as a deletion

*Not yet implemented. Recorded here so the amplifier isn't forgotten once patch 3 hides it.*

`nextRecordZoneChangeBatch` (SyncEngine.swift:1132-1148) treats a failed metadata read exactly
like a missing record: both fall through to
`state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])`. That conflation is what turned
the 0.33.1 decode bug into six days of *silent, unrecoverable* data loss rather than a visible
error — the record left the queue permanently and no retry ever touched it again.

Patch 3 removes the trigger that was actually hit. It does nothing about the amplifier: any future
read failure — a schema change, a corrupt row, a lock timeout — reproduces the same outage shape.
The fix should follow patch 1's idiom: a read failure **parks or retries**, and only a genuinely
absent record is dropped. Worth doing regardless of root cause (MontiSprout incident, "the guard is
arguably wrong").

### 5. Test commits — patch 3 (no library behavior change)

- **`PendingRecordMetadataDecodeTests`** — the tripwire for patch 3. Exercises the send path's
  metadata read for a record awaiting its first upload (root and child, at a realistic wall-clock
  `userModificationTime`) plus an end-to-end "it actually reaches the server" assertion. **Passes
  at 0.31.x; verified 2026-07-18 that all four fail at 0.33.1 with the exact production error and
  query.** Note this suite cannot catch the defect on its own — it runs against the pinned
  resolution, which is precisely why the outage reached the field: the tests and the consuming app
  were in different dependency worlds. To re-check, point `Package.resolved` at 0.33.1 and re-run.

### 6. Test commits — patches 1–2 (no library behavior change)

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

## Candidate patches (not yet written)

### 4. A failed `CKAsset` download must not be written as `NULL`

*MontiSprout, observed 2026-07-19 (Sentry 7619718981) — **candidate, not implemented**.*

On the fetch path, a record whose `CKAsset` fails to materialise yields a nil value, and the engine writes
it straight into the local column. Where that column is `NOT NULL` — as any "the bytes themselves" column
will be — SQLite rejects the row:

```
SQLite error 19: NOT NULL constraint failed: mediaBlobs.data
INSERT INTO "mediaBlobs" ("id","classroomID","data","createdAt") VALUES (?, ?, NULL, ?) ON CONFLICT…
```

A transient asset-download failure therefore becomes a **constraint violation**, not a retry. The record is
dropped from that fetch with no queued recovery — the same "a failure the engine can't distinguish from a
decision" shape as patch 1.

**Proposed:** when an expected asset is nil, skip the row and leave it unsynced (or park it, patch-1 style)
so the next fetch retries, rather than attempting an insert that cannot succeed.

**Not yet reproduced deliberately.** Observed only on a device that had just crossed CloudKit
Development→Production, so the trigger may be stale cross-environment asset references rather than a plain
download failure. No data loss was observed (every `mediaItem` still had its blob on both devices) — the
insert fails, so nothing local is overwritten. Worth reproducing with a deliberately failed asset download
before writing the patch.

Full context: MontiSprout `docs/incidents/2026-07-18-metadata-decode-blocks-all-uploads.md` § Addendum.

## Why upstream won't take patches 1–2

Reported as [pointfreeco/sqlite-data#485](https://github.com/pointfreeco/sqlite-data/issues/485);
closed with upstream disputing the framing (re-verified 2026-07-10: upstream `main` post-1.6.6
still carries the CASCADE local-delete). The patches are ours to carry indefinitely.

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
  MangoSyncKit) pin mismatched revisions *or* different URL forms (https vs SSH), resolution
  fails. Bump in lockstep, always.

## Rebase procedure (new upstream release `1.X.Y`)

1. `git remote add upstream https://github.com/pointfreeco/sqlite-data.git` (if absent);
   `git fetch upstream --tags`.
2. Cut `mango/patches-1.X` from tag `1.X.Y`.
3. Cherry-pick, in order: patch 1 (park guard), patch 2 (dropped-save reporting), patch 3
   (the `swift-structured-queries` bound in `Package.swift`), the test commits (take them from
   the tip of the previous `mango/patches-*` branch). Resolve conflicts by **idiom, not line
   number** — the `SyncEngine` error-handling region drifts. Patch 3 conflicts every time, because
   the rebase re-inherits upstream's `from:` declaration — take **ours**.
4. **Vacuity guard (required):** `git revert --no-commit <patch-1 sha>` →
   `swift test --filter ReferenceViolationGuardTests` must go **red** on
   `cascadeChild_isParkedAndReEnqueued_notDeleted` (all three assertions); `git reset --hard`
   → green. A rebase that skips this can silently drop the guard.
5. **Manifest check (required):** confirm `Package.swift` still reads
   `.upToNextMinor(from: "0.31.1")` for `swift-structured-queries` — unless the new upstream tag is
   written against a later version, in which case bound it to *that* minor. **No test can catch a
   dropped patch 3**: the suite resolves via this repo's own `Package.resolved` and stays green on
   any version, which is exactly how the original outage reached the field. Check it by eye.
6. Full `swift test` green (known-intermittent issues aside), twice.
7. Push the branch; update consumers' `Package.swift` `revision:` pins in lockstep.
