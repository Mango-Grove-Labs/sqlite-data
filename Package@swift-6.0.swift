// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "sqlite-data",
  platforms: [
    .iOS(.v16),
    .macOS(.v13),
    .tvOS(.v16),
    .watchOS(.v9),
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
  dependencies: [
    .package(url: "https://github.com/apple/swift-collections", .upToNextMinor(from: "1.6.0")),
    .package(url: "https://github.com/groue/GRDB.swift", .upToNextMinor(from: "7.11.1")),
    .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", .upToNextMinor(from: "1.4.1")),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", .upToNextMinor(from: "1.7.3")),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", .upToNextMinor(from: "1.17.1")),
    .package(url: "https://github.com/pointfreeco/swift-sharing", .upToNextMinor(from: "2.10.1")),
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", .upToNextMinor(from: "1.19.4")),
    .package(url: "https://github.com/pointfreeco/swift-structured-queries", .upToNextMinor(from: "0.39.1")),
    .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", .upToNextMinor(from: "1.13.0")),
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
        .product(name: "Sharing", package: "swift-sharing"),
        .product(name: "StructuredQueriesSQLite", package: "swift-structured-queries"),
      ]
    ),
    .target(
      name: "SQLiteDataTestSupport",
      dependencies: [
        "SQLiteData",
        .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
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
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
        .product(name: "InlineSnapshotTesting", package: "swift-snapshot-testing"),
        .product(name: "SnapshotTestingCustomDump", package: "swift-snapshot-testing"),
        .product(name: "StructuredQueries", package: "swift-structured-queries"),
      ]
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
  // MANGO PATCH 3 (audit) — bounded like every other dependency; 1.12.0 resolves 1.5.0. Docs-only
  // build tooling, so it cannot cause a field failure, but it is declared here and therefore
  // propagates into a consumer's resolution graph like any other range.
  package.dependencies.append(
    .package(url: "https://github.com/apple/swift-docc-plugin", .upToNextMinor(from: "1.5.0"))
  )
#endif
