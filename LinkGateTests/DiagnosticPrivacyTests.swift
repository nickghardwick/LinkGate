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

    func testSanitizedLocationPathReplacesUserHomeWithTildeAndPreservesSystemApplicationsPath() {
        let developmentCopy = URL(fileURLWithPath: "/Users/alice/Library/Developer/Xcode/DerivedData/LinkGate-abc123/Build/Products/Debug/LinkGate.app")
        let installedApplication = URL(fileURLWithPath: "/Applications/LinkGate.app")

        let sanitizedDevelopmentPath = DiagnosticLocation.sanitizedPath(for: developmentCopy)
        let sanitizedInstalledPath = DiagnosticLocation.sanitizedPath(for: installedApplication)

        XCTAssertEqual(
            sanitizedDevelopmentPath,
            "~/Library/Developer/Xcode/DerivedData/LinkGate-abc123/Build/Products/Debug/LinkGate.app"
        )
        assertDoesNotContain(sanitizedDevelopmentPath, anyOf: ["alice", "/Users/alice"])
        XCTAssertEqual(sanitizedInstalledPath, "/Applications/LinkGate.app")
    }

    func testBrowserOpenErrorsUseOnlyTheClosedBrowserOpenFailureCategory() {
        let fixtures: [(error: Error, secrets: [String])] = [
            (
                NSError(
                    domain: "com.example.browser.private-domain-token-193",
                    code: 41,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Could not open https://private.example/documents/DOC-BROWSER-771?access_token=browser-token-41 for alice@example.com.",
                        "privatePath": "/Users/alice/Library/Application Support/Browser/session-41",
                    ]
                ),
                [
                    "private-domain-token-193",
                    "private.example",
                    "DOC-BROWSER-771",
                    "browser-token-41",
                    "alice@example.com",
                    "/Users/alice",
                    "session-41",
                ]
            ),
            (
                UnsafeLocalizedDescriptionError(
                    localizedSecret: "browser-localized-token-66",
                    describedSecret: "browser-described-token-67"
                ),
                ["browser-localized-token-66", "browser-described-token-67"]
            ),
        ]

        for fixture in fixtures {
            let category = DiagnosticError.category(for: fixture.error, operation: .browserOpen)

            XCTAssertEqual(category, "browser-open-failed")
            assertDoesNotContain(category, anyOf: fixture.secrets)
        }
    }

    func testDefaultHandlerErrorsUseOnlyTheClosedDefaultHandlerFailureCategory() {
        let fixtures: [(error: Error, secrets: [String])] = [
            (
                NSError(
                    domain: "com.example.default-handler.private-domain-token-284",
                    code: 52,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Could not set default handler for https://private.example/documents/DOC-DEFAULT-882?access_token=default-token-52 for alice@example.com.",
                        "privatePath": "/Users/alice/Library/Application Support/LinkGate/request-52",
                    ]
                ),
                [
                    "private-domain-token-284",
                    "private.example",
                    "DOC-DEFAULT-882",
                    "default-token-52",
                    "alice@example.com",
                    "/Users/alice",
                    "request-52",
                ]
            ),
            (
                UnsafeLocalizedDescriptionError(
                    localizedSecret: "default-localized-token-76",
                    describedSecret: "default-described-token-77"
                ),
                ["default-localized-token-76", "default-described-token-77"]
            ),
        ]

        for fixture in fixtures {
            let category = DiagnosticError.category(for: fixture.error, operation: .defaultHandler)

            XCTAssertEqual(category, "default-handler-failed")
            assertDoesNotContain(category, anyOf: fixture.secrets)
        }
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

private struct UnsafeLocalizedDescriptionError: LocalizedError, CustomStringConvertible {
    let localizedSecret: String
    let describedSecret: String

    var errorDescription: String? {
        "Unsafe LocalizedError description containing \(localizedSecret)."
    }

    var description: String {
        "Unsafe CustomStringConvertible description containing \(describedSecret)."
    }
}
