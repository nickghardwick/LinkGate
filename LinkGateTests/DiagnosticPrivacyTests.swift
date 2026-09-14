import Foundation
import XCTest
@testable import LinkGate

// Acceptance Contract mapping:
// A1: Incoming HTTP/HTTPS URLs produce only a safe scheme, never URL content.
// A2: Application locations use useful, non-identifying classifications.
// A3: Browser-open and default-handler failures use closed safe categories.
// A4 is intentionally covered by source review: the test surface excludes OSLog internals.
final class DiagnosticPrivacyTests: XCTestCase {
    func testURLDiagnosticEmitsOnlyTheSchemeForSensitiveHTTPAndHTTPSURLs() {
        let fixtures: [(url: URL, expectedScheme: String, secrets: [String])] = [
            (
                URL(string: "http://alice%40example.com:password@private.example/documents/DOC-HTTP-714?access_token=http-token-9f3#fragment-http-44")!,
                "http",
                ["alice", "private.example", "password", "DOC-HTTP-714", "http-token-9f3", "fragment-http-44"]
            ),
            (
                URL(string: "https://alice%40example.com:password@private.example/documents/DOC-HTTPS-815?access_token=https-token-a62#fragment-https-55")!,
                "https",
                ["alice", "private.example", "password", "DOC-HTTPS-815", "https-token-a62", "fragment-https-55"]
            ),
        ]

        for fixture in fixtures {
            let diagnostic = DiagnosticURL.scheme(of: fixture.url)

            XCTAssertEqual(diagnostic, fixture.expectedScheme)
            assertDoesNotContain(diagnostic, anyOf: fixture.secrets)
        }
    }

    func testLocationDiagnosticClassifiesKnownLocationsWithoutLeakingUserPathDetails() {
        let fixtures: [(url: URL, expectedDescription: String, secrets: [String])] = [
            (
                URL(fileURLWithPath: "/Applications/LinkGate.app"),
                "Applications",
                []
            ),
            (
                URL(fileURLWithPath: "/Users/alice/Applications/LinkGate.app"),
                "User Applications",
                ["alice", "/Users/alice"]
            ),
            (
                URL(fileURLWithPath: "/Users/alice/Library/Developer/Xcode/DerivedData/LinkGate-abc123/Build/Products/Debug/LinkGate.app"),
                "Development copy",
                ["alice", "/Users/alice", "abc123"]
            ),
            (
                URL(fileURLWithPath: "/Volumes/PrivateDrive/Browser Builds/LinkGate.app"),
                "Other location",
                ["PrivateDrive", "Browser Builds", "/Volumes"]
            ),
        ]

        for fixture in fixtures {
            let diagnostic = DiagnosticLocation.description(for: fixture.url)

            XCTAssertEqual(diagnostic, fixture.expectedDescription)
            assertDoesNotContain(diagnostic, anyOf: fixture.secrets)
        }
    }

    func testBrowserOpenErrorsUseOnlyTheClosedBrowserOpenFailureCategory() {
        let error = NSError(
            domain: "com.example.browser.private-domain-token-193",
            code: 41,
            userInfo: [
                NSLocalizedDescriptionKey: "Could not open https://private.example/documents/DOC-BROWSER-771?access_token=browser-token-41 for alice@example.com.",
                "privatePath": "/Users/alice/Library/Application Support/Browser/session-41",
            ]
        )

        let category = DiagnosticError.category(for: error, operation: .browserOpen)

        XCTAssertEqual(category, "browser-open-failed")
        assertDoesNotContain(category, anyOf: [
            "private-domain-token-193",
            "private.example",
            "DOC-BROWSER-771",
            "browser-token-41",
            "alice@example.com",
            "/Users/alice",
            "session-41",
        ])
    }

    func testDefaultHandlerErrorsUseOnlyTheClosedDefaultHandlerFailureCategory() {
        let error = NSError(
            domain: "com.example.default-handler.private-domain-token-284",
            code: 52,
            userInfo: [
                NSLocalizedDescriptionKey: "Could not set default handler for https://private.example/documents/DOC-DEFAULT-882?access_token=default-token-52 for alice@example.com.",
                "privatePath": "/Users/alice/Library/Application Support/LinkGate/request-52",
            ]
        )

        let category = DiagnosticError.category(for: error, operation: .defaultHandler)

        XCTAssertEqual(category, "default-handler-failed")
        assertDoesNotContain(category, anyOf: [
            "private-domain-token-284",
            "private.example",
            "DOC-DEFAULT-882",
            "default-token-52",
            "alice@example.com",
            "/Users/alice",
            "request-52",
        ])
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
                "Diagnostic value must not contain \(forbiddenSubstring): \(value)",
                file: file,
                line: line
            )
        }
    }
}
