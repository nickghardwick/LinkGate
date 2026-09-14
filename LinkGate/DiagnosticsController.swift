import AppKit

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
        let orderedCandidates = BrowserOrdering.orderedCandidates(
            candidates,
            savedOrder: ruleStore.browserOrder,
            pathHints: ruleStore.browserOrderPathHints
        )
        let disabledIdentifiers = ruleStore.disabledBrowserIdentifiers
        let visibleCandidates = BrowserOrdering.visibleCandidates(
            orderedCandidates,
            savedOrder: ruleStore.browserOrder,
            pathHints: ruleStore.browserOrderPathHints,
            disabledIdentifiers: disabledIdentifiers
        )
        let disabledBrowserCount = candidates.count - visibleCandidates.count

        return DiagnosticsSnapshot(
            applicationVersion: applicationVersion,
            applicationBuild: applicationBuild,
            macOSVersion: macOSVersion,
            applicationLocation: DiagnosticLocation.classification(for: applicationURL),
            defaultBrowserStatus: defaultBrowserStatus(),
            enabledBrowsers: diagnosticBrowsers(
                from: visibleCandidates,
                duplicateBundleIdentifiers: duplicateBundleIdentifiers(in: candidates)
            ),
            disabledBrowserCount: disabledBrowserCount,
            ruleCount: ruleStore.rules.count,
            updateState: updateDiagnosticState()
        )
    }

    func copyDiagnostics(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(snapshot().renderedText, forType: .string)
    }

    private func diagnosticBrowsers(
        from candidates: [ApplicationCandidate],
        duplicateBundleIdentifiers: Set<String>
    ) -> [DiagnosticsSnapshot.Browser] {
        let identifiedCandidates = candidates.compactMap { candidate -> (String, DiagnosticLocation.Classification)? in
            normalizedBundleIdentifier(for: candidate).map {
                ($0, DiagnosticLocation.classification(for: candidate.applicationURL))
            }
        }
        let duplicateCounts = identifiedCandidates.reduce(into: [String: Int]()) { counts, candidate in
            guard duplicateBundleIdentifiers.contains(candidate.0) else { return }
            counts["\(candidate.0)|\(candidate.1.rawValue)", default: 0] += 1
        }
        var encountered = [String: Int]()

        return candidates.map { candidate in
            guard let bundleIdentifier = normalizedBundleIdentifier(for: candidate) else {
                return DiagnosticsSnapshot.Browser(
                    bundleIdentifier: "unknown bundle identifier",
                    location: nil,
                    locationOrdinal: nil
                )
            }
            let location = DiagnosticLocation.classification(for: candidate.applicationURL)
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
                location: duplicateBundleIdentifiers.contains(bundleIdentifier) ? location : nil,
                locationOrdinal: ordinal
            )
        }
    }

    private func duplicateBundleIdentifiers(in candidates: [ApplicationCandidate]) -> Set<String> {
        let counts = candidates.compactMap(normalizedBundleIdentifier(for:)).reduce(into: [String: Int]()) {
            $0[$1, default: 0] += 1
        }
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }

    private func normalizedBundleIdentifier(for candidate: ApplicationCandidate) -> String? {
        guard let bundleIdentifier = candidate.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty
        else {
            return nil
        }
        return bundleIdentifier
    }
}
