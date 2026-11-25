#if canImport(CloudKit)
  public import CloudKit
  import ConcurrencyExtras

  @available(iOS 15, tvOS 15, macOS 12, watchOS 8, *)
  package protocol CloudContainer<Database>: AnyObject, Equatable, Hashable, Sendable {
    associatedtype Database: CloudDatabase

    func accountStatus() async throws -> CKAccountStatus
    var containerIdentifier: String? { get }
    var rawValue: CKContainer { get }
    var privateCloudDatabase: Database { get }
    func accept(_ metadata: ShareMetadata) async throws -> CKShare
    static func createContainer(identifier containerIdentifier: String) -> Self
    var sharedCloudDatabase: Database { get }
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    func shareMetadata(for share: CKShare, shouldFetchRootRecord: Bool) async throws
      -> ShareMetadata
  }

  @available(iOS 15, tvOS 15, macOS 12, watchOS 8, *)
  package struct ShareMetadata: Hashable {
    package var containerIdentifier: String
    package var hierarchicalRootRecordID: CKRecord.ID?
    package var rootRecord: CKRecord?
    package var share: CKShare
    package var rawValue: CKShare.Metadata?
    package init(rawValue: CKShare.Metadata) {
      self.containerIdentifier = rawValue.containerIdentifier
      self.hierarchicalRootRecordID = rawValue.hierarchicalRootRecordID
      self.rootRecord = rawValue.rootRecord
      self.share = rawValue.share
      self.rawValue = rawValue
    }
    package init(
      containerIdentifier: String,
      hierarchicalRootRecordID: CKRecord.ID?,
      rootRecord: CKRecord?,
      share: CKShare
    ) {
      self.containerIdentifier = containerIdentifier
      self.hierarchicalRootRecordID = hierarchicalRootRecordID
      self.rootRecord = rootRecord
      self.share = share
      self.rawValue = nil
    }
  }

  @available(iOS 15, tvOS 15, macOS 12, watchOS 8, *)
  extension CloudContainer {
    package func database(for recordID: CKRecord.ID) -> any CloudDatabase {
      recordID.zoneID.ownerName == CKCurrentUserDefaultName
        ? privateCloudDatabase
        : sharedCloudDatabase
    }
  }

  @available(iOS 15, tvOS 15, macOS 12, watchOS 8, *)
  extension CKContainer: CloudContainer {
    package func accept(_ metadata: ShareMetadata) async throws -> CKShare {
      guard let metadata = metadata.rawValue
      else {
        fatalError("This should never be called with 'ShareMetadata' that has a nil 'rawValue'")
      }
      return try await self.accept(metadata)
    }

    package static func createContainer(identifier containerIdentifier: String) -> Self {
      Self(identifier: containerIdentifier)
    }

    package var rawValue: CKContainer {
      self
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    package func shareMetadata(
      for share: CKShare,
      shouldFetchRootRecord: Bool = false
    ) async throws -> ShareMetadata {
      // MANGO PATCH 22 — see `fetchShareMetadata(shareURL:shouldFetchRootRecord:run:)`.
      ShareMetadata(
        rawValue: try await Self.fetchShareMetadata(
          shareURL: share.url,
          shouldFetchRootRecord: shouldFetchRootRecord,
          run: { [self] operation in add(operation) }
        )
      )
    }

    // MANGO PATCH 22 (MonteSprout Phase 120.2, bug bash A-F2) — a share-metadata fetch resumes
    // exactly once, from the operation's completion block.
    //
    // Upstream resumed an unsafe continuation from the per-share block only. An operation-level
    // failure (network lost, the system cancelling the operation, a whole-request rate limit) is
    // reported through the completion block, which upstream never set — so the continuation stayed
    // suspended forever, and with it `cacheShare`, `handleFetchedRecordZoneChanges` and the
    // engine's serial event delivery: that database stopped syncing until relaunch. A share with no
    // URL built an empty operation whose per-share block could never run at all.
    //
    // Now: no URL throws `ShareMetadataFetchError.missingURL` before anything runs; the per-share
    // block only records its result; the completion block resumes once (its own error, else the
    // recorded result, else `.noResult`); a checked continuation; task cancellation cancels the
    // operation (CloudKit then completes it with `.operationCancelled`), and a fetch cancelled before
    // the hand-over never runs it; CloudKit's own timeouts
    // bound it (request 30 s, resource 60 s); `shouldFetchRootRecord` is honoured (upstream forced
    // `true`). `run` is the seam a test drives the operation's blocks through by hand, and the URL is
    // a parameter because a test cannot make a `CKShare` that has one.
    package static func fetchShareMetadata(
      shareURL: URL?,
      shouldFetchRootRecord: Bool,
      run: (CKFetchShareMetadataOperation) -> Void
    ) async throws -> CKShare.Metadata {
      guard let url = shareURL
      else { throw ShareMetadataFetchError.missingURL }
      let operation = CKFetchShareMetadataOperation(shareURLs: [url])
      operation.shouldFetchRootRecord = shouldFetchRootRecord
      let configuration = CKOperation.Configuration()
      configuration.timeoutIntervalForRequest = ShareMetadataFetchError.requestTimeout
      configuration.timeoutIntervalForResource = ShareMetadataFetchError.resourceTimeout
      operation.configuration = configuration
      let perShareResult = LockIsolated<Result<CKShare.Metadata, any Error>?>(nil)
      let cancellable = UncheckedSendable(operation)
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          // Cancelled before it was handed over: never run it, so nothing else can resume.
          guard !operation.isCancelled
          else {
            continuation.resume(throwing: CancellationError())
            return
          }
          operation.perShareMetadataResultBlock = { _, result in
            perShareResult.setValue(result)
          }
          operation.fetchShareMetadataResultBlock = { result in
            switch result {
            case .failure(let error):
              continuation.resume(throwing: error)
            case .success:
              continuation.resume(
                with: perShareResult.value ?? .failure(ShareMetadataFetchError.noResult)
              )
            }
          }
          run(operation)
        }
      } onCancel: {
        cancellable.value.cancel()
      }
    }
  }

  /// MANGO PATCH 22 — the live share-metadata fetch's own failures.
  package enum ShareMetadataFetchError: Error, Equatable {
    /// The share has no URL (it was never saved), so there is nothing to fetch. Not parked.
    case missingURL
    /// The operation completed successfully without reporting the share.
    case noResult

    package static let requestTimeout: TimeInterval = 30
    package static let resourceTimeout: TimeInterval = 60
  }
#endif
