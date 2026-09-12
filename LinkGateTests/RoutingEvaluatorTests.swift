import XCTest
@testable import LinkGate

// Acceptance Contract mapping:
// 2: exact-domain matching is case-insensitive/trailing-dot equivalent, but not a suffix match.
// 3: domain-family matching includes root and dot-delimited subdomains only.
// 4: prefix matching strips incoming fragments and preserves literal path/query/encoding/port/slash details.
// 5: matching rules use fixed URL-prefix, exact-domain, domain-family precedence; within each
//    match type the most-specific matching canonical pattern wins rather than persisted order.
final class RoutingEvaluatorTests: XCTestCase {
    func testExactDomainMatchesNormalizedRootButNotSubdomainOrFalseSuffix() {
        let rule = makeRule(matchType: .exactDomain, pattern: "example.com")
        let evaluator = RoutingEvaluator()

        XCTAssertEqual(evaluator.matchingRule(for: URL(string: "https://EXAMPLE.COM./path")!, rules: [rule])?.id, rule.id)
        XCTAssertNil(evaluator.matchingRule(for: URL(string: "https://www.example.com/path")!, rules: [rule]))
        XCTAssertNil(evaluator.matchingRule(for: URL(string: "https://notexample.com/path")!, rules: [rule]))
    }

    func testDomainFamilyMatchesRootAndDelimitedSubdomainButNotFalseSuffix() {
        let rule = makeRule(matchType: .domainFamily, pattern: "example.com")
        let evaluator = RoutingEvaluator()

        XCTAssertEqual(evaluator.matchingRule(for: URL(string: "https://example.com/path")!, rules: [rule])?.id, rule.id)
        XCTAssertEqual(evaluator.matchingRule(for: URL(string: "https://deep.www.example.com/path")!, rules: [rule])?.id, rule.id)
        XCTAssertNil(evaluator.matchingRule(for: URL(string: "https://notexample.com/path")!, rules: [rule]))
        XCTAssertNil(evaluator.matchingRule(for: URL(string: "https://example.com.evil/path")!, rules: [rule]))
    }

    func testPrefixMatchingNormalizesOnlyAuthorityAndIgnoresIncomingFragment() {
        let rule = makeRule(
            matchType: .urlPrefix,
            pattern: "https://example.com:8443/A%2Fb//path?first=one%20two&second=%2Fvalue"
        )
        let evaluator = RoutingEvaluator()

        XCTAssertEqual(
            evaluator.matchingRule(
                for: URL(string: "HTTPS://EXAMPLE.COM.:8443/A%2Fb//path?first=one%20two&second=%2Fvalue#section")!,
                rules: [rule]
            )?.id,
            rule.id
        )
        XCTAssertNil(
            evaluator.matchingRule(
                for: URL(string: "https://example.com:8443/A/b//path?first=one%20two&second=%2Fvalue")!,
                rules: [rule]
            )
        )
        XCTAssertNil(
            evaluator.matchingRule(
                for: URL(string: "https://example.com:8443/A%2Fb/path?first=one%20two&second=%2Fvalue")!,
                rules: [rule]
            )
        )
        XCTAssertNil(
            evaluator.matchingRule(
                for: URL(string: "https://example.com:443/A%2Fb//path?first=one%20two&second=%2Fvalue")!,
                rules: [rule]
            )
        )
        XCTAssertNil(
            evaluator.matchingRule(
                for: URL(string: "https://example.com:8443/A%2Fb//path?second=%2Fvalue&first=one%20two")!,
                rules: [rule]
            )
        )
    }

    func testPrefixWinsOverExactAndFamilyRegardlessOfPersistedOrder() {
        let family = makeRule(matchType: .domainFamily, pattern: "example.com", target: "com.example.family")
        let exact = makeRule(matchType: .exactDomain, pattern: "shop.example.com", target: "com.example.exact")
        let prefix = makeRule(matchType: .urlPrefix, pattern: "https://shop.example.com/promo", target: "com.example.prefix")
        let evaluator = RoutingEvaluator()

        let matched = evaluator.matchingRule(
            for: URL(string: "https://shop.example.com/promo/today?source=mail")!,
            rules: [family, exact, prefix]
        )

        XCTAssertEqual(matched?.id, prefix.id)
    }

    func testExactWinsOverFamilyWhenNoPrefixMatchesAndNoRuleReturnsNil() {
        let family = makeRule(matchType: .domainFamily, pattern: "example.com", target: "com.example.family")
        let exact = makeRule(matchType: .exactDomain, pattern: "shop.example.com", target: "com.example.exact")
        let prefix = makeRule(matchType: .urlPrefix, pattern: "https://shop.example.com/promo", target: "com.example.prefix")
        let evaluator = RoutingEvaluator()

        XCTAssertEqual(
            evaluator.matchingRule(for: URL(string: "https://shop.example.com/other")!, rules: [family, exact, prefix])?.id,
            exact.id
        )
        XCTAssertNil(evaluator.matchingRule(for: URL(string: "https://unrelated.example/other")!, rules: [family, exact, prefix]))
    }

    func testLongestMatchingPrefixWinsRegardlessOfPersistedOrder() {
        let shorter = makeRule(matchType: .urlPrefix, pattern: "https://example.com/store", target: "com.example.short")
        let longer = makeRule(matchType: .urlPrefix, pattern: "https://example.com/store/special", target: "com.example.long")
        let evaluator = RoutingEvaluator()

        let matched = evaluator.matchingRule(
            for: URL(string: "https://example.com/store/special/today")!,
            rules: [shorter, longer]
        )

        XCTAssertEqual(matched?.id, longer.id)
    }

    func testMostSpecificMatchingDomainFamilyWinsRegardlessOfPersistedOrder() {
        let broader = makeRule(matchType: .domainFamily, pattern: "example.com", target: "com.example.broader")
        let narrower = makeRule(matchType: .domainFamily, pattern: "shop.example.com", target: "com.example.narrower")
        let evaluator = RoutingEvaluator()

        let matched = evaluator.matchingRule(
            for: URL(string: "https://deals.shop.example.com/today")!,
            rules: [broader, narrower]
        )

        XCTAssertEqual(matched?.id, narrower.id)
    }

    func testLeadingDotIncomingHostDoesNotMatchExactDomainRule() {
        let rule = makeRule(matchType: .exactDomain, pattern: "example.com")
        let evaluator = RoutingEvaluator()

        XCTAssertNil(evaluator.matchingRule(for: URL(string: "https://.example.com/path")!, rules: [rule]))
    }

    private func makeRule(
        matchType: RoutingRule.MatchType,
        pattern: String,
        target: String = "com.example.browser"
    ) -> RoutingRule {
        RoutingRule(id: UUID(), matchType: matchType, pattern: pattern, browserBundleIdentifier: target)
    }
}
