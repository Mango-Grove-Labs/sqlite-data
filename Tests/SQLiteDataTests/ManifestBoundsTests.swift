import Foundation
import Testing

// MANGO PATCH 3 (audit half) — the tripwire for the manifests' dependency bounds.
//
// The rebase procedure's step 5 says to check both manifests "by eye", because no *behavior* test
// can catch a dropped bound: the suite resolves via this repo's own `Package.resolved` and stays
// green on whatever version is pinned there, which is exactly how the 1.0(12) outage reached the
// field. This suite checks the manifests as TEXT instead, which the eye-check can be automated into:
//
//   1. no dependency is declared with a bare `from:` (an unbounded range a consumer's resolver, not
//      this fork, gets to fill), and
//   2. every bound's floor is the minor this branch's base tag is actually tested against — the
//      version in `Package.resolved` — so a retarget that forgets to retune the bounds goes red
//      here instead of shipping a range that excludes the code's own tested dependency.
//
// It fails on the manifest sources, so it is toolchain-independent. Since the 1.12.0 base the
// manifest is versioned three ways: `Package.swift` (tools 6.4) is what a current toolchain and
// upstream CI use, `Package@swift-6.1.swift` is the manifest that ACTUALLY resolves on the 6.1–6.3
// toolchains this fork currently builds with, and `Package@swift-6.0.swift` is inert everywhere we
// build — every one of them propagates into some consumer's resolution graph, so every one is
// checked.
@Suite struct ManifestBoundsTests {
  static let manifests = ["Package.swift", "Package@swift-6.1.swift", "Package@swift-6.0.swift"]

  @Test(arguments: manifests)
  func manifestDeclaresNoUnboundedRange(manifest: String) throws {
    for dependency in try Self.dependencies(inManifest: manifest) {
      #expect(
        dependency.isBounded,
        """
        \(dependency.identity) is declared with an unbounded `from:` in \(manifest). \
        Bound it with `.upToNextMinor(from:)` — see MANGO-PATCHES.md § 3.
        """
      )
    }
  }

  @Test(arguments: manifests)
  func everyBoundMatchesTheResolvedMinor(manifest: String) throws {
    let resolved = try Self.resolvedVersions()
    for dependency in try Self.dependencies(inManifest: manifest) {
      // A trait-gated dependency (swift-tagged) is in no resolution of this package, so there is no
      // tested-against version to compare with; its bound is anchored to its own declared floor.
      guard let resolvedVersion = resolved[dependency.identity] else { continue }
      #expect(
        dependency.floor.map(Self.minor) == Self.minor(resolvedVersion),
        """
        \(dependency.identity) is bounded at \(dependency.floor ?? "??") in \(manifest) but \
        Package.resolved pins \(resolvedVersion). Retune the bound to the base tag's own pin — \
        see MANGO-PATCHES.md § 3 and rebase procedure step 5.
        """
      )
    }
  }

  // MARK: - Manifest parsing

  struct Dependency {
    var identity: String
    var floor: String?
    var isBounded: Bool
  }

  static let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // SQLiteDataTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // <package root>

  /// Every `.package(url:…)` declaration in a manifest, with the `from:` floor it was declared with
  /// and whether that floor carries an explicit ceiling.
  static func dependencies(inManifest manifest: String) throws -> [Dependency] {
    let source = try String(contentsOf: packageRoot.appendingPathComponent(manifest), encoding: .utf8)
    // Comments discuss ranges in the same syntax they bound them with; only code counts.
    let code = source
      .split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")

    return code.components(separatedBy: ".package(").dropFirst().compactMap { chunk in
      guard let url = value(ofArgument: "url: \"", in: chunk) else { return nil }
      let identity = URL(fileURLWithPath: url).lastPathComponent.lowercased()
      guard let floorRange = chunk.range(of: "from: \"") else {
        // `.revision`/`.branch`/`.exact` — no floor to bound, nothing for this suite to say.
        return Dependency(identity: identity, floor: nil, isBounded: true)
      }
      let prefix = chunk[..<floorRange.lowerBound]
      let isBounded =
        prefix.hasSuffix(".upToNextMinor(") || prefix.hasSuffix(".upToNextMajor(")
      return Dependency(
        identity: identity,
        floor: value(ofArgument: "from: \"", in: chunk),
        isBounded: isBounded
      )
    }
  }

  static func value(ofArgument argument: String, in chunk: String) -> String? {
    guard let start = chunk.range(of: argument),
      let end = chunk[start.upperBound...].firstIndex(of: "\"")
    else { return nil }
    return String(chunk[start.upperBound..<end])
  }

  // MARK: - Package.resolved

  static func resolvedVersions() throws -> [String: String] {
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Package.resolved"))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let pins = json?["pins"] as? [[String: Any]] ?? []
    return Dictionary(
      uniqueKeysWithValues: pins.compactMap { pin in
        guard let identity = pin["identity"] as? String,
          let version = (pin["state"] as? [String: Any])?["version"] as? String
        else { return nil }
        return (identity, version)
      }
    )
  }

  /// `major.minor` — the granularity `.upToNextMinor` actually pins.
  static func minor(_ version: String) -> String {
    version.split(separator: ".").prefix(2).joined(separator: ".")
  }
}
