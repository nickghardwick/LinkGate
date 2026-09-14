import Foundation

@MainActor
final class DiagnosticsController {
    private let ruleStore: RoutingRuleStore
    private let browserDiscovery: BrowserDiscoveryService
    private let defaultBrowserStatus: () -> DefaultBrowserDiagnosticStatus
    private let updateDiagnosticState: () -> UpdateDiagnosticState
    private let applicationVersion: String
    private let applicationBuild: String
    private let macOSVersion: String
    private let applicationURL: URL

    init(
        ruleStore: RoutingRuleStore,
        browserDiscovery: BrowserDiscoveryService,
        defaultBrowserStatus: @escaping () -> DefaultBrowserDiagnosticStatus,
        updateDiagnosticState: @escaping () -> UpdateDiagnosticState,
        applicationVersion: String,
        applicationBuild: String,
        macOSVersion: String,
        applicationURL: URL
    ) {
        self.ruleStore = ruleStore
        self.browserDiscovery = browserDiscovery
        self.defaultBrowserStatus = defaultBrowserStatus
        self.updateDiagnosticState = updateDiagnosticState
        self.applicationVersion = applicationVersion
        self.applicationBuild = applicationBuild
        self.macOSVersion = macOSVersion
        self.applicationURL = applicationURL
    }

    func snapshot() -> DiagnosticsSnapshot {
        let candidates = browserDiscovery.candidates(for: URL(string: "https://example.com")!)
        let identifiers = BrowserOrdering.identifiers(
            for: candidates,
            savedOrder: ruleStore.browserOrder,
            pathHints: ruleStore.browserOrderPathHints
        )
        let disabledIdentifiers = ruleStore.disabledBrowserIdentifiers
        let disabledBrowserCount = identifiers.filter(disabledIdentifiers.contains).count
        let visibleCandidates = zip(candidates, identifiers).compactMap { candidate, identifier in
            disabledIdentifiers.contains(identifier) ? nil : candidate
        }
        let orderedCandidates = BrowserOrdering.orderedCandidates(
            visibleCandidates,
            savedOrder: ruleStore.browserOrder,
            pathHints: ruleStore.browserOrderPathHints
        )

        return DiagnosticsSnapshot(
            applicationVersion: applicationVersion,
            applicationBuild: applicationBuild,
            macOSVersion: macOSVersion,
            applicationLocation: DiagnosticLocation.classification(for: applicationURL),
            defaultBrowserStatus: defaultBrowserStatus(),
            enabledBrowsers: diagnosticBrowsers(from: orderedCandidates),
            disabledBrowserCount: disabledBrowserCount,
            ruleCount: ruleStore.rules.count,
            updateState: updateDiagnosticState()
        )
    }

    private func diagnosticBrowsers(from candidates: [ApplicationCandidate]) -> [DiagnosticsSnapshot.Browser] {
        let identifiedCandidates = candidates.compactMap { candidate -> (String, DiagnosticLocation.Classification)? in
            guard let bundleIdentifier = candidate.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundleIdentifier.isEmpty
            else {
                return nil
            }
            return (bundleIdentifier, DiagnosticLocation.classification(for: candidate.applicationURL))
        }
        let bundleIdentifierCounts = identifiedCandidates.reduce(into: [String: Int]()) { counts, candidate in
            counts[candidate.0, default: 0] += 1
        }
        let duplicateCounts = identifiedCandidates.reduce(into: [String: Int]()) { counts, candidate in
            counts["\(candidate.0)|\(candidate.1.rawValue)", default: 0] += 1
        }
        var encountered = [String: Int]()

        return identifiedCandidates.map { bundleIdentifier, location in
            let key = "\(bundleIdentifier)|\(location.rawValue)"
            let ordinal: Int?
            if duplicateCounts[key, default: 0] > 1 {
                encountered[key, default: 0] += 1
                ordinal = encountered[key]
            } else {
                ordinal = nil
            }
            return DiagnosticsSnapshot.Browser(
                bundleIdentifier: bundleIdentifier,
                location: bundleIdentifierCounts[bundleIdentifier, default: 0] > 1 ? location : nil,
                locationOrdinal: ordinal
            )
        }
    }
}
