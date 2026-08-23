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

    // MANGO patch 13 — the sibling the hook above turned out to need (upstream declares neither):
    /// An event indicating that access to one or more **shared record hierarchies** has ended,
    /// delivered just *before* the sync engine hard-deletes their local rows in response.
    ///
    /// This is the shape a revocation actually takes on CloudKit, and it is **not** the zone event
    /// above. A participant's shared zone belongs to the owner and survives a revocation; what
    /// arrives is the deletion of the hierarchy's root record and its `cloudkit.share`. The zone
    /// hook only ever fires for a zone the owner deleted or purged outright.
    ///
    /// It reports **root record IDs**, not a zone, because one owner zone holds every hierarchy
    /// that owner shares out of it: a participant given two records from the same zone sees them
    /// both in one shared zone, and losing one says nothing about the other. Acting on the zone
    /// would destroy local data belonging to a record the participant still has.
    ///
    /// The delegate is called while those rows are still readable, so it may snapshot whatever it
    /// needs (a display name for a removal notice) and clean up alongside — a consumer's own
    /// private rows hanging off a shared record by foreign key are deleted locally by the cascade
    /// but stay behind in the consumer's own zone unless removed here. It cannot veto the
    /// deletion; access is already gone server-side.
    ///
    /// Only `.shared`-scope deletions reach this. The identical pair of record deletions arrives on
    /// the **owner's private** engine when she stops sharing, where it means the opposite thing.
    ///
    /// The default implementation does nothing.
    ///
    /// - Parameters:
    ///   - syncEngine: The sync engine that generates the event.
    ///   - rootRecordIDs: The shared hierarchies' root records, whose local rows (and everything
    ///     the consumer's schema cascades off them) are about to be deleted.
    ///   - zoneID: The shared zone those roots live in. The zone itself is **not** going away.
    func syncEngine(
      _ syncEngine: SyncEngine,
      willDeleteSharedRootRecords rootRecordIDs: [CKRecord.ID],
      inZone zoneID: CKRecordZone.ID
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

    // MANGO patch 13 — the default implementation. Deliberately a no-op rather than a forward to
    // the zone hook above: forwarding would hand a consumer a zone-wide event for the loss of one
    // hierarchy, and a consumer that acts on it (sweeping its own rows for every record in the
    // zone) would destroy data for records it still has. Silence until adopted is recoverable;
    // that is not.
    public func syncEngine(
      _ syncEngine: SyncEngine,
      willDeleteSharedRootRecords rootRecordIDs: [CKRecord.ID],
      inZone zoneID: CKRecordZone.ID
    ) async {}
  }
#endif
