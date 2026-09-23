#if canImport(CloudKit)
  import CloudKit
  import Dependencies
  import Foundation
  import SQLiteData
  import Testing

  // MonteSprout Phase 82.8 — F47 at the desk: two writers, one row, and a save acknowledgement that
  // carries no encrypted fields.
  //
  // The field report (74.5): a lead edited an assistant's note, three devices disagreed about its text
  // for twenty minutes, and the author's phone showed HER OWN words under "Edited by <the lead>".
  // The code-reading hypothesis, stated so it could be falsified:
  //
  //   1. A real CloudKit save ack does not carry the record's encrypted custom fields (the same fact
  //      patch 7's F2 amendment records from the stamp's side).
  //   2. `refreshLastKnownServerRecord` (`SyncEngine.swift`) writes whatever the ack holds into
  //      `_lastKnownServerRecordAllFields` — unconditionally while the archived record carries no
  //      `modificationDate` to compare against, which is the mock's case and CloudKit's on a fresh archive.
  //   3. That archive is the baseline the next fetch's per-field merge reads
  //      (`upsertFromServerRecord` → `CKRecord.update(with:row:columnNames:)`): a local column whose value
  //      differs from the archive is read as "an unsent local edit" and is REMOVED from the columns the
  //      incoming server record may write.
  //   4. Against a slim archive every NON-NULL local column differs, so the other writer's value is
  //      dropped for those columns: the local row keeps its own text while the server holds the other
  //      writer's — and NULL columns, which match the slim archive, still take the server's value.
  //
  // These tests play exactly that. The hypothesis holds, and two things it did not predict are pinned
  // here too: the divergence is **permanent and silent** (the archive heals to the fetched record, the
  // local row is never re-enqueued, so both sides believe they are in sync while they disagree), and it
  // needs **no local edit at all** — any row this device uploaded is exposed until a full fetch of it
  // re-heals the archive.
  //
  // `fullSaveAck_convergesOnTheLeadsWords` is the vacuity check: with the mock's usual full echo the
  // same script converges, so the divergence is the ack's shape and not the harness.
  //
  // ONE LINK THE DESK CANNOT EXERCISE, stated so nobody reads more into these tests than they show:
  // `refreshLastKnownServerRecord` only replaces the archive when the archived record has no
  // `modificationDate` or an older one. The mock never sets `modificationDate` on anything, so here the
  // replacement is always taken. Against the real service the ack for a fresh save carries a newer
  // `modificationDate` than the archive it replaces, so the same branch is taken — but that is reasoning,
  // not evidence from this file, and it is the one place a real-world narrowing of the trigger could hide.
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
      /// the lead's words land on the author's device and every copy agrees.
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

      /// F47, reproduced: the same two writers, acknowledged the way the real service acknowledges, leave
      /// the author's device showing her own words while the server holds the lead's.
      ///
      /// And it does not resolve itself. The archive heals to the fetched record and no save is
      /// re-enqueued, so the divergence is permanent and invisible from both ends — which is what 74.5
      /// watched for twenty minutes behind clean sync doctors.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func slimSaveAck_leavesTheAuthorsDeviceDivergedForGood() async throws {
        try await seedAndUpload(slimSaveAcks: true)
        try await authorWritesAndUploads()
        #expect(try serverTitle() == "her words")
        // The stomp itself: the ack the author's own upload received carried no fields.
        #expect(try await archivedTitle() == nil)

        try await leadEditsAndIsFetched()

        #expect(try serverTitle() == "the lead's words")
        #expect(try await localReminder()?.title == "her words")  // the divergence
        // Healed archive + nothing pending = neither side has anything left to do about it.
        #expect(try await archivedTitle() == "the lead's words")
        syncEngine.private.state.assertPendingRecordZoneChanges([])
      }

      /// The mechanism, isolated: it is the per-field merge baseline, not the fetch. In the same round the
      /// lead sets two columns — `title`, which the author's row holds non-NULL, and `priority`, which is
      /// NULL locally. The NULL column matches the slim archive, so it is not read as an unsent local edit
      /// and the lead's value lands; the non-NULL one is dropped.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func slimSaveAck_dropsTheNonNullColumnsOnly() async throws {
        try await seedAndUpload(slimSaveAcks: true)
        try await authorWritesAndUploads()

        try await leadEditsAndIsFetched(alsoSettingPriority: true)

        let local = try await localReminder()
        #expect(local?.title == "her words")  // dropped
        #expect(local?.priority == 3)  // applied
      }

      /// How wide the trigger is: no local edit is needed, and no unsynced window. A row this device merely
      /// UPLOADED — its ack slim, its archive never re-healed by a fetch — drops the other writer's edit
      /// just the same, for every column it holds non-NULL. "Two people in one note inside one unsynced
      /// window" is not the precondition; having uploaded the row is.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func slimSaveAck_hitsARowThisDeviceOnlyUploaded() async throws {
        try await seedAndUpload(slimSaveAcks: true)
        #expect(try await localReminder()?.title == "")

        try await leadEditsAndIsFetched()

        #expect(try serverTitle() == "the lead's words")
        #expect(try await localReminder()?.title == "")  // the seeded value, never overwritten
        syncEngine.private.state.assertPendingRecordZoneChanges([])
      }
    }
  }
#endif
