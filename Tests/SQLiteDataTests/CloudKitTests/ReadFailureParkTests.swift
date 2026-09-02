#if canImport(CloudKit)
  import CloudKit
  import Dependencies
  import Foundation
  import GRDB
  import SQLiteData
  import Testing

  // MANGO PATCH 8 — a failed READ in the send path is not a deletion.
  //
  // `nextRecordZoneChangeBatch` builds each outgoing record from two reads: the record's metadata row
  // and the user-table row itself. Upstream ran both through `withErrorReporting(…) ?? nil` and then
  // dropped the pending change on `nil` — a value reached both by "the read threw" and by "there is
  // no such row". The record left the upload queue permanently, and since its shape never changed,
  // nothing ever put it back: that is the amplifier that turned the 1.0(12) decode bug into six days
  // of silent, unrecoverable upload loss (MANGO-PATCHES § 3 for the trigger, § 8 for this).
  //
  // Patch 3 removed the *trigger* of that era. These tests pin the *amplifier's* removal, with the
  // failure injected as a corrupt row — the class § 8 names alongside schema changes and lock
  // timeouts, and the only one reproducible in-process:
  //
  //   * metadata read — a garbage `_lastKnownServerRecordAllFields` blob, which `NSKeyedUnarchiver`
  //     rejects, so the send path's own `SyncMetadata` query throws.
  //   * user-table read — an unparseable `dueDate` string, which the `Date` decode rejects.
  //
  // Both must leave the pending change in the engine's state (and the durable ledger untouched), so
  // the very next send retries it; both must upload normally once the corruption is repaired. The
  // guard is vacuity-checked by restoring the drop in either branch — the repaired send then finds
  // nothing pending and the server keeps the stale record.
  extension BaseCloudKitTests {
    @MainActor
    final class ReadFailureParkTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func ledgerCount() async throws -> Int {
        try await syncEngine.metadatabase.read { db in
          try Int.fetchOne(
            db,
            sql: #"SELECT count(*) FROM "sqlitedata_icloud_pendingRecordZoneChanges""#
          ) ?? -1
        }
      }

      /// Waits (bounded, quiet) for 5.3b's unstructured ledger write to land; the assertion that
      /// follows carries the verdict. Same idiom as `DurablePendingLedgerTests`.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func settleLedger(at expected: Int) async throws {
        for _ in 0..<200 {
          if try await ledgerCount() == expected { return }
          try await Task.sleep(for: .milliseconds(10))
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func serverTitle(listID: Int) throws -> String? {
        try syncEngine.private.database
          .record(for: RemindersList.recordID(for: listID))
          .encryptedValues["title"] as? String
      }

      /// The metadata read: a corrupt archive must park the record, not retire it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aFailedMetadataReadParksTheRecord() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(try serverTitle(listID: 1) == "Personal")

        // The edit that must survive the failed read.
        try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Personal 2" }.execute(db)
          }
        }

        // Corrupt the all-fields archive the send path decodes. Keep the original bytes so the
        // repair below restores the row exactly — a NULLed archive would send a record with no
        // change tag, which `.ifServerRecordUnchanged` rejects for unrelated reasons.
        let archive = try await syncEngine.metadatabase.read { db in
          try Data.fetchOne(
            db,
            sql: """
              SELECT "_lastKnownServerRecordAllFields" FROM "sqlitedata_icloud_metadata"
               WHERE "recordPrimaryKey" = '1' AND "recordType" = 'remindersLists'
              """
          )
        }
        #expect(archive != nil, "precondition: the row really has an archive to corrupt")
        try await syncEngine.metadatabase.write { db in
          try db.execute(
            sql: """
              UPDATE "sqlitedata_icloud_metadata" SET "_lastKnownServerRecordAllFields" = X'DEADBEEF'
               WHERE "recordPrimaryKey" = '1' AND "recordType" = 'remindersLists'
              """
          )
        }

        try await settleLedger(at: 1)  // the edit's durable ledger row
        await withKnownIssue {
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        }

        // Parked, not dropped: still queued, still in the ledger, and the server untouched.
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges.contains(
            .saveRecord(RemindersList.recordID(for: 1))
          ),
          "a record whose metadata read FAILED must stay in the upload queue"
        )
        #expect(try await ledgerCount() == 1, "the durable ledger row must survive a parked read")
        #expect(try serverTitle(listID: 1) == "Personal")

        // Repaired, the very next send delivers the edit — no relaunch, no re-enqueue.
        try await syncEngine.metadatabase.write { [archive] db in
          try db.execute(
            sql: """
              UPDATE "sqlitedata_icloud_metadata" SET "_lastKnownServerRecordAllFields" = ?
               WHERE "recordPrimaryKey" = '1' AND "recordType" = 'remindersLists'
              """,
            arguments: [archive]
          )
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(try serverTitle(listID: 1) == "Personal 2")
      }

      /// The user-table read, one read later in the same closure: same conflation, same fix.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aFailedRecordReadParksTheRecord() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        // An unparseable date makes the send path's `Reminder` decode throw — a corrupt row, exactly
        // the failure § 8 says must never look like a deletion. The write also re-enqueues the save.
        try await userDatabase.userWrite { db in
          try db.execute(sql: #"UPDATE "reminders" SET "dueDate" = 'not-a-date' WHERE "id" = 1"#)
        }

        try await settleLedger(at: 1)  // the edit's durable ledger row
        await withKnownIssue {
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        }

        #expect(
          syncEngine.private.state.pendingRecordZoneChanges.contains(
            .saveRecord(Reminder.recordID(for: 1))
          ),
          "a record whose own row FAILED to read must stay in the upload queue"
        )
        #expect(try await ledgerCount() == 1, "the durable ledger row must survive a parked read")

        // Repair, and the parked change goes out on the next send.
        try await userDatabase.userWrite { db in
          try db.execute(sql: #"UPDATE "reminders" SET "dueDate" = NULL, "title" = 'Get milk 2' WHERE "id" = 1"#)
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(
          try syncEngine.private.database
            .record(for: Reminder.recordID(for: 1))
            .encryptedValues["title"] as? String == "Get milk 2"
        )
      }

      /// The boundary that must NOT drift: a metadata row that is genuinely GONE still retires the
      /// pending change. Without this, patch 8 could quietly become "never drop anything", and every
      /// deleted record would re-enter the batch builder forever.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func anAbsentMetadataRowStillLeavesTheQueue() async throws {
        syncEngine.private.state.add(
          pendingRecordZoneChanges: [.saveRecord(RemindersList.recordID(for: 99))]
        )

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(
          syncEngine.private.state.pendingRecordZoneChanges.isEmpty,
          "an absent metadata row is a deletion, and still leaves the queue"
        )
      }
    }
  }
#endif
