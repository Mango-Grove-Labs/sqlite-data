#if canImport(CloudKit)
  import CloudKit
  import OrderedCollections
  import SQLiteData
  import Testing

  // MontiSprout fork (27.6c): a CASCADE parent-reference violation on a *save* means the child's
  // parent hasn't landed in the zone YET — not that the child should be destroyed. Upstream
  // local-DELETEs the child inside the failed-save handler, which surfaces as user rows that appear
  // and then vanish (a local-first data-loss bug). The fork instead mirrors the failed-*delete*
  // handler: it parks the child in `UnsyncedRecordID` and re-enqueues its save so the row lands once
  // the parent syncs. The non-destructive FK actions (setNull/setDefault) keep upstream behavior.
  //
  // Why a dedicated test: the existing end-to-end `ReferenceViolationTests` all DELETE the parent, so
  // SQLite's own local `ON DELETE CASCADE` removes the child regardless of what the CloudKit handler
  // does — masking the handler's park-vs-delete behavior. That is exactly why the guard shipped with
  // no failing test and a future rebase could silently drop it. These tests inject the failed save
  // DIRECTLY into `handleSentRecordZoneChanges` with the parent still present locally (as
  // `DroppedSaveReportingTests` does), isolating the handler's behavior.
  //
  // Vacuity guard (required by ROADMAP Phase 32.1): reverting the `foreignKey.onDelete == .cascade`
  // park hunk in `SyncEngine.swift` makes `cascadeChild_isParkedAndReEnqueued_notDeleted` go RED —
  // the child is local-deleted, nothing is parked, and nothing is re-enqueued. Restoring it → green.
  extension BaseCloudKitTests {
    @MainActor
    final class ReferenceViolationGuardTests: BaseCloudKitTests, @unchecked Sendable {
      /// The core guard (ROADMAP assertions 1–3): a `.referenceViolation` save on a CASCADE child
      /// (1) leaves the child row intact locally, (2) parks it in `UnsyncedRecordID`, and
      /// (3) re-enqueues its `.saveRecord`.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func cascadeChild_isParkedAndReEnqueued_notDeleted() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        // Flush the seed to the mock server so the pending-changes slate is clean before we inject
        // the failure — the only pending change afterward is the guard's own re-enqueue.
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let failedReminder = CKRecord(
          recordType: Reminder.tableName,
          recordID: Reminder.recordID(for: 1)
        )
        await syncEngine.handleSentRecordZoneChanges(
          failedRecordSaves: [(failedReminder, CKError(.referenceViolation))],
          syncEngine: syncEngine.private
        )

        // (1) The child row is NOT destroyed — the whole point of the guard.
        try await userDatabase.read { db in
          try #expect(
            Reminder.all.fetchAll(db) == [Reminder(id: 1, title: "Get milk", remindersListID: 1)]
          )
        }
        // (2) It is parked as unsynced so a later reconcile knows to re-send it.
        try await syncEngine.metadatabase.read { db in
          try #expect(UnsyncedRecordID.find(Reminder.recordID(for: 1)).fetchCount(db) == 1)
        }
        // (3) Its save is re-enqueued so it lands once the parent syncs. (Asserting also drains the
        // pending set, satisfying the harness's empty-pending-changes teardown invariant.)
        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(Reminder.recordID(for: 1))
        ])

        // Clear the park so the harness's `UnsyncedRecordID.count() == 0` teardown invariant holds.
        try await userDatabase.write { db in
          try UnsyncedRecordID.find(Reminder.recordID(for: 1)).delete().execute(db)
        }
      }

      /// ROADMAP assertion 4 (SET NULL half): a `.referenceViolation` save on a `ON DELETE SET NULL`
      /// child keeps upstream behavior — the FK column is nulled in place, the row is neither parked
      /// nor re-enqueued.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func setNullChild_isNulledInPlace_notParked() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            Parent(id: 1)
            ChildWithOnDeleteSetNull(id: 1, parentID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let failedChild = CKRecord(
          recordType: ChildWithOnDeleteSetNull.tableName,
          recordID: ChildWithOnDeleteSetNull.recordID(for: 1)
        )
        await syncEngine.handleSentRecordZoneChanges(
          failedRecordSaves: [(failedChild, CKError(.referenceViolation))],
          syncEngine: syncEngine.private
        )

        try await userDatabase.read { db in
          try #expect(
            ChildWithOnDeleteSetNull.all.fetchAll(db) == [
              ChildWithOnDeleteSetNull(id: 1, parentID: nil)
            ]
          )
        }
        try await syncEngine.metadatabase.read { db in
          try #expect(
            UnsyncedRecordID.find(ChildWithOnDeleteSetNull.recordID(for: 1)).fetchCount(db) == 0
          )
        }
        // Not parked (the distinguishing behavior vs. the CASCADE guard): its save is re-enqueued to
        // push the now-nulled FK up, exactly as upstream. (Asserting also drains the pending set.)
        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(ChildWithOnDeleteSetNull.recordID(for: 1))
        ])
      }

      /// ROADMAP assertion 4 (SET DEFAULT half): a `.referenceViolation` save on a `ON DELETE SET
      /// DEFAULT` child keeps upstream behavior — the FK column is reset to its default in place, the
      /// row is neither parked nor re-enqueued.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func setDefaultChild_isResetToDefaultInPlace_notParked() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            Parent(id: 0)
            Parent(id: 1)
            ChildWithOnDeleteSetDefault(id: 1, parentID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let failedChild = CKRecord(
          recordType: ChildWithOnDeleteSetDefault.tableName,
          recordID: ChildWithOnDeleteSetDefault.recordID(for: 1)
        )
        await syncEngine.handleSentRecordZoneChanges(
          failedRecordSaves: [(failedChild, CKError(.referenceViolation))],
          syncEngine: syncEngine.private
        )

        try await userDatabase.read { db in
          try #expect(
            ChildWithOnDeleteSetDefault.all.fetchAll(db) == [
              ChildWithOnDeleteSetDefault(id: 1, parentID: 0)
            ]
          )
        }
        try await syncEngine.metadatabase.read { db in
          try #expect(
            UnsyncedRecordID.find(ChildWithOnDeleteSetDefault.recordID(for: 1)).fetchCount(db) == 0
          )
        }
        // Not parked (as above): its save is re-enqueued to push the reset FK up, exactly as
        // upstream. (Asserting also drains the pending set.)
        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(ChildWithOnDeleteSetDefault.recordID(for: 1))
        ])
      }

      // ROADMAP assertion 5 (the failed-*delete* `.referenceViolation` park idiom the save-guard
      // mirrors is unchanged) is left to the existing end-to-end coverage: the patch touches ONLY the
      // failed-*save* CASCADE branch (see the 94ca01d diff), and `ReferenceViolationTests`'
      // `deleteList_RemoteAddsReminderToList` / `…_Variation` already exercise the failed-delete
      // park path and stay green. A direct `handleSentRecordZoneChanges(failedRecordDeletes:)`
      // injection is not equivalent here — its trailing `handleFetchedRecordZoneChanges` reconciles
      // away a park for a record with no local row/metadata, which the end-to-end tests avoid.
    }
  }
#endif
