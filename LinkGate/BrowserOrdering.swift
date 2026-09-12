import Foundation

protocol BrowserOrderStoring: AnyObject {
    var browserOrder: [String]? { get }
    var browserOrderPathHints: [String: String] { get }
    var disabledBrowserIdentifiers: Set<String> { get }

    func saveBrowserOrder(_ identifiers: [String]) throws
    func saveBrowserOrder(_ identifiers: [String], pathHints: [String: String]) throws
    func saveDisabledBrowserIdentifiers(_ identifiers: Set<String>) throws
}

extension BrowserOrderStoring {
    var browserOrder: [String]? { nil }
    var browserOrderPathHints: [String: String] { [:] }
    var disabledBrowserIdentifiers: Set<String> { [] }

    func saveBrowserOrder(_ identifiers: [String]) throws {
        throw RoutingRuleStorageError.readOnlyStorage
    }

    func saveBrowserOrder(_ identifiers: [String], pathHints: [String: String]) throws {
        try saveBrowserOrder(identifiers)
    }

    func saveDisabledBrowserIdentifiers(_ identifiers: Set<String>) throws {
        throw RoutingRuleStorageError.readOnlyStorage
    }
}

enum BrowserOrdering {
    static func identifiers(
        for candidates: [ApplicationCandidate],
        savedOrder: [String]? = nil,
        pathHints: [String: String] = [:]
    ) -> [String] {
        let bundleIdentifierCounts = candidates.reduce(into: [String: Int]()) { counts, candidate in
            guard let bundleIdentifier = candidate.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundleIdentifier.isEmpty
            else {
                return
            }
            counts[bundleIdentifier, default: 0] += 1
        }

        var firstCandidateBoundToLegacyBundle = Set<String>()
        return candidates.map { candidate in
            let normalizedPath = normalizedApplicationURL(candidate.applicationURL).path
            let pathIdentifier = "path:\(normalizedPath)"
            guard let bundleIdentifier = candidate.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundleIdentifier.isEmpty
            else {
                return pathIdentifier
            }
            let bundleIdentifierKey = "bundle:\(bundleIdentifier)"
            if let hintedPath = pathHints[bundleIdentifierKey] {
                return hintedPath == normalizedPath ? bundleIdentifierKey : pathIdentifier
            }
            if savedOrder?.contains(pathIdentifier) == true {
                return pathIdentifier
            }
            if bundleIdentifierCounts[bundleIdentifier] == 1 {
                return bundleIdentifierKey
            }
            if pathHints[bundleIdentifierKey] == nil,
               savedOrder?.contains(bundleIdentifierKey) == true,
               !firstCandidateBoundToLegacyBundle.contains(bundleIdentifierKey) {
                firstCandidateBoundToLegacyBundle.insert(bundleIdentifierKey)
                return bundleIdentifierKey
            }
            return pathIdentifier
        }
    }

    static func orderedCandidates(
        _ candidates: [ApplicationCandidate],
        savedOrder: [String]?,
        pathHints: [String: String] = [:]
    ) -> [ApplicationCandidate] {
        guard let savedOrder else { return candidates }

        let positions = Dictionary(uniqueKeysWithValues: savedOrder.enumerated().map { ($0.element, $0.offset) })
        let identifiers = identifiers(for: candidates, savedOrder: savedOrder, pathHints: pathHints)
        return zip(candidates, identifiers)
            .enumerated()
            .sorted { left, right in
                let leftPosition = positions[left.element.1] ?? Int.max
                let rightPosition = positions[right.element.1] ?? Int.max
                if leftPosition != rightPosition {
                    return leftPosition < rightPosition
                }
                return left.offset < right.offset
            }
            .map { $0.element.0 }
    }

    static func visibleCandidates(
        _ candidates: [ApplicationCandidate],
        savedOrder: [String]?,
        pathHints: [String: String],
        disabledIdentifiers: Set<String>
    ) -> [ApplicationCandidate] {
        let identifiers = identifiers(for: candidates, savedOrder: savedOrder, pathHints: pathHints)
        return zip(candidates, identifiers).compactMap { candidate, identifier in
            disabledIdentifiers.contains(identifier) ? nil : candidate
        }
    }

    static func updatedPathHints(
        for candidates: [ApplicationCandidate],
        savedOrder: [String]?,
        existingHints: [String: String]
    ) -> [String: String] {
        let identifiers = identifiers(for: candidates, savedOrder: savedOrder, pathHints: existingHints)
        var hints = existingHints
        for (candidate, identifier) in zip(candidates, identifiers) where identifier.hasPrefix("bundle:") {
            hints[identifier] = normalizedApplicationURL(candidate.applicationURL).path
        }
        return hints
    }

    static func isValidIdentifier(_ identifier: String) -> Bool {
        if identifier.hasPrefix("bundle:") {
            let value = String(identifier.dropFirst("bundle:".count))
            return !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if identifier.hasPrefix("path:") {
            let value = String(identifier.dropFirst("path:".count))
            return value.hasPrefix("/") && value == normalizedApplicationURL(URL(fileURLWithPath: value)).path
        }
        return false
    }

    static func isValidOrder(_ identifiers: [String]) -> Bool {
        Set(identifiers).count == identifiers.count && identifiers.allSatisfy { isValidIdentifier($0) }
    }

    static func isValidPathHints(_ hints: [String: String]) -> Bool {
        hints.allSatisfy { key, value in
            key.hasPrefix("bundle:")
                && isValidIdentifier(key)
                && value.hasPrefix("/")
                && value == normalizedApplicationURL(URL(fileURLWithPath: value)).path
        }
    }
}
