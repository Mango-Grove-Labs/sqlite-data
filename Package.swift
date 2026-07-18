// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "sqlite-data",
  platforms: [
    .iOS(.v13),
    .macOS(.v10_15),
    .tvOS(.v13),
    .watchOS(.v7),
  ],
  products: [
    .library(
      name: "SQLiteData",
      targets: ["SQLiteData"]
    ),
    .library(
      name: "SQLiteDataTestSupport",
      targets: ["SQLiteDataTestSupport"]
    ),
  ],
  traits: [
    .trait(
      name: "SQLiteDataTagged",
      description: "Introduce SQLiteData conformances to the swift-tagged package."
    )
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.6.0"),
    .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", from: "1.4.0"),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.3"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.9.0"),
    .package(url: "https://github.com/pointfreeco/swift-perception", from: "2.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.3.0"),
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.18.4"),
    // MANGO PATCH 3 — bound this range. Upstream declares `from: "0.31.0"`, which is unbounded, so a
    // consumer's SPM graph silently resolves whatever is newest. Tag 1.6.6 (this branch's base) is written
    // and tested against **0.31.1** — its own `Package.resolved` pins exactly that — but an app that
    // resolves **0.33.1** misaligns `SyncMetadata`'s generated column decoding. The sync engine's send path
    // then fails reading every pending record's own metadata row with a bogus
    // `Expected column 14 ("userModificationTime") to not be NULL`, and the call site cannot tell that
    // failure from "record deleted", so it REMOVES the pending change. Every record is silently dropped from
    // the upload queue: outbound sync dies completely, unrecoverably, with no user-visible error.
    //
    // This shipped. MontiSprout TestFlight 1.0(12) uploaded nothing for six days across two testers'
    // devices. Nothing in this repo's suite could catch it, because the suite runs against the pinned 0.31.1
    // while consumers ran 0.33.1 — see `PendingRecordMetadataDecodeTests`, which passes on 0.31.1 and fails
    // with the exact production error on 0.33.1. Full forensics: MontiSprout
    // `docs/incidents/2026-07-18-metadata-decode-blocks-all-uploads.md`.
    //
    // `.upToNextMinor` because swift-structured-queries is pre-1.0, where minor bumps are breaking by
    // convention: 0.31.x patches stay allowed, and 0.32+ requires a deliberate, tested upgrade of this fork
    // (rebasing onto an upstream tag that supports it).
    .package(
      url: "https://github.com/pointfreeco/swift-structured-queries",
      .upToNextMinor(from: "0.31.1"),
      traits: [
        .trait(name: "StructuredQueriesTagged", condition: .when(traits: ["SQLiteDataTagged"]))
      ]
    ),
    .package(url: "https://github.com/pointfreeco/swift-tagged", from: "0.10.0"),
    .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", from: "1.5.0"),
  ],
  targets: [
    .target(
      name: "SQLiteData",
      dependencies: [
        .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "IssueReporting", package: "xctest-dynamic-overlay"),
        .product(name: "OrderedCollections", package: "swift-collections"),
        .product(name: "Perception", package: "swift-perception"),
        .product(name: "Sharing", package: "swift-sharing"),
        .product(name: "StructuredQueriesSQLite", package: "swift-structured-queries"),
        .product(
          name: "Tagged",
          package: "swift-tagged",
          condition: .when(traits: ["SQLiteDataTagged"])
        ),
      ]
    ),
    .target(
      name: "SQLiteDataTestSupport",
      dependencies: [
        "SQLiteData",
        .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
        .product(name: "ConcurrencyExtrasTestSupport", package: "swift-concurrency-extras"),
        .product(name: "CustomDump", package: "swift-custom-dump"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "InlineSnapshotTesting", package: "swift-snapshot-testing"),
        .product(name: "StructuredQueriesTestSupport", package: "swift-structured-queries"),
      ]
    ),
    .testTarget(
      name: "SQLiteDataTests",
      dependencies: [
        "SQLiteData",
        "SQLiteDataTestSupport",
        "TestLocals",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
        .product(name: "InlineSnapshotTesting", package: "swift-snapshot-testing"),
        .product(name: "SnapshotTestingCustomDump", package: "swift-snapshot-testing"),
        .product(name: "StructuredQueries", package: "swift-structured-queries"),
      ]
    ),
    .target(
      name: "TestLocals",
      dependencies: ["SQLiteData"]
    ),
  ],
  swiftLanguageModes: [.v6]
)

for target in package.targets {
  target.swiftSettings = target.swiftSettings ?? []
  target.swiftSettings?.append(contentsOf: [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("InferIsolatedConformances"),
  ])
  if target.type != .test {
    target.swiftSettings?.append(contentsOf: [
      .enableUpcomingFeature("InternalImportsByDefault"),
      .enableUpcomingFeature("MemberImportVisibility"),
    ])
  }
}

#if !os(Windows)
  // Add the documentation compiler plugin if possible
  package.dependencies.append(
    .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0")
  )
#endif
