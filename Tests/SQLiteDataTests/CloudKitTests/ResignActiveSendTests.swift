#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import IssueReporting
  import SQLiteData
  import Testing
  import os

  // MonteSprout fork (91.1, patch 19 — F55): the send the library makes when the app resigns active.
  //
  // Upstream awaited the private database's send and then the shared one inside ONE throwing task, so
  // a private send that threw (a full iCloud account's first symptom) meant the shared database —
  // where a participant's notes in somebody else's room live — was never asked to send; the error
  // went nowhere; and with no expiration handler a send still running at the end of the background
  // grant was never cancelled. `ResignActiveSend.sendIndependently` sends each database on its own
  // child task and records each outcome.
  //
  // Vacuity guard (MANGO-PATCHES § 19, neutralize in place; verified 2026-09-26): replacing the task
  // group in `ResignActiveSend.sendIndependently` with upstream's shape — a `for` loop that awaits each
  // engine in order and marks every later engine failed once one throws, with no `reportIssue` and no
  // `CKError.operationCancelled` arm — sends 4 of the 5 RED (8 issues): the two independence tests
  // (`aFailedPrivateSend_stillSendsTheSharedDatabase`, `aHungPrivateSend_neverDelaysTheSharedDatabase`)
  // and the two whose hunks go with it. `expiration_cancelsEverySendStillRunning` stays green by design
  // — a sequential loop cancels too; that test pins the outcome shape, not the independence.
  @Suite struct ResignActiveSendTests {
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func aFailedPrivateSend_stillSendsTheSharedDatabase() async {
      let privateEngine = StubSendEngine(scope: .private, behavior: .fail(CKError(.quotaExceeded)))
      let sharedEngine = StubSendEngine(scope: .shared, behavior: .succeed)

      let results = await withIssueReporters([]) {
        await ResignActiveSend.sendIndependently(
          [privateEngine, sharedEngine],
          logger: Logger(.disabled)
        )
      }

      #expect(sharedEngine.sendCount.value == 1)
      #expect(results.map(\.scope) == [.private, .shared])
      #expect(results[1].outcome == .sent)
      guard case .failed = results[0].outcome else {
        Issue.record("expected the private send to be recorded as failed, got \(results[0].outcome)")
        return
      }
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func aHungPrivateSend_neverDelaysTheSharedDatabase() async throws {
      let privateEngine = StubSendEngine(scope: .private, behavior: .hangUntilCancelled)
      let sharedEngine = StubSendEngine(scope: .shared, behavior: .succeed)

      let send = Task {
        await ResignActiveSend.sendIndependently(
          [privateEngine, sharedEngine],
          logger: Logger(.disabled)
        )
      }
      // The shared send must go out while the private one is still hung — bounded, never a sleep.
      for _ in 0..<1_000 where sharedEngine.sendCount.value == 0 {
        await Task.yield()
      }
      #expect(sharedEngine.sendCount.value == 1)
      #expect(privateEngine.sendCount.value == 1)

      send.cancel()
      let results = await send.value
      #expect(
        results == [
          ResignActiveSend.Result(scope: .private, outcome: .cancelled),
          ResignActiveSend.Result(scope: .shared, outcome: .sent),
        ]
      )
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func expiration_cancelsEverySendStillRunning() async {
      let privateEngine = StubSendEngine(scope: .private, behavior: .hangUntilCancelled)
      let sharedEngine = StubSendEngine(scope: .shared, behavior: .hangUntilCancelled)
      let recorder = SendReportRecorder()

      let send = Task {
        await withIssueReporters([recorder]) {
          await ResignActiveSend.sendIndependently(
            [privateEngine, sharedEngine],
            logger: Logger(.disabled)
          )
        }
      }
      for _ in 0..<1_000
      where privateEngine.sendCount.value == 0 || sharedEngine.sendCount.value == 0 {
        await Task.yield()
      }
      send.cancel()
      let results = await send.value

      #expect(
        results == [
          ResignActiveSend.Result(scope: .private, outcome: .cancelled),
          ResignActiveSend.Result(scope: .shared, outcome: .cancelled),
        ]
      )
      // A cancellation is the expiration handler doing its job, never an issue.
      #expect(recorder.reports.value.isEmpty)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func aCloudKitCancellation_isACancellationNotAFailure() async {
      let privateEngine = StubSendEngine(scope: .private, behavior: .fail(CKError(.operationCancelled)))
      let recorder = SendReportRecorder()

      let results = await withIssueReporters([recorder]) {
        await ResignActiveSend.sendIndependently([privateEngine], logger: Logger(.disabled))
      }

      #expect(results == [ResignActiveSend.Result(scope: .private, outcome: .cancelled)])
      #expect(recorder.reports.value.isEmpty)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func eachFailedDatabase_isReportedOnce_withItsError() async {
      let privateEngine = StubSendEngine(scope: .private, behavior: .fail(CKError(.quotaExceeded)))
      let sharedEngine = StubSendEngine(scope: .shared, behavior: .fail(CKError(.networkFailure)))
      let recorder = SendReportRecorder()

      _ = await withIssueReporters([recorder]) {
        await ResignActiveSend.sendIndependently(
          [privateEngine, sharedEngine],
          logger: Logger(.disabled)
        )
      }

      let reports = recorder.reports.value
      #expect(reports.count == 2)
      #expect(Set(reports.compactMap(\.code)) == [.quotaExceeded, .networkFailure])
      #expect(reports.contains { $0.message.contains("the private database's send on resign-active failed") })
      #expect(reports.contains { $0.message.contains("the shared database's send on resign-active failed") })
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private final class StubSendEngine: SyncEngineProtocol {
    enum Behavior: Sendable {
      case succeed
      case fail(CKError)
      case hangUntilCancelled
    }

    let database: MockCloudDatabase
    let state = MockSyncEngineState()
    let behavior: Behavior
    let sendCount = LockIsolated(0)

    init(scope: CKDatabase.Scope, behavior: Behavior) {
      self.database = MockCloudDatabase(databaseScope: scope)
      self.behavior = behavior
    }

    func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws {
      sendCount.withValue { $0 += 1 }
      switch behavior {
      case .succeed:
        return
      case .fail(let error):
        throw error
      case .hangUntilCancelled:
        try await Task.sleep(for: .seconds(600))
      }
    }

    func cancelOperations() async {}
    func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws {}
    func recordZoneChangeBatch(
      pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
      recordProvider: @Sendable (CKRecord.ID) async -> CKRecord?
    ) async -> CKSyncEngine.RecordZoneChangeBatch? { nil }
  }

  /// Counts the reports made inside a `withIssueReporters([recorder]) { … }` scope.
  private final class SendReportRecorder: IssueReporter, Sendable {
    struct Report: Sendable {
      let code: CKError.Code?
      let message: String
    }

    let reports = LockIsolated<[Report]>([])

    func reportIssue(
      _ message: @autoclosure () -> String?,
      severity: IssueSeverity,
      fileID: StaticString,
      filePath: StaticString,
      line: UInt,
      column: UInt
    ) {
      let message = message() ?? ""
      reports.withValue { $0.append(Report(code: nil, message: message)) }
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
      reports.withValue { $0.append(Report(code: (error as? CKError)?.code, message: message)) }
    }
  }
#endif
