import XCTest
@testable import LinkGate

// Acceptance Contract mapping:
// 2: canonical exact-domain rules compare normalized hosts only. Rejects an implementation
//    that accepts a subdomain, raw suffix, scheme, port, or path as an exact-domain rule.
// 3: canonical domain-family rules use dot-delimited host boundaries. Rejects raw-suffix matching.
// 4: canonical prefix rules normalize only scheme/host/trailing-dot and exclude configured fragments.
// 6: malformed domains/prefixes and empty bundle identities fail validation.
// 8: surrounding bundle-identifier whitespace canonicalizes before a rule is stored.
// 7: validation identifies rules by match type plus canonical pattern and supports self-exclusion on edit.
final class RoutingRuleValidationTests: XCTestCase {
    func testCanonicalizesDomainInputAndPreservesNonEmptyBundleIdentifier() throws {
        let validator = RoutingRuleValidator()

        let rule = try validator.makeRule(
            matchType: .exactDomain,
            pattern: "  ExAmPle.COM.  ",
            browserBundleIdentifier: "com.example.browser",
            existingRules: []
        )

        XCTAssertEqual(rule.matchType, .exactDomain)
        XCTAssertEqual(rule.pattern, "example.com")
        XCTAssertEqual(rule.browserBundleIdentifier, "com.example.browser")
    }

    func testCanonicalizesSurroundingWhitespaceInBrowserBundleIdentifier() throws {
        let validator = RoutingRuleValidator()

        let rule = try validator.makeRule(
            matchType: .exactDomain,
            pattern: "example.com",
            browserBundleIdentifier: "  com.example.browser  ",
            existingRules: []
        )

        XCTAssertEqual(rule.browserBundleIdentifier, "com.example.browser")
    }

    func testRejectsDomainFormsThatAreNotHostnames() {
        let validator = RoutingRuleValidator()
        let invalidPatterns = [
            "",
            ".example.com",
            "*.example.com",
            "https://example.com",
            "example.com:8443",
            "example.com/path",
            "example..com",
            "-example.com",
            "example-.com",
            "example.com?query=value",
            "example.com#fragment",
        ]

        for pattern in invalidPatterns {
            XCTAssertThrowsError(
                try validator.makeRule(
                    matchType: .domainFamily,
                    pattern: pattern,
                    browserBundleIdentifier: "com.example.browser",
                    existingRules: []
                ),
                "Expected \(pattern.debugDescription) to be rejected as a domain rule."
            )
        }
    }

    func testCanonicalizesOnlyPermittedURLPrefixComponents() throws {
        let validator = RoutingRuleValidator()

        let rule = try validator.makeRule(
            matchType: .urlPrefix,
            pattern: "HTTPS://ExAmPlE.Com.:8443/A%2Fb//path?first=one%20two&second=%2Fvalue",
            browserBundleIdentifier: "com.example.browser",
            existingRules: []
        )

        XCTAssertEqual(
            rule.pattern,
            "https://example.com:8443/A%2Fb//path?first=one%20two&second=%2Fvalue"
        )
    }

    func testRejectsMalformedOrFragmentedPrefixAndEmptyBundleIdentifier() {
        let validator = RoutingRuleValidator()
        let invalidPrefixes = [
            "example.com/path",
            "ftp://example.com/path",
            "https:///path",
            "https://example.com/path#configured-fragment",
        ]

        for pattern in invalidPrefixes {
            XCTAssertThrowsError(
                try validator.makeRule(
                    matchType: .urlPrefix,
                    pattern: pattern,
                    browserBundleIdentifier: "com.example.browser",
                    existingRules: []
                ),
                "Expected \(pattern.debugDescription) to be rejected as a prefix rule."
            )
        }

        XCTAssertThrowsError(
            try validator.makeRule(
                matchType: .exactDomain,
                pattern: "example.com",
                browserBundleIdentifier: "   ",
                existingRules: []
            )
        )
    }

    func testRejectsDuplicateCanonicalIdentityRegardlessOfTargetBrowser() throws {
        let validator = RoutingRuleValidator()
        let existing = try validator.makeRule(
            matchType: .exactDomain,
            pattern: "example.com",
            browserBundleIdentifier: "com.example.first",
            existingRules: []
        )

        XCTAssertThrowsError(
            try validator.makeRule(
                matchType: .exactDomain,
                pattern: "EXAMPLE.COM.",
                browserBundleIdentifier: "com.example.second",
                existingRules: [existing]
            )
        )
    }

    func testRejectsDuplicateCanonicalDomainFamilyIdentityRegardlessOfTargetBrowser() throws {
        let validator = RoutingRuleValidator()
        let existing = try validator.makeRule(
            matchType: .domainFamily,
            pattern: "example.com",
            browserBundleIdentifier: "com.example.first",
            existingRules: []
        )

        XCTAssertThrowsError(
            try validator.makeRule(
                matchType: .domainFamily,
                pattern: "EXAMPLE.COM.",
                browserBundleIdentifier: "com.example.second",
                existingRules: [existing]
            )
        )
    }

    func testRejectsDuplicateCanonicalURLPrefixIdentityRegardlessOfTargetBrowser() throws {
        let validator = RoutingRuleValidator()
        let existing = try validator.makeRule(
            matchType: .urlPrefix,
            pattern: "https://example.com:8443/A%2Fb//path?encoded=%2Fvalue",
            browserBundleIdentifier: "com.example.first",
            existingRules: []
        )

        XCTAssertThrowsError(
            try validator.makeRule(
                matchType: .urlPrefix,
                pattern: "HTTPS://EXAMPLE.COM.:8443/A%2Fb//path?encoded=%2Fvalue",
                browserBundleIdentifier: "com.example.second",
                existingRules: [existing]
            )
        )
    }

    func testEditingRuleExcludesItsOwnStableIDButRejectsAnotherRulesIdentity() throws {
        let validator = RoutingRuleValidator()
        let editable = try validator.makeRule(
            matchType: .exactDomain,
            pattern: "example.com",
            browserBundleIdentifier: "com.example.first",
            existingRules: []
        )
        let other = try validator.makeRule(
            matchType: .domainFamily,
            pattern: "other.example",
            browserBundleIdentifier: "com.example.second",
            existingRules: [editable]
        )

        let selfEdit = try validator.makeRule(
            id: editable.id,
            matchType: .exactDomain,
            pattern: "EXAMPLE.COM.",
            browserBundleIdentifier: "com.example.changed",
            existingRules: [editable, other],
            excludingRuleID: editable.id
        )
        XCTAssertEqual(selfEdit.pattern, "example.com")
        XCTAssertEqual(selfEdit.browserBundleIdentifier, "com.example.changed")

        XCTAssertThrowsError(
            try validator.makeRule(
                id: editable.id,
                matchType: .domainFamily,
                pattern: "OTHER.EXAMPLE.",
                browserBundleIdentifier: "com.example.changed",
                existingRules: [editable, other],
                excludingRuleID: editable.id
            )
        )
    }
}
