import AppKit
import XCTest
@testable import LinkGate

// Acceptance Contract mapping
// 2: preserves Launch Services order, filters current and stale-copy LinkGate registrations, and deduplicates normalized application URLs.
// 3: retains each original application URL and its metadata; identity is never bundle identifier or name.
// 4: preserves empty and one-candidate discovery results for the coordinator to present.
final class BrowserDiscoveryServiceTests: XCTestCase {
    func testMapsEligibleApplicationsInWorkspaceOrderWithMetadata() {
        let requestedURL = URL(string: "https://example.com/path")!
        let first = URL(fileURLWithPath: "/Applications/Zulu.app")
        let second = URL(fileURLWithPath: "/Applications/Alpha.app")
        let firstIcon = makeImage(color: .systemRed)
        let secondIcon = makeImage(color: .systemBlue)
        let workspace = FakeWorkspace(returnedURLs: [first, second])
        let service = NSWorkspaceBrowserDiscoveryService(
            workspace: workspace,
            metadataProvider: FakeMetadataProvider(values: [
                first: .init(displayName: "Zulu", bundleIdentifier: "example.zulu", icon: firstIcon),
                second: .init(displayName: "Alpha", bundleIdentifier: "example.alpha", icon: secondIcon),
            ]),
            currentApplicationURL: nil,
            currentBundleIdentifier: nil
        )

        let candidates = service.candidates(for: requestedURL)

        XCTAssertEqual(candidates.map(\.applicationURL), [first, second])
        XCTAssertEqual(candidates.map(\.displayName), ["Zulu", "Alpha"])
        XCTAssertEqual(candidates.map(\.bundleIdentifier), ["example.zulu", "example.alpha"])
        assertEquivalentImage(candidates[0].icon, firstIcon)
        assertEquivalentImage(candidates[1].icon, secondIcon)
        XCTAssertEqual(workspace.requestedURLs, [requestedURL])
    }

    func testExcludesCurrentLinkGateApplicationUsingStandardizedURL() {
        let linkGateOriginalURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let linkGateEquivalentURL = URL(fileURLWithPath: "/Applications/Unused/../LinkGate.app")
        let browserURL = URL(fileURLWithPath: "/Applications/Browser.app")
        XCTAssertEqual(
            normalizedApplicationURL(linkGateOriginalURL),
            normalizedApplicationURL(linkGateEquivalentURL)
        )
        let service = makeService(
            returnedURLs: [linkGateEquivalentURL, browserURL],
            metadata: [browserURL: metadata(name: "Browser")],
            currentApplicationURL: linkGateOriginalURL
        )

        let candidates = service.candidates(for: URL(string: "https://example.com")!)

        XCTAssertEqual(candidates.map(\.applicationURL), [browserURL])
    }

    func testExcludesStaleLinkGateCopyUsingCurrentBundleIdentifier() {
        let currentLinkGateURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let staleLinkGateURL = URL(fileURLWithPath: "/Applications/LinkGate Development.app")
        let browserURL = URL(fileURLWithPath: "/Applications/Browser.app")
        let linkGateBundleIdentifier = "com.example.LinkGate"
        let service = makeService(
            returnedURLs: [staleLinkGateURL, browserURL],
            metadata: [
                staleLinkGateURL: metadata(name: "LinkGate Development", bundleIdentifier: linkGateBundleIdentifier),
                browserURL: metadata(name: "Browser", bundleIdentifier: "com.example.browser"),
            ],
            currentApplicationURL: currentLinkGateURL,
            currentBundleIdentifier: linkGateBundleIdentifier
        )

        let candidates = service.candidates(for: URL(string: "https://example.com")!)

        XCTAssertEqual(candidates.map(\.applicationURL), [browserURL])
    }

    func testDeduplicatesStandardizedAndSymlinkResolvedURLsAndRetainsFirstOriginalURL() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let canonicalBrowserURL = directoryURL.appendingPathComponent("Browser.app", isDirectory: true)
        try FileManager.default.createDirectory(at: canonicalBrowserURL, withIntermediateDirectories: true)
        let firstOriginalURL = directoryURL.appendingPathComponent("Browser Alias.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: firstOriginalURL, withDestinationURL: canonicalBrowserURL)
        let standardizedDuplicateURL = directoryURL.appendingPathComponent("Unused/../Browser.app", isDirectory: true)
        let secondBrowserURL = URL(fileURLWithPath: "/Applications/Second.app")
        XCTAssertEqual(
            normalizedApplicationURL(firstOriginalURL),
            normalizedApplicationURL(standardizedDuplicateURL)
        )
        XCTAssertEqual(
            normalizedApplicationURL(firstOriginalURL),
            normalizedApplicationURL(canonicalBrowserURL)
        )
        let service = makeService(
            returnedURLs: [firstOriginalURL, standardizedDuplicateURL, canonicalBrowserURL, secondBrowserURL],
            metadata: [
                firstOriginalURL: metadata(name: "First Browser Alias"),
                standardizedDuplicateURL: metadata(name: "Duplicate Browser"),
                canonicalBrowserURL: metadata(name: "Canonical Duplicate Browser"),
                secondBrowserURL: metadata(name: "Second Browser"),
            ]
        )

        let candidates = service.candidates(for: URL(string: "https://example.com")!)

        XCTAssertEqual(candidates.map(\.applicationURL), [firstOriginalURL, secondBrowserURL])
        XCTAssertEqual(candidates.map(\.displayName), ["First Browser Alias", "Second Browser"])
    }

    func testRetainsDifferentApplicationURLsWithMatchingBundleIdentifierAndName() {
        let first = URL(fileURLWithPath: "/Applications/Browser One.app")
        let second = URL(fileURLWithPath: "/Applications/Browser Two.app")
        let sharedMetadata = metadata(name: "Browser", bundleIdentifier: "example.browser")
        let service = makeService(
            returnedURLs: [first, second],
            metadata: [first: sharedMetadata, second: sharedMetadata],
            currentBundleIdentifier: "com.example.LinkGate"
        )

        let candidates = service.candidates(for: URL(string: "https://example.com")!)

        XCTAssertEqual(candidates.map(\.applicationURL), [first, second])
        XCTAssertEqual(candidates.map(\.bundleIdentifier), ["example.browser", "example.browser"])
        XCTAssertEqual(candidates.map(\.displayName), ["Browser", "Browser"])
    }

    func testPreservesEmptyAndSingleCandidateResults() {
        let requestedURL = URL(string: "https://example.com")!
        let emptyService = makeService(returnedURLs: [], metadata: [:])
        let onlyBrowser = URL(fileURLWithPath: "/Applications/Only Browser.app")
        let oneService = makeService(
            returnedURLs: [onlyBrowser],
            metadata: [onlyBrowser: metadata(name: "Only Browser")]
        )

        XCTAssertTrue(emptyService.candidates(for: requestedURL).isEmpty)
        XCTAssertEqual(oneService.candidates(for: requestedURL).map(\.applicationURL), [onlyBrowser])
    }

    func testUsesApplicationNameAndGenericIconWhenMetadataIsMissing() {
        let applicationURL = URL(fileURLWithPath: "/Applications/Fallback Browser.app")
        let service = makeService(
            returnedURLs: [applicationURL],
            metadata: [applicationURL: .init(displayName: nil, bundleIdentifier: nil, icon: nil)]
        )

        let candidate = try! XCTUnwrap(service.candidates(for: URL(string: "https://example.com")!).first)

        XCTAssertEqual(candidate.applicationURL, applicationURL)
        XCTAssertEqual(candidate.displayName, "Fallback Browser")
        XCTAssertNil(candidate.bundleIdentifier)
        XCTAssertEqual(candidate.icon.name(), NSImage.applicationIconName)
    }

    private func makeService(
        returnedURLs: [URL],
        metadata: [URL: ApplicationMetadata],
        currentApplicationURL: URL? = nil,
        currentBundleIdentifier: String? = nil
    ) -> BrowserDiscoveryService {
        NSWorkspaceBrowserDiscoveryService(
            workspace: FakeWorkspace(returnedURLs: returnedURLs),
            metadataProvider: FakeMetadataProvider(values: metadata),
            currentApplicationURL: currentApplicationURL,
            currentBundleIdentifier: currentBundleIdentifier
        )
    }

    private func metadata(
        name: String,
        bundleIdentifier: String? = nil,
        icon: NSImage = NSImage(size: NSSize(width: 16, height: 16))
    ) -> ApplicationMetadata {
        ApplicationMetadata(displayName: name, bundleIdentifier: bundleIdentifier, icon: icon)
    }

    private func normalizedApplicationURL(_ url: URL) -> URL {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        return URL(fileURLWithPath: resolvedURL.path, isDirectory: false)
    }

    private func makeImage(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 2, height: 2)).fill()
        image.unlockFocus()
        return image
    }

    private func assertEquivalentImage(
        _ actual: NSImage,
        _ expected: NSImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualRepresentation = actual.tiffRepresentation
        let expectedRepresentation = expected.tiffRepresentation
        XCTAssertNotNil(actualRepresentation, file: file, line: line)
        XCTAssertNotNil(expectedRepresentation, file: file, line: line)
        XCTAssertEqual(actualRepresentation, expectedRepresentation, file: file, line: line)
    }
}

private final class FakeWorkspace: WorkspaceApplicationProviding {
    let returnedURLs: [URL]
    private(set) var requestedURLs: [URL] = []

    init(returnedURLs: [URL]) {
        self.returnedURLs = returnedURLs
    }

    func applicationURLs(toOpen url: URL) -> [URL] {
        requestedURLs.append(url)
        return returnedURLs
    }
}

private final class FakeMetadataProvider: ApplicationMetadataProviding {
    let values: [URL: ApplicationMetadata]

    init(values: [URL: ApplicationMetadata]) {
        self.values = values
    }

    func metadata(for applicationURL: URL) -> ApplicationMetadata {
        values[applicationURL] ?? ApplicationMetadata(displayName: nil, bundleIdentifier: nil, icon: nil)
    }
}
