#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import SQLiteData
  import SQLiteDataTestSupport
  import Testing
  import TestLocals

  extension BaseCloudKitTests {
    // MANGO patch 13 guard — on real CloudKit a revoked participant is NOT told by a zone
    // deletion. The zone stays (it is the owner's), and what arrives on the shared engine is a
    // pair of RECORD deletions: the hierarchy's root record and the `cloudkit.share` record.
    // Patch 12's hook therefore never fired, the library hard-deleted the root (and the consumer
    // schema's FK cascade took the rest) with no event of any kind, and the revocation notice a
    // consumer builds on that hook could never be minted (MonteSprout 55.2, finding F13).
    //
    // These pin that the hook fires for the zone losing its share, **before** the local delete,
    // and that it stays silent for the two neighbours it must not claim: an ordinary record
    // deletion inside a still-shared zone, and anything at all in the private scope.
    @MainActor
    @Suite
    final class SharedRecordRevocationDelegateTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(ZonePurgeRecorder()))
      func aRevokedShareNotifiesTheDelegateBeforeDeletingTheRootRecord() async throws {
        let recorder = try #require(syncEngineDelegate as? ZonePurgeRecorder)
        let shared = try await acceptExternalShare()

        let rowsBefore = try await userDatabase.read { db in
          try RemindersList.count().fetchOne(db) ?? 0
        }
        #expect(rowsBefore == 1)

        // Prove the "will" timing: at notification time the room's rows must still be readable —
        // the name shown in the notice, and the participant's own private rows hanging off the
        // shared row by foreign key, are only reachable in this window.
        recorder.probe.setValue { [userDatabase] in
          (try? await userDatabase.read { db in
            try RemindersList.count().fetchOne(db) ?? 0
          }) ?? -1
        }

        // What CloudKit actually delivers to a revoked participant.
        try await syncEngine
          .modifyRecords(
            scope: .shared,
            deleting: [shared.rootRecordID, shared.shareRecordID]
          )
          .notify()

        let notices = recorder.notices.withValue(\.self)
        #expect(notices.count == 1)
        #expect(notices.first?.zoneName == "external.zone")
        #expect(notices.first?.ownerName == "external.owner")
        #expect(notices.first?.scope == .shared)
        // A record teardown is not a purge — the zone itself survives, it is the access that ended.
        #expect(notices.first?.isPurge == false)
        // The hook ran while the row was still there…
        #expect(recorder.rowCountAtNotice.withValue(\.self) == 1)
        // …and the deletion still happened after it.
        let rowsAfter = try await userDatabase.read { db in
          try RemindersList.count().fetchOne(db) ?? 0
        }
        #expect(rowsAfter == 0)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(ZonePurgeRecorder()))
      func aRootRecordDeletionArrivingWithoutItsShareStillNotifies() async throws {
        let recorder = try #require(syncEngineDelegate as? ZonePurgeRecorder)
        let shared = try await acceptExternalShare()

        // CloudKit makes no promise that the root and the share land in the same fetch batch. If
        // only the root arrives, the cached share is what identifies it as the hierarchy this
        // device was given — and the notice has to be minted here, because by the time the share's
        // own deletion turns up the room and its name are gone.
        try await syncEngine
          .modifyRecords(scope: .shared, deleting: [shared.rootRecordID])
          .notify()

        let notices = recorder.notices.withValue(\.self)
        #expect(notices.count == 1)
        #expect(notices.first?.zoneName == "external.zone")
        #expect(notices.first?.scope == .shared)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(ZonePurgeRecorder()))
      func anOrdinaryDeletionInsideAStillSharedZoneDoesNotNotify() async throws {
        let recorder = try #require(syncEngineDelegate as? ZonePurgeRecorder)
        let shared = try await acceptExternalShare()

        // The owner deleted one child row. Access is intact; a removal notice here would tell a
        // co-teacher she had lost a classroom that is still on her screen.
        let reminderRecord = CKRecord(
          recordType: Reminder.tableName,
          recordID: Reminder.recordID(for: 1, zoneID: shared.rootRecordID.zoneID)
        )
        reminderRecord.setValue(1, forKey: "id", at: now)
        reminderRecord.setValue("Get milk", forKey: "title", at: now)
        reminderRecord.setValue(1, forKey: "remindersListID", at: now)
        reminderRecord.parent = CKRecord.Reference(recordID: shared.rootRecordID, action: .none)
        try await syncEngine.modifyRecords(scope: .shared, saving: [reminderRecord]).notify()

        try await syncEngine
          .modifyRecords(scope: .shared, deleting: [reminderRecord.recordID])
          .notify()

        #expect(recorder.notices.withValue(\.self).isEmpty)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(ZonePurgeRecorder()))
      func theOwnersOwnUnshareDoesNotNotifyHerAsIfSheHadBeenRevoked() async throws {
        let recorder = try #require(syncEngineDelegate as? ZonePurgeRecorder)

        // The lead's own device. Stopping sharing deletes the very same two records — root and
        // `cloudkit.share` — and CloudKit reports them on her PRIVATE engine. She has lost nothing:
        // the room is hers, and telling her it was taken away is the mirror image of F13. The
        // scope is the only thing that separates the two, which is why it is a guard and not a
        // comment. (A record whose share was never cached would pass this test with the guard
        // deleted, so the share is created here on purpose.)
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let rootRecordID = RemindersList.recordID(for: 1, zoneID: syncEngine.defaultZone.zoneID)
        let rootRecord = try syncEngine.private.database.record(for: rootRecordID)
        let share = CKShare(
          rootRecord: rootRecord,
          shareID: CKRecord.ID(
            recordName: "share-\(rootRecordID.recordName)",
            zoneID: rootRecordID.zoneID
          )
        )
        // Saved together: the mock refuses a share whose root record is not in the same batch,
        // exactly as CloudKit does.
        try await syncEngine.modifyRecords(scope: .private, saving: [share, rootRecord]).notify()
        #expect(
          (try? syncEngine.private.database.record(for: share.recordID)) != nil,
          "the share must actually exist, or the deletion below carries no share record type"
        )

        try await syncEngine
          .modifyRecords(scope: .private, deleting: [rootRecordID, share.recordID])
          .notify()

        #expect(recorder.notices.withValue(\.self).isEmpty)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(ZonePurgeRecorder()))
      func revokingOneOfTwoRoomsInAZoneNamesOnlyTheRevokedRoot() async throws {
        let recorder = try #require(syncEngineDelegate as? ZonePurgeRecorder)
        let first = try await acceptExternalShare(id: 1, title: "Personal")
        let second = try await acceptExternalShare(id: 2, title: "Work")
        #expect(first.rootRecordID.zoneID == second.rootRecordID.zoneID)

        // Everything one owner shares out of one of her zones lands in ONE zone on the
        // participant's side. Revoking a single hierarchy is therefore NOT a fact about the zone:
        // a zone-granular notice would tell a consumer to sweep the room that is still shared —
        // deleting the participant's own private rows about it and announcing a loss that did not
        // happen. The notice has to name the roots that actually went.
        try await syncEngine
          .modifyRecords(scope: .shared, deleting: [first.rootRecordID, first.shareRecordID])
          .notify()

        let notices = recorder.notices.withValue(\.self)
        #expect(notices.count == 1)
        #expect(notices.first?.rootRecordIDs == [first.rootRecordID])
        // …and the other room really is still there, which is what makes the point above concrete.
        let survivors = try await userDatabase.read { db in
          try RemindersList.all.fetchAll(db)
        }
        #expect(survivors == [RemindersList(id: 2, title: "Work")])
      }

      /// A participant holding an accepted share of an externally-owned `RemindersList`.
      struct AcceptedShare {
        var rootRecordID: CKRecord.ID
        var shareRecordID: CKRecord.ID
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func acceptExternalShare(
        id: Int = 1,
        title: String = "Personal"
      ) async throws -> AcceptedShare {
        let externalZone = CKRecordZone(
          zoneID: CKRecordZone.ID(
            zoneName: "external.zone",
            ownerName: "external.owner"
          )
        )
        try await syncEngine.modifyRecordZones(scope: .shared, saving: [externalZone]).notify()

        let remindersListRecord = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: id, zoneID: externalZone.zoneID)
        )
        remindersListRecord.setValue(id, forKey: "id", at: now)
        remindersListRecord.setValue(title, forKey: "title", at: now)
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
        return AcceptedShare(
          rootRecordID: remindersListRecord.recordID,
          shareRecordID: share.recordID
        )
      }
    }
  }
#endif
