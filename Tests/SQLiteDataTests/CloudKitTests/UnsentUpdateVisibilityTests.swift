#if canImport(CloudKit)
  import CloudKit
  import Dependencies
  import OrderedCollections
  import SQLiteData
  import Testing

  // MonteSprout Phase 41.2a — why "pending = 0" can be honest and still hide unsent data.
  //
  // Consumers derive their "waiting to upload" number from the metadata's server record: MonteSprout's sync
  // doctor counts `lastKnownServerRecord IS NULL AND _isDeleted = 0`, and MangoSync's `UploadTruth` derives
  // `unconfirmed` from the same fact via `hasLastKnownServerRecord`. Both therefore measure **"has this row
  // EVER reached the server"** — not "are this row's current bytes on the server".
  //
  // That distinction has a blind spot with a name: an **update to an already-synced row**. The local write
  // trigger bumps `userModificationTime` and deliberately leaves `lastKnownServerRecord` alone (it still holds
  // the previous server version), so a save that never lands leaves every never-confirmed count reading **0**
  // while the edit is genuinely unsent. This is a **characterization** test — it pins library behavior the two
  // consumer probes depend on, and it is the third mechanism the 1.0(15) matrix's `pending=0`-while-unsent
  // reading could have been (the other two: a record dropped before its first upload, which these counts DO
  // see, and an acked record whose visibility stalled on the fetch side).
  //
  // It also pins the discriminator that *would* see it, for whoever implements that probe: the metadata's
  // `userModificationTime` versus the **all-fields** server record's own. A successful save stamps the server
  // record from the metadata, so the two are equal after a round trip and diverge exactly while an edit is
  // unsent. Note it must be `_lastKnownServerRecordAllFields`: `userModificationTime` lives in
  // `encryptedValues`, which `lastKnownServerRecord`'s system-fields archive does not carry.
  extension BaseCloudKitTests {
    @MainActor
    final class UnsentUpdateVisibilityTests: BaseCloudKitTests, @unchecked Sendable {
      /// Mirrors MonteSprout's sync-doctor query verbatim — the number that read 0 on the device.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func recordsAwaitingUpload() async throws -> Int {
        try await syncEngine.metadatabase.read { db in
          try Int.fetchOne(
            db,
            sql: #"""
              SELECT count(*) FROM "sqlitedata_icloud_metadata"
               WHERE "lastKnownServerRecord" IS NULL AND "_isDeleted" = 0
              """#
          ) ?? -1
        }
      }

      /// Patch 7's mirrored column, read as SQL sees it — deliberately NOT via the archived record, so a
      /// test of the mirror cannot pass by accidentally reading the thing the mirror copies.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func mirroredServerStamp() async throws -> Int64? {
        try await syncEngine.metadatabase.read { db in
          try Int64.fetchOne(
            db,
            sql: #"""
              SELECT "serverUserModificationTime" FROM "sqlitedata_icloud_metadata"
               WHERE "recordPrimaryKey" = '1' AND "recordType" = 'remindersLists'
              """#
          )
        }
      }

      /// The consumer-side predicate the mirror exists to enable (MonteSprout's unsent-edit count).
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func unsentEdits() async throws -> Int {
        try await syncEngine.metadatabase.read { db in
          try Int.fetchOne(
            db,
            sql: #"""
              SELECT count(*) FROM "sqlitedata_icloud_metadata"
               WHERE "lastKnownServerRecord" IS NOT NULL
                 AND "serverUserModificationTime" < "userModificationTime"
                 AND "_isDeleted" = 0
              """#
          ) ?? -1
        }
      }

      /// The metadata's own modification time and the one archived in the all-fields server record.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func modificationTimes() async throws -> (local: Int64, server: Int64?) {
        try await syncEngine.metadatabase.read { db in
          let row = try SyncMetadata
            .find(RemindersList.recordID(for: 1))
            .select { ($0.userModificationTime, $0._lastKnownServerRecordAllFields) }
            .fetchOne(db)
          return (row?.0 ?? -1, row?.1?.userModificationTime)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func anUnsentUpdateIsInvisibleToEveryNeverConfirmedCount() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        // One full round trip: the row now has a server record, so nothing is "awaiting upload"…
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(try await recordsAwaitingUpload() == 0)
        // …and the two modification times agree, because the save stamped the server record from the metadata.
        let synced = try await modificationTimes()
        #expect(synced.server == synced.local)

        // A local edit, clock advanced, and NO sync round after it.
        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Renamed" }.execute(db)
          }
        }

        // The blind spot, stated as an assertion: the edit is unsent, and the count says zero.
        #expect(try await recordsAwaitingUpload() == 0)

        // The discriminator that does see it — local time has moved past the server's.
        let edited = try await modificationTimes()
        #expect(edited.local > synced.local)
        #expect(edited.server == synced.server)  // the server record is untouched by a local write
        #expect(edited.server! < edited.local)

        // The engine itself does know: the save is pending. (Asserting also drains the pending set,
        // satisfying the harness's empty-pending-changes teardown invariant.)
        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(RemindersList.recordID(for: 1))
        ])
      }

      /// Patch 7's column, end to end: `nil` before the first upload, equal to the local stamp after a
      /// round trip, behind it exactly while an edit is unsent, and level again once that edit lands.
      /// This is the whole point of the mirror — the state above becomes an ordinary SQL predicate.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func theMirroredServerStampMakesAnUnsentEditCountable() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        // Never uploaded: no server record, so no mirrored stamp — and nothing to call an *edit* yet
        // (the existing "never confirmed" counts already see this row).
        #expect(try await mirroredServerStamp() == nil)
        #expect(try await unsentEdits() == 0)

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        var times = try await modificationTimes()
        #expect(times.server == times.local)  // in sync after the round trip
        #expect(try await mirroredServerStamp() == times.local)  // …and the mirror agrees with the archive
        #expect(try await unsentEdits() == 0)

        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Renamed" }.execute(db)
          }
        }
        times = try await modificationTimes()
        #expect(times.server! < times.local)
        #expect(try await unsentEdits() == 1)  // the reading the old counts could not produce

        // …and it goes back to zero on its own once the edit reaches the server.
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        times = try await modificationTimes()
        #expect(times.server == times.local)
        #expect(try await unsentEdits() == 0)
      }

      /// Clearing the server record must clear the mirror with it — a leftover stamp would read as "in
      /// sync" with a server copy that no longer exists. Driven through the real path that clears
      /// (`.serverRejectedRequest`, whose handler calls `setLastKnownServerRecord(nil)`) rather than the
      /// helper, so it pins the behavior a consumer actually meets.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func clearingTheServerRecordClearsTheMirror() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(try await mirroredServerStamp() != nil)

        let failed = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1)
        )
        // The handler reports the dropped save (patch 2), hence `withKnownIssue`.
        await withKnownIssue {
          await syncEngine.handleSentRecordZoneChanges(
            failedRecordSaves: [(failed, CKError(.serverRejectedRequest))],
            syncEngine: syncEngine.private
          )
        }

        #expect(try await mirroredServerStamp() == nil)
      }

      /// Patch 7 amendment (F2, the 1.0(16) matrix false-positive): a save ack that does NOT carry the
      /// encrypted custom fields — what real CloudKit delivers, unlike the mocked container's full-record
      /// echo — must never land the `?? -1` getter fallback in the mirror. On a first upload the mirror
      /// stays `nil` ("stamp unknown"), and the unsent-edit count stays 0 instead of false-positiving on
      /// every uploaded row forever (the fetch path already refuses stampless records at the top of
      /// `upsertFromServerRecord`; this pins the same discipline on the save-ack path).
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aStamplessSaveAckNeverInventsAMirrorStamp() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        // The ack for the pending save arrives slim: system fields only, no encrypted values.
        let slimAck = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1)
        )
        await syncEngine.handleSentRecordZoneChanges(
          savedRecords: [slimAck],
          syncEngine: syncEngine.private
        )

        // The row did reach the server (the never-confirmed count no longer sees it)…
        #expect(try await recordsAwaitingUpload() == 0)
        // …and the mirror holds no invented stamp: nil, not -1 — so the predicate reads 0, not 1.
        #expect(try await mirroredServerStamp() == nil)
        #expect(try await unsentEdits() == 0)

        // The seeded row's save is still in the engine's pending set — the injection above is the ack
        // handler alone, not a send round. (Asserting also drains it for the harness teardown.)
        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(RemindersList.recordID(for: 1))
        ])
      }

      /// The update half of the same guard: a slim re-ack after a genuine round trip must PRESERVE the
      /// earlier, correct mirror stamp — never overwrite it with the -1 fallback. (On a nullable-mirror
      /// row this is the stamp-stomp direction: good data destroyed by an ack that carried nothing.)
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aStamplessReAckPreservesTheEarlierMirrorStamp() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let confirmed = try await mirroredServerStamp()
        #expect(confirmed != nil)  // the full mock round trip mirrored the real stamp

        let slimAck = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1)
        )
        await syncEngine.handleSentRecordZoneChanges(
          savedRecords: [slimAck],
          syncEngine: syncEngine.private
        )

        #expect(try await mirroredServerStamp() == confirmed)
        #expect(try await unsentEdits() == 0)
      }

      /// Patch 7 amendment (F4, the 2026-08-23 two-account session): applying a record that came DOWN
      /// from the server must not leave the row reading as a locally-unsent edit. The sync engine's own
      /// row write fires the user table's after-update trigger, which stamps the metadata's
      /// `userModificationTime` with the wall clock — a value no user edit produced — while the mirror is
      /// stamped from the server record. Local then sits strictly ahead of the mirror and the row counts
      /// as unsent forever. Sharing a zone re-delivers every record in it, which is why the field reading
      /// was the device's whole row set (iPhone 0 → 180 the moment a room was shared).
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aRecordAppliedFromTheServerIsNotAnUnsentEdit() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(try await unsentEdits() == 0)
        let confirmed = try await mirroredServerStamp()

        // The server re-delivers the record already on this device, unchanged — what a share does to
        // every record in the zone. Time has moved on, as it always has by the next fetch round.
        let serverRecord = try syncEngine.private.database.record(
          for: RemindersList.recordID(for: 1)
        )
        await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          await syncEngine.handleFetchedRecordZoneChanges(
            modifications: [serverRecord],
            syncEngine: syncEngine.private
          )
        }

        // Nothing was edited here, so nothing is waiting to upload.
        #expect(try await unsentEdits() == 0)
        // …and the mirror still describes the server copy it was stamped from.
        #expect(try await mirroredServerStamp() == confirmed)
        let times = try await modificationTimes()
        #expect(times.server == times.local)
      }

      /// The other half of the same guard: an edit made **after** the fetch applied is still an unsent
      /// edit. The fix above must not make the fetch path a blanket "declare this row clean" — the
      /// discriminator has to keep discriminating.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func anEditAfterAServerApplyIsStillAnUnsentEdit() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let serverRecord = try syncEngine.private.database.record(
          for: RemindersList.recordID(for: 1)
        )
        await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          await syncEngine.handleFetchedRecordZoneChanges(
            modifications: [serverRecord],
            syncEngine: syncEngine.private
          )
        }
        #expect(try await unsentEdits() == 0)

        try await withDependencies {
          $0.currentTime.now += 120
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Renamed" }.execute(db)
          }
        }
        #expect(try await unsentEdits() == 1)

        // Drain the pending save for the harness's teardown invariant.
        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(RemindersList.recordID(for: 1))
        ])
      }

      /// Characterization, NOT a fixed behavior — the residual patch 14 deliberately leaves standing.
      /// A row that arrived by FETCH carries a real mirror stamp; edit it and upload it, and the only
      /// thing that could level the mirror again is the save ack — which real CloudKit delivers without
      /// the encrypted fields, so patch 7's F2 rule (never invent a stamp) leaves it behind. The row
      /// then reads as an unsent edit after its edit has landed. Fixing it needs the stamp the SENT
      /// record carried, which nothing currently keeps across the batch → ack boundary; that is its own
      /// slice. Pinned here so the next reading of "Unsent edits > 0" is not re-diagnosed from scratch.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aSlimAckCannotLevelTheMirrorOfAFetchedRow() async throws {
        // The row arrives from the server, so the mirror holds a real stamp (not the NULL an
        // upload-only row keeps under the F2 rule).
        let serverRecord = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1)
        )
        serverRecord.setValue("1", forKey: "id", at: now)
        serverRecord.setValue("Personal", forKey: "title", at: now)
        _ = try syncEngine.modifyRecords(scope: .private, saving: [serverRecord])
        await syncEngine.handleFetchedRecordZoneChanges(
          modifications: [serverRecord],
          syncEngine: syncEngine.private
        )
        #expect(try await mirroredServerStamp() != nil)
        #expect(try await unsentEdits() == 0)

        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Renamed" }.execute(db)
          }
        }
        #expect(try await unsentEdits() == 1)  // correct: the edit is genuinely unsent

        // The save lands, and CloudKit's ack carries system fields only.
        let slimAck = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1)
        )
        await syncEngine.handleSentRecordZoneChanges(
          savedRecords: [slimAck],
          syncEngine: syncEngine.private
        )
        // The edit HAS landed, and the count still says 1. This is the residual.
        #expect(try await unsentEdits() == 1)

        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(RemindersList.recordID(for: 1))
        ])
      }

      /// The hardest direction, and the one a "declare the row clean on apply" fix would get wrong: an
      /// edit that is ALREADY unsent when an older server record for the same row arrives. The merge
      /// keeps the local value, the save is still pending, and the count must still say 1. (The mirror
      /// must therefore record the stamp the SERVER record carried, not the one the apply path forces up
      /// to the local time so the merged row can be re-uploaded.)
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func anAlreadyUnsentEditSurvivesAServerApply() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let serverRecord = try syncEngine.private.database.record(
          for: RemindersList.recordID(for: 1)
        )

        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Renamed" }.execute(db)
          }
        }
        #expect(try await unsentEdits() == 1)

        // The server re-delivers its (older) copy. The local edit wins the merge and is still unsent.
        await withDependencies {
          $0.currentTime.now += 120
        } operation: {
          await syncEngine.handleFetchedRecordZoneChanges(
            modifications: [serverRecord],
            syncEngine: syncEngine.private
          )
        }
        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).select(\.title).fetchOne(db) == "Renamed")
        }
        #expect(try await unsentEdits() == 1)

        // Drain the pending save for the harness's teardown invariant.
        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(RemindersList.recordID(for: 1))
        ])
      }
    }
  }
#endif
