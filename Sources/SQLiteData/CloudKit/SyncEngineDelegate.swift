#if canImport(CloudKit)
  public import CloudKit
  import CustomDump
  import IssueReporting

  /// An interface for observing ``SyncEngine`` events and customizing ``SyncEngine`` behavior.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public protocol SyncEngineDelegate: AnyObject, Sendable {
    /// An event indicating a change to the device's iCloud account.
    ///
    /// By default, a sync engine will clear out local data when detecting a logout or account
    /// change. To override this behavior, _e.g._ if you want to prompt the user and let them decide
    /// if they want to clear their local data or not, implement this method, and explicitly call
    /// ``SyncEngine/deleteLocalData()`` if/when the data should be cleared.
    ///
    /// For example, an observable model could override this method to set up some alert state:
    ///
    /// ```swift
    /// @MainActor
    /// @Observable
    /// class MySyncEngineDelegate: SyncEngineDelegate {
    ///   var isResetDataAlertPresented = false
    ///
    ///   func syncEngine(
    ///     _ syncEngine: SyncEngine,
    ///     accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ///   ) {
    ///     switch changeType {
    ///     case .signOut, .switchAccounts:
    ///       isResetDataAlertPresented = true
    ///     case .signIn:
    ///       break
    ///     }
    ///   }
    /// }
    /// ```
    ///
    /// And then SwiftUI could drive an alert with this state:
    ///
    /// ```swift
    /// struct MyApp: App {
    ///   @State var syncEngineDelegate = MySyncEngineDelegate()
    ///
    ///   init() {
    ///     prepareDependencies {
    ///       try! $0.bootstrapDatabase(syncEngineDelegate: syncEngineDelegate)
    ///     }
    ///   }
    ///
    ///   var body: some Scene {
    ///     WindowGroup {
    ///       MyRootView()
    ///         .alert(
    ///           "Reset local data?",
    ///           isPresented: $syncEngineDelegate.isDeleteLocalDataAlertPresented
    ///         ) {
    ///           Button("Reset", role: .destructive) {
    ///             Task {
    ///               try await syncEngine.deleteLocalData()
    ///             }
    ///           }
    ///         } message: {
    ///           Text(
    ///             """
    ///             You are no longer logged into iCloud. Would you like to reset your local data \
    ///             to the defaults? This will not affect your data in iCloud.
    ///             """
    ///           )
    ///         }
    ///     }
    ///   }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - syncEngine: The sync engine that generates the event.
    ///   - changeType: The iCloud account's change type.
    func syncEngine(
      _ syncEngine: SyncEngine,
      accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async

    // MANGO patch 12 — an additive, default-implemented hook (upstream declares none):
    /// An event indicating CloudKit deleted or purged an entire record zone, delivered just
    /// *before* the sync engine hard-deletes the zone's local rows in response.
    ///
    /// This is the only signal a consumer gets that a zone's data is about to disappear — on a
    /// participant device a shared zone vanishes this way when the owner stops sharing (or the
    /// participant is removed), and without this hook that removal is silent: no event fires
    /// and nothing can be shown to the user or cleaned up alongside it.
    ///
    /// The delegate is called while the zone's rows are still readable, so it may snapshot
    /// whatever it needs (e.g. a display name for a revocation notice). It cannot veto the
    /// deletion — the zone is already gone server-side; the local purge follows regardless.
    /// `.encryptedDataReset` zone events re-upload rather than delete and do not call this.
    ///
    /// The default implementation does nothing.
    ///
    /// - Parameters:
    ///   - syncEngine: The sync engine that generates the event.
    ///   - zoneID: The zone whose local records are about to be deleted.
    ///   - scope: The database scope the zone belongs to (`.shared` for a zone shared with the
    ///     current user, `.private` for the user's own).
    ///   - reason: CloudKit's stated reason (`.deleted` or `.purged`).
    func syncEngine(
      _ syncEngine: SyncEngine,
      willDeleteRecordsInZone zoneID: CKRecordZone.ID,
      scope: CKDatabase.Scope,
      reason: CKDatabase.DatabaseChange.Deletion.Reason
    ) async
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngineDelegate {
    public func syncEngine(
      _ syncEngine: SyncEngine,
      accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async {
      switch changeType {
      case .signOut, .switchAccounts:
        await withErrorReporting {
          try await syncEngine.deleteLocalData()
        }
      case .signIn:
        break
      @unknown default:
        break
      }
    }

    // MANGO patch 12 — the default implementation: observing a zone purge is opt-in.
    public func syncEngine(
      _ syncEngine: SyncEngine,
      willDeleteRecordsInZone zoneID: CKRecordZone.ID,
      scope: CKDatabase.Scope,
      reason: CKDatabase.DatabaseChange.Deletion.Reason
    ) async {}
  }
#endif
