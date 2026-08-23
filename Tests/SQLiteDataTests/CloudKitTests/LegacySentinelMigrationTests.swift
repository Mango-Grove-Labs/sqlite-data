#if canImport(CloudKit)
  import CloudKit
  import GRDB
  import SQLiteData
  import Testing

  // MANGO Phase 5.3a (the patch-7 F2 follow-up) — the legacy `-1` mirror sentinels must be nulled
  // on upgrade.
  //
  // Rows uploaded under pre-amendment code hold `serverUserModificationTime = -1` (the CKRecord
  // getter fallback the old ack path wrote on every slim ack). Patch 9's start rescan selects
  // `-1 < userModificationTime` at EVERY launch, and the amended ack path (correctly) never
  // rewrites a slim ack's mirror — so without the migration an upgraded device re-enqueues its
  // entire pre-fix dataset on every start, forever: a de-facto blanket reupload composed from two
  // individually-correct patches.
  //
  // The migration test builds a genuinely PRE-upgrade metadatabase (a migration prefix via the
  // `upTo:` hook), seeds legacy rows, and runs the full migrator over them — the only faithful
  // shape, since a normal engine init has already applied every migration before a test can seed.
  @Suite struct LegacySentinelMigrationTests {
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func theUpgradeNullsLegacySentinelsAndPreservesRealStamps() throws {
      let metadatabase = try DatabaseQueue()
      // The pre-upgrade ledger: everything up to and including patch 7's migration, nothing newer.
      try migrate(
        metadatabase: metadatabase,
        upTo: "Mango: mirror the server userModificationTime"
      )
      try metadatabase.write { db in
        try db.execute(
          sql: """
            INSERT INTO "sqlitedata_icloud_metadata"
              ("recordPrimaryKey","recordType","zoneName","ownerName",
               "lastKnownServerRecord","serverUserModificationTime","userModificationTime")
            VALUES
              ('1','remindersLists','zone','owner', X'00', -1, 60),
              ('2','remindersLists','zone','owner', X'00', 60, 60),
              ('3','remindersLists','zone','owner', NULL, NULL, 60)
            """
        )
      }

      // The upgrade: the full migrator runs over the seeded ledger.
      try migrate(metadatabase: metadatabase)

      let mirrors = try metadatabase.read { db in
        try Row.fetchAll(
          db,
          sql: """
            SELECT "recordPrimaryKey", "serverUserModificationTime"
              FROM "sqlitedata_icloud_metadata" ORDER BY "recordPrimaryKey"
            """
        ).map { ($0["recordPrimaryKey"] as String, $0["serverUserModificationTime"] as Int64?) }
      }
      #expect(mirrors.count == 3)
      // The legacy sentinel becomes an honest unknown…
      #expect(mirrors[0] == ("1", nil))
      // …while a real stamp and a never-confirmed NULL are untouched. (Row 2 is a *settled* mirror,
      // level with its local stamp — the state a confirmed row actually holds after a round trip.
      // A behind-mirror would be nulled here too, by patch 14's repair further down the migrator,
      // and would say nothing about this migration's `= -1` specificity.)
      #expect(mirrors[1] == ("2", 60))
      #expect(mirrors[2] == ("3", nil))
    }

    // PATCH 14 (F4) — the same repair, one bug later. Rows applied from the server under the
    // pre-patch-14 trigger hold a mirror stranded *behind* a wall-clock local stamp; they read as
    // unsent edits forever and re-enter patch 9's rescan on every launch. The upgrade nulls exactly
    // those, and leaves a level mirror and a never-confirmed NULL alone.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func theUpgradeNullsMirrorsStrandedBehindTheLocalStamp() throws {
      let metadatabase = try DatabaseQueue()
      try migrate(
        metadatabase: metadatabase,
        upTo: "Mango: null the legacy -1 mirror sentinels"
      )
      try metadatabase.write { db in
        try db.execute(
          sql: """
            INSERT INTO "sqlitedata_icloud_metadata"
              ("recordPrimaryKey","recordType","zoneName","ownerName",
               "lastKnownServerRecord","serverUserModificationTime","userModificationTime")
            VALUES
              ('1','remindersLists','zone','owner', X'00', 42, 1755900000),
              ('2','remindersLists','zone','owner', X'00', 60, 60),
              ('3','remindersLists','zone','owner', NULL, NULL, 60)
            """
        )
      }

      try migrate(metadatabase: metadatabase)

      let mirrors = try metadatabase.read { db in
        try Row.fetchAll(
          db,
          sql: """
            SELECT "recordPrimaryKey", "serverUserModificationTime"
              FROM "sqlitedata_icloud_metadata" ORDER BY "recordPrimaryKey"
            """
        ).map { ($0["recordPrimaryKey"] as String, $0["serverUserModificationTime"] as Int64?) }
      }
      #expect(mirrors.count == 3)
      // The stranded mirror becomes an honest unknown…
      #expect(mirrors[0] == ("1", nil))
      // …while a level mirror and a never-confirmed NULL are untouched.
      #expect(mirrors[1] == ("2", 60))
      #expect(mirrors[2] == ("3", nil))
    }
  }

  // The loop the migration exists to break, characterized end to end: with `-1` on disk (the
  // pre-upgrade device state), patch 9 re-enqueues the row at EVERY engine start. This test stays
  // green with and without the migration — a `-1` written *after* init is deliberately untouched
  // until the next upgrade-time migration run — it pins WHY 5.3a must ship with patch 9.
  extension BaseCloudKitTests {
    @MainActor
    final class LegacySentinelLoopTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aLegacySentinelLoopsTheRescanOnEveryStart() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        // Simulate the pre-upgrade ledger: the confirmed row's mirror holds the old sentinel.
        // (Direct metadatabase write — the sync triggers live on the user connection.)
        try await syncEngine.metadatabase.write { db in
          try db.execute(
            sql: """
              UPDATE "sqlitedata_icloud_metadata" SET "serverUserModificationTime" = -1
               WHERE "recordPrimaryKey" = '1' AND "recordType" = 'remindersLists'
              """
          )
        }

        for _ in 1...2 {
          syncEngine.stop()
          try await syncEngine.start()
          syncEngine.private.state.assertPendingDatabaseChanges([
            .saveZone(SyncEngine.defaultTestZone)
          ])
          // Re-enqueued again on this start — the every-launch loop.
          syncEngine.private.state.assertPendingRecordZoneChanges([
            .saveRecord(RemindersList.recordID(for: 1))
          ])
        }
      }
    }
  }
#endif
