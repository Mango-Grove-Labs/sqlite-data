#if canImport(CloudKit)
  import CloudKit
  import SQLiteData
  import SQLiteDataTestSupport
  import Testing

  extension BaseCloudKitTests {
    // MANGO patch 11 guard — a share deletion arriving on a PARTICIPANT device must clear the
    // cached share. `deleteShare` re-fetches the share's root record to refresh the metadata,
    // and on a participant that root record lives in the *shared* database: reading
    // `container.privateCloudDatabase` unconditionally (upstream) throws `.zoneNotFound`,
    // the error is swallowed into a reported issue at the call site, and the stale share
    // stays cached forever — which is what breaks "Remove Me" on a participant.
    @MainActor
    @Suite
    final class ParticipantShareDeletionTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aShareDeletionOnAParticipantClearsTheCachedShare() async throws {
        // A participant accepts a share of an externally-owned record.
        let externalZone = CKRecordZone(
          zoneID: CKRecordZone.ID(
            zoneName: "external.zone",
            ownerName: "external.owner"
          )
        )
        try await syncEngine.modifyRecordZones(scope: .shared, saving: [externalZone]).notify()

        let remindersListRecord = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1, zoneID: externalZone.zoneID)
        )
        remindersListRecord.setValue(1, forKey: "id", at: now)
        remindersListRecord.setValue("Personal", forKey: "title", at: now)
        let share = CKShare(
          rootRecord: remindersListRecord,
          shareID: CKRecord.ID(
            recordName: "share-\(remindersListRecord.recordID.recordName)",
            zoneID: remindersListRecord.recordID.zoneID
          )
        )
        _ = try syncEngine.modifyRecords(scope: .shared, saving: [share, remindersListRecord])
        let freshShare = try syncEngine.shared.database.record(for: share.recordID) as! CKShare
        let freshRemindersListRecord = try syncEngine.shared.database.record(
          for: remindersListRecord.recordID
        )

        try await syncEngine
          .acceptShare(
            metadata: ShareMetadata(
              containerIdentifier: container.containerIdentifier!,
              hierarchicalRootRecordID: freshRemindersListRecord.recordID,
              rootRecord: freshRemindersListRecord,
              share: freshShare
            )
          )

        // Sanity: the share is cached against the root record's metadata.
        let cachedShareIDs = try await syncEngine.metadatabase.read { db in
          try SyncMetadata.select(\.share).fetchAll(db).map { $0?.recordID }
        }
        #expect(cachedShareIDs == [share.recordID])

        // The share record's deletion arrives on the shared engine — what CloudKit delivers
        // after "Remove Me" or the owner stopping sharing.
        try await syncEngine.modifyRecords(scope: .shared, deleting: [share.recordID]).notify()

        // The cached share is cleared and the root's server record was refreshed from the
        // *shared* database. (Upstream reads the private database here, throws
        // `.zoneNotFound`, reports an issue, and leaves the stale share cached.)
        let metadata = try await syncEngine.metadatabase.read { db in
          try SyncMetadata
            .select { ($0.share, $0.hasLastKnownServerRecord) }
            .fetchAll(db)
        }
        #expect(metadata.count == 1)
        #expect(metadata.first?.0 == nil)
        #expect(metadata.first?.1 == true)

        // The participant's local row itself is untouched by the share deletion — only the
        // share cache is; the zone purge that may follow is a separate, observable event.
        let localRows = try await userDatabase.read { db in
          try RemindersList.all.fetchAll(db)
        }
        #expect(localRows == [RemindersList(id: 1, title: "Personal")])
      }
    }
  }
#endif
