#if canImport(CloudKit)
  import CloudKit
  import Dependencies
  import OrderedCollections
  import SQLiteData
  import Testing

  // MontiSprout Phase 41.2a — why "pending = 0" can be honest and still hide unsent data.
  //
  // Consumers derive their "waiting to upload" number from the metadata's server record: MontiSprout's sync
  // doctor counts `lastKnownServerRecord IS NULL AND _isDeleted = 0`, and MangoSync's `UploadTruth` derives
  // `unconfirmed` from the same fact via `hasLastKnownServerRecord`. Both therefore measure **"has this row
  // EVER reached the server"** — not "are this row's current bytes on the server".
  //
  // That distinction has a blind spot with a name: an **update to an already-synced row**. The local write
  // trigger bumps `userModificationTime` and deliberately leaves `lastKnownServerRecord` alone (it still holds
  // the previous server version), so a save that never lands leaves every never-confirmed count reading **0**
  // while the edit is genuinely unsent. This is a **characterization** test — it pins library behavior the two
  // consumer probes depend on, and it is the third mechanism the 1.0(15) matrix's `pending=0`-while-unsent
  // reading could have been (the other two: a record dropped before its first upload, which these counts DO
  // see, and an acked record whose visibility stalled on the fetch side).
  //
  // It also pins the discriminator that *would* see it, for whoever implements that probe: the metadata's
  // `userModificationTime` versus the **all-fields** server record's own. A successful save stamps the server
  // record from the metadata, so the two are equal after a round trip and diverge exactly while an edit is
  // unsent. Note it must be `_lastKnownServerRecordAllFields`: `userModificationTime` lives in
  // `encryptedValues`, which `lastKnownServerRecord`'s system-fields archive does not carry.
  extension BaseCloudKitTests {
    @MainActor
    final class UnsentUpdateVisibilityTests: BaseCloudKitTests, @unchecked Sendable {
      /// Mirrors MontiSprout's sync-doctor query verbatim — the number that read 0 on the device.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func recordsAwaitingUpload() async throws -> Int {
        try await syncEngine.metadatabase.read { db in
          try Int.fetchOne(
            db,
            sql: #"""
              SELECT count(*) FROM "sqlitedata_icloud_metadata"
               WHERE "lastKnownServerRecord" IS NULL AND "_isDeleted" = 0
              """#
          ) ?? -1
        }
      }

      /// Patch 7's mirrored column, read as SQL sees it — deliberately NOT via the archived record, so a
      /// test of the mirror cannot pass by accidentally reading the thing the mirror copies.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func mirroredServerStamp() async throws -> Int64? {
        try await syncEngine.metadatabase.read { db in
          try Int64.fetchOne(
            db,
            sql: #"""
              SELECT "serverUserModificationTime" FROM "sqlitedata_icloud_metadata"
               WHERE "recordPrimaryKey" = '1' AND "recordType" = 'remindersLists'
              """#
          )
        }
      }

      /// The metadata's own modification time and the one archived in the all-fields server record.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func modificationTimes() async throws -> (local: Int64, server: Int64?) {
        try await syncEngine.metadatabase.read { db in
          let row = try SyncMetadata
            .find(RemindersList.recordID(for: 1))
            .select { ($0.userModificationTime, $0._lastKnownServerRecordAllFields) }
            .fetchOne(db)
          return (row?.0 ?? -1, row?.1?.userModificationTime)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func anUnsentUpdateIsInvisibleToEveryNeverConfirmedCount() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        // One full round trip: the row now has a server record, so nothing is "awaiting upload"…
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(try await recordsAwaitingUpload() == 0)
        // …and the two modification times agree, because the save stamped the server record from the metadata.
        let synced = try await modificationTimes()
        #expect(synced.server == synced.local)

        // A local edit, clock advanced, and NO sync round after it.
        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Renamed" }.execute(db)
          }
        }

        // The blind spot, stated as an assertion: the edit is unsent, and the count says zero.
        #expect(try await recordsAwaitingUpload() == 0)

        // The discriminator that does see it — local time has moved past the server's.
        let edited = try await modificationTimes()
        #expect(edited.local > synced.local)
        #expect(edited.server == synced.server)  // the server record is untouched by a local write
        #expect(edited.server! < edited.local)

        // The engine itself does know: the save is pending. (Asserting also drains the pending set,
        // satisfying the harness's empty-pending-changes teardown invariant.)
        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(RemindersList.recordID(for: 1))
        ])
      }

      /// Patch 7's column, end to end: `nil` before the first upload, equal to the local stamp after a
      /// round trip, behind it exactly while an edit is unsent, and level again once that edit lands.
      /// This is the whole point of the mirror — the state above becomes an ordinary SQL predicate.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func theMirroredServerStampMakesAnUnsentEditCountable() async throws {
        /// The consumer-side predicate this column exists to enable.
        func unsentEdits() async throws -> Int {
          try await syncEngine.metadatabase.read { db in
            try Int.fetchOne(
              db,
              sql: #"""
                SELECT count(*) FROM "sqlitedata_icloud_metadata"
                 WHERE "lastKnownServerRecord" IS NOT NULL
                   AND "serverUserModificationTime" < "userModificationTime"
                   AND "_isDeleted" = 0
                """#
            ) ?? -1
          }
        }

        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        // Never uploaded: no server record, so no mirrored stamp — and nothing to call an *edit* yet
        // (the existing "never confirmed" counts already see this row).
        #expect(try await mirroredServerStamp() == nil)
        #expect(try await unsentEdits() == 0)

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        var times = try await modificationTimes()
        #expect(times.server == times.local)  // in sync after the round trip
        #expect(try await mirroredServerStamp() == times.local)  // …and the mirror agrees with the archive
        #expect(try await unsentEdits() == 0)

        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Renamed" }.execute(db)
          }
        }
        times = try await modificationTimes()
        #expect(times.server! < times.local)
        #expect(try await unsentEdits() == 1)  // the reading the old counts could not produce

        // …and it goes back to zero on its own once the edit reaches the server.
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        times = try await modificationTimes()
        #expect(times.server == times.local)
        #expect(try await unsentEdits() == 0)
      }

      /// Clearing the server record must clear the mirror with it — a leftover stamp would read as "in
      /// sync" with a server copy that no longer exists. Driven through the real path that clears
      /// (`.serverRejectedRequest`, whose handler calls `setLastKnownServerRecord(nil)`) rather than the
      /// helper, so it pins the behavior a consumer actually meets.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func clearingTheServerRecordClearsTheMirror() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(try await mirroredServerStamp() != nil)

        let failed = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1)
        )
        // The handler reports the dropped save (patch 2), hence `withKnownIssue`.
        await withKnownIssue {
          await syncEngine.handleSentRecordZoneChanges(
            failedRecordSaves: [(failed, CKError(.serverRejectedRequest))],
            syncEngine: syncEngine.private
          )
        }

        #expect(try await mirroredServerStamp() == nil)
      }
    }
  }
#endif
