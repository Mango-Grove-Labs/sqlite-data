// swift-tools-version: 6.1

import Foundation
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
  traits: [
    .trait(
      name: "LazyInitializableByDefault",
      description: "Optionalize draft properties that have no default."
    ),
    .trait(
      name: "CasePaths",
      description: "Introduce support for enum tables."
    ),
    .trait(
      name: "SuppressPlatformSQLiteAvailability",
      description: """
        Suppress '@available' checks on APIs that depend on a newer version of SQLite than the one \
        bundled with the platform.
        """
    ),
    .trait(
      name: "StrictDecoding",
      description: """
        Throw an error, rather than coerce, when decoding a column whose storage type does not \
        match the expected type.
        """
    ),
    .trait(
      name: "Tagged",
      description: "Introduce SQLiteData conformances to the swift-tagged package."
    ),
    .trait(
      name: "SQLiteDataTagged",
      description: "A deprecated alias for the 'Tagged' trait.",
      enabledTraits: ["Tagged"]
    ),
  ],
  dependencies: [
    // MANGO PATCH 3, second half (2026-09-02) — **every** dependency here is bounded to the minor
    // this branch's base tag (upstream 1.10.0) is actually written and tested against, i.e. the
    // version that tag's own `Package.resolved` pins. Upstream declares each one with a bare
    // `from:`, which for a pre-1.0 package means "any breaking minor" and for a post-1.0 one still
    // means "any untested minor" — either way the resolver, not this fork, picks what a consumer
    // links against. That is the exact hole that produced the 1.0(12) sync outage (see the
    // swift-structured-queries note below for the full forensics); it is a CLASS of bug, not a
    // one-off, and GRDB — declared `from: "7.6.0"`, resolving 7.11.1, sitting directly under the
    // storage layer — was the widest gap in the manifest.
    //
    // Consequence, deliberately accepted: a new minor of any of these becomes a DELIBERATE, tested
    // fork upgrade (retune here, run the suite twice, bump consumer pins) instead of something a
    // consumer's resolver decides silently. The failure mode of a bound that is too tight is a LOUD
    // resolution error at build time; the failure mode of no bound is silent data loss in the field.
    // Keep every bound in lockstep with the base tag's `Package.resolved` at each rebase (rebase
    // procedure step 5), and keep `Package@swift-6.0.swift` in lockstep with this file.
    .package(url: "https://github.com/apple/swift-collections", .upToNextMinor(from: "1.6.0")),
    .package(url: "https://github.com/groue/GRDB.swift", .upToNextMinor(from: "7.11.1")),
    .package(
      url: "https://github.com/pointfreeco/swift-concurrency-extras",
      .upToNextMinor(from: "1.4.1")
    ),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", .upToNextMinor(from: "1.7.0")),
    .package(
      url: "https://github.com/pointfreeco/swift-dependencies",
      .upToNextMinor(from: "1.14.1")
    ),
    .package(url: "https://github.com/pointfreeco/swift-perception", .upToNextMinor(from: "2.0.11")),
    .package(url: "https://github.com/pointfreeco/swift-sharing", .upToNextMinor(from: "2.9.1")),
    .package(
      url: "https://github.com/pointfreeco/swift-snapshot-testing",
      .upToNextMinor(from: "1.19.4")
    ),
    // MANGO PATCH 3 — bound this range. Upstream declares an open lower bound (`from:`), so a consumer's
    // SPM graph silently resolves whatever is newest. The bound pins the minor this branch's base tag is
    // actually written and tested against: **1.10.0 pins 0.36.0** in its own `Package.resolved`.
    //
    // History (the 1.6.6-era outage this patch exists for): 1.6.6 was tested against 0.31.1, but an app
    // that resolved **0.33.1** misaligned `SyncMetadata`'s generated column decoding on that base. The
    // sync engine's send path then failed reading every pending record's own metadata row with a bogus
    // `Expected column 14 ("userModificationTime") to not be NULL`, and the call site cannot tell that
    // failure from "record deleted", so it REMOVES the pending change. Every record is silently dropped
    // from the upload queue: outbound sync dies completely, unrecoverably, with no user-visible error.
    // That shipped: MonteSprout TestFlight 1.0(12) uploaded nothing for six days across two testers'
    // devices — the suite ran against the pinned minor while consumers resolved a newer one. See
    // `PendingRecordMetadataDecodeTests` (the tripwire; it fails with the exact production error on a
    // base/dep mismatch). Full forensics: MonteSprout
    // `docs/incidents/2026-07-18-metadata-decode-blocks-all-uploads.md`.
    //
    // `.upToNextMinor` because swift-structured-queries is pre-1.0, where minor bumps are breaking by
    // convention: 0.36.x patches stay allowed, and 0.37+ requires a deliberate, tested upgrade of this fork
    // (rebasing onto an upstream tag that supports it).
    .package(
      url: "https://github.com/pointfreeco/swift-structured-queries",
      .upToNextMinor(from: "0.36.0"),
      traits: [
        .trait(
          name: "LazyInitializableByDefault",
          condition: .when(traits: ["LazyInitializableByDefault"])
        ),
        .trait(name: "CasePaths", condition: .when(traits: ["CasePaths"])),
        .trait(
          name: "LazyInitializableByDefault",
          condition: .when(traits: ["LazyInitializableByDefault"])
        ),
        .trait(
          name: "SuppressPlatformSQLiteAvailability",
          condition: .when(traits: ["SuppressPlatformSQLiteAvailability"])
        ),
        .trait(name: "Tagged", condition: .when(traits: ["Tagged"])),
      ]
    ),
    // swift-tagged is trait-gated (`Tagged`, off by default), so it appears in NO `Package.resolved`
    // here — there is no tested-against version to read off the base tag. Bounded at its own declared
    // floor's minor: pre-1.0, so 0.11+ is breaking by convention and must be a deliberate upgrade.
    .package(url: "https://github.com/pointfreeco/swift-tagged", .upToNextMinor(from: "0.10.0")),
    .package(
      url: "https://github.com/pointfreeco/xctest-dynamic-overlay",
      .upToNextMinor(from: "1.11.0")
    ),
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
          condition: .when(traits: ["Tagged"])
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
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  ])
  if target.type != .test {
    target.swiftSettings?.append(contentsOf: [
      .enableUpcomingFeature("InternalImportsByDefault"),
      .enableUpcomingFeature("MemberImportVisibility"),
    ])
    if ProcessInfo.processInfo.environment.keys.contains("EXCLUDE_EXPORTS") {
      target.swiftSettings?.append(.define("EXCLUDE_EXPORTS"))
    }
  }
}

#if !os(Windows)
  // Add the documentation compiler plugin if possible
  // MANGO PATCH 3 (audit) — bounded like every other dependency; 1.10.0 resolves 1.5.0. Docs-only
  // build tooling, so it cannot cause a field failure, but it is declared here and therefore
  // propagates into a consumer's resolution graph like any other range.
  package.dependencies.append(
    .package(url: "https://github.com/apple/swift-docc-plugin", .upToNextMinor(from: "1.5.0"))
  )
#endif
