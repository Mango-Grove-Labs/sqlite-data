# MANGO-PATCHES — the Mango Grove Labs sqlite-data fork

This fork (`Mango-Grove-Labs/sqlite-data`) is the **org-wide vehicle for library-level fixes**
to [pointfreeco/sqlite-data](https://github.com/pointfreeco/sqlite-data). It is fully
API-compatible with upstream — no app imports a fork-only symbol; every patch is behavioral.
Library bugs get fixed **here**, never re-implemented or shadowed in an app or wrapper package.

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

### 2. Report every silently-dropped failed SAVE with its CKError

*MontiSprout Phase 27.4d — observability for the invisible failure.*

Upstream abandons several failed-save buckets (`.serverRejectedRequest`, the terminal bucket:
`.badDatabase`/`.quotaExceeded`/…, and `@unknown default`) with no retry **and no signal** — a
record failing there simply never reaches CloudKit, invisibly. The patch adds a
`reportIssue(...)` naming the record type and CKError code on every such drop (diagnostic only —
control flow unchanged, no per-code special-casing). Hosts bridge IssueReporting to their
telemetry (MontiSprout: IssueReporting→Sentry) so the field failure gets a name.

Known noise: benign duplicate-record conflicts can be reported; triage before reacting.

### 3. Test commits (no library behavior change)

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

## Consumer rule

- **Pin by revision** (`.package(url: "git@github.com:Mango-Grove-Labs/sqlite-data.git",
  revision: "<sha>")`) — never by branch or version range.
- **All Mango apps pin the *same* revision.** If two `Package.swift`s in one dependency graph
  pin this package (e.g. an app + MangoSyncKit), SPM unifies by package identity — mismatched
  revisions fail resolution. Bump in lockstep, always.

## Rebase procedure (new upstream release `1.X.Y`)

1. `git remote add upstream https://github.com/pointfreeco/sqlite-data.git` (if absent);
   `git fetch upstream --tags`.
2. Cut `mango/patches-1.X` from tag `1.X.Y`.
3. Cherry-pick, in order: patch 1 (park guard), patch 2 (dropped-save reporting), the test
   commits (take them from the tip of the previous `mango/patches-*` branch). Resolve conflicts
   by **idiom, not line number** — the `SyncEngine` error-handling region drifts.
4. **Vacuity guard (required):** `git revert --no-commit <patch-1 sha>` →
   `swift test --filter ReferenceViolationGuardTests` must go **red** on
   `cascadeChild_isParkedAndReEnqueued_notDeleted` (all three assertions); `git reset --hard`
   → green. A rebase that skips this can silently drop the guard.
5. Full `swift test` green (known-intermittent issues aside), twice.
6. Push the branch; update consumers' `Package.swift` `revision:` pins in lockstep.
