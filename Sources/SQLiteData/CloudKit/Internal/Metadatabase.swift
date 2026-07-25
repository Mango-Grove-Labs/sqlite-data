#if canImport(CloudKit)
  import Dependencies
  import GRDB
  import Foundation
  import os
  import StructuredQueries

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  func defaultMetadatabase(
    logger: Logger,
    url: URL
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

    let metadatabase = try DatabasePool(path: url.path(percentEncoded: false))
    try migrate(metadatabase: metadatabase)
    return metadatabase
  }

  func migrate(metadatabase: some DatabaseWriter) throws {
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
    // MontiSprout fork (41.2b, PATCH 7): mirror the server record's own `userModificationTime` into a
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
    try migrator.migrate(metadatabase)
  }
#endif
