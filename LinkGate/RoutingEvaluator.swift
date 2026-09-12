import Foundation

struct RoutingEvaluator {
    func matchingRule(for url: URL, rules: [RoutingRule]) -> RoutingRule? {
        let host = url.host.map(normalizedHost)
        let normalizedURL = normalizedURLString(url)

        if let prefix = rules
            .filter({ $0.matchType == .urlPrefix && normalizedURL.hasPrefix($0.pattern) })
            .max(by: { $0.pattern.count < $1.pattern.count }) {
            return prefix
        }
        if let exact = rules.first(where: { $0.matchType == .exactDomain && host == $0.pattern }) {
            return exact
        }
        return rules
            .filter {
                guard $0.matchType == .domainFamily, let host else { return false }
                return host == $0.pattern || host.hasSuffix("." + $0.pattern)
            }
            .max(by: { $0.pattern.count < $1.pattern.count })
    }
}
