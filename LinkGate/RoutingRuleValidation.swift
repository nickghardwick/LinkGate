import Foundation

enum RoutingRuleValidationError: LocalizedError {
    case invalidDomain
    case invalidURLPrefix
    case emptyBrowserBundleIdentifier
    case duplicateRule
    case ruleNotFound

    var errorDescription: String? {
        switch self {
        case .invalidDomain:
            "Enter a valid domain name."
        case .invalidURLPrefix:
            "Enter an absolute HTTP or HTTPS URL without a fragment."
        case .emptyBrowserBundleIdentifier:
            "Choose a browser."
        case .duplicateRule:
            "A rule with this type and pattern already exists."
        case .ruleNotFound:
            "The routing rule no longer exists."
        }
    }
}

struct RoutingRuleValidator {
    func makeRule(
        id: UUID = UUID(),
        matchType: RoutingRule.MatchType,
        pattern: String,
        browserBundleIdentifier: String,
        existingRules: [RoutingRule],
        excludingRuleID: UUID? = nil
    ) throws -> RoutingRule {
        let canonicalPattern: String
        switch matchType {
        case .exactDomain, .domainFamily:
            canonicalPattern = try canonicalDomain(pattern)
        case .urlPrefix:
            canonicalPattern = try canonicalURLPrefix(pattern)
        }

        let canonicalBundleIdentifier = browserBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonicalBundleIdentifier.isEmpty else {
            throw RoutingRuleValidationError.emptyBrowserBundleIdentifier
        }
        guard !existingRules.contains(where: {
            $0.id != excludingRuleID && $0.matchType == matchType && $0.pattern == canonicalPattern
        }) else {
            throw RoutingRuleValidationError.duplicateRule
        }

        return RoutingRule(
            id: id,
            matchType: matchType,
            pattern: canonicalPattern,
            browserBundleIdentifier: canonicalBundleIdentifier
        )
    }

    func canonicalDomain(_ input: String) throws -> String {
        let domain = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let canonical = domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !canonical.isEmpty,
              !domain.hasPrefix("."),
              !domain.contains(":") && !domain.contains("/") && !domain.contains("?") && !domain.contains("#") && !domain.contains("*"),
              canonical.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                      && label.unicodeScalars.allSatisfy {
                          CharacterSet.alphanumerics.contains($0) || $0 == "-"
                      }
              })
        else {
            throw RoutingRuleValidationError.invalidDomain
        }
        return canonical
    }

    func canonicalURLPrefix(_ input: String) throws -> String {
        guard let url = URL(string: input),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty,
              url.fragment == nil
        else {
            throw RoutingRuleValidationError.invalidURLPrefix
        }
        return normalizedURLString(url, scheme: scheme, host: normalizedHost(host))
    }
}

func normalizedHost(_ host: String) -> String {
    var normalized = host.lowercased()
    while normalized.last == "." {
        normalized.removeLast()
    }
    return normalized
}

func normalizedURLString(_ url: URL) -> String {
    guard let scheme = url.scheme?.lowercased(), let host = url.host else {
        return url.absoluteString
    }
    return normalizedURLString(url, scheme: scheme, host: normalizedHost(host))
}

private func normalizedURLString(_ url: URL, scheme: String, host: String) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return url.absoluteString
    }
    components.scheme = scheme
    components.host = host
    components.fragment = nil
    return components.string ?? url.absoluteString
}
