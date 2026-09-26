#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import IssueReporting
  import OrderedCollections
  import SQLiteData
  import Testing

  // MonteSprout fork (41.1): an account-availability transition is not a verdict on the record.
  // Upstream drops `.notAuthenticated` / `.accountTemporarilyUnavailable` failures into the terminal
  // "give up silently" bucket on BOTH the failed-save and failed-delete paths, so a change that is in
  // flight when iCloud signs out, signs in, or has its per-app toggle flipped never reaches the zone
  // — and nothing resumes it until an app relaunch re-enqueues from the ledger (observed on hardware
  // 2026-07-25 during the MonteSprout 1.0(15) device matrix; Sentry 7633019003). The fork re-enqueues
  // the change instead, so CKSyncEngine holds it while the account is unavailable and sends it when
  // availability returns.
  //
  // MonteSprout fork (61.1, patch 17): a FULL iCloud account is not a verdict either. `.quotaExceeded`
  // joins the parked set on both paths — the user frees space and the same change succeeds — and its
  // save reports are collapsed to one per (zone, code) per send (Sentry 7736897474: 45 in a second).
  //
  // Deliberately narrow: only the two transition codes and quota retry. A genuinely restricted or
  // revoked account keeps upstream's give-up behavior — see `managedAccountRestrictedSave_isStillDropped`
  // — and so does quota's nearest sibling, `.limitExceeded` — see `terminalBucketSave_isStillDropped`.
  //
  // Vacuity guard (required by MANGO-PATCHES § Rebase procedure): reverting the patch-6 hunks in
  // `SyncEngine.swift` sends `notAuthenticatedSave_isReEnqueuedForRetry`,
  // `accountTemporarilyUnavailableSave_isReEnqueuedForRetry` and
  // `notAuthenticatedDelete_isReEnqueuedForRetry` RED (nothing is re-enqueued); reverting the patch-17
  // hunks sends `quotaExceededSave_isParked`, `quotaExceededSaves_reportOncePerZoneAndCodePerSend` and
  // `quotaExceededDelete_isReEnqueuedForRetry` RED. Restoring either → green.
  //
  // MANGO PATCH 20 (MonteSprout 91.4): a transient transport error's reports collapse the same way —
  // control flow untouched, wording still a drop. Vacuity guard: moving the six transient codes back
  // into the per-record `reportDroppedSave()` case sends both `…transient…`/`networkFailure…` tests
  // RED (3 reports and 5 reports). Restoring → green.
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
        label: String,
        recordType: String = Reminder.tableName
      ) -> (record: CKRecord, error: CKError) {
        (
          CKRecord(recordType: recordType, recordID: recordID(label)),
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

      /// Patch 17's core guard: a `.quotaExceeded` save is parked, not abandoned — the user frees
      /// space and the SAME save succeeds. The report is pinned by its own wording: distinct from
      /// patch 2's "dropped" and patch 6's "across an account transition", carrying the CKError (so a
      /// reporter keyed on the error's type still sees code 25) and the count.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func quotaExceededSave_isParked() async {
        let recorder = RecordingIssueReporter()
        await withIssueReporters([recorder]) {
          await syncEngine.handleSentRecordZoneChanges(
            failedRecordSaves: [failedSave(.quotaExceeded, label: "save-quota")],
            syncEngine: syncEngine.private
          )
        }

        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(recordID("save-quota"))
        ])
        let reports = recorder.reports.value
        #expect(reports.count == 1)
        #expect(reports.first?.error?.code == .quotaExceeded)
        #expect(
          reports.first?.message.contains(
            "parked 1 failed record save(s) for retry until iCloud storage frees"
          ) == true
        )
        #expect(reports.first?.message.contains("(25)") == true)
        #expect(reports.first?.message.contains("recordTypes=reminders×1") == true)
      }

      /// The collapse: a batch refused at once is ONE report per (zone, code) per send, naming the
      /// count and the record types — never one per record (45 records × one attempt per retry window
      /// would be hundreds of identical events an hour from one full phone). Every save is still
      /// parked individually.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func quotaExceededSaves_reportOncePerZoneAndCodePerSend() async {
        let recorder = RecordingIssueReporter()
        await withIssueReporters([recorder]) {
          await syncEngine.handleSentRecordZoneChanges(
            failedRecordSaves: [
              failedSave(.quotaExceeded, label: "save-quota-1"),
              failedSave(.quotaExceeded, label: "save-quota-2"),
              failedSave(
                .quotaExceeded, label: "save-quota-3", recordType: RemindersList.tableName
              ),
            ],
            syncEngine: syncEngine.private
          )
        }

        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(recordID("save-quota-1")),
          .saveRecord(recordID("save-quota-2")),
          .saveRecord(recordID("save-quota-3")),
        ])
        let reports = recorder.reports.value
        #expect(reports.count == 1)
        #expect(
          reports.first?.message.contains(
            "parked 3 failed record save(s) for retry until iCloud storage frees"
          ) == true
        )
        #expect(
          reports.first?.message.contains("recordTypes=reminders×2,remindersLists×1") == true
        )
      }

      /// Patch 20: a transient transport error inside a batch reports ONCE per (zone, code) per send,
      /// naming the count and the types — never once per record. The control flow is untouched: the
      /// saves stay in patch 2's dropped bucket (nothing re-enqueued), and the wording stays a drop.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func networkFailureSaves_reportOncePerZoneAndCodePerSend() async {
        let recorder = RecordingIssueReporter()
        await withIssueReporters([recorder]) {
          await syncEngine.handleSentRecordZoneChanges(
            failedRecordSaves: [
              failedSave(.networkFailure, label: "save-net-1"),
              failedSave(.networkFailure, label: "save-net-2"),
              failedSave(.networkFailure, label: "save-net-3", recordType: RemindersList.tableName),
            ],
            syncEngine: syncEngine.private
          )
        }

        syncEngine.private.state.assertPendingRecordZoneChanges([])
        let reports = recorder.reports.value
        #expect(reports.count == 1)
        #expect(reports.first?.error?.code == .networkFailure)
        #expect(
          reports.first?.message.contains(
            "dropped 3 failed record save(s) with no retry on a transient error"
          ) == true
        )
        #expect(reports.first?.message.contains("(4)") == true)
        #expect(
          reports.first?.message.contains("recordTypes=reminders×2,remindersLists×1") == true
        )
      }

      /// Patch 20's boundary: each transient code is its own episode, and a code that speaks about
      /// the RECORD (`.limitExceeded`) keeps patch 2's one report per record — so two transient codes
      /// plus two record-level failures are 2 + 2 reports, not 1 and not 5.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func transientCollapse_keepsCodesApart_andLeavesRecordLevelCodesPerRecord() async {
        let recorder = RecordingIssueReporter()
        await withIssueReporters([recorder]) {
          await syncEngine.handleSentRecordZoneChanges(
            failedRecordSaves: [
              failedSave(.networkFailure, label: "save-mix-net-1"),
              failedSave(.serviceUnavailable, label: "save-mix-svc"),
              failedSave(.networkFailure, label: "save-mix-net-2"),
              failedSave(.limitExceeded, label: "save-mix-limit-1"),
              failedSave(.limitExceeded, label: "save-mix-limit-2"),
            ],
            syncEngine: syncEngine.private
          )
        }

        syncEngine.private.state.assertPendingRecordZoneChanges([])
        let reports = recorder.reports.value
        #expect(reports.count == 4)
        #expect(
          reports.filter {
            $0.message.contains("dropped a failed record save with no retry")
              && $0.error?.code == .limitExceeded
          }.count == 2
        )
        #expect(
          reports.contains {
            $0.message.contains("dropped 2 failed record save(s) with no retry on a transient error")
              && $0.error?.code == .networkFailure
          }
        )
        #expect(
          reports.contains {
            $0.message.contains("dropped 1 failed record save(s) with no retry on a transient error")
              && $0.error?.code == .serviceUnavailable
          }
        )
      }

      /// The scope boundary, and the half that must NOT drift: quota's nearest sibling in the terminal
      /// bucket (`.limitExceeded` — a request too large, which resending cannot shrink) still reports
      /// and still gives up. Without this, widening the retry set later would pass unnoticed.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func terminalBucketSave_isStillDropped() async {
        await withKnownIssue {
          await syncEngine.handleSentRecordZoneChanges(
            failedRecordSaves: [failedSave(.limitExceeded, label: "save-limit")],
            syncEngine: syncEngine.private
          )
        }

        syncEngine.private.state.assertPendingRecordZoneChanges([])
      }

      /// A permanently restricted account is not a transition — it keeps upstream's give-up behavior,
      /// because retrying it could never succeed. This is patch 6's (and patch 17's) boundary example.
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

      /// Patch 17's delete half: a delete refused under a full account is re-enqueued too, or the next
      /// fetch would resurrect the row. Silent, like patch 6's delete half.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func quotaExceededDelete_isReEnqueuedForRetry() async {
        await syncEngine.handleSentRecordZoneChanges(
          failedRecordDeletes: [recordID("delete-quota"): CKError(.quotaExceeded)],
          syncEngine: syncEngine.private
        )

        syncEngine.private.state.assertPendingRecordZoneChanges([
          .deleteRecord(recordID("delete-quota"))
        ])
      }

      /// The delete side's scope boundary — a terminal code is still dropped there too.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func terminalBucketDelete_isStillDropped() async {
        await syncEngine.handleSentRecordZoneChanges(
          failedRecordDeletes: [recordID("delete-managed"): CKError(.managedAccountRestricted)],
          syncEngine: syncEngine.private
        )

        syncEngine.private.state.assertPendingRecordZoneChanges([])
      }
    }
  }

  /// Records every issue reported inside a `withIssueReporters([recorder]) { … }` scope, so a test can
  /// assert on the COUNT of reports (which `withKnownIssue` cannot — it absorbs any number).
  private final class RecordingIssueReporter: IssueReporter, Sendable {
    struct Report: Sendable {
      let error: CKError?
      let message: String
    }

    let reports = LockIsolated<[Report]>([])

    func reportIssue(
      _ message: @autoclosure () -> String?,
      severity: IssueSeverity,
      fileID: StaticString,
      filePath: StaticString,
      line: UInt,
      column: UInt
    ) {
      let message = message() ?? ""
      reports.withValue { $0.append(Report(error: nil, message: message)) }
    }

    func reportIssue(
      _ error: any Error,
      _ message: @autoclosure () -> String?,
      fileID: StaticString,
      filePath: StaticString,
      line: UInt,
      column: UInt
    ) {
      let message = message() ?? ""
      reports.withValue { $0.append(Report(error: error as? CKError, message: message)) }
    }
  }
#endif
