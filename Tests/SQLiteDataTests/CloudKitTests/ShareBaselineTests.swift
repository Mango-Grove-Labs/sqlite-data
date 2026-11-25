#if canImport(CloudKit)
  import CloudKit
  import Dependencies
  import Foundation
  import SQLiteData
  import Testing

  // MANGO PATCH 23 (MonteSprout 120.4, the 2026-11-25 bug bash's A-F4) — share and unshare keep the merge
  // baseline.
  //
  // `share(record:)` and `deleteShare` refresh the row's archive from a record fetched from the server just
  // now, and never write that record's values into the local row. When the server copy carried another
  // device's edit this device had not fetched yet, the edit landed in the per-field merge's baseline and not
  // in the row; the fetch that later delivered it read the stale row as an unsent local edit
  // (`CKRecord.update(with:row:columnNames:)` — server == baseline, row != baseline) and dropped it, and the
  // row's next send pushed the stale value back over it on the server. In MonteSprout terms: the lead renames
  // the classroom on her iPad, taps Invite on her iPhone before the rename arrives, and the iPhone keeps the
  // old name and later writes it back.
  //
  // Each test runs with the mock's full save echo and with slim acks (the real service's shape, patch 18):
  // `share(record:)`'s archive is built from its save ack, and the two shapes reach the bug by different
  // routes (the full echo carries the server's values in the ack; the slim ack leaves the fetched record's).
  //
  // Guard (neutralize in place): `keepingValues(of:)` returning `self` at once reddens every test here.
  extension BaseCloudKitTests {
    @MainActor
    @Suite
    final class ShareBaselineTests: BaseCloudKitTests, @unchecked Sendable {
      private let listID = RemindersList.recordID(for: 1)

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func localTitle() async throws -> String? {
        try await userDatabase.read { db in
          try RemindersList.find(1).fetchOne(db)?.title
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func serverTitle() throws -> String? {
        try syncEngine.private.database.record(for: listID).encryptedValues["title"] as? String
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func archivedTitle() async throws -> String? {
        try await syncEngine.metadatabase.read { db in
          try SyncMetadata
            .find(RemindersList.recordID(for: 1))
            .select(\._lastKnownServerRecordAllFields)
            .fetchOne(db)?
            .flatMap { $0.encryptedValues["title"] as? String }
        }
      }

      /// The room exists on both sides, uploaded by this device.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func seedAndUpload(slimSaveAcks: Bool) async throws {
        if slimSaveAcks {
          syncEngine.private.database.enableSlimSaveAcks()
        }
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Daisy Room")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
      }

      /// Another device renames the room. The save reaches the server; this device has not fetched it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func renamedElsewhereUnfetched() throws -> CKRecord {
        let record = try syncEngine.private.database.record(for: listID)
        record.setValue("Sunflower Room", forKey: "title", at: now + 60)
        _ = try syncEngine.modifyRecords(scope: .private, saving: [record])
        return try syncEngine.private.database.record(for: listID)
      }

      /// The fetch that finally delivers the server's current copy of the root.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func fetchTheRoot() async throws {
        let current = try syncEngine.private.database.record(for: listID)
        await syncEngine.private.parentSyncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [current], deletions: []),
          syncEngine: syncEngine.private
        )
      }

      /// Any later send of the row — the next local edit to any of its columns does this.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func sendTheRowAgain() async throws {
        syncEngine.private.state.add(pendingRecordZoneChanges: [.saveRecord(listID)])
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func shareKeepsTheBaseline(slimSaveAcks: Bool) async throws {
        try await seedAndUpload(slimSaveAcks: slimSaveAcks)
        _ = try renamedElsewhereUnfetched()

        _ = try await syncEngine.share(
          record: RemindersList(id: 1, title: "Daisy Room"),
          configure: { _ in }
        )

        // The patch: the archive still holds what the row holds; only the system fields moved.
        #expect(try await archivedTitle() == "Daisy Room")
        #expect(try await localTitle() == "Daisy Room")
        #expect(try serverTitle() == "Sunflower Room")
        // The share reference (a system field) did reach the archive.
        let archivedShare = try await syncEngine.metadatabase.read { db in
          try SyncMetadata
            .find(RemindersList.recordID(for: 1))
            .select(\._lastKnownServerRecordAllFields)
            .fetchOne(db)??
            .share
        }
        #expect(archivedShare != nil)

        try await fetchTheRoot()
        #expect(try await localTitle() == "Sunflower Room")
        #expect(try await archivedTitle() == "Sunflower Room")

        try await sendTheRowAgain()
        #expect(try serverTitle() == "Sunflower Room")
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func share_keepsTheBaseline_fullSaveAcks() async throws {
        try await shareKeepsTheBaseline(slimSaveAcks: false)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func share_keepsTheBaseline_slimSaveAcks() async throws {
        try await shareKeepsTheBaseline(slimSaveAcks: true)
      }

      /// The owner stops sharing; the share's deletion arrives alone, and the root's rename after it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func deleteShareKeepsTheBaseline(slimSaveAcks: Bool) async throws {
        try await seedAndUpload(slimSaveAcks: slimSaveAcks)
        let shared = try await syncEngine.share(
          record: RemindersList(id: 1, title: "Daisy Room"),
          configure: { _ in }
        )
        _ = try renamedElsewhereUnfetched()

        try await syncEngine.modifyRecords(scope: .private, deleting: [shared.share.recordID])
          .notify()

        #expect(try await archivedTitle() == "Daisy Room")
        #expect(try await localTitle() == "Daisy Room")
        let share = try await syncEngine.metadatabase.read { db in
          try SyncMetadata.find(RemindersList.recordID(for: 1)).select(\.share).fetchOne(db) ?? nil
        }
        #expect(share == nil)

        try await fetchTheRoot()
        #expect(try await localTitle() == "Sunflower Room")

        try await sendTheRowAgain()
        #expect(try serverTitle() == "Sunflower Room")
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func deleteShare_keepsTheBaseline_fullSaveAcks() async throws {
        try await deleteShareKeepsTheBaseline(slimSaveAcks: false)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func deleteShare_keepsTheBaseline_slimSaveAcks() async throws {
        try await deleteShareKeepsTheBaseline(slimSaveAcks: true)
      }

      /// The batch shape A-F4 names: the share's deletion and the root's rename in ONE fetch. Deletions are
      /// processed first, so before the patch the rename was dropped by the very batch that carried it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func deleteShare_andTheRenameInOneBatch_appliesTheRename() async throws {
        try await seedAndUpload(slimSaveAcks: true)
        let shared = try await syncEngine.share(
          record: RemindersList(id: 1, title: "Daisy Room"),
          configure: { _ in }
        )
        let renamed = try syncEngine.private.database.record(for: listID)
        renamed.setValue("Sunflower Room", forKey: "title", at: now + 60)

        try await syncEngine
          .modifyRecords(scope: .private, saving: [renamed], deleting: [shared.share.recordID])
          .notify()

        #expect(try await localTitle() == "Sunflower Room")
        try await sendTheRowAgain()
        #expect(try serverTitle() == "Sunflower Room")
      }

      /// The patch is not a ratchet the other way: a genuinely unsent local edit made before the share
      /// still reads as unsent, still wins its column, and still goes on to win on the server.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func share_stillProtectsAGenuinelyUnsentLocalEdit() async throws {
        try await seedAndUpload(slimSaveAcks: true)
        _ = try renamedElsewhereUnfetched()
        try await withDependencies {
          $0.currentTime.now += 90
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Rose Room" }.execute(db)
          }
        }

        _ = try await syncEngine.share(
          record: RemindersList(id: 1, title: "Rose Room"),
          configure: { _ in }
        )
        try await fetchTheRoot()
        #expect(try await localTitle() == "Rose Room")

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(try serverTitle() == "Rose Room")
      }

      /// The helper itself, on a record with no baseline and one with: every encrypted key comes from the
      /// baseline or is cleared; system fields stay.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func keepingValues_takesEveryEncryptedKeyFromTheBaseline() throws {
        let fetched = CKRecord(recordType: RemindersList.tableName, recordID: listID)
        fetched.setValue("Sunflower Room", forKey: "title", at: 60)
        fetched.setValue(Int64(3), forKey: "onlyOnTheServer", at: 60)
        let baseline = CKRecord(recordType: RemindersList.tableName, recordID: listID)
        baseline.setValue("Daisy Room", forKey: "title", at: 10)

        #expect(fetched.keepingValues(of: nil) === fetched)

        let kept = fetched.keepingValues(of: baseline)
        #expect(kept !== fetched)
        #expect(kept.recordID == fetched.recordID)
        #expect(kept.encryptedValues["title"] as? String == "Daisy Room")
        #expect(kept.encryptedValues["onlyOnTheServer"] == nil)
        #expect(kept.encryptedValues["\(CKRecord.userModificationTimeKey)_onlyOnTheServer"] == nil)
        #expect(kept.userModificationTime == 10)
        // The fetched record is untouched.
        #expect(fetched.encryptedValues["title"] as? String == "Sunflower Room")
      }

      /// Assets, the one value kept outside `encryptedValues`, follow the baseline too: its asset wins a key
      /// both carry, and an asset only the fetched record carries is cleared.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func keepingValues_takesAssetsFromTheBaseline() throws {
        let baselineURL = URL.temporaryDirectory.appending(path: "baseline-\(UUID().uuidString)")
        let serverURL = URL.temporaryDirectory.appending(path: "server-\(UUID().uuidString)")
        let fetched = CKRecord(recordType: RemindersListAsset.tableName, recordID: listID)
        fetched["coverImage"] = CKAsset(fileURL: serverURL)
        fetched["onlyOnTheServer"] = CKAsset(fileURL: serverURL)
        let baseline = CKRecord(recordType: RemindersListAsset.tableName, recordID: listID)
        baseline["coverImage"] = CKAsset(fileURL: baselineURL)

        let kept = fetched.keepingValues(of: baseline)
        #expect((kept["coverImage"] as? CKAsset)?.fileURL == baselineURL)
        #expect(kept["onlyOnTheServer"] == nil)
        #expect((fetched["coverImage"] as? CKAsset)?.fileURL == serverURL)
      }
    }
  }
#endif
