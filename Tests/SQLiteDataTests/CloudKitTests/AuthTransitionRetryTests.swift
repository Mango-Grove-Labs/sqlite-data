#if canImport(CloudKit)
  import CloudKit
  import OrderedCollections
  import SQLiteData
  import Testing

  // MontiSprout fork (41.1): an account-availability transition is not a verdict on the record.
  // Upstream drops `.notAuthenticated` / `.accountTemporarilyUnavailable` failures into the terminal
  // "give up silently" bucket on BOTH the failed-save and failed-delete paths, so a change that is in
  // flight when iCloud signs out, signs in, or has its per-app toggle flipped never reaches the zone
  // — and nothing resumes it until an app relaunch re-enqueues from the ledger (observed on hardware
  // 2026-07-25 during the MontiSprout 1.0(15) device matrix; Sentry 7633019003). The fork re-enqueues
  // the change instead, so CKSyncEngine holds it while the account is unavailable and sends it when
  // availability returns.
  //
  // Deliberately narrow: only the two transition codes retry. A genuinely restricted or revoked
  // account keeps upstream's give-up behavior — see `terminalBucketSave_isStillDropped`.
  //
  // Vacuity guard (required by MANGO-PATCHES § Rebase procedure): reverting the patch-6 hunks in
  // `SyncEngine.swift` sends `notAuthenticatedSave_isReEnqueuedForRetry`,
  // `accountTemporarilyUnavailableSave_isReEnqueuedForRetry` and
  // `notAuthenticatedDelete_isReEnqueuedForRetry` RED (nothing is re-enqueued). Restoring it → green.
  extension BaseCloudKitTests {
    @MainActor
    final class AuthTransitionRetryTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func recordID(_ label: String) -> CKRecord.ID {
        CKRecord.ID(
          recordName: "auth-transition-\(label)",
          zoneID: SyncEngine.defaultTestZone.zoneID
        )
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func failedSave(
        _ code: CKError.Code,
        label: String
      ) -> (record: CKRecord, error: CKError) {
        (
          CKRecord(recordType: Reminder.tableName, recordID: recordID(label)),
          CKError(code)
        )
      }

      /// The core guard: a `.notAuthenticated` save is re-enqueued, not abandoned. The `withKnownIssue`
      /// also pins the diagnostic — a parked save still reports, so the failure never goes invisible.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func notAuthenticatedSave_isReEnqueuedForRetry() async {
        await withKnownIssue {
          await syncEngine.handleSentRecordZoneChanges(
            failedRecordSaves: [failedSave(.notAuthenticated, label: "save-not-authed")],
            syncEngine: syncEngine.private
          )
        }

        // Re-enqueued, so account restoration resumes the upload with no relaunch. (Asserting also
        // drains the pending set, satisfying the harness's empty-pending-changes teardown invariant.)
        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(recordID("save-not-authed"))
        ])
      }

      /// The second transition code, which Apple documents as explicitly temporary.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func accountTemporarilyUnavailableSave_isReEnqueuedForRetry() async {
        await withKnownIssue {
          await syncEngine.handleSentRecordZoneChanges(
            failedRecordSaves: [
              failedSave(.accountTemporarilyUnavailable, label: "save-temporarily-unavailable")
            ],
            syncEngine: syncEngine.private
          )
        }

        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(recordID("save-temporarily-unavailable"))
        ])
      }

      /// The scope boundary, and the half that must NOT drift: a terminal-bucket code still reports
      /// and still gives up. Without this, widening the retry set later would pass unnoticed.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func terminalBucketSave_isStillDropped() async {
        await withKnownIssue {
          await syncEngine.handleSentRecordZoneChanges(
            failedRecordSaves: [failedSave(.quotaExceeded, label: "save-quota")],
            syncEngine: syncEngine.private
          )
        }

        syncEngine.private.state.assertPendingRecordZoneChanges([])
      }

      /// A permanently restricted account is not a transition — it keeps upstream's give-up behavior,
      /// because retrying it could never succeed.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func managedAccountRestrictedSave_isStillDropped() async {
        await withKnownIssue {
          await syncEngine.handleSentRecordZoneChanges(
            failedRecordSaves: [failedSave(.managedAccountRestricted, label: "save-managed")],
            syncEngine: syncEngine.private
          )
        }

        syncEngine.private.state.assertPendingRecordZoneChanges([])
      }

      /// The failed-DELETE half: an abandoned delete leaves the record alive in the zone, so the next
      /// fetch resurrects a row the user deleted. Re-enqueued for the same reason as the save.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func notAuthenticatedDelete_isReEnqueuedForRetry() async {
        await syncEngine.handleSentRecordZoneChanges(
          failedRecordDeletes: [recordID("delete-not-authed"): CKError(.notAuthenticated)],
          syncEngine: syncEngine.private
        )

        syncEngine.private.state.assertPendingRecordZoneChanges([
          .deleteRecord(recordID("delete-not-authed"))
        ])
      }

      /// The delete side's scope boundary — a terminal code is still dropped there too.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func terminalBucketDelete_isStillDropped() async {
        await syncEngine.handleSentRecordZoneChanges(
          failedRecordDeletes: [recordID("delete-quota"): CKError(.quotaExceeded)],
          syncEngine: syncEngine.private
        )

        syncEngine.private.state.assertPendingRecordZoneChanges([])
      }
    }
  }
#endif
