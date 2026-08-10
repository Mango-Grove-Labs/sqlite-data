#if canImport(CloudKit)
  import CloudKit
  import CustomDump
  import Dependencies
  import Foundation
  import SQLiteData
  import Testing
  import TestLocals

  // MonteSprout incident 2026-07-18 — REGRESSION TEST for a dependency-version defect.
  //
  // **Root cause (confirmed):** this package is written and tested against
  // **swift-structured-queries 0.31.1** (see `Package.resolved`), but upstream declared the dependency
  // `from: "0.31.0"` — unbounded — so a consumer's SPM graph silently resolved **0.33.1**. At 0.33.1 the
  // generated column decoding for `SyncMetadata` misaligns and the send path's metadata read fails with:
  //
  //     QueryCursor<(SyncMetadata, Optional<CKRecord>)>.DecodingError:
  //       Expected column 14 ("userModificationTime") to not be NULL
  //
  // The message is a lie — `userModificationTime` is `INTEGER NOT NULL` in a STRICT table and every row on
  // the affected device held a valid value. `QueryCursor` reports `decoder.currentIndex - 1`, i.e. wherever
  // the decoder gave up, so the named column is an artefact of the misalignment, not its cause.
  //
  // **Why it is catastrophic rather than noisy.** `SyncEngine.nextRecordZoneChangeBatch` (SyncEngine.swift
  // :1132-1148) cannot distinguish "this record is gone" from "I failed to read it" — either way it runs
  // `state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])`. The record leaves the upload queue,
  // never gets a server record, keeps the same shape, and fails identically forever. Outbound sync dies
  // silently: MonteSprout TestFlight 1.0(12) uploaded **nothing** for six days across two testers' devices
  // (Sentry 7607055566), and the app's own sync health reported "ok" throughout.
  //
  // **Why nothing caught it:** this suite runs against the pinned 0.31.1 while consumers ran 0.33.1 — two
  // different dependency worlds. Reproduction was only possible by varying the *dependency version*, not the
  // data: the same code decodes the real device metadatabase correctly on macOS and iOS at 0.31.1.
  //
  // **The fix** is the bounded range in `Package.swift` (MANGO PATCH 3). These tests are the tripwire: they
  // pass at 0.31.x and fail with the exact production error the moment someone widens that range without
  // upgrading the fork. To verify by hand, temporarily point `Package.resolved` at 0.33.1 and re-run — all
  // four fail.
  //
  // Full forensics: MonteSprout `docs/incidents/2026-07-18-metadata-decode-blocks-all-uploads.md`.

  extension BaseCloudKitTests {
    @MainActor
    final class PendingRecordMetadataDecodeTests: BaseCloudKitTests, @unchecked Sendable {

      /// A real `clock_gettime_nsec_np(CLOCK_REALTIME)` reading from the affected device — the exact value
      /// sitting in its metadatabase. Used verbatim so the tests run the production shape rather than the
      /// suite's default clock of 0. It is realism, **not** the trigger: this magnitude was tested and ruled
      /// out (see `neverUploadedRecordMetadataDecodesAtZeroClock`).
      static let deviceRealtimeNanos: Int64 = 1_784_409_193_458_805_000

      /// The core defect, isolated: the exact query the send path runs, against a record awaiting its
      /// first upload, with a realistic wall-clock `userModificationTime`.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func neverUploadedRecordMetadataDecodesWithRealisticClock() async throws {
        try await withDependencies {
          $0.currentTime.now = Self.deviceRealtimeNanos
        } operation: {
          // Seeding writes the row + its metadata via the library's triggers. We deliberately do NOT sync,
          // so both `CKRecord?` columns stay NULL — the never-uploaded shape.
          try await userDatabase.userWrite { db in
            try db.seed { RemindersList(id: 1, title: "Personal") }
          }

          let recordID = RemindersList.recordID(for: 1)

          // Ground truth straight out of SQLite, bypassing the tuple decode entirely.
          let storedTime = try await syncEngine.metadatabase.read { db in
            try SyncMetadata.find(recordID).select(\.userModificationTime).fetchOne(db)
          }
          #expect(storedTime == Self.deviceRealtimeNanos, "the row really does hold the realistic value")

          // The decode under test — verbatim the send path's query (SyncEngine.swift:1140).
          let row = try await syncEngine.metadatabase.read { db in
            try SyncMetadata
              .find(recordID)
              .select { ($0, $0._lastKnownServerRecordAllFields) }
              .fetchOne(db)
          }

          let metadata = try #require(row?.0, "the pending record's metadata must decode")
          #expect(metadata.recordType == "remindersLists")
          // The field the bogus error blames — it must survive the decode intact.
          #expect(metadata.userModificationTime == Self.deviceRealtimeNanos)
          // Legitimately nil for a never-uploaded record; it must not take the row down with it.
          #expect(row?.1 == nil)

          // Drain the queue so the harness' "no pending changes at teardown" invariant holds.
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        }
      }

      /// The consequence, end to end: with a realistic clock, a never-uploaded record must actually reach
      /// the server rather than being silently dropped from the pending queue.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func neverUploadedRecordIsActuallySentWithRealisticClock() async throws {
        try await withDependencies {
          $0.currentTime.now = Self.deviceRealtimeNanos
        } operation: {
          try await userDatabase.userWrite { db in
            try db.seed { RemindersList(id: 1, title: "Personal") }
          }

          try await syncEngine.processPendingRecordZoneChanges(scope: .private)

          let saved = syncEngine.private.database.state.storage[syncEngine.defaultZone.zoneID]?
            .records[RemindersList.recordID(for: 1)]

          #expect(
            saved != nil,
            "a record awaiting its first upload must be sent, not dropped from the pending queue"
          )
        }
      }

      /// The device's failing rows are overwhelmingly **child** records (165 of 166 carry a non-null
      /// `parentRecordPrimaryKey`) that have never been uploaded. This exercises that exact shape.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func neverUploadedChildRecordMetadataDecodes() async throws {
        try await withDependencies {
          $0.currentTime.now = Self.deviceRealtimeNanos
        } operation: {
          try await userDatabase.userWrite { db in
            try db.seed {
              RemindersList(id: 1, title: "Personal")
              Reminder(id: 1, title: "Groceries", remindersListID: 1)
            }
          }

          let recordID = Reminder.recordID(for: 1)

          let parent = try await syncEngine.metadatabase.read { db in
            try SyncMetadata.find(recordID).select(\.parentRecordPrimaryKey).fetchOne(db)
          }
          #expect(parent != nil, "precondition: this is a child record")

          let row = try await syncEngine.metadatabase.read { db in
            try SyncMetadata
              .find(recordID)
              .select { ($0, $0._lastKnownServerRecordAllFields) }
              .fetchOne(db)
          }
          let metadata = try #require(row?.0, "a pending CHILD record's metadata must decode")
          #expect(metadata.userModificationTime == Self.deviceRealtimeNanos)

          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        }
      }

      /// The same decode at the suite's default clock (0), i.e. the shape every other CloudKit test runs.
      ///
      /// It is NOT a control that isolates the trigger — the magnitude of `userModificationTime` was
      /// explicitly ruled out (incident reproduction attempt #3 fed this suite the device's exact
      /// `1_784_409_193_458_805_000` and it decoded fine). The trigger is the dependency version alone, and
      /// this test fails at 0.33.1 right alongside the other three. It earns its place by proving the
      /// tripwire isn't an artefact of the realistic-clock scaffolding: the failure follows the version even
      /// with none of that in play.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func neverUploadedRecordMetadataDecodesAtZeroClock() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }

        let row = try await syncEngine.metadatabase.read { db in
          try SyncMetadata
            .find(RemindersList.recordID(for: 1))
            .select { ($0, $0._lastKnownServerRecordAllFields) }
            .fetchOne(db)
        }
        let metadata = try #require(row?.0)
        #expect(metadata.userModificationTime == 0)

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
      }
    }
  }
#endif
