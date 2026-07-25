#if canImport(CloudKit)
  import CloudKit
  import OrderedCollections
  import SQLiteData
  import Testing

  // MANGO PATCH 5 — the resetFresh false-success. MontiSprout
  // `docs/incidents/2026-07-20-resetfresh-left-local-data-cross-env.md`: on-device, a full reset
  // reported success, erased the sync metadata and re-created the zone — and left EVERY local row
  // in place with its pre-reset `updatedAt`.
  //
  // Pre-patch mechanism (proven by the pre-flip version of this test, 2026-07-25): upstream's
  // `deleteLocalData()` wrapped its row-clearing write in `withErrorReporting`, which reports and
  // SWALLOWS. Any failure inside that write — including `setUpSyncEngine(writableDB:)` throwing at
  // the end, which rolls back every per-table delete in the same transaction — left the function
  // returning cleanly over a database that still held all of its rows, with the metadatabase
  // already erased by `tearDownSyncEngine()`.
  //
  // Patched contract, pinned here: a failed clear THROWS (no reported-issue side channel), and the
  // engine stays stopped (the rollback removed the sync triggers — a running engine would track
  // nothing). Reverting patch 5 makes `failedClearThrows` go red (the call returns cleanly and
  // reports issues instead).
  extension BaseCloudKitTests {
    @MainActor
    final class DeleteLocalDataFailureTests: BaseCloudKitTests, @unchecked Sendable {
      /// A failure inside the clearing write surfaces as a throw. The rows still survive (the
      /// transaction rolls back — SQLite semantics, not a choice) and the metadatabase is already
      /// erased, but the caller now KNOWS, instead of reporting success over a half-reset.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func failedClearThrows() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        // Sabotage one rostered table so the clearing write fails mid-flight: the per-table
        // `DELETE` on it throws, and even if it didn't, `setUpSyncEngine(writableDB:)` would
        // throw re-creating its triggers — rolling back the whole write.
        try await userDatabase.write { db in
          try #sql("ALTER TABLE \"remindersLists\" RENAME TO \"remindersLists_broken\"")
            .execute(db)
        }

        var thrownError: (any Error)?
        do {
          try await syncEngine.deleteLocalData()
        } catch {
          thrownError = error
        }

        // The failure is the caller's to see.
        #expect(thrownError != nil)

        // …and the engine stays stopped, which is the other half of the patched contract: the
        // rollback took the sync triggers with it, so a running engine would track nothing.
        // (The harness's teardown pending-changes invariant catches a restart too — via the
        // `.saveZone` it would enqueue — but that is incidental; this states the intent.)
        #expect(syncEngine.isRunning == false)

        // The rolled-back transaction leaves every row, in the broken table and the healthy
        // ones alike…
        try await userDatabase.read { db in
          try #expect(Reminder.count().fetchOne(db) == 1)
          let survivors =
            try #sql(#"SELECT count(*) FROM "remindersLists_broken""#, as: Int.self)
            .fetchOne(db)
          #expect(survivors == 1)
        }

        // …and the metadatabase is already erased — which is exactly why the caller must know:
        // the surviving rows are no longer tracked by anything.
        try await syncEngine.metadatabase.read { db in
          try #expect(SyncMetadata.count().fetchOne(db) == 0)
        }
      }

      /// The happy path, called directly (the existing coverage only reaches this method through
      /// the sign-out handler): every synced table cleared, metadatabase cleared, engine restarted.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func directCallClearsAndRestarts() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await syncEngine.deleteLocalData()

        try await userDatabase.read { db in
          try #expect(RemindersList.count().fetchOne(db) == 0)
          try #expect(Reminder.count().fetchOne(db) == 0)
        }
        try await syncEngine.metadatabase.read { db in
          try #expect(SyncMetadata.count().fetchOne(db) == 0)
        }

        // The "AndRestarts" half of the name, stated rather than implied.
        #expect(syncEngine.isRunning == true)

        // Drain the restarted engine's re-scheduled zone save (fresh metadatabase → it wants its
        // zone back) so the harness teardown invariants hold.
        syncEngine.private.state.assertPendingDatabaseChanges([
          .saveZone(SyncEngine.defaultTestZone)
        ])
      }
    }
  }
#endif
