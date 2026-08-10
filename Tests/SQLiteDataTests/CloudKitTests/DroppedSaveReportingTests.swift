#if canImport(CloudKit)
  import CloudKit
  import SQLiteData
  import Testing

  // MonteSprout fork (27.4d): the failed-*save* handler abandons several CKError buckets with no retry
  // and no signal (a record that fails there never reaches CloudKit, invisibly). The fork now
  // `reportIssue`s every such dropped save with its CKError so the host's IssueReporting→Sentry bridge
  // can NAME the otherwise-unnamed error. These tests inject a failed save directly into
  // `handleSentRecordZoneChanges` and assert an issue is reported — `withKnownIssue` fails if none is.
  extension BaseCloudKitTests {
    @MainActor
    final class DroppedSaveReportingTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func failedSave(_ code: CKError.Code) -> (record: CKRecord, error: CKError) {
        let recordID = CKRecord.ID(
          recordName: "dropped-save-\(code.rawValue)",
          zoneID: SyncEngine.defaultTestZone.zoneID
        )
        return (CKRecord(recordType: "reminders", recordID: recordID), CKError(code))
      }

      /// The `.serverRejectedRequest` branch (clears the server record, then abandons the save).
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func serverRejectedRequest_reportsDroppedSave() async {
        await withKnownIssue {
          await syncEngine.handleSentRecordZoneChanges(
            failedRecordSaves: [failedSave(.serverRejectedRequest)],
            syncEngine: syncEngine.private
          )
        }
      }

      /// A member of the terminal "give up silently" bucket — reported generically (no per-code
      /// special-casing), which is what lets this surface the tester's still-unnamed error.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func terminalBucket_reportsDroppedSave() async {
        await withKnownIssue {
          await syncEngine.handleSentRecordZoneChanges(
            failedRecordSaves: [failedSave(.quotaExceeded)],
            syncEngine: syncEngine.private
          )
        }
      }
    }
  }
#endif
