#if canImport(CloudKit)
  import CloudKit
  import Foundation
  import GRDB
  import SQLiteData
  import Testing

  // MANGO PATCH 10 — the metadatabase connection must wait for a lock, never fail immediately.
  //
  // The metadatabase file has TWO writers: the library's own connection, and the host's connection
  // reaching the same file through the attached `sqlitedata_icloud` schema. Since patch 5.3b the host
  // side writes there on every local change (the always-on pending ledger runs through
  // `userDatabase.write`), so the two contend routinely rather than never. Upstream left the library's
  // connection on GRDB's default `busyMode = .immediateError`, which turns a few milliseconds of
  // normal contention into an outright `SQLITE_BUSY` — swallowed by the `withErrorReporting` around
  // the persist, so the row quietly loses the durability 5.3b exists to give it.
  //
  // Found in review of the 1.10.0 retarget (2026-08-15): this is the mechanism behind the two
  // `AccountLifecycleTests` failures the 5.3b landing left unexplained
  // (`signInUploadsLocalRecordsToCloudKit_SkipExistingCloudKitRecords`,
  // `createSharedRecordWhileSoftLoggedOut` — both pass on a clean upstream tag and on a 5.3b revert,
  // both fail with `SQLite error 5: database is locked` while 5.3b is in). Those two remain the
  // end-to-end evidence; the tests here pin the decision, the waiting, and the wiring.
  @Suite struct MetadatabaseBusyModeTests {
    @Test func aDefaultHostConfigurationStillGetsABoundedBusyTimeout() {
      guard case .timeout(let seconds) = mangoMetadatabaseBusyMode(inheriting: .immediateError)
      else {
        Issue.record("Expected a bounded busy timeout, got an immediate error.")
        return
      }
      #expect(seconds == mangoDefaultMetadatabaseBusyTimeout)
    }

    @Test func theHostsOwnBusyTimeoutIsInheritedVerbatim() {
      guard case .timeout(let seconds) = mangoMetadatabaseBusyMode(inheriting: .timeout(9))
      else {
        Issue.record("Expected the host's own timeout to survive.")
        return
      }
      #expect(seconds == 9, "The host's own choice must win over the patch's default.")
    }

    // The behavioral half: a second connection holds the file's write lock, exactly as the host's
    // connection does while a 5.3b ledger write runs.
    @Test func aHeldWriteLockIsWaitedOutRatherThanFailingImmediately() async throws {
      let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
      var configuration = Configuration()
      configuration.busyMode = mangoMetadatabaseBusyMode(inheriting: Configuration().busyMode)
      let metadatabase = try DatabasePool(path: url.path(percentEncoded: false), configuration: configuration)
      let otherWriter = try DatabasePool(path: url.path(percentEncoded: false))

      let lockAcquired = AsyncStream<Void>.makeStream()
      let holding = Task {
        try await otherWriter.write { db in
          try db.execute(sql: #"CREATE TABLE "mango_lock_holder" ("id" INTEGER)"#)
          lockAcquired.continuation.yield()
          lockAcquired.continuation.finish()
          // Hold the write lock well past the point where `.immediateError` gives up, and far short
          // of the timeout the patch installs.
          Thread.sleep(forTimeInterval: 0.25)
        }
      }
      var acquired = lockAcquired.stream.makeAsyncIterator()
      await acquired.next()

      // Without patch 10 this throws `SQLITE_BUSY` instead of waiting for the holder to commit.
      try await metadatabase.write { db in
        try db.execute(sql: #"CREATE TABLE "mango_busy_probe" ("id" INTEGER)"#)
      }
      try await holding.value
    }
  }

  // The wiring: an engine built the ordinary way must end up with a waiting metadatabase connection.
  // Reverting the one-line call site in `defaultMetadatabase` sends this red while the three tests
  // above stay green.
  extension BaseCloudKitTests {
    @MainActor
    final class MetadatabaseBusyModeWiringTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func theEnginesMetadatabaseConnectionWaitsForALock() {
        guard case .timeout(let seconds) = syncEngine.metadatabase.configuration.busyMode
        else {
          Issue.record(
            """
            The engine's metadatabase connection fails immediately on contention — the host's \
            connection holds this file's write lock on every local change since 5.3b.
            """
          )
          return
        }
        #expect(seconds == mangoDefaultMetadatabaseBusyTimeout)
      }
    }
  }
#endif
