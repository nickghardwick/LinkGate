import AppKit
import Foundation
import XCTest
@testable import LinkGate

// Task 3 frozen acceptance contract mapping:
// 1: app/version/platform/location render only a safe location class.
// 2: HTTP and HTTPS handler identities retain their independent exact/wrong-copy/other/unresolved states.
// 3: current eligible candidates are BrowserOrdering-ordered and identity-filtered without writing preferences.
// 4: routing reports only the count.
// 5: updater output is limited to the four stable Sparkle values and accurately labels downloads.
// 6: handler-preservation output is the in-memory summary, with no-pending represented as none this launch.
// 7: output is deterministic plain text and rejects application paths, persisted identity keys, rules, URLs, and names.
@MainActor
final class DiagnosticsSnapshotTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let storageKey = "LinkGateTests.diagnosticsSnapshot"

    override func setUp() {
        super.setUp()
        suiteName = "LinkGateTests.DiagnosticsSnapshotTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSnapshotRendersSafeAppAndIndependentDefaultHandlerStates() {
        let applicationURL = URL(fileURLWithPath: "/Users/alice/Library/Developer/Xcode/DerivedData/LinkGate-secret/Build/Products/Debug/LinkGate.app")
        let snapshot = makeController(
            applicationURL: applicationURL,
            defaultBrowserStatus: DefaultBrowserDiagnosticStatus(
                http: .exactCurrentApplication,
                https: .otherApplication(bundleIdentifier: "org.example.other-browser")
            )
        ).snapshot()

        let text = snapshot.renderedText

        XCTAssertEqual(
            text,
            """
            LinkGate diagnostics
            App
            - Version: 0.1.8 (108)
            - macOS: 15.0
            - Location: Development copy
            Default handlers
            - HTTP: current LinkGate bundle
            - HTTPS: other application (org.example.other-browser)
            Browsers
            - Enabled: none
            - Disabled detected: 0
            Routing
            - Rules: 0
            Updates
            - Automatic checks: enabled
            - Automatic downloads: disabled
            - Can check now: yes
            - Update session in progress: no
            Handler preservation
            - Result: none this launch
            """
        )
        assertDoesNotContain(text, anyOf: [
            "alice",
            "LinkGate-secret",
            "/Users/alice",
            applicationURL.path,
        ])
    }

    func testSnapshotRendersSameBundleIdentifierAtDifferentLocationWithoutRenderingItsPath() {
        let wrongCopyURL = URL(fileURLWithPath: "/Users/alice/Library/Developer/Xcode/DerivedData/LinkGate-secret/Build/Products/Debug/LinkGate.app")
        let text = makeController(
            defaultBrowserStatus: DefaultBrowserDiagnosticStatus(
                http: .sameBundleIdentifierAtDifferentLocation(.developmentCopy),
                https: .unresolved
            )
        ).snapshot().renderedText

        XCTAssertTrue(text.contains("- HTTP: LinkGate at Development copy"))
        XCTAssertTrue(text.contains("- HTTPS: unresolved"))
        assertDoesNotContain(text, anyOf: [
            wrongCopyURL.path,
            "alice",
            "LinkGate-secret",
            "/Users/alice",
        ])
    }

    func testSnapshotOrdersCurrentEligibleBrowsersFiltersDisabledCandidatesAndDoesNotPersist() throws {
        let firstInstalledCopy = makeCandidate(
            path: "/Applications/Browser A.app",
            displayName: "Alice's Personal Browser",
            bundleIdentifier: "org.example.shared"
        )
        let secondInstalledCopy = makeCandidate(
            path: "/Applications/Browser B.app",
            displayName: "Browser B - private token",
            bundleIdentifier: "org.example.shared"
        )
        let disabledDevelopmentCopy = makeCandidate(
            path: "/Users/alice/Library/Developer/Browser B.app",
            displayName: "Disabled development copy",
            bundleIdentifier: "org.example.shared"
        )
        let firstEnabled = makeCandidate(
            path: "/Applications/Zulu Browser.app",
            displayName: "Zulu Browser",
            bundleIdentifier: "org.example.zulu"
        )
        let store = makeStore()
        try store.saveBrowserOrder([
            "bundle:org.example.zulu",
            "path:\(disabledDevelopmentCopy.applicationURL.path)",
            "path:\(secondInstalledCopy.applicationURL.path)",
            "path:\(firstInstalledCopy.applicationURL.path)",
        ])
        try store.saveDisabledBrowserIdentifiers([
            "path:\(disabledDevelopmentCopy.applicationURL.path)",
            "bundle:org.example.stale-disabled",
        ])
        let beforeData = try XCTUnwrap(defaults.data(forKey: storageKey))
        let beforeOrder = store.browserOrder
        let beforeDisabled = store.disabledBrowserIdentifiers
        let discovery = FixedBrowserDiscovery(
            candidates: [firstInstalledCopy, secondInstalledCopy, disabledDevelopmentCopy, firstEnabled]
        )
        let controller = makeController(store: store, browserDiscovery: discovery)

        let text = controller.snapshot().renderedText

        let browserSection = section(in: text, heading: "Browsers", endingBefore: "Routing")
        XCTAssertEqual(browserSection.first, "Browsers")
        XCTAssertEqual(browserSection.dropFirst().first, "- Enabled (3):")
        XCTAssertEqual(browserSection.last, "- Disabled detected: 1")
        let enabledLines = browserSection.filter { $0.hasPrefix("  - ") }
        XCTAssertEqual(enabledLines.first, "  - org.example.zulu")
        let sharedCopyLabels = Array(enabledLines.dropFirst())
        XCTAssertEqual(sharedCopyLabels.count, 2)
        XCTAssertNotEqual(sharedCopyLabels[0], sharedCopyLabels[1])
        for label in sharedCopyLabels {
            XCTAssertTrue(label.hasPrefix("  - org.example.shared ("))
            XCTAssertTrue(label.contains("Applications"))
        }
        XCTAssertEqual(defaults.data(forKey: storageKey), beforeData)
        XCTAssertEqual(store.browserOrder, beforeOrder)
        XCTAssertEqual(store.disabledBrowserIdentifiers, beforeDisabled)
        XCTAssertEqual(discovery.requestedURLs, [URL(string: "https://example.com")!])
        assertDoesNotContain(text, anyOf: [
            firstInstalledCopy.applicationURL.path,
            secondInstalledCopy.applicationURL.path,
            disabledDevelopmentCopy.applicationURL.path,
            "Alice's Personal Browser",
            "private token",
            "bundle:org.example",
            "path:/Applications",
            "stale-disabled",
        ])
    }

    func testSnapshotRendersRuleCountOnlyAndStableUpdaterAndRestorationValues() throws {
        let store = makeStore()
        let firstRule = try store.create(
            matchType: .urlPrefix,
            pattern: "https://private.example/invoices/INV-483?token=rule-secret",
            browserBundleIdentifier: "org.example.rule-target"
        )
        let secondRule = try store.create(
            matchType: .domainFamily,
            pattern: "staff.private.example",
            browserBundleIdentifier: "org.example.second-target"
        )
        let restoration = HandlerPreservationRestorationSummary(
            disposition: .exhausted,
            http: .verificationFailed,
            https: .notOwnedBeforeUpdate
        )
        let snapshot = makeController(
            store: store,
            updateState: UpdateDiagnosticState(
                automaticallyChecksForUpdates: false,
                automaticallyDownloadsUpdates: true,
                canCheckForUpdates: false,
                sessionInProgress: true,
                latestHandlerPreservationResult: restoration
            )
        ).snapshot()

        let text = snapshot.renderedText

        XCTAssertTrue(text.contains("- Rules: 2"))
        XCTAssertTrue(text.contains("- Automatic checks: disabled"))
        XCTAssertTrue(text.contains("- Automatic downloads: enabled"))
        XCTAssertTrue(text.contains("- Can check now: no"))
        XCTAssertTrue(text.contains("- Update session in progress: yes"))
        XCTAssertTrue(text.contains("- Result: exhausted"))
        XCTAssertTrue(text.contains("- HTTP: verification failed"))
        XCTAssertTrue(text.contains("- HTTPS: not owned before update"))
        XCTAssertEqual(
            section(in: text, heading: "Routing", endingBefore: "Updates"),
            ["Routing", "- Rules: 2"],
            "The Routing section must expose only the rule count."
        )
        assertDoesNotContain(text, anyOf: [
            firstRule.pattern,
            secondRule.pattern,
            firstRule.browserBundleIdentifier,
            secondRule.browserBundleIdentifier,
            firstRule.id.uuidString,
            secondRule.id.uuidString,
            "rule-secret",
            "urlPrefix",
            "domainFamily",
            "exactDomain",
            "automatic install",
            "appcast",
            "signature",
            "feed",
        ])
    }

    func testNoPendingRecordRendersAsNoneThisLaunchAndOtherTerminalSummariesRetainBothSchemes() {
        let noPending = makeController(
            updateState: UpdateDiagnosticState(
                automaticallyChecksForUpdates: true,
                automaticallyDownloadsUpdates: false,
                canCheckForUpdates: true,
                sessionInProgress: false,
                latestHandlerPreservationResult: .init(
                    disposition: .noPendingRecord,
                    http: .notAttempted,
                    https: .notAttempted
                )
            )
        ).snapshot().renderedText
        let terminal = makeController(
            updateState: UpdateDiagnosticState(
                automaticallyChecksForUpdates: true,
                automaticallyDownloadsUpdates: false,
                canCheckForUpdates: true,
                sessionInProgress: false,
                latestHandlerPreservationResult: .init(
                    disposition: .registrationFailed,
                    http: .restored,
                    https: .registrationFailed
                )
            )
        ).snapshot().renderedText
        let gated = makeController(
            updateState: UpdateDiagnosticState(
                automaticallyChecksForUpdates: true,
                automaticallyDownloadsUpdates: false,
                canCheckForUpdates: true,
                sessionInProgress: false,
                latestHandlerPreservationResult: .init(
                    disposition: .gated,
                    http: .notAttempted,
                    https: .notAttempted
                )
            )
        ).snapshot().renderedText

        XCTAssertTrue(noPending.contains("- Result: none this launch"))
        XCTAssertFalse(noPending.contains("not attempted"))
        XCTAssertTrue(terminal.contains("- Result: registration failed"))
        XCTAssertTrue(terminal.contains("- HTTP: restored"))
        XCTAssertTrue(terminal.contains("- HTTPS: registration failed"))
        XCTAssertTrue(gated.contains("- Result: gated"))
        XCTAssertTrue(gated.contains("- HTTP: not attempted"))
        XCTAssertTrue(gated.contains("- HTTPS: not attempted"))
    }

    private func makeController(
        store: UserDefaultsRoutingRuleStore? = nil,
        candidates: [ApplicationCandidate] = [],
        browserDiscovery: FixedBrowserDiscovery? = nil,
        applicationURL: URL = URL(fileURLWithPath: "/Applications/LinkGate.app"),
        defaultBrowserStatus: DefaultBrowserDiagnosticStatus = .init(http: .unresolved, https: .unresolved),
        updateState: UpdateDiagnosticState = .init(
            automaticallyChecksForUpdates: true,
            automaticallyDownloadsUpdates: false,
            canCheckForUpdates: true,
            sessionInProgress: false,
            latestHandlerPreservationResult: nil
        )
    ) -> DiagnosticsController {
        DiagnosticsController(
            ruleStore: store ?? makeStore(),
            browserDiscovery: browserDiscovery ?? FixedBrowserDiscovery(candidates: candidates),
            defaultBrowserStatus: { defaultBrowserStatus },
            updateDiagnosticState: { updateState },
            applicationVersion: "0.1.8",
            applicationBuild: "108",
            macOSVersion: "15.0",
            applicationURL: applicationURL
        )
    }

    private func makeStore() -> UserDefaultsRoutingRuleStore {
        UserDefaultsRoutingRuleStore(userDefaults: defaults, storageKey: storageKey)
    }

    private func makeCandidate(path: String, displayName: String, bundleIdentifier: String) -> ApplicationCandidate {
        ApplicationCandidate(
            applicationURL: URL(fileURLWithPath: path),
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            icon: NSImage(size: NSSize(width: 16, height: 16))
        )
    }

    private func section(in text: String, heading: String, endingBefore nextHeading: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(of: heading) else { return [] }
        let end = lines[(start + 1)...].firstIndex(of: nextHeading) ?? lines.endIndex
        return Array(lines[start..<end])
    }

    private func assertDoesNotContain(
        _ value: String,
        anyOf forbiddenSubstrings: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for forbiddenSubstring in forbiddenSubstrings {
            XCTAssertFalse(
                value.localizedCaseInsensitiveContains(forbiddenSubstring),
                "Diagnostic snapshot must not contain \(forbiddenSubstring): \(value)",
                file: file,
                line: line
            )
        }
    }
}

private final class FixedBrowserDiscovery: BrowserDiscoveryService {
    private let candidatesToReturn: [ApplicationCandidate]
    private(set) var requestedURLs: [URL] = []

    init(candidates: [ApplicationCandidate]) {
        candidatesToReturn = candidates
    }

    func candidates(for url: URL) -> [ApplicationCandidate] {
        requestedURLs.append(url)
        return candidatesToReturn
    }
}
