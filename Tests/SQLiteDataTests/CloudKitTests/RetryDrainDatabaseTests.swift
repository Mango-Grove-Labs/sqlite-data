#if canImport(CloudKit)
  import CloudKit
  import SQLiteData
  import SQLiteDataTestSupport
  import Testing

  // MANGO PATCH 25 guard (A-F6) — the fetch-side retry drain must fetch each parked record ID from
  // its OWN database (`container.database(for:)`, by zone owner), never from the database of
  // whichever engine is handling the event. `UnsyncedRecordID` holds parks from both scopes
  // (patch 1's reference-violation parks, FK parks, patch 4's failed asset downloads); upstream asked
  // `syncEngine.database` for all of them. Real CloudKit might answer a shared-zone ID asked of the
  // private database with `.unknownItem` (both zones carry the same name), which deletes the park
  // for good — the mock answers `.zoneNotFound` instead (the drain `continue`s), so these tests pin
  // the observable half: an event of EITHER scope now applies a parked record of the other scope.
  //
  // Vacuity guard: putting `syncEngine.database` back in place of `container.database(for:)` in
  // the drain turns both tests red (the record stays parked and never lands).
  extension BaseCloudKitTests {
    @MainActor
    @Suite
    final class RetryDrainDatabaseTests: BaseCloudKitTests, @unchecked Sendable {
      /// A co-teacher's parked shared record is applied by a PRIVATE-scope fetch event.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aPrivateEventDrainsAParkedSharedRecordFromTheSharedDatabase() async throws {
        let externalZone = CKRecordZone(
          zoneID: CKRecordZone.ID(zoneName: "external.zone", ownerName: "external.owner")
        )
        try await syncEngine.modifyRecordZones(scope: .shared, saving: [externalZone]).notify()

        // The co-teacher has joined a room (the `ParticipantShareDeletionTests` idiom).
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
        try await syncEngine.acceptShare(
          metadata: ShareMetadata(
            containerIdentifier: container.containerIdentifier!,
            hierarchicalRootRecordID: freshRemindersListRecord.recordID,
            rootRecord: freshRemindersListRecord,
            share: freshShare
          )
        )

        // A reminder in that room is on the server but never landed on this device: it was
        // parked (an out-of-order arrival, a failed asset download).
        let reminderRecord = CKRecord(
          recordType: Reminder.tableName,
          recordID: Reminder.recordID(for: 1, zoneID: externalZone.zoneID)
        )
        reminderRecord.setValue(1, forKey: "id", at: now)
        reminderRecord.setValue("Get milk", forKey: "title", at: now)
        reminderRecord.setValue(1, forKey: "remindersListID", at: now)
        reminderRecord.parent = CKRecord.Reference(
          recordID: remindersListRecord.recordID,
          action: .none
        )
        _ = try syncEngine.modifyRecords(scope: .shared, saving: [reminderRecord])
        try await park(reminderRecord.recordID)

        await syncEngine.handleFetchedRecordZoneChanges(syncEngine: syncEngine.private)

        try await userDatabase.read { db in
          try #expect(
            Reminder.find(1).fetchOne(db)
              == Reminder(id: 1, title: "Get milk", remindersListID: 1)
          )
        }
        try await expectNotParked(reminderRecord.recordID)
      }

      /// The mirror: an owned record parked on this device is applied by a SHARED-scope event.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aSharedEventDrainsAParkedOwnedRecordFromThePrivateDatabase() async throws {
        let remindersListRecord = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1)
        )
        remindersListRecord.setValue(1, forKey: "id", at: now)
        remindersListRecord.setValue("Personal", forKey: "title", at: now)
        _ = try syncEngine.modifyRecords(scope: .private, saving: [remindersListRecord])
        try await park(remindersListRecord.recordID)

        await syncEngine.handleFetchedRecordZoneChanges(syncEngine: syncEngine.shared)

        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db) == RemindersList(id: 1, title: "Personal"))
        }
        try await expectNotParked(remindersListRecord.recordID)
      }

      private func park(_ recordID: CKRecord.ID) async throws {
        try await userDatabase.write { db in
          try UnsyncedRecordID.insert { UnsyncedRecordID(recordID: recordID) }.execute(db)
        }
      }

      private func expectNotParked(_ recordID: CKRecord.ID) async throws {
        try await syncEngine.metadatabase.read { db in
          try #expect(UnsyncedRecordID.find(recordID).fetchCount(db) == 0)
        }
      }
    }
  }
#endif
