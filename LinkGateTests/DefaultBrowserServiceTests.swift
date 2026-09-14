import AppKit
import XCTest
@testable import LinkGate

// Acceptance Contract mapping:
// A5: Default-browser status checks both HTTP and HTTPS through public workspace APIs. A request
// targets LinkGate explicitly, performs HTTP before HTTPS, stops after a failure, and reports one
// completion. These tests exercise the workspace adapter seam rather than macOS global defaults.
@MainActor
final class DefaultBrowserServiceTests: XCTestCase {
    func testStatusLooksUpBothSchemesAndReportsDefaultWhenTheCurrentBundleOwnsEach() {
        let linkGateURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let workspace = DefaultBrowserWorkspaceFake(
            applicationsToOpen: [
                "http": linkGateURL,
                "https": linkGateURL,
            ],
            bundleIdentifiers: [
                linkGateURL: "com.example.LinkGate",
            ]
        )
        let service = NSWorkspaceDefaultBrowserService(
            workspace: workspace,
            applicationURL: linkGateURL,
            bundleIdentifier: "com.example.LinkGate"
        )

        let status = service.status()

        XCTAssertEqual(workspace.lookupSchemes, ["http", "https"])
        XCTAssertTrue(status.httpIsDefault)
        XCTAssertTrue(status.httpsIsDefault)
        XCTAssertTrue(status.isDefault)
        XCTAssertTrue(workspace.setDefaultCalls.isEmpty)
    }

    func testStatusTreatsSameBundleIdentifierAtAnotherPathAsNotDefault() {
        let linkGateURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let fixtureURL = URL(fileURLWithPath: "/repo/fixtures/LinkGate.app")
        let workspace = DefaultBrowserWorkspaceFake(
            applicationsToOpen: ["http": fixtureURL, "https": fixtureURL],
            bundleIdentifiers: [fixtureURL: "com.nickghardwick.LinkGate"]
        )
        let service = NSWorkspaceDefaultBrowserService(
            workspace: workspace,
            applicationURL: linkGateURL,
            bundleIdentifier: "com.nickghardwick.LinkGate"
        )

        let status = service.status()

        XCTAssertEqual(status, DefaultBrowserStatus(httpIsDefault: false, httpsIsDefault: false))
        XCTAssertFalse(status.isDefault)
    }

    func testStatusReportsOnlyTheSchemeResolvedToTheCurrentBundle() {
        let linkGateURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let fixtureURL = URL(fileURLWithPath: "/repo/fixtures/LinkGate.app")
        let workspace = DefaultBrowserWorkspaceFake(
            applicationsToOpen: ["http": linkGateURL, "https": fixtureURL],
            bundleIdentifiers: [
                linkGateURL: "com.nickghardwick.LinkGate",
                fixtureURL: "com.nickghardwick.LinkGate",
            ]
        )
        let service = NSWorkspaceDefaultBrowserService(
            workspace: workspace,
            applicationURL: linkGateURL,
            bundleIdentifier: "com.nickghardwick.LinkGate"
        )

        let status = service.status()

        XCTAssertEqual(status, DefaultBrowserStatus(httpIsDefault: true, httpsIsDefault: false))
        XCTAssertFalse(status.isDefault)
    }

    func testStatusRecognizesStandardizedEquivalentBundleURLs() {
        let linkGateURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let alternateSpelling = URL(fileURLWithPath: "/Applications/Current/../LinkGate.app")
        let workspace = DefaultBrowserWorkspaceFake(
            applicationsToOpen: ["http": alternateSpelling, "https": alternateSpelling],
            bundleIdentifiers: [alternateSpelling: "com.nickghardwick.LinkGate"]
        )
        let service = NSWorkspaceDefaultBrowserService(
            workspace: workspace,
            applicationURL: linkGateURL,
            bundleIdentifier: "com.nickghardwick.LinkGate"
        )

        XCTAssertEqual(
            service.status(),
            DefaultBrowserStatus(httpIsDefault: true, httpsIsDefault: true)
        )
    }

    func testStatusTreatsMissingOrWrongResolvedApplicationAsNotDefault() {
        let linkGateURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let otherURL = URL(fileURLWithPath: "/Applications/Other.app")
        let workspace = DefaultBrowserWorkspaceFake(
            applicationsToOpen: ["http": otherURL],
            bundleIdentifiers: [otherURL: "com.example.other"]
        )
        let service = NSWorkspaceDefaultBrowserService(
            workspace: workspace,
            applicationURL: linkGateURL,
            bundleIdentifier: "com.example.LinkGate"
        )

        let status = service.status()

        XCTAssertEqual(workspace.lookupSchemes, ["http", "https"])
        XCTAssertEqual(status, DefaultBrowserStatus(httpIsDefault: false, httpsIsDefault: false))
    }

    // Task 3 acceptance 2: diagnostics preserve the existing exact-path ownership rule while
    // independently identifying an installed LinkGate copy that has the same bundle identifier.
    func testDiagnosticStatusReportsExactAndWrongCopyIndependentlyForEachScheme() {
        let linkGateURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let developmentCopyURL = URL(fileURLWithPath: "/Users/alice/Library/Developer/Xcode/DerivedData/LinkGate/Build/LinkGate.app")
        let workspace = DefaultBrowserWorkspaceFake(
            applicationsToOpen: ["http": linkGateURL, "https": developmentCopyURL],
            bundleIdentifiers: [
                linkGateURL: "com.example.LinkGate",
                developmentCopyURL: "com.example.LinkGate",
            ]
        )
        let service = NSWorkspaceDefaultBrowserService(
            workspace: workspace,
            applicationURL: linkGateURL,
            bundleIdentifier: "com.example.LinkGate"
        )

        let diagnosticStatus = service.diagnosticStatus()

        XCTAssertEqual(
            diagnosticStatus,
            DefaultBrowserDiagnosticStatus(
                http: .exactCurrentApplication,
                https: .sameBundleIdentifierAtDifferentLocation(.developmentCopy)
            )
        )
        XCTAssertEqual(
            service.status(),
            DefaultBrowserStatus(httpIsDefault: true, httpsIsDefault: false),
            "The diagnostic boundary must not relax exact-path default-handler behavior."
        )
    }

    // Task 3 acceptance 2: another application is identifiable only by bundle ID, and either a
    // missing resolved application or a missing bundle ID remains unresolved.
    func testDiagnosticStatusReportsOtherApplicationAndUnresolvedHandlerWithoutPaths() {
        let linkGateURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let otherURL = URL(fileURLWithPath: "/Volumes/private/Other Browser.app")
        let workspace = DefaultBrowserWorkspaceFake(
            applicationsToOpen: ["http": otherURL],
            bundleIdentifiers: [otherURL: "org.example.other-browser"]
        )
        let service = NSWorkspaceDefaultBrowserService(
            workspace: workspace,
            applicationURL: linkGateURL,
            bundleIdentifier: "com.example.LinkGate"
        )

        XCTAssertEqual(
            service.diagnosticStatus(),
            DefaultBrowserDiagnosticStatus(
                http: .otherApplication(bundleIdentifier: "org.example.other-browser"),
                https: .unresolved
            )
        )

        let unidentifiedOtherURL = URL(fileURLWithPath: "/Volumes/private/Unidentified Browser.app")
        workspace.applicationsToOpen = ["http": otherURL, "https": unidentifiedOtherURL]
        workspace.bundleIdentifiers = [otherURL: "org.example.other-browser"]

        XCTAssertEqual(
            service.diagnosticStatus(),
            DefaultBrowserDiagnosticStatus(http: .otherApplication(bundleIdentifier: "org.example.other-browser"), https: .unresolved),
            "A noncurrent resolved handler without a bundle identifier is not another application's identity."
        )
    }

    // Task 3 acceptance 2: a service without LinkGate's own bundle identifier cannot establish
    // ownership, even when Launch Services resolves the current bundle path.
    func testDiagnosticStatusIsUnresolvedWhenCurrentBundleIdentifierIsMissing() {
        let linkGateURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let workspace = DefaultBrowserWorkspaceFake(
            applicationsToOpen: ["http": linkGateURL, "https": linkGateURL],
            bundleIdentifiers: [linkGateURL: "com.example.LinkGate"]
        )
        let service = NSWorkspaceDefaultBrowserService(
            workspace: workspace,
            applicationURL: linkGateURL,
            bundleIdentifier: nil
        )

        XCTAssertEqual(
            service.diagnosticStatus(),
            DefaultBrowserDiagnosticStatus(http: .unresolved, https: .unresolved)
        )
    }

    func testRequestSetsHTTPThenHTTPSAndCompletesAfterBothSucceed() {
        let linkGateURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let workspace = DefaultBrowserWorkspaceFake()
        let service = NSWorkspaceDefaultBrowserService(
            workspace: workspace,
            applicationURL: linkGateURL,
            bundleIdentifier: "com.example.LinkGate"
        )
        var result: Result<Void, Error>?

        service.requestDefault { result = $0 }

        XCTAssertEqual(workspace.setDefaultCalls.map(\.scheme), ["http"])
        XCTAssertEqual(workspace.setDefaultCalls.map(\.applicationURL), [linkGateURL])
        XCTAssertNil(result)

        workspace.completeSetDefault(forScheme: "http", error: nil)

        XCTAssertEqual(workspace.setDefaultCalls.map(\.scheme), ["http", "https"])
        XCTAssertEqual(workspace.setDefaultCalls.map(\.applicationURL), [linkGateURL, linkGateURL])
        XCTAssertNil(result)

        workspace.completeSetDefault(forScheme: "https", error: nil)

        switch result {
        case .success:
            break
        default:
            XCTFail("Expected success after both scheme requests succeed, got \(String(describing: result)).")
        }
    }

    func testRequestStopsAfterHTTPFailureAndForwardsOneFailure() {
        let linkGateURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let workspace = DefaultBrowserWorkspaceFake()
        let service = NSWorkspaceDefaultBrowserService(
            workspace: workspace,
            applicationURL: linkGateURL,
            bundleIdentifier: "com.example.LinkGate"
        )
        var result: Result<Void, Error>?
        let expectedError = NSError(domain: "LinkGateTests", code: 7)

        service.requestDefault { result = $0 }
        workspace.completeSetDefault(forScheme: "http", error: expectedError)

        XCTAssertEqual(workspace.setDefaultCalls.map(\.scheme), ["http"])
        switch result {
        case let .failure(error):
            XCTAssertEqual(error as NSError, expectedError)
        default:
            XCTFail("Expected HTTP failure, got \(String(describing: result)).")
        }
    }

    func testRequestStopsAfterHTTPSFailureAndDoesNotReportSuccess() {
        let linkGateURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let workspace = DefaultBrowserWorkspaceFake()
        let service = NSWorkspaceDefaultBrowserService(
            workspace: workspace,
            applicationURL: linkGateURL,
            bundleIdentifier: "com.example.LinkGate"
        )
        var result: Result<Void, Error>?
        let expectedError = NSError(domain: "LinkGateTests", code: 8)

        service.requestDefault { result = $0 }
        workspace.completeSetDefault(forScheme: "http", error: nil)
        workspace.completeSetDefault(forScheme: "https", error: expectedError)

        XCTAssertEqual(workspace.setDefaultCalls.map(\.scheme), ["http", "https"])
        switch result {
        case let .failure(error):
            XCTAssertEqual(error as NSError, expectedError)
        default:
            XCTFail("Expected HTTPS failure, got \(String(describing: result)).")
        }
    }

    func testHTTPRequestCompletingWithBothSchemesOwnedCompletesWithoutRedundantHTTPSRequest() {
        let linkGateURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let otherURL = URL(fileURLWithPath: "/Applications/Other.app")
        let workspace = DefaultBrowserWorkspaceFake(
            applicationsToOpen: ["http": otherURL, "https": otherURL],
            bundleIdentifiers: [otherURL: "com.example.other"]
        )
        let service = NSWorkspaceDefaultBrowserService(
            workspace: workspace,
            applicationURL: linkGateURL,
            bundleIdentifier: "com.example.LinkGate"
        )
        var result: Result<Void, Error>?

        service.requestDefault { result = $0 }
        XCTAssertEqual(workspace.setDefaultCalls.map(\.scheme), ["http"])

        workspace.applicationsToOpen = ["http": linkGateURL, "https": linkGateURL]
        workspace.bundleIdentifiers = [linkGateURL: "com.example.LinkGate"]
        workspace.completeSetDefault(forScheme: "http", error: nil)

        XCTAssertEqual(workspace.setDefaultCalls.map(\.scheme), ["http"])
        switch result {
        case .success:
            break
        default:
            XCTFail("Expected success when the HTTP request also makes HTTPS default, got \(String(describing: result)).")
        }
    }

    func testRequestSkipsAlreadyDefaultHTTPAndRequestsOnlyHTTPS() {
        let linkGateURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let otherURL = URL(fileURLWithPath: "/Applications/Other.app")
        let workspace = DefaultBrowserWorkspaceFake(
            applicationsToOpen: ["http": linkGateURL, "https": otherURL],
            bundleIdentifiers: [
                linkGateURL: "com.example.LinkGate",
                otherURL: "com.example.other",
            ]
        )
        let service = NSWorkspaceDefaultBrowserService(
            workspace: workspace,
            applicationURL: linkGateURL,
            bundleIdentifier: "com.example.LinkGate"
        )
        var result: Result<Void, Error>?

        service.requestDefault { result = $0 }

        XCTAssertEqual(workspace.setDefaultCalls.map(\.scheme), ["https"])
        workspace.completeSetDefault(forScheme: "https", error: nil)

        switch result {
        case .success:
            break
        default:
            XCTFail("Expected success after requesting the only non-default scheme, got \(String(describing: result)).")
        }
    }

    func testRequestDoesNotSkipSameBundleIdentifierAtAnotherPath() {
        let linkGateURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let fixtureURL = URL(fileURLWithPath: "/repo/fixtures/LinkGate.app")
        let workspace = DefaultBrowserWorkspaceFake(
            applicationsToOpen: ["http": fixtureURL, "https": fixtureURL],
            bundleIdentifiers: [fixtureURL: "com.nickghardwick.LinkGate"]
        )
        let service = NSWorkspaceDefaultBrowserService(
            workspace: workspace,
            applicationURL: linkGateURL,
            bundleIdentifier: "com.nickghardwick.LinkGate"
        )

        service.requestDefault { _ in }

        XCTAssertEqual(workspace.setDefaultCalls.map(\.scheme), ["http"])
        XCTAssertEqual(workspace.setDefaultCalls.map(\.applicationURL), [linkGateURL])

        workspace.applicationsToOpen["http"] = linkGateURL
        workspace.completeSetDefault(forScheme: "http", error: nil)

        XCTAssertEqual(workspace.setDefaultCalls.map(\.scheme), ["http", "https"])
        XCTAssertEqual(workspace.setDefaultCalls.map(\.applicationURL), [linkGateURL, linkGateURL])
    }

    func testRequestCompletesImmediatelyWhenBothSchemesAlreadyUseLinkGate() {
        let linkGateURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
        let workspace = DefaultBrowserWorkspaceFake(
            applicationsToOpen: ["http": linkGateURL, "https": linkGateURL],
            bundleIdentifiers: [linkGateURL: "com.example.LinkGate"]
        )
        let service = NSWorkspaceDefaultBrowserService(
            workspace: workspace,
            applicationURL: linkGateURL,
            bundleIdentifier: "com.example.LinkGate"
        )
        var result: Result<Void, Error>?

        service.requestDefault { result = $0 }

        XCTAssertTrue(workspace.setDefaultCalls.isEmpty)
        switch result {
        case .success:
            break
        default:
            XCTFail("Expected immediate success when LinkGate already handles both schemes, got \(String(describing: result)).")
        }
    }
}

@MainActor
private final class DefaultBrowserWorkspaceFake: DefaultBrowserWorkspace {
    struct SetDefaultCall {
        let applicationURL: URL
        let scheme: String
    }

    var applicationsToOpen: [String: URL]
    var bundleIdentifiers: [URL: String]
    private(set) var lookupSchemes: [String] = []
    private(set) var setDefaultCalls: [SetDefaultCall] = []
    private var completions: [String: (Error?) -> Void] = [:]

    init(
        applicationsToOpen: [String: URL] = [:],
        bundleIdentifiers: [URL: String] = [:]
    ) {
        self.applicationsToOpen = applicationsToOpen
        self.bundleIdentifiers = bundleIdentifiers
    }

    func applicationURL(toOpen url: URL) -> URL? {
        let scheme = url.scheme ?? ""
        lookupSchemes.append(scheme)
        return applicationsToOpen[scheme]
    }

    func bundleIdentifier(at url: URL) -> String? {
        bundleIdentifiers[url]
    }

    func setDefaultApplication(
        at url: URL,
        forScheme scheme: String,
        completion: @escaping (Error?) -> Void
    ) {
        setDefaultCalls.append(SetDefaultCall(applicationURL: url, scheme: scheme))
        completions[scheme] = completion
    }

    func completeSetDefault(forScheme scheme: String, error: Error?) {
        let completion = completions.removeValue(forKey: scheme)
        completion?(error)
    }
}
