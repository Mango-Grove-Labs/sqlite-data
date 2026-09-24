#if canImport(CloudKit)
  import CloudKit
  import Dependencies
  import Foundation
  import SQLiteData
  import Testing

  // MonteSprout Phases 82.8 / 82.9a — F47: two writers, one row, and a save acknowledgement that
  // carries no encrypted fields.
  //
  // The field report (74.5): a lead edited an assistant's note, three devices disagreed about its text
  // for twenty minutes, and the author's phone showed HER OWN words under "Edited by <the lead>".
  // 82.8 measured the mechanism at the desk, and these tests played it:
  //
  //   1. A real CloudKit save ack does not carry the record's encrypted custom fields (the same fact
  //      patch 7's F2 amendment records from the stamp's side).
  //   2. `refreshLastKnownServerRecord` (`SyncEngine.swift`) wrote whatever the ack held into
  //      `_lastKnownServerRecordAllFields`, so after this device's own upload the archive was empty.
  //   3. That archive is the baseline the next fetch's per-field merge reads
  //      (`upsertFromServerRecord` → `CKRecord.update(with:row:columnNames:)`): a local column whose
  //      value differs from the archive is treated as "an unsent local edit" and is REMOVED from the
  //      columns the incoming server record may write.
  //   4. Against an empty baseline every NON-NULL local column differed, so the other writer's value
  //      was dropped for those columns — permanently and silently, because the same fetch healed the
  //      archive and re-enqueued nothing, and with no local edit and no unsynced window needed: any
  //      row this device had uploaded was exposed until a full fetch of it re-healed the baseline.
  //
  // **Patch 18 (82.9a, candidate A) closes it at the ack:** the record this device SENT is the true
  // new server state, so a save ack now merges only its system fields into it
  // (`CKRecord.mergingSaveAcknowledgement(_:)`, over the engine's `sentRecords` map) instead of
  // replacing the archive with a fieldless record.
  // Per-field last-writer-wins is restored, and these tests are its pins: run them against the patch
  // reverted (pass `isSaveAcknowledgement: false` at the ack call site) the three *convergence* tests go
  // red while `fullSaveAck_convergesOnTheLeadsWords` — the vacuity control, which never depended on the
  // archive's shape — stays green; dropping only the sent-record half (`sentRecord: nil` there) reddens
  // `slimSaveAck_archivesWhatWasSent_notWhateverTheArchiveHeld` alone.
  // `slimSaveAck_stillProtectsAGenuinelyUnsentLocalEdit` passes either way by design: it is the patch's
  // non-regression pin, not a repro of the bug, and it is here so a later "just take the server record
  // whole" simplification (82.8's candidate B) cannot land quietly.
  //
  // ONE LINK THE DESK CANNOT EXERCISE, stated so nobody reads more into these tests than they show:
  // `refreshLastKnownServerRecord` only rewrites the archive when the archived record has no
  // `modificationDate` or an older one. The mock never sets `modificationDate` on anything, so here the
  // rewrite is always taken. Against the real service the ack for a fresh save carries a newer
  // `modificationDate` than the archive it re-stamps, so the same branch is taken — but that is
  // reasoning, not evidence from this file. Note that under patch 18 the branch not being taken is now
  // the SAFE outcome (the archive keeps the values it had) rather than the harmful one.
  extension BaseCloudKitTests {
    @MainActor
    final class SlimSaveAckMergeTests: BaseCloudKitTests, @unchecked Sendable {
      /// What the author's phone shows.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func localReminder() async throws -> Reminder? {
        try await userDatabase.read { db in
          try Reminder.find(1).fetchOne(db)
        }
      }

      /// What the server holds.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func serverTitle() throws -> String? {
        try syncEngine.private.database
          .record(for: Reminder.recordID(for: 1))
          .encryptedValues["title"] as? String
      }

      /// The archive the per-field merge reads as "the server's copy".
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func archivedTitle() async throws -> String? {
        try await syncEngine.metadatabase.read { db in
          try SyncMetadata
            .find(Reminder.recordID(for: 1))
            .select(\._lastKnownServerRecordAllFields)
            .fetchOne(db)?
            .flatMap { $0.encryptedValues["title"] as? String }
        }
      }

      /// A row on both sides, uploaded by THIS device — the ack whose shape is under test.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func seedAndUpload(slimSaveAcks: Bool) async throws {
        if slimSaveAcks {
          syncEngine.private.database.enableSlimSaveAcks()
        }
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Daisy Room")
            Reminder(id: 1, title: "", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
      }

      /// The author writes her note and it reaches the server.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func authorWritesAndUploads() async throws {
        try await withDependencies {
          $0.currentTime.now += 30
        } operation: {
          try await userDatabase.userWrite { db in
            try Reminder.find(1).update { $0.title = "her words" }.execute(db)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
      }

      /// The lead edits the same row on another device, later, and the change is fetched here.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func leadEditsAndIsFetched(alsoSettingPriority: Bool = false) async throws {
        let leadsRecord = try syncEngine.private.database.record(for: Reminder.recordID(for: 1))
        leadsRecord.setValue("the lead's words", forKey: "title", at: now + 60)
        if alsoSettingPriority {
          leadsRecord.setValue(Int64(3), forKey: "priority", at: now + 60)
        }
        let leadsSave = try syncEngine.modifyRecords(scope: .private, saving: [leadsRecord])
        await leadsSave.notify()
      }

      /// The control, and the vacuity check: with the mock's usual full echo, last-writer-wins holds —
      /// the lead's words land on the author's device and every copy agrees. Green before patch 18 and
      /// after it, which is what makes the three tests below evidence about the ack's shape.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fullSaveAck_convergesOnTheLeadsWords() async throws {
        try await seedAndUpload(slimSaveAcks: false)
        try await authorWritesAndUploads()
        #expect(try serverTitle() == "her words")

        try await leadEditsAndIsFetched()

        #expect(try serverTitle() == "the lead's words")
        #expect(try await localReminder()?.title == "the lead's words")
        #expect(try await archivedTitle() == "the lead's words")
      }

      /// F47, closed: the same two writers, acknowledged the way the real service acknowledges, now
      /// converge on the lead's words.
      ///
      /// The first assertion after the upload is the patch itself — the ack re-stamps the archive but
      /// leaves the values this device sent standing, so the baseline the next fetch merges against is
      /// honest instead of empty. Before patch 18 the archive read `nil` here, and the author's device
      /// then kept her own sentence for good behind clean sync doctors.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func slimSaveAck_convergesOnTheLeadsWords() async throws {
        try await seedAndUpload(slimSaveAcks: true)
        try await authorWritesAndUploads()
        #expect(try serverTitle() == "her words")
        // Patch 18: the fieldless ack no longer empties the baseline.
        #expect(try await archivedTitle() == "her words")

        try await leadEditsAndIsFetched()

        #expect(try serverTitle() == "the lead's words")
        #expect(try await localReminder()?.title == "the lead's words")
        #expect(try await archivedTitle() == "the lead's words")
        syncEngine.private.state.assertPendingRecordZoneChanges([])
      }

      /// The mechanism, isolated, from the other side: in one round the lead sets two columns — `title`,
      /// which the author's row holds non-NULL, and `priority`, which is NULL locally. Before patch 18
      /// the NULL column matched the empty baseline and landed while the non-NULL one was dropped; that
      /// asymmetry is exactly what named the baseline as the cause, and it is gone.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func slimSaveAck_appliesTheNonNullColumnsToo() async throws {
        try await seedAndUpload(slimSaveAcks: true)
        try await authorWritesAndUploads()

        try await leadEditsAndIsFetched(alsoSettingPriority: true)

        let local = try await localReminder()
        #expect(local?.title == "the lead's words")  // was dropped before patch 18
        #expect(local?.priority == 3)
      }

      /// How wide the trigger was, now covered: no local edit and no unsynced window were needed — a row
      /// this device merely UPLOADED, its ack slim and its archive never re-healed by a fetch, dropped
      /// the other writer's edit to every column it held non-NULL. It takes it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func slimSaveAck_appliesToARowThisDeviceOnlyUploaded() async throws {
        try await seedAndUpload(slimSaveAcks: true)
        #expect(try await localReminder()?.title == "")

        try await leadEditsAndIsFetched()

        #expect(try serverTitle() == "the lead's words")
        #expect(try await localReminder()?.title == "the lead's words")
        syncEngine.private.state.assertPendingRecordZoneChanges([])
      }

      /// The other half of the patch's contract: merging must not make the archive a ratchet. A genuinely
      /// unsent local edit — one made after the upload and never sent — still wins the per-field merge
      /// against a slim ack, because the baseline holds the value the device SENT, not the newer local
      /// one, and the column therefore still reads as unsent.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func slimSaveAck_stillProtectsAGenuinelyUnsentLocalEdit() async throws {
        try await seedAndUpload(slimSaveAcks: true)
        try await authorWritesAndUploads()

        // She types again; this one never leaves the device.
        try await withDependencies {
          $0.currentTime.now += 90
        } operation: {
          try await userDatabase.userWrite { db in
            try Reminder.find(1).update { $0.title = "her second thought" }.execute(db)
          }
        }

        try await leadEditsAndIsFetched()

        #expect(try await localReminder()?.title == "her second thought")

        // And it is still genuinely pending, so it goes on to win on the server too.
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(try serverTitle() == "her second thought")
      }

      /// The half of patch 18 the mock's shape hides, forced into view.
      ///
      /// On the real service the batch builder's own `refreshLastKnownServerRecord` is SKIPPED for any
      /// row whose archive already carries a `modificationDate`: the outgoing record is built from that
      /// archive and inherits its date, so the "is this newer?" guard answers no. The archive therefore
      /// still holds the values of the last *fetch* when the ack lands — not the values just sent. The
      /// mock sets `modificationDate` on nothing, so at the desk that call is always taken and the
      /// archive happens to agree with the wire; merging from the archive would pass every other test
      /// in this file and leave F47 standing in the field.
      ///
      /// This test removes the coincidence instead of simulating the date: it poisons the archive in
      /// the window between the batch going out and its acknowledgement (the seam
      /// `NextRecordZoneChangeBatchTests.editBetweenBatchAndSentRecordZoneChanges` uses), which is the
      /// same state the field is in. Only an ack that archives what this device SENT survives it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func slimSaveAck_archivesWhatWasSent_notWhateverTheArchiveHeld() async throws {
        try await seedAndUpload(slimSaveAcks: true)

        try await withDependencies {
          $0.currentTime.now += 30
        } operation: {
          try await userDatabase.userWrite { db in
            try Reminder.find(1).update { $0.title = "her words" }.execute(db)
          }
        }
        let changes = try await syncEngine.sendPendingRecordZoneChanges(scope: .private)

        // The batch is on the wire. Stand the archive back up holding a stale copy of the row, exactly
        // as the real service's skipped refresh leaves it.
        let stale = try syncEngine.private.database.record(for: Reminder.recordID(for: 1))
        stale.encryptedValues["title"] = "a copy the server no longer has"
        try await userDatabase.write { db in
          try SyncMetadata
            .find(Reminder.recordID(for: 1))
            .update { $0._lastKnownServerRecordAllFields = #bind(stale) }
            .execute(db)
        }

        await changes.receive()

        #expect(try await archivedTitle() == "her words")

        // And the consequence that matters: the lead's edit still lands.
        try await leadEditsAndIsFetched()
        #expect(try await localReminder()?.title == "the lead's words")
      }
    }
  }
#endif
