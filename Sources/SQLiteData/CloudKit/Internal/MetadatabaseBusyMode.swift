#if canImport(CloudKit)
  package import Foundation
  package import GRDB

  /// The busy timeout given to the metadatabase connection when the host expressed no preference of
  /// its own. Bounded waiting, well under any watchdog horizon.
  package let mangoDefaultMetadatabaseBusyTimeout: TimeInterval = 5

  /// MANGO PATCH 10 — the metadatabase connection must wait for a lock, never fail immediately.
  ///
  /// The metadatabase file has **two** writers: the library's own connection (built in
  /// `defaultMetadatabase`) and the host's connection, which reaches the same file through the
  /// attached `sqlitedata_icloud` schema. Before patch 5.3b the host side wrote there rarely; since
  /// 5.3b it writes on **every local change** — the always-on pending ledger runs through
  /// `userDatabase.write` — so the two connections now contend routinely.
  ///
  /// Upstream builds the library's connection from a fresh `Configuration()`, which leaves it on
  /// GRDB's default `busyMode = .immediateError`. A few milliseconds of ordinary contention therefore
  /// becomes an outright `SQLITE_BUSY`, and the persist's own `withErrorReporting` swallows it: the row
  /// silently loses the durability 5.3b exists to give it, degrading to the pre-5.3b behavior patch 9
  /// was written to prevent, plus one reported issue per occurrence in the host's telemetry.
  ///
  /// The rule: inherit whatever the host chose — MangoSync's `SyncConfiguration` hardens its own
  /// connection to `.timeout(5)`, and a host that installed a `.callback` means it — and upgrade only
  /// the `.immediateError` default. An internal database the library is the sole owner of has no
  /// reason to prefer an instant failure over a bounded wait.
  ///
  /// Found reviewing the 1.10.0 retarget (2026-08-15); it is the mechanism behind the two
  /// `AccountLifecycleTests` failures 5.3b left unexplained. Guards: `MetadatabaseBusyModeTests`
  /// (this decision + that waiting actually happens) and those two tests (the end-to-end wiring).
  package func mangoMetadatabaseBusyMode(
    inheriting hostBusyMode: Database.BusyMode
  ) -> Database.BusyMode {
    if case .immediateError = hostBusyMode {
      return .timeout(mangoDefaultMetadatabaseBusyTimeout)
    }
    return hostBusyMode
  }

  /// MANGO PATCH 10, second half — the 5.3b ledger writes must survive transient contention.
  ///
  /// The ledger persists through `userDatabase.write`, i.e. the **host's** connection, whose busy
  /// behavior the library does not own: a host that never hardened it (upstream's default) fails
  /// instantly the moment the library's own metadatabase connection holds the file's write lock —
  /// which the first half of this patch makes *more* likely, since that connection now waits for the
  /// lock and then takes it instead of giving up. Left alone, the `withErrorReporting` around each
  /// persist swallows the failure and the row silently loses its durability.
  ///
  /// Bounded, short, and only for the transient contention class — anything else (schema errors,
  /// corruption) will not succeed on a retry and is rethrown immediately. Mirrors the host-side idiom
  /// in MangoSync's `Fetch.loadRetrying`.
  ///
  /// The sleeps deliberately use `Task.sleep` rather than `\.continuousClock`: this runs inside the
  /// library's own detached persist `Task`, and the test suite injects a `TestClock` that nothing
  /// advances — riding that clock would hang the suite instead of retrying.
  package func mangoRetryingTransientContention<T: Sendable>(
    delays: [Duration] = [.milliseconds(25), .milliseconds(50), .milliseconds(100)],
    _ operation: @Sendable () async throws -> T
  ) async throws -> T {
    for delay in delays {
      do {
        return try await operation()
      } catch {
        guard error.isTransientDatabaseContention, !Task.isCancelled else { throw error }
        try await Task.sleep(for: delay)
      }
    }
    return try await operation()  // Final attempt — a throw here reaches the caller.
  }

  extension Error {
    /// The cross-connection contention class the busy timeout and these retries exist for.
    fileprivate var isTransientDatabaseContention: Bool {
      guard let databaseError = self as? DatabaseError else { return false }
      return databaseError.resultCode == .SQLITE_BUSY || databaseError.resultCode == .SQLITE_LOCKED
    }
  }
#endif
