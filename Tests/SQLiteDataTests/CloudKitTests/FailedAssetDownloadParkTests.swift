#if canImport(CloudKit)
  import CloudKit
  import Dependencies
  import SQLiteData
  import Testing

  // MontiSprout fork (45.4 / patch 4): a fetched record whose `CKAsset` cannot be loaded must be
  // PARKED for retry, never written as a literal `NULL`. Upstream maps the failed load to `NULL`:
  // on a `NOT NULL` bytes column the insert fails and the record is dropped from the fetch with the
  // change token advanced — a permanent local husk that is never re-delivered (Sentry 7619718981);
  // on a nullable column it would silently overwrite existing good bytes with `NULL`. The fork
  // throws `AssetDataNotLoadable` out of the upsert builder and parks the record in
  // `UnsyncedRecordID` (patch-1 idiom), so a later fetch round — whose records carry freshly
  // downloaded assets — retries the whole row.
  //
  // Why direct handler injection: `MockCloudDatabase` re-materializes asset data on every
  // fetch/notify (`record(for:)` saves the server-held bytes to a fresh URL), so an end-to-end
  // delivery can never present an unloadable asset — exactly the well-behaved path that masked
  // this bug. The tests therefore inject the stale record straight into
  // `handleFetchedRecordZoneChanges` (the `ReferenceViolationGuardTests` idiom), then use the real
  // delivery path for the retry half.
  //
  // Vacuity guard (rebase procedure step 4): reverting the patch-4 hunks in `SyncEngine.swift`
  // makes both tests go RED — the failed statement is reported-and-dropped, nothing is parked, and
  // the first-delivery row never lands even after the asset loads. Restoring the patch → green.
  extension BaseCloudKitTests {
    @MainActor
    final class FailedAssetDownloadParkTests: BaseCloudKitTests, @unchecked Sendable {
      /// The core guard: a first-delivery record whose asset data cannot be loaded is parked, not
      /// inserted with `NULL` — and the sibling record in the same batch still applies (the park
      /// is per-record, no batch poisoning). The re-delivery with a loadable asset lands the row
      /// and clears the park. The `withKnownIssue` pins the patch's diagnostic: a parked record
      /// still reports, so the failure never goes invisible.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func unloadableAsset_isParkedForRetry_notWrittenAsNull() async throws {
        let remindersListRecord = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1)
        )
        remindersListRecord.setValue("1", forKey: "id", at: now)
        remindersListRecord.setValue("Personal", forKey: "title", at: now)

        let fileURL = URL(fileURLWithPath: UUID().uuidString)
        try inMemoryDataManager.save(Data("image".utf8), to: fileURL)
        let assetRecord = CKRecord(
          recordType: RemindersListAsset.tableName,
          recordID: RemindersListAsset.recordID(for: 1)
        )
        assetRecord.setValue("1", forKey: "id", at: now)
        assetRecord.setAsset(CKAsset(fileURL: fileURL), forKey: "coverImage", at: now)
        assetRecord.setValue("1", forKey: "remindersListID", at: now)
        assetRecord.parent = CKRecord.Reference(record: remindersListRecord, action: .none)

        // The server accepts both records (capturing the asset bytes server-side, so the later
        // re-delivery can materialize them again)…
        let modification = try syncEngine.modifyRecords(
          scope: .private,
          saving: [assetRecord, remindersListRecord]
        )
        // …but the asset's local backing file vanishes before the fetch applies it — CloudKit's
        // *temporary* asset file lifecycle, or a plain failed download.
        inMemoryDataManager.storage.withValue { $0[fileURL] = nil }
        await withKnownIssue {
          await syncEngine.handleFetchedRecordZoneChanges(
            modifications: [assetRecord, remindersListRecord],
            syncEngine: syncEngine.private
          )
        }

        // No husk: the row is absent, not present-with-NULL — and the sibling record from the
        // same batch still applied.
        try await userDatabase.read { db in
          try #expect(RemindersListAsset.all.fetchCount(db) == 0)
          try #expect(RemindersList.all.fetchCount(db) == 1)
        }
        // The record is parked, so the failure is a retry, not a decision.
        try await syncEngine.metadatabase.read { db in
          try #expect(
            UnsyncedRecordID.find(RemindersListAsset.recordID(for: 1)).fetchCount(db) == 1
          )
        }

        // The real delivery arrives — the mock's fetch materializes the server-held asset bytes
        // to a fresh, loadable file, as a real fetch's completed download does. The row lands and
        // the park clears.
        await modification.notify()

        try await userDatabase.read { db in
          let asset = try #require(try RemindersListAsset.find(1).fetchOne(db))
          #expect(asset.coverImage == Data("image".utf8))
        }
        // Park cleared by the successful apply (also the harness's teardown invariant).
        try await syncEngine.metadatabase.read { db in
          try #expect(
            UnsyncedRecordID.find(RemindersListAsset.recordID(for: 1)).fetchCount(db) == 0
          )
        }
      }

      /// The update half: when a row already holds good bytes and the server delivers an updated
      /// asset that fails to download, the old bytes survive untouched (no `NULL` overwrite, no
      /// failed-statement husk) and the record parks until the new bytes actually load.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func existingBytes_surviveUnloadableAssetUpdate() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            RemindersListAsset(remindersListID: 1, coverImage: Data("image".utf8))
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let modification = try await withDependencies {
          $0.currentTime.now += 1
        } operation: {
          let fileURL = URL(fileURLWithPath: UUID().uuidString)
          try inMemoryDataManager.save(Data("new-image".utf8), to: fileURL)
          let assetRecord = try syncEngine.private.database.record(
            for: RemindersListAsset.recordID(for: 1)
          )
          assetRecord.setAsset(CKAsset(fileURL: fileURL), forKey: "coverImage", at: now)
          // The server accepts the update (capturing the new bytes server-side)…
          let modification = try syncEngine.modifyRecords(
            scope: .private,
            saving: [assetRecord]
          )
          // …but the update's asset file cannot be read when the fetch applies it.
          inMemoryDataManager.storage.withValue { $0[fileURL] = nil }
          await withKnownIssue {
            await syncEngine.handleFetchedRecordZoneChanges(
              modifications: [assetRecord],
              syncEngine: syncEngine.private
            )
          }
          return modification
        }

        // The good bytes are still there — a transient download failure destroyed nothing.
        try await userDatabase.read { db in
          let asset = try #require(try RemindersListAsset.find(1).fetchOne(db))
          #expect(asset.coverImage == Data("image".utf8))
        }
        try await syncEngine.metadatabase.read { db in
          try #expect(
            UnsyncedRecordID.find(RemindersListAsset.recordID(for: 1)).fetchCount(db) == 1
          )
        }

        // The download succeeds on the re-delivery; the update lands and the park clears.
        await modification.notify()

        try await userDatabase.read { db in
          let asset = try #require(try RemindersListAsset.find(1).fetchOne(db))
          #expect(asset.coverImage == Data("new-image".utf8))
        }
        try await syncEngine.metadatabase.read { db in
          try #expect(
            UnsyncedRecordID.find(RemindersListAsset.recordID(for: 1)).fetchCount(db) == 0
          )
        }
      }
    }
  }
#endif
