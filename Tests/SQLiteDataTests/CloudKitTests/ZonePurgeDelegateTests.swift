#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import SQLiteData
  import SQLiteDataTestSupport
  import Testing
  import TestLocals

  extension BaseCloudKitTests {
    // MANGO patch 12 guard — a zone deletion/purge hard-deletes every local row in the zone;
    // the delegate hook is the only signal a consumer gets (revocation UX depends on it), and
    // it must fire BEFORE the purge, while the zone's rows are still readable.
    @MainActor
    @Suite
    final class ZonePurgeDelegateTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(ZonePurgeRecorder()))
      func aSharedZonePurgeNotifiesTheDelegateBeforeDeletingLocalRows() async throws {
        let recorder = try #require(syncEngineDelegate as? ZonePurgeRecorder)

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
        let rowsBeforePurge = try await userDatabase.read { db in
          try RemindersList.count().fetchOne(db) ?? 0
        }
        #expect(rowsBeforePurge == 1)

        // Prove the "will" timing: at notification time the zone's rows must still be there.
        recorder.probe.setValue { [userDatabase] in
          (try? await userDatabase.read { db in
            try RemindersList.count().fetchOne(db) ?? 0
          }) ?? -1
        }

        // The owner revokes: CloudKit purges the shared zone.
        await syncEngine.handleEvent(
          .fetchedDatabaseChanges(
            modifications: [],
            deletions: [(externalZone.zoneID, .purged)]
          ),
          syncEngine: syncEngine.shared
        )

        let notices = recorder.notices.withValue(\.self)
        #expect(notices.count == 1)
        #expect(notices.first?.zoneName == "external.zone")
        #expect(notices.first?.ownerName == "external.owner")
        #expect(notices.first?.scope == .shared)
        #expect(notices.first?.isPurge == true)
        // The hook ran while the zone's local rows were still present…
        #expect(recorder.rowCountAtNotice.withValue(\.self) == 1)
        // …and the purge itself still happened after it.
        let rowsAfterPurge = try await userDatabase.read { db in
          try RemindersList.count().fetchOne(db) ?? 0
        }
        #expect(rowsAfterPurge == 0)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(ZonePurgeRecorder()))
      func anEncryptedDataResetDoesNotNotifyTheDelegate() async throws {
        let recorder = try #require(syncEngineDelegate as? ZonePurgeRecorder)

        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        // An encrypted-data reset re-uploads the zone's records — nothing is deleted, so the
        // deletion hook must stay silent.
        await syncEngine.handleEvent(
          .fetchedDatabaseChanges(
            modifications: [],
            deletions: [(syncEngine.defaultZone.zoneID, .encryptedDataReset)]
          ),
          syncEngine: syncEngine.private
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(recorder.notices.withValue(\.self).isEmpty)
        let rows = try await userDatabase.read { db in
          try RemindersList.count().fetchOne(db) ?? 0
        }
        #expect(rows == 1)
      }
    }
  }

  final class ZonePurgeRecorder: SyncEngineDelegate, @unchecked Sendable {
    struct Notice: Sendable {
      var zoneName: String
      var ownerName: String
      var scope: CKDatabase.Scope
      var isPurge: Bool
      /// Non-nil only for MANGO patch 13's record-granular notice — the roots that actually went.
      /// `nil` is patch 12's zone event, where the whole zone is going.
      var rootRecordIDs: [CKRecord.ID]?
    }
    let notices = LockIsolated<[Notice]>([])
    let probe = LockIsolated<(@Sendable () async -> Int)?>(nil)
    let rowCountAtNotice = LockIsolated<Int?>(nil)

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    func syncEngine(
      _ syncEngine: SQLiteData.SyncEngine,
      willDeleteRecordsInZone zoneID: CKRecordZone.ID,
      scope: CKDatabase.Scope,
      reason: CKDatabase.DatabaseChange.Deletion.Reason
    ) async {
      let isPurge: Bool
      switch reason {
      case .purged: isPurge = true
      default: isPurge = false
      }
      notices.withValue {
        $0.append(
          Notice(
            zoneName: zoneID.zoneName,
            ownerName: zoneID.ownerName,
            scope: scope,
            isPurge: isPurge
          )
        )
      }
      if let probe = probe.withValue(\.self) {
        let count = await probe()
        rowCountAtNotice.withValue { $0 = count }
      }
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    func syncEngine(
      _ syncEngine: SQLiteData.SyncEngine,
      willDeleteSharedRootRecords rootRecordIDs: [CKRecord.ID],
      inZone zoneID: CKRecordZone.ID
    ) async {
      notices.withValue {
        $0.append(
          Notice(
            zoneName: zoneID.zoneName,
            ownerName: zoneID.ownerName,
            scope: .shared,
            isPurge: false,
            rootRecordIDs: rootRecordIDs
          )
        )
      }
      if let probe = probe.withValue(\.self) {
        let count = await probe()
        rowCountAtNotice.withValue { $0 = count }
      }
    }
  }
#endif
