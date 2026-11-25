#if canImport(CloudKit)
  import CloudKit
  import Dependencies
  import Foundation
  import SQLiteData
  import Testing

  // MANGO PATCH 24 (MonteSprout 120.5, the 2026-11-25 bug bash's A-F5) — a local edit is stamped after
  // everything this device has seen.
  //
  // The user-write trigger stamped the row with the plain wall clock. A fetched server record raises the
  // row's stamp to its own (`setLastKnownServerRecord`), and its per-field stamps land in the archive; with
  // the other device's clock ahead, a local edit made right after that fetch took a stamp OLDER than the
  // archive's stamp for the column, the batch builder's `setValue(_:at:)` refused it, and the other device's
  // value went out instead. The row then differed from its baseline, so every later fetch protected the
  // column as an unsent edit (the field froze on this device), and the row's next send wrote the stale
  // local value back over the server. In MonteSprout terms: a co-teacher's iPad set by hand a few seconds
  // fast fixes a note's wording, the lead corrects it on her iPhone just after, and her correction never
  // leaves the phone.
  //
  // Guard (neutralize in place): the trigger's `else` back to `$currentTime()` reddens the two skew tests and the one-tick test.
  extension BaseCloudKitTests {
    @MainActor
    @Suite
    final class ClockSkewStampTests: BaseCloudKitTests, @unchecked Sendable {
      private let listID = RemindersList.recordID(for: 1)
      /// How far the other device's clock runs ahead of this one's.
      private let skew: Int64 = 10_000_000_000

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
      private func stamp(_ id: Int) async throws -> Int64? {
        try await syncEngine.metadatabase.read { db in
          try SyncMetadata
            .find(RemindersList.recordID(for: id))
            .select(\.userModificationTime)
            .fetchOne(db)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func seedAndUpload() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Daisy Room")
            RemindersList(id: 2, title: "Rose Room")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
      }

      /// The other device (clock `skew` ahead) edits the title, and this device fetches it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func editedElsewhereAndFetched(_ title: String, at stamp: Int64) async throws {
        let record = try syncEngine.private.database.record(for: listID)
        record.setValue(title, forKey: "title", at: stamp)
        _ = try syncEngine.modifyRecords(scope: .private, saving: [record])
        let current = try syncEngine.private.database.record(for: listID)
        await syncEngine.private.parentSyncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [current], deletions: []),
          syncEngine: syncEngine.private
        )
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func editLocally(_ title: String, id: Int = 1) async throws {
        try await userDatabase.userWrite { db in
          try RemindersList.find(id).update { $0.title = title }.execute(db)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func skewScenario(slimSaveAcks: Bool) async throws {
        if slimSaveAcks {
          syncEngine.private.database.enableSlimSaveAcks()
        }
        try await seedAndUpload()
        try await editedElsewhereAndFetched("Sunflower Room", at: now + skew)
        #expect(try await localTitle() == "Sunflower Room")

        // This device's clock still reads `now`: the edit comes after the fetch, behind the other clock.
        try await editLocally("Tulip Room")
        let stamped = try #require(try await stamp(1))
        #expect(stamped > now + skew)

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(try serverTitle() == "Tulip Room")
        #expect(try await localTitle() == "Tulip Room")

        // The column did not freeze: the other device's next edit reaches this device.
        try await editedElsewhereAndFetched("Lily Room", at: now + 2 * skew)
        #expect(try await localTitle() == "Lily Room")
        // Applied as the server's value, not protected as an unsent edit: nothing is left to send.
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aLocalEditBehindASkewedFetch_isSent_fullSaveAcks() async throws {
        try await skewScenario(slimSaveAcks: false)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aLocalEditBehindASkewedFetch_isSent_slimSaveAcks() async throws {
        try await skewScenario(slimSaveAcks: true)
      }

      /// With the clock ahead of everything seen, the stamp is the clock — the patch only ever moves a
      /// stamp forward by the minimum.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aLocalEditWithTheClockAhead_isStampedWithTheClock() async throws {
        try await seedAndUpload()
        try await withDependencies {
          $0.currentTime.now = 500
        } operation: {
          try await editLocally("Tulip Room")
        }
        #expect(try await stamp(1) == 500)
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
      }

      /// The stamp moves strictly forward per write even when the clock does not (two writes in one tick).
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func twoWritesInOneTick_stampStrictlyForward() async throws {
        try await seedAndUpload()
        let before = try #require(try await stamp(1))
        try await editLocally("Tulip Room")
        let first = try #require(try await stamp(1))
        try await editLocally("Lily Room")
        let second = try #require(try await stamp(1))
        #expect(first > before)
        #expect(second > first)
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
      }

      /// No ratchet across rows: a high stamp on one row does not lift another row's next stamp.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aSkewedRow_doesNotLiftAnotherRowsStamp() async throws {
        try await seedAndUpload()
        try await editedElsewhereAndFetched("Sunflower Room", at: now + skew)
        try await withDependencies {
          $0.currentTime.now = 500
        } operation: {
          try await editLocally("Peony Room", id: 2)
        }
        #expect(try await stamp(2) == 500)
        #expect(try #require(try await stamp(1)) >= now + skew)
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
      }
    }
  }
#endif
