#if canImport(CloudKit)
  import CloudKit
  import Dependencies
  import SQLiteData
  import Testing

  // MANGO 5.3b — the durable pending ledger is ALWAYS-ON.
  //
  // Upstream writes the `PendingRecordZoneChange` table only while the engine is STOPPED; a change
  // made while it runs lives solely in CKSyncEngine's in-memory state until the next state
  // serialization. That window is exactly what stranded the consumer's S5 matrix rows in the two
  // shapes patch 9's targeted rescan cannot see: an edit to a slim-acked row (confirmed, NULL
  // mirror) and a DELETE. 5.3b makes the ledger write on every local change, clear on every sent
  // outcome (success or failure — the failure handlers then re-enqueue through the ledger), and
  // drain at start via the existing `enqueueLocallyPendingChanges`.
  //
  // ⚠️ Patch 15 narrowed the first of those shapes on a real device — a row that went through the
  // batch builder now leaves its slim ack with a real mirror, so a later edit to it IS mirror-behind
  // and the rescan does see it. The ledger is still the only guard for a change that dies BEFORE its
  // ack, which is what these tests kill. The NULL-mirror row below is made by injecting an ack with
  // no batch build.
  //
  // The kill shape is `stop()` → `start()` as in EngineStartRescanTests: the mock engines and
  // their in-memory pending state die with `stop()`, while the durable ledger survives.
  //
  // The ledger write from a local change is an unstructured Task (the sync trigger cannot write
  // re-entrantly from inside the user's transaction — upstream's own TODO), so tests settle the
  // ledger to an expected count before killing; the settle is quiet on timeout and the assertion
  // that follows carries the verdict.
  extension BaseCloudKitTests {
    @MainActor
    final class DurablePendingLedgerTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func ledgerCount() async throws -> Int {
        try await syncEngine.metadatabase.read { db in
          try Int.fetchOne(
            db,
            sql: #"SELECT count(*) FROM "sqlitedata_icloud_pendingRecordZoneChanges""#
          ) ?? -1
        }
      }

      /// Waits (bounded, quiet) for the async ledger write to land; assertions after it decide.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func settleLedger(at expected: Int) async throws {
        for _ in 0..<200 {
          if try await ledgerCount() == expected { return }
          try await Task.sleep(for: .milliseconds(10))
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func mirroredServerStamp(id: Int) async throws -> Int64? {
        try await syncEngine.metadatabase.read { db in
          try Int64.fetchOne(
            db,
            sql: """
              SELECT "serverUserModificationTime" FROM "sqlitedata_icloud_metadata"
               WHERE "recordPrimaryKey" = '\(id)' AND "recordType" = 'remindersLists'
              """
          )
        }
      }

      /// S5 shape one: an edit to a slim-acked row (confirmed, NULL mirror — patch 9's rescan is
      /// structurally blind to it) killed mid-flight must survive the process via the ledger.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aKilledEditOnASlimAckedRowIsReEnqueuedAtStart() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        try await settleLedger(at: 1)
        // The slim ack confirms the row (NULL mirror) and, being a sent outcome, clears its
        // ledger row.
        let slimAck = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1)
        )
        await syncEngine.handleSentRecordZoneChanges(
          savedRecords: [slimAck],
          syncEngine: syncEngine.private
        )
        try await settleLedger(at: 0)
        #expect(try await mirroredServerStamp(id: 1) == nil)  // the rescan-blind shape
        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(RemindersList.recordID(for: 1))
        ])

        // The edit whose save will die with the process.
        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Renamed" }.execute(db)
          }
        }
        try await settleLedger(at: 1)
        syncEngine.stop()
        try await syncEngine.start()
        syncEngine.private.state.assertPendingDatabaseChanges([
          .saveZone(SyncEngine.defaultTestZone)
        ])

        // The ledger drain re-enqueued the edit; a full round trip lands it and clears the row.
        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(RemindersList.recordID(for: 1))
        ])
      }

      /// S5 shape two: a DELETE killed mid-flight must survive the process — without the ledger
      /// the server copy outlives the tombstone and the next fetch resurrects the deleted row.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aKilledDeleteIsReEnqueuedAtStart() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await settleLedger(at: 0)  // the ack resolved the seed's ledger row

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }
        try await settleLedger(at: 1)
        syncEngine.stop()
        try await syncEngine.start()
        syncEngine.private.state.assertPendingDatabaseChanges([
          .saveZone(SyncEngine.defaultTestZone)
        ])

        syncEngine.private.state.assertPendingRecordZoneChanges([
          .deleteRecord(RemindersList.recordID(for: 1))
        ])
      }

      /// The lifecycle contract: a local change lands in the ledger, and EVERY sent outcome clears
      /// it — rows never accumulate past their resolution.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func theLedgerClearsOnResolution() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        try await settleLedger(at: 1)
        #expect(try await ledgerCount() == 1)

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await settleLedger(at: 0)
        #expect(try await ledgerCount() == 0)

        // An edit and its round trip: written, then resolved.
        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Renamed" }.execute(db)
          }
        }
        try await settleLedger(at: 1)
        #expect(try await ledgerCount() == 1)
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await settleLedger(at: 0)
        #expect(try await ledgerCount() == 0)
      }
    }
  }
#endif
