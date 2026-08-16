#if canImport(CloudKit)
  import CloudKit
  import Dependencies
  import SQLiteData
  import Testing

  // MANGO PATCH 9 (MonteSprout F10, the 1.0(16) matrix's hard failure) — a stranded row must be
  // rescanned at engine start.
  //
  // While the engine runs, a local write's pending save lives only in CKSyncEngine's in-memory
  // state (durable `PendingRecordZoneChange` rows are written only while the engine is *stopped*).
  // A process death inside that window loses the change, and on the 1.9 base nothing at `start()`
  // rescans the ledger — the row is stranded silently and permanently while `pending = 0` reads
  // honest-but-blind. The patch re-enqueues, at start, exactly the rows the ledger already knows
  // are stranded: never confirmed (`lastKnownServerRecord IS NULL`) plus mirror-behind
  // (`serverUserModificationTime < userModificationTime`, patch 7's mirror) — live rows only.
  //
  // The kill shape below is `stop()` → `start()`: `stop()` discards the engines and, in the mock,
  // their in-memory pending state with them — the same loss a force-quit produces — while the
  // durable table stays empty because the write happened on a *running* engine.
  //
  // The boundary is as load-bearing as the rescan: a confirmed row whose mirror is NULL (the
  // slim-ack shape patch 7's F2 amendment leaves behind on real CloudKit) must NOT be selected —
  // NULL is "unknown", and selecting it would degrade the targeted rescan into exactly the
  // blanket reupload the consumer ruled out (stamp-stomp risk, blob rewrite cost, fleet re-fetch).
  extension BaseCloudKitTests {
    @MainActor
    final class EngineStartRescanTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func lastKnownServerRecordExists() async throws -> Bool {
        try await syncEngine.metadatabase.read { db in
          try Bool.fetchOne(
            db,
            sql: #"""
              SELECT count(*) FROM "sqlitedata_icloud_metadata"
               WHERE "recordPrimaryKey" = '1' AND "recordType" = 'remindersLists'
                 AND "lastKnownServerRecord" IS NOT NULL
              """#
          ) ?? false
        }
      }

      /// The mirror and local stamps, read via SQL (never the archived record).
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func stamps(id: Int) async throws -> (local: Int64, mirror: Int64?) {
        try await syncEngine.metadatabase.read { db in
          let row = try SyncMetadata
            .find(RemindersList.recordID(for: id))
            .select { ($0.userModificationTime, $0.serverUserModificationTime) }
            .fetchOne(db)
          return (row?.0 ?? -1, row?.1)
        }
      }

      /// F10's exact field shape: a row created while the engine runs, whose in-flight save dies
      /// with the process. At the next start the ledger's never-confirmed row must be re-enqueued
      /// and land — relaunch heals, no manual reupload.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aKilledNeverConfirmedSaveIsReEnqueuedAtStart() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        // The kill: the pending save exists only in the engines' in-memory state, which stop()
        // discards — the durable pending table was never written (the engine was running).
        syncEngine.stop()
        try await syncEngine.start()
        // Drain the restarted engine's re-scheduled zone save (DeleteLocalDataFailureTests idiom).
        syncEngine.private.state.assertPendingDatabaseChanges([
          .saveZone(SyncEngine.defaultTestZone)
        ])

        // The rescan re-enqueued the never-confirmed row; a normal send round then lands it.
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(try await lastKnownServerRecordExists())
      }

      /// The mirror-behind half: an edit to an already-synced row whose save dies with the
      /// process. Patch 7's mirror is what makes the row selectable at all.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aKilledUnsentEditIsReEnqueuedAtStart() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        var s = try await stamps(id: 1)
        #expect(s.mirror == s.local)  // confirmed and in sync

        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Renamed" }.execute(db)
          }
        }
        syncEngine.stop()
        try await syncEngine.start()
        syncEngine.private.state.assertPendingDatabaseChanges([
          .saveZone(SyncEngine.defaultTestZone)
        ])

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        s = try await stamps(id: 1)
        #expect(s.mirror == s.local)  // the stranded edit landed and the mirror caught up
      }

      /// The targeted/blanket boundary: neither an in-sync row nor a confirmed row whose mirror
      /// is NULL (the slim-ack shape) may be re-enqueued by a restart. NULL is "unknown", never a
      /// rescan trigger.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func confirmedRowsAreNotRescannedAtStart() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        // Row 2 becomes the slim-ack shape: confirmed (lastKnownServerRecord set) with a NULL
        // mirror, exactly what the F2 amendment leaves on a real device.
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 2, title: "Work") }
        }
        let slimAck = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 2)
        )
        await syncEngine.handleSentRecordZoneChanges(
          savedRecords: [slimAck],
          syncEngine: syncEngine.private
        )
        let s = try await stamps(id: 2)
        #expect(s.mirror == nil)
        // Drain row 2's still-pending in-memory save so the restart starts from a clean set.
        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(RemindersList.recordID(for: 2))
        ])

        syncEngine.stop()
        try await syncEngine.start()
        syncEngine.private.state.assertPendingDatabaseChanges([
          .saveZone(SyncEngine.defaultTestZone)
        ])

        // Neither row is stranded by the ledger's own account: nothing may be re-enqueued.
        syncEngine.private.state.assertPendingRecordZoneChanges([])
      }
    }
  }
#endif
