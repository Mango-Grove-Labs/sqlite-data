#if canImport(CloudKit)
  import Dependencies
  import GRDB
  import Foundation
  import os
  import StructuredQueries

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  func defaultMetadatabase(
    logger: Logger,
    url: URL,
    configuration: Configuration
  ) throws -> any DatabaseWriter {
    logger.debug(
      """
      Metadatabase connection:
      open "\(url.path(percentEncoded: false))"
      """
    )

    @Dependency(\.context) var context
    guard !url.isInMemory || context != .live
    else {
      struct InMemoryDatabase: Error {}
      throw InMemoryDatabase()
    }

    var metadatabaseConfiguration = Configuration()
    metadatabaseConfiguration.observesSuspensionNotifications = configuration.observesSuspensionNotifications
    // MANGO PATCH 10 — this connection must wait for a lock, never fail immediately. Rationale and
    // the decision itself live in `MetadatabaseBusyMode.swift` (a Mango-owned file, so the patch costs
    // one line here).
    metadatabaseConfiguration.busyMode = mangoMetadatabaseBusyMode(inheriting: configuration.busyMode)
    let metadatabase: any DatabaseWriter =
      if url.isInMemory {
        try DatabaseQueue(
          path: url.absoluteString,
          configuration: metadatabaseConfiguration
        )
      } else {
        try DatabasePool(
          path: url.path(percentEncoded: false),
          configuration: metadatabaseConfiguration
        )
      }
    try migrate(metadatabase: metadatabase)
    return metadatabase
  }

  // MonteSprout fork (Phase 5.3a): `package` + the `upTo:` hook exist for the upgraded-ledger guard
  // test, which must build a PRE-upgrade metadatabase (a migration prefix), seed legacy rows, and then
  // run the full migrator over them — the only faithful way to test a data migration, since a normal
  // engine init has already applied every migration before a test can seed anything.
  package func migrate(metadatabase: some DatabaseWriter, upTo lastMigration: String? = nil) throws {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("Create Metadata Tables") { db in
      try #sql(
        """
        CREATE TABLE "\(raw: .sqliteDataCloudKitSchemaName)_metadata" (
          "recordPrimaryKey" TEXT NOT NULL,
          "recordType" TEXT NOT NULL,
          "recordName" TEXT NOT NULL AS ("recordPrimaryKey" || ':' || "recordType"),
          "zoneName" TEXT NOT NULL,
          "ownerName" TEXT NOT NULL,
          "parentRecordPrimaryKey" TEXT,
          "parentRecordType" TEXT,
          "parentRecordName" TEXT AS ("parentRecordPrimaryKey" || ':' || "parentRecordType"),
          "lastKnownServerRecord" BLOB,
          "_lastKnownServerRecordAllFields" BLOB,
          "share" BLOB,
          "hasLastKnownServerRecord" INTEGER NOT NULL AS ("lastKnownServerRecord" IS NOT NULL),
          "isShared" INTEGER NOT NULL AS ("share" IS NOT NULL),
          "userModificationTime" INTEGER NOT NULL DEFAULT (\($currentTime())),
          "_isDeleted" INTEGER NOT NULL DEFAULT 0,

          PRIMARY KEY ("recordPrimaryKey", "recordType"),
          UNIQUE ("recordName")
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "\(raw: .sqliteDataCloudKitSchemaName)_metadata_zoneID"
        ON "\(raw: .sqliteDataCloudKitSchemaName)_metadata"("ownerName", "zoneName")
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "\(raw: .sqliteDataCloudKitSchemaName)_metadata_parentRecordName"
        ON "\(raw: .sqliteDataCloudKitSchemaName)_metadata"("parentRecordName")
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "\(raw: .sqliteDataCloudKitSchemaName)_metadata_isShared"
        ON "\(raw: .sqliteDataCloudKitSchemaName)_metadata"("isShared")
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX IF NOT EXISTS "\(raw: .sqliteDataCloudKitSchemaName)_metadata_hasLastKnownServerRecord"
        ON "\(raw: .sqliteDataCloudKitSchemaName)_metadata"("hasLastKnownServerRecord")
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "\(raw: .sqliteDataCloudKitSchemaName)_recordTypes" (
          "tableName" TEXT NOT NULL PRIMARY KEY,
          "schema" TEXT NOT NULL,
          "tableInfo" TEXT NOT NULL
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "\(raw: .sqliteDataCloudKitSchemaName)_stateSerialization" (
          "scope" TEXT NOT NULL PRIMARY KEY,
          "data" TEXT NOT NULL
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "\(raw: .sqliteDataCloudKitSchemaName)_unsyncedRecordIDs" (
          "recordName" TEXT NOT NULL,
          "zoneName" TEXT NOT NULL,
          "ownerName" TEXT NOT NULL,
          PRIMARY KEY ("recordName", "zoneName", "ownerName")
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "\(raw: .sqliteDataCloudKitSchemaName)_pendingRecordZoneChanges" (
          "pendingRecordZoneChange" BLOB NOT NULL
        ) STRICT
        """
      )
      .execute(db)
    }
    // MonteSprout fork (41.2b, PATCH 7): mirror the server record's own `userModificationTime` into a
    // plain column. Every consumer number for "waiting to upload" is derived from
    // `lastKnownServerRecord`, so it measures "has this row ever reached the server" and is structurally
    // blind to an **update to an already-synced row** — the row keeps its (older) server record, so the
    // count reads 0 while the edit is unsent. The comparison that sees it lives inside the archived
    // record's `encryptedValues`, which no SQL can reach; mirroring it makes
    // `userModificationTime > serverUserModificationTime` an ordinary indexed-ish predicate.
    //
    // A NEW migration, never an edit to the released one (the assertion below exists to enforce that).
    // The backfill assumes rows that already have a server record are in sync at migration time: we
    // cannot know better without unarchiving every blob, the assumption is right for every row that
    // isn't mid-edit, and a wrong guess self-corrects on that row's next round trip.
    migrator.registerMigration("Mango: mirror the server userModificationTime") { db in
      try #sql(
        """
        ALTER TABLE "\(raw: .sqliteDataCloudKitSchemaName)_metadata"
        ADD COLUMN "serverUserModificationTime" INTEGER
        """
      )
      .execute(db)
      try #sql(
        """
        UPDATE "\(raw: .sqliteDataCloudKitSchemaName)_metadata"
           SET "serverUserModificationTime" = "userModificationTime"
         WHERE "lastKnownServerRecord" IS NOT NULL
        """
      )
      .execute(db)
    }
    // MonteSprout fork (Phase 5.3a, the patch-7 F2 follow-up): null the legacy `-1` mirror sentinels.
    // Rows uploaded under pre-amendment code hold mirror `-1` — the CKRecord getter fallback the old
    // ack path wrote on every slim ack. Patch 9's start rescan selects `-1 < userModificationTime` on
    // EVERY launch, and the amended ack path (correctly) never rewrites a slim ack's mirror — so an
    // upgraded device would re-enqueue its entire pre-fix dataset per launch, forever: a permanent
    // de-facto blanket reupload composed from two individually-correct patches. `-1` can never be a
    // legitimate stamp (the insert half and the amended funnel both require a carried stamp; patch 7's
    // backfill copies real values), so junk becomes honest unknown. A NEW migration, never an edit to
    // a released one — the DEBUG assertion below enforces exactly that.
    migrator.registerMigration("Mango: null the legacy -1 mirror sentinels") { db in
      try #sql(
        """
        UPDATE "\(raw: .sqliteDataCloudKitSchemaName)_metadata"
           SET "serverUserModificationTime" = NULL
         WHERE "serverUserModificationTime" = -1
        """
      )
      .execute(db)
    }
    // MonteSprout fork (PATCH 14, the F4 repair): null the mirrors the pre-patch-14 apply path left
    // stranded behind the local stamp. Applying a fetched record bumped `userModificationTime` to the
    // wall clock (the user-table trigger could not tell the sync engine's own write from a user's)
    // while the mirror kept the server's stamp — so every row the server re-delivered read as an unsent
    // edit permanently, and patch 9's start rescan re-enqueued the device's whole downloaded dataset on
    // EVERY launch. Exactly the 5.3a failure shape above, repaired the same way: at upgrade time a
    // behind-mirror cannot be told apart from a genuine unsent edit, so junk becomes honest unknown
    // rather than an invented "in sync" stamp (patch 7's rule). The rare true positive this also clears
    // is not that row's only guard — 5.3b's durable pending ledger carries a stranded save across the
    // launch, and the mirror re-fills on the row's next apply. A NEW migration, never an edit to a
    // released one — the DEBUG assertion below enforces exactly that.
    migrator.registerMigration("Mango: null mirrors stranded by the pre-patch-14 apply path") { db in
      try #sql(
        """
        UPDATE "\(raw: .sqliteDataCloudKitSchemaName)_metadata"
           SET "serverUserModificationTime" = NULL
         WHERE "serverUserModificationTime" < "userModificationTime"
        """
      )
      .execute(db)
    }
    // MonteSprout fork (PATCH 15, the F4 residual): keep the stamp the SENT record carried across the
    // batch → ack boundary. A real CloudKit save ack arrives without the encrypted custom fields, so
    // nothing in it can say which `userModificationTime` landed — and patch 7's rule rightly forbids
    // inventing one. The batch builder does know, because it is the code that stamps the outgoing
    // record; this column is where it writes that stamp down until the ack (or the failure) settles
    // it. No backfill: at upgrade time nothing this process could know about is in flight, and NULL
    // already means exactly that. A NEW migration, never an edit to a released one — the DEBUG
    // assertion below enforces that, and this one now holds the "registered last" slot.
    migrator.registerMigration("Mango: carry the sent userModificationTime to the ack") { db in
      try #sql(
        """
        ALTER TABLE "\(raw: .sqliteDataCloudKitSchemaName)_metadata"
        ADD COLUMN "sentUserModificationTime" INTEGER
        """
      )
      .execute(db)
    }

    #if DEBUG
      try metadatabase.read { db in
        let hasSchemaChanges = try migrator.hasSchemaChanges(db)
        assert(
          !hasSchemaChanges,
          """
          A previously run migration has been removed or edited. \
          Metadatabase migrations must not be modified after release.
          """
        )
      }
    #endif
    if let lastMigration {
      try migrator.migrate(metadatabase, upTo: lastMigration)
    } else {
      try migrator.migrate(metadatabase)
    }
  }
#endif
