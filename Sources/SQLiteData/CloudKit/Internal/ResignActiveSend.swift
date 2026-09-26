#if canImport(CloudKit)
  package import CloudKit
  import IssueReporting
  package import os

  /// MANGO PATCH 19 (MonteSprout F55) — the send the library makes when the app resigns active.
  ///
  /// Upstream's `willResignActive` handler awaited the private database's send and THEN the shared
  /// one, inside one throwing task with no expiration handler. So a private send that threw (a full
  /// iCloud account, an account in transition) meant the shared database — where an assistant's
  /// notes in somebody else's room live — was never asked to send at all, the error went nowhere,
  /// and a send still running when the background grant ran out was never cancelled and never let
  /// the grant go. This is the platform-neutral half: each database is sent **independently and
  /// concurrently**, and each one's outcome is recorded on its own. The UIKit half (the background
  /// task and its expiration handler) lives beside the observer in `SyncEngine.init`.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  package enum ResignActiveSend {
    package enum Outcome: Equatable, Sendable {
      /// The database's send returned.
      case sent
      /// The database's send threw; the associated value is the error's description.
      case failed(String)
      /// The send was cancelled — the background grant expired before it returned.
      case cancelled
    }

    package struct Result: Equatable, Sendable {
      package let scope: CKDatabase.Scope
      package let outcome: Outcome

      package init(scope: CKDatabase.Scope, outcome: Outcome) {
        self.scope = scope
        self.outcome = outcome
      }
    }

    /// Sends every given database's pending changes, each on its own child task, and returns one
    /// result per database in the order given. One database's failure or cancellation never
    /// prevents or delays another's send.
    ///
    /// A failure is reported (one `reportIssue` per failed database, carrying the error so a host's
    /// reporter keyed on the error's type still sees it); a cancellation is not — it is the
    /// expiration handler doing its job. Every outcome is logged.
    package static func sendIndependently(
      _ engines: [any SyncEngineProtocol],
      logger: Logger
    ) async -> [Result] {
      let results = await withTaskGroup(
        of: (Int, Result).self,
        returning: [Result].self
      ) { group in
        for (index, engine) in engines.enumerated() {
          group.addTask {
            let scope = engine.database.databaseScope
            do {
              try await engine.sendChanges(CKSyncEngine.SendChangesOptions())
              return (index, Result(scope: scope, outcome: .sent))
            } catch is CancellationError {
              return (index, Result(scope: scope, outcome: .cancelled))
            } catch let error as CKError where error.code == .operationCancelled {
              return (index, Result(scope: scope, outcome: .cancelled))
            } catch {
              reportIssue(
                error,
                """
                sqlite-data sync: the \(scope.mangoName) database's send on resign-active failed; \
                its changes stay pending for the next send
                """
              )
              return (index, Result(scope: scope, outcome: .failed("\(error)")))
            }
          }
        }
        var collected: [(Int, Result)] = []
        for await result in group {
          collected.append(result)
        }
        return collected.sorted { $0.0 < $1.0 }.map(\.1)
      }
      for result in results {
        switch result.outcome {
        case .sent:
          logger.info("sqlite-data resign-active send: \(result.scope.mangoName, privacy: .public) sent")
        case .failed(let description):
          logger.error(
            "sqlite-data resign-active send: \(result.scope.mangoName, privacy: .public) failed — \(description, privacy: .public)"
          )
        case .cancelled:
          logger.notice(
            "sqlite-data resign-active send: \(result.scope.mangoName, privacy: .public) cancelled (background time expired)"
          )
        }
      }
      return results
    }
  }

  extension CKDatabase.Scope {
    /// The scope's name for a report or a log line (`Logging.swift`'s `label` is DEBUG-only).
    fileprivate var mangoName: String {
      switch self {
      case .public: "public"
      case .private: "private"
      case .shared: "shared"
      @unknown default: "unknown"
      }
    }
  }
#endif

#if canImport(UIKit) && !os(watchOS)
  import UIKit

  /// MANGO PATCH 19 (F55) — the background-task grant the resign-active send runs under, ended
  /// exactly once: by the send returning, or by the expiration handler, which first cancels the send
  /// and then gives the grant back before it returns (UIKit terminates an app whose expired grant is
  /// still held). Upstream began the grant with no expiration handler.
  @MainActor
  final class ResignActiveBackgroundGrant {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin(onExpiration: @escaping @MainActor () -> Void) {
      identifier = UIApplication.shared.beginBackgroundTask(
        withName: "sqlite-data.resignActiveSend"
      ) { [weak self] in
        MainActor.assumeIsolated {
          onExpiration()
          self?.end()
        }
      }
    }

    func end() {
      guard identifier != .invalid else { return }
      UIApplication.shared.endBackgroundTask(identifier)
      identifier = .invalid
    }
  }
#endif
