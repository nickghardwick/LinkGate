import Foundation

struct RoutingRule: Codable, Equatable, Identifiable {
    enum MatchType: String, Codable, CaseIterable {
        case exactDomain
        case domainFamily
        case urlPrefix
    }

    let id: UUID
    let matchType: MatchType
    let pattern: String
    let browserBundleIdentifier: String
}
