#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Dependencies
  import IssueReporting
  import SQLiteData
  import Testing

  // MANGO PATCH 21 (MonteSprout Phase 120.1, bug bash 2026-11-25 A-F1) — a row is confirmed by an
  // ack, never by a batch build.
  //
  // Upstream's batch builder archived the OUTGOING record of a never-uploaded row through
  // `setLastKnownServerRecord`: `lastKnownServerRecord` set, `hasLastKnownServerRecord` = 1 and
  // patch 7's mirror levelled, before anything had gone over the wire. A first save then refused
  // with a code that does not clear the server record read as uploaded to every probe — the
  // never-confirmed counts, patch 9's start rescan, a consumer's upload proof — and, for the dropped
  // codes, nothing would ever send it again.
  //
  // The patch: for a row whose `lastKnownServerRecord` is NULL the batch build writes
  // `_lastKnownServerRecordAllFields` ONLY (the values baseline). Confirmation is the ack's, or a
  // fetch's. So "`_lastKnownServerRecordAllFields` set with `lastKnownServerRecord` NULL" reads:
  // sent, not confirmed.
  //
  // Every test here BUILDS A BATCH FIRST, through the package entry point CKSyncEngine calls. That
  // is the step no earlier suite took for a never-uploaded row — `DroppedSaveReportingTests` and
  // `AuthTransitionRetryTests` inject a failure with no batch build, `EngineStartRescanTests` kills
  // the change before the batch is built — and it is why the defect stayed invisible at the desk.
  //
  // Vacuity guards (neutralize in place, never revert the commit; verified 2026-11-25):
  //   - make the `isBatchBuild` early return in `refreshLastKnownServerRecord` unreachable (the batch
  //     build confirms again) → both refusal tests go RED on every unconfirmed reading, and
  //     `aLandedSaveWithALostReply_keepsALaterEdit_andDeliversIt` on its unconfirmed precondition;
  //     the fetch-first crash-window test stays green (it pins the baseline, which the old form
  //     also wrote).
  //   - keep the early return but drop its baseline write (the "no-baseline" form the plan's first
  //     draft had) → both crash-window tests go RED on her edit (local and server read "Personal"),
  //     and the two refusal tests on their `hasBaseline` pin alone.
  //
  // ⚠️ What the desk cannot show: the crash-window re-send is answered by the mock's
  // `enableInsertConflictsAsServerRecordChanged()`, i.e. by what real CloudKit is ASSUMED to answer
  // a tagless save of a record that exists. The real answer is a hardware read (MonteSprout
  // DECISIONS § "`/clarify` over Phases 119–120" 18).
  extension BaseCloudKitTests {
    @MainActor
    final class BatchBuildConfirmationTests: BaseCloudKitTests, @unchecked Sendable {
      /// What every "is it uploaded?" reading is built from, read as SQL (never via the archive).
      private struct Confirmation: Equatable {
        var hasLastKnownServerRecord: Bool
        var hasServerRecord: Bool
        var hasBaseline: Bool
        var mirror: Int64?
        var local: Int64
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func confirmation() async throws -> Confirmation? {
        try await syncEngine.metadatabase.read { db in
          func value(_ expression: String) throws -> Int64? {
            try Int64.fetchOne(
              db,
              sql: """
                SELECT \(expression) FROM "sqlitedata_icloud_metadata"
                 WHERE "recordPrimaryKey" = '1' AND "recordType" = 'remindersLists'
                """
            )
          }
          guard let local = try value(#""userModificationTime""#)
          else { return nil }
          return Confirmation(
            hasLastKnownServerRecord: try value(#""hasLastKnownServerRecord""#) == 1,
            hasServerRecord: try value(#""lastKnownServerRecord" IS NOT NULL"#) == 1,
            hasBaseline: try value(#""_lastKnownServerRecordAllFields" IS NOT NULL"#) == 1,
            mirror: try value(#""serverUserModificationTime""#),
            local: local
          )
        }
      }

      /// Patch 9's start-rescan predicate, as a count.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func strandedCount() async throws -> Int {
        try await syncEngine.metadatabase.read { db in
          try Int.fetchOne(
            db,
            sql: #"""
              SELECT count(*) FROM "sqlitedata_icloud_metadata"
               WHERE NOT "_isDeleted"
                 AND (NOT "hasLastKnownServerRecord"
                      OR "serverUserModificationTime" < "userModificationTime")
              """#
          ) ?? -1
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func ledgerCount() async throws -> Int {
        try await syncEngine.metadatabase.read { db in
          try Int.fetchOne(
            db,
            sql: #"SELECT count(*) FROM "sqlitedata_icloud_pendingRecordZoneChanges""#
          ) ?? -1
        }
      }

      /// Waits (bounded, quiet) for 5.3b's asynchronous ledger writes — `EngineStartRescanTests`' idiom.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func settleLedger(at expected: Int) async throws {
        for _ in 0..<200 {
          if try await ledgerCount() == expected { return }
          try await Task.sleep(for: .milliseconds(10))
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func localTitle() async throws -> String? {
        try await userDatabase.read { db in
          try RemindersList.find(1).fetchOne(db)?.title
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func serverTitle() throws -> String? {
        try syncEngine.private.database
          .record(for: RemindersList.recordID(for: 1))
          .encryptedValues["title"] as? String
      }

      /// A new row, and the batch CKSyncEngine would be handed for it. Nothing is sent.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func seedAndBuildBatch() async throws -> CKRecord {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Personal") }
        }
        try await settleLedger(at: 1)
        let batch = await syncEngine.nextRecordZoneChangeBatch(syncEngine: syncEngine.private)
        return try #require(batch?.recordsToSave.first)
      }

      /// A-F1's scenario. A first save refused with a code in the terminal bucket leaves the row
      /// reading NOT uploaded — on every signal — and the next start sends it again.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aRefusedFirstSave_staysUnconfirmed_andARestartLandsIt() async throws {
        let sent = try await seedAndBuildBatch()

        // The batch build: a values baseline, and no confirmation.
        let built = try #require(try await confirmation())
        #expect(
          built
            == Confirmation(
              hasLastKnownServerRecord: false,
              hasServerRecord: false,
              hasBaseline: true,
              mirror: nil,
              local: built.local
            )
        )

        let recorder = RecordingIssueReporter()
        await withIssueReporters([recorder]) {
          await syncEngine.handleSentRecordZoneChanges(
            failedRecordSaves: [(sent, CKError(.internalError))],
            syncEngine: syncEngine.private
          )
        }
        // Patch 2's report, unchanged: the save was dropped, and says so.
        #expect(recorder.messages.value.count == 1)
        #expect(
          recorder.messages.value.first?.contains("dropped a failed record save with no retry")
            == true
        )

        // Dropped: not pending, and the 5.3b ledger row is resolved — so nothing but the row's own
        // unconfirmed state can bring it back.
        syncEngine.private.state.assertPendingRecordZoneChanges([])
        try await settleLedger(at: 0)
        #expect(try await ledgerCount() == 0)
        let refused = try #require(try await confirmation())
        #expect(!refused.hasLastKnownServerRecord)
        #expect(!refused.hasServerRecord)
        #expect(refused.mirror == nil)
        #expect(try await strandedCount() == 1)
        #expect(throws: (any Error).self) { try self.serverTitle() }

        // The next launch: patch 9's never-confirmed half selects it, and a send round lands it.
        syncEngine.stop()
        try await syncEngine.start()
        syncEngine.private.state.assertPendingDatabaseChanges([
          .saveZone(SyncEngine.defaultTestZone)
        ])
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(try serverTitle() == "Personal")
        let landed = try #require(try await confirmation())
        #expect(landed.hasLastKnownServerRecord)
        #expect(landed.mirror == landed.local)
        #expect(try await strandedCount() == 0)
      }

      /// The parked twin (patch 17): while a full account's refused save waits for its retry, the
      /// row reads unconfirmed — the health line must not go green on a note that is not on the
      /// server. The ack, and only the ack, confirms it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aParkedFirstSave_readsUnconfirmedUntilItsAck() async throws {
        let sent = try await seedAndBuildBatch()

        let recorder = RecordingIssueReporter()
        await withIssueReporters([recorder]) {
          await syncEngine.handleSentRecordZoneChanges(
            failedRecordSaves: [(sent, CKError(.quotaExceeded))],
            syncEngine: syncEngine.private
          )
        }
        #expect(recorder.messages.value.count == 1)

        let parked = try #require(try await confirmation())
        #expect(!parked.hasLastKnownServerRecord)
        #expect(!parked.hasServerRecord)
        #expect(parked.hasBaseline)
        #expect(parked.mirror == nil)
        #expect(try await strandedCount() == 1)

        // Parked means still pending (asserting drains the set; put it back for the retry).
        syncEngine.private.state.assertPendingRecordZoneChanges([
          .saveRecord(RemindersList.recordID(for: 1))
        ])
        syncEngine.private.state.add(
          pendingRecordZoneChanges: [.saveRecord(RemindersList.recordID(for: 1))]
        )

        // Storage frees; the retry is acknowledged.
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let landed = try #require(try await confirmation())
        #expect(landed.hasLastKnownServerRecord)
        #expect(landed.mirror == landed.local)
        #expect(try await strandedCount() == 0)
        #expect(try serverTitle() == "Personal")
      }

      /// Why the baseline stays. The first save LANDS but its reply is lost (a kill between send
      /// and ack); she edits; the relaunch re-sends a record with no change tag and the server
      /// answers with its own, older copy. The per-field merge needs the baseline to see that her
      /// edit is newer than what the server holds — without it the older copy overwrites her edit
      /// locally and is then re-uploaded over it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aLandedSaveWithALostReply_keepsALaterEdit_andDeliversIt() async throws {
        let sent = try await seedAndBuildBatch()
        // The save reaches the server; the callback that would deliver its outcome is dropped.
        _ = try syncEngine.private.database.modifyRecords(saving: [sent])
        #expect(try serverTitle() == "Personal")
        #expect(try await confirmation()?.hasLastKnownServerRecord == false)

        syncEngine.stop()
        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Renamed" }.execute(db)
          }
          try await syncEngine.start()
          syncEngine.private.state.assertPendingDatabaseChanges([
            .saveZone(SyncEngine.defaultTestZone)
          ])

          syncEngine.private.database.enableInsertConflictsAsServerRecordChanged()
          // The tagless re-send: refused with the server's copy, merged, re-enqueued.
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
          #expect(try await localTitle() == "Renamed")
          #expect(try await confirmation()?.hasLastKnownServerRecord == true)
          // The merged record, now built on the server's copy and its change tag, lands.
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        }

        #expect(try await localTitle() == "Renamed")
        #expect(try serverTitle() == "Renamed")
        let landed = try #require(try await confirmation())
        #expect(landed.hasLastKnownServerRecord)
        #expect(landed.mirror == landed.local)
      }

      /// The same window, the other order: the relaunch FETCHES the landed record before it
      /// re-sends. A fetch confirms the row just as an ack does, the baseline keeps her edit out
      /// of the incoming copy's way, and the edit still reads unsent until it is delivered.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aLandedSaveWithALostReply_isConfirmedByAFetch_andKeepsALaterEdit() async throws {
        let sent = try await seedAndBuildBatch()
        let landedOnServer = try syncEngine.modifyRecords(scope: .private, saving: [sent])

        syncEngine.stop()
        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Renamed" }.execute(db)
          }
          try await syncEngine.start()
          syncEngine.private.state.assertPendingDatabaseChanges([
            .saveZone(SyncEngine.defaultTestZone)
          ])

          await landedOnServer.notify()
          #expect(try await localTitle() == "Renamed")
          let fetched = try #require(try await confirmation())
          #expect(fetched.hasLastKnownServerRecord)
          #expect(try #require(fetched.mirror) < fetched.local)  // her edit is still unsent

          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        }

        #expect(try await localTitle() == "Renamed")
        #expect(try serverTitle() == "Renamed")
        let landed = try #require(try await confirmation())
        #expect(landed.mirror == landed.local)
      }
    }
  }

  /// Records the message of every issue reported inside a `withIssueReporters([recorder]) { … }` scope.
  private final class RecordingIssueReporter: IssueReporter, Sendable {
    let messages = LockIsolated<[String]>([])

    func reportIssue(
      _ message: @autoclosure () -> String?,
      severity: IssueSeverity,
      fileID: StaticString,
      filePath: StaticString,
      line: UInt,
      column: UInt
    ) {
      let message = message() ?? ""
      messages.withValue { $0.append(message) }
    }

    func reportIssue(
      _ error: any Error,
      _ message: @autoclosure () -> String?,
      fileID: StaticString,
      filePath: StaticString,
      line: UInt,
      column: UInt
    ) {
      let message = message() ?? ""
      messages.withValue { $0.append(message) }
    }
  }
#endif
