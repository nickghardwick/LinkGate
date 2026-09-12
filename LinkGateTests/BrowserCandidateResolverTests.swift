import AppKit
import XCTest
@testable import LinkGate

// Acceptance Contract mapping:
// 8: rule resolution is by nonempty bundle identifier only, choosing the first discovery-order
//    match and retaining the original candidate URL/metadata. No match is nil for chooser fallback.
final class BrowserCandidateResolverTests: XCTestCase {
    func testReturnsFirstDiscoveryOrderMatchWithOriginalURLAndMetadata() {
        let first = makeCandidate(
            url: URL(fileURLWithPath: "/Applications/Browser One.app"),
            name: "Renamed Browser",
            bundleIdentifier: "com.example.browser"
        )
        let second = makeCandidate(
            url: URL(fileURLWithPath: "/Volumes/External/Browser Two.app"),
            name: "Another Copy",
            bundleIdentifier: "com.example.browser"
        )
        let resolver = BrowserCandidateResolver()

        let resolved = resolver.candidate(bundleIdentifier: "com.example.browser", among: [first, second])

        XCTAssertEqual(resolved?.applicationURL, first.applicationURL)
        XCTAssertEqual(resolved?.displayName, "Renamed Browser")
        XCTAssertEqual(resolved?.bundleIdentifier, "com.example.browser")
    }

    func testDoesNotResolveByDisplayNamePathOrMissingBundleIdentifier() {
        let sameName = makeCandidate(
            url: URL(fileURLWithPath: "/Applications/Matching Name.app"),
            name: "Browser",
            bundleIdentifier: "com.example.different"
        )
        let unidentifiable = makeCandidate(
            url: URL(fileURLWithPath: "/Applications/Unidentified.app"),
            name: "Browser",
            bundleIdentifier: nil
        )
        let resolver = BrowserCandidateResolver()

        XCTAssertNil(resolver.candidate(bundleIdentifier: "com.example.browser", among: [sameName, unidentifiable]))
        XCTAssertNil(resolver.candidate(bundleIdentifier: "", among: [sameName, unidentifiable]))
    }

    private func makeCandidate(url: URL, name: String, bundleIdentifier: String?) -> ApplicationCandidate {
        ApplicationCandidate(
            applicationURL: url,
            displayName: name,
            bundleIdentifier: bundleIdentifier,
            icon: NSImage(size: NSSize(width: 16, height: 16))
        )
    }
}
