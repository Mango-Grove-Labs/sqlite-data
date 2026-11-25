#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Dependencies
  import SQLiteData
  import Testing

  // MonteSprout fork (Phase 120.2 / patch 22): a share's cache always resolves.
  //
  // A-F3: upstream wrote `SyncMetadata.share` on a receiving device once per fetched record. A thrown
  // metadata fetch, a failed share fetch from a root's share reference, or an `UPDATE` that ran
  // before the root's metadata row existed left the share NULL with the change token advanced — the
  // room read "not shared" on that device until the share or its root changed again. The fork parks
  // the share's record ID in `UnsyncedRecordID`; the fetch-side drain re-fetches it at the next fetch
  // event, and engine start retries share parks.
  //
  // Why direct handler injection: the mock replaces the live metadata fetch, so a failure is armed on
  // `MockCloudContainer.shareMetadataFailures` (or `MockCloudDatabase`'s one-shot record-fetch
  // failure) and the records are handed straight to `handleFetchedRecordZoneChanges` (the
  // `FailedAssetDownloadParkTests` idiom). A delivery of a share with its root caches twice (the
  // `.share` path and the root's `.reference` path), so a failure is armed for both. The harness's
  // teardown asserts no park is left behind.
  //
  // Vacuity guard (rebase procedure step 4): neutralize patch 22's parks in `SyncEngine.swift` (make
  // `parkShare` return at once and the `changesCount == 0` branch skip its insert) → the four park
  // tests go red; drop the `retryParkedShares()` call at start → the start test goes red.
  extension BaseCloudKitTests {
    @MainActor
    final class ShareCacheResolutionTests: BaseCloudKitTests, @unchecked Sendable {
      private var externalZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "external.zone", ownerName: "external.owner")
      }

      /// A shared root and its share, stored on the server's shared database, returned as the
      /// server's copies (what a fetch would deliver).
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func seedSharedRoot() async throws -> (root: CKRecord, share: CKShare) {
        try await syncEngine
          .modifyRecordZones(scope: .shared, saving: [CKRecordZone(zoneID: externalZoneID)])
          .notify()
        let root = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1, zoneID: externalZoneID)
        )
        root.setValue(1, forKey: "id", at: now)
        root.setValue("Personal", forKey: "title", at: now)
        let share = CKShare(
          rootRecord: root,
          shareID: CKRecord.ID(
            recordName: "share-\(root.recordID.recordName)",
            zoneID: externalZoneID
          )
        )
        _ = try syncEngine.modifyRecords(scope: .shared, saving: [share, root])
        return (
          try syncEngine.shared.database.record(for: root.recordID),
          try syncEngine.shared.database.record(for: share.recordID) as! CKShare
        )
      }

      /// An unrelated row in the same shared hierarchy (a reminder under the root, which carries no
      /// share reference of its own) — a fetch event that carries a change.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func deliverAnUnrelatedChange(under root: CKRecord) async throws {
        let other = CKRecord(
          recordType: Reminder.tableName,
          recordID: Reminder.recordID(for: 1, zoneID: externalZoneID)
        )
        other.setValue(1, forKey: "id", at: now)
        other.setValue(false, forKey: "isCompleted", at: now)
        other.setValue("Get milk", forKey: "title", at: now)
        other.setValue(1, forKey: "remindersListID", at: now)
        other.parent = CKRecord.Reference(record: root, action: .none)
        _ = try syncEngine.modifyRecords(scope: .shared, saving: [other])
        await syncEngine.handleFetchedRecordZoneChanges(
          modifications: [try syncEngine.shared.database.record(for: other.recordID)],
          syncEngine: syncEngine.shared
        )
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func cachedShare(onRoot rootRecordID: CKRecord.ID) async throws -> CKShare? {
        try await syncEngine.metadatabase.read { db in
          try SyncMetadata.find(rootRecordID).select(\.share).fetchOne(db) ?? nil
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func isParked(_ recordID: CKRecord.ID) async throws -> Bool {
        try await syncEngine.metadatabase.read { db in
          try UnsyncedRecordID.find(recordID).fetchCount(db) == 1
        }
      }

      /// A-F3's scenario: the metadata fetch throws once on the share's first delivery, then nothing
      /// about the share changes. The next fetch event carrying any change caches it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aFailedMetadataFetch_isParked_andTheNextFetchEventCachesIt() async throws {
        let (root, share) = try await seedSharedRoot()
        container.shareMetadataFailures.setValue([CKError(.networkFailure), CKError(.networkFailure)])

        // Still reported, as before the patch — the park does not hide the failure.
        await withKnownIssue {
          await syncEngine.handleFetchedRecordZoneChanges(
            modifications: [share, root],
            syncEngine: syncEngine.shared
          )
        }
        #expect(try await cachedShare(onRoot: root.recordID) == nil)
        #expect(try await isParked(share.recordID))

        try await deliverAnUnrelatedChange(under: root)

        #expect(try await cachedShare(onRoot: root.recordID)?.recordID == share.recordID)
        #expect(try await !isParked(share.recordID))
      }

      /// A share delivered before its root's metadata row exists: the `UPDATE` matches no row. It
      /// is parked, and the park is cleared once the share lands.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aShareCachedBeforeItsRootRow_isParked_andClearedWhenItLands() async throws {
        let (root, share) = try await seedSharedRoot()

        await syncEngine.handleFetchedRecordZoneChanges(
          modifications: [share],
          syncEngine: syncEngine.shared
        )
        #expect(try await isParked(share.recordID))

        await syncEngine.handleFetchedRecordZoneChanges(
          modifications: [root],
          syncEngine: syncEngine.shared
        )
        #expect(try await cachedShare(onRoot: root.recordID)?.recordID == share.recordID)
        #expect(try await !isParked(share.recordID))
      }

      /// The `.reference` path: the root arrives carrying its share reference, and fetching the
      /// share record fails (upstream's `try?` swallowed it). Parked; the next event caches it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aFailedShareFetchFromARootReference_isParked_andRetried() async throws {
        let (root, share) = try await seedSharedRoot()
        syncEngine.shared.database.state.withValue {
          $0.nextRecordFetchFailures[share.recordID] = CKError(.networkFailure)
        }

        await syncEngine.handleFetchedRecordZoneChanges(
          modifications: [root],
          syncEngine: syncEngine.shared
        )
        #expect(try await cachedShare(onRoot: root.recordID) == nil)
        #expect(try await isParked(share.recordID))

        try await deliverAnUnrelatedChange(under: root)

        #expect(try await cachedShare(onRoot: root.recordID)?.recordID == share.recordID)
        #expect(try await !isParked(share.recordID))
      }

      /// A park does not wait for a fetch event that carries a change: engine start retries it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aParkedShare_isRetriedAtEngineStart() async throws {
        let (root, share) = try await seedSharedRoot()
        container.shareMetadataFailures.setValue([CKError(.networkFailure), CKError(.networkFailure)])
        await withKnownIssue {
          await syncEngine.handleFetchedRecordZoneChanges(
            modifications: [share, root],
            syncEngine: syncEngine.shared
          )
        }
        #expect(try await isParked(share.recordID))

        syncEngine.stop()
        try await syncEngine.start()
        syncEngine.private.state.assertPendingDatabaseChanges([
          .saveZone(SyncEngine.defaultTestZone)
        ])

        #expect(try await cachedShare(onRoot: root.recordID)?.recordID == share.recordID)
        #expect(try await !isParked(share.recordID))
      }

      /// A parked share that no longer exists on the server is unparked by the drain's
      /// `.unknownItem` answer — it is not retried forever.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aParkedShareThatIsGone_isUnparkedByTheDrain() async throws {
        let (root, share) = try await seedSharedRoot()
        container.shareMetadataFailures.setValue([CKError(.networkFailure), CKError(.networkFailure)])
        await withKnownIssue {
          await syncEngine.handleFetchedRecordZoneChanges(
            modifications: [share, root],
            syncEngine: syncEngine.shared
          )
        }
        #expect(try await isParked(share.recordID))

        _ = try syncEngine.modifyRecords(scope: .shared, deleting: [share.recordID])
        try await deliverAnUnrelatedChange(under: root)

        #expect(try await !isParked(share.recordID))
      }

      /// A share with no URL has nothing to fetch: it is not parked and nothing is reported.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func aShareWithNoURL_isNotParked() async throws {
        let (root, share) = try await seedSharedRoot()
        container.shareMetadataFailures.setValue([
          ShareMetadataFetchError.missingURL, ShareMetadataFetchError.missingURL,
        ])

        await syncEngine.handleFetchedRecordZoneChanges(
          modifications: [share, root],
          syncEngine: syncEngine.shared
        )
        #expect(try await cachedShare(onRoot: root.recordID) == nil)
        #expect(try await !isParked(share.recordID))
      }
    }
  }

  // A-F2: the live share-metadata fetch, driven through its operation's blocks by hand. Upstream
  // resumed only from the per-share block, so a completion-only failure hung forever. The first test
  // waits for the outcome from an unstructured task with its own bound, so a regression fails it
  // instead of hanging the suite (a suspended continuation ignores a time limit's cancellation).
  // Guard: neutralize the completion block's failure resume → the first test goes red.
  @Suite
  struct LiveShareMetadataFetchTests {
    private let url = URL(string: "https://www.icloud.com/share/0abc")!

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func aCompletionOnlyFailure_throws_neverHangs() async throws {
      let outcome = LockIsolated<Result<CKShare.Metadata, any Error>?>(nil)
      Task { [url] in
        do {
          let metadata = try await CKContainer.fetchShareMetadata(
            shareURL: url,
            shouldFetchRootRecord: false
          ) { operation in
            operation.fetchShareMetadataResultBlock?(.failure(CKError(.networkFailure)))
          }
          outcome.setValue(.success(metadata))
        } catch {
          outcome.setValue(.failure(error))
        }
      }
      for _ in 0..<500 where outcome.value == nil {
        try await Task.sleep(for: .milliseconds(10))
      }
      let result = try #require(outcome.value, "the fetch never resumed")
      #expect(throws: CKError(.networkFailure)) { try result.get() }
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func aPerShareFailure_throwsItOnce_atCompletion() async throws {
      await #expect(throws: CKError(.unknownItem)) {
        _ = try await CKContainer.fetchShareMetadata(
          shareURL: url,
          shouldFetchRootRecord: false
        ) { [url] operation in
          operation.perShareMetadataResultBlock?(url, .failure(CKError(.unknownItem)))
          operation.fetchShareMetadataResultBlock?(.success(()))
        }
      }
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func aSuccessfulCompletionWithNoShare_throwsNoResult() async throws {
      await #expect(throws: ShareMetadataFetchError.noResult) {
        _ = try await CKContainer.fetchShareMetadata(
          shareURL: url,
          shouldFetchRootRecord: false
        ) { operation in
          operation.fetchShareMetadataResultBlock?(.success(()))
        }
      }
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func noURL_throwsBeforeAnythingRuns() async throws {
      let ran = LockIsolated(false)
      await #expect(throws: ShareMetadataFetchError.missingURL) {
        _ = try await CKContainer.fetchShareMetadata(
          shareURL: nil,
          shouldFetchRootRecord: false
        ) { _ in ran.setValue(true) }
      }
      #expect(!ran.value)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func theOperation_carriesCloudKitsTimeouts_andTheRootRecordFlag() async throws {
      for shouldFetchRootRecord in [false, true] {
        let seen = LockIsolated<(Bool, TimeInterval, TimeInterval)?>(nil)
        _ = try? await CKContainer.fetchShareMetadata(
          shareURL: url,
          shouldFetchRootRecord: shouldFetchRootRecord
        ) { operation in
          seen.setValue(
            (
              operation.shouldFetchRootRecord,
              operation.configuration.timeoutIntervalForRequest,
              operation.configuration.timeoutIntervalForResource
            )
          )
          operation.fetchShareMetadataResultBlock?(.failure(CKError(.networkFailure)))
        }
        let (flag, request, resource) = try #require(seen.value)
        #expect(flag == shouldFetchRootRecord)
        #expect(request == 30)
        #expect(resource == 60)
      }
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func aFetchCancelledBeforeItStarts_neverRunsTheOperation() async throws {
      let ran = LockIsolated(false)
      let task = Task { [url] in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await CKContainer.fetchShareMetadata(
          shareURL: url,
          shouldFetchRootRecord: false
        ) { _ in ran.setValue(true) }
      }
      await #expect(throws: CancellationError.self) { _ = try await task.value }
      #expect(!ran.value)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func cancellation_cancelsTheOperation() async throws {
      let captured = LockIsolated<CKFetchShareMetadataOperation?>(nil)
      let task = Task { [url] in
        try await CKContainer.fetchShareMetadata(
          shareURL: url,
          shouldFetchRootRecord: false
        ) { operation in captured.setValue(operation) }
      }
      while captured.value == nil { await Task.yield() }
      task.cancel()
      let operation = try #require(captured.value)
      while !operation.isCancelled { await Task.yield() }
      // CloudKit completes a cancelled operation with `.operationCancelled`; the fetch resumes once.
      operation.fetchShareMetadataResultBlock?(.failure(CKError(.operationCancelled)))
      await #expect(throws: CKError(.operationCancelled)) { _ = try await task.value }
    }
  }
#endif
