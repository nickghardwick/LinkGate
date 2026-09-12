import Combine
import Foundation
import SwiftUI

@MainActor
final class RoutingSettingsModel: ObservableObject {
    @Published private(set) var rules: [RoutingRule]
    @Published private(set) var browserChoices: [ApplicationCandidate] = []
    @Published private(set) var detectedBrowsers: [ApplicationCandidate] = []
    @Published private(set) var defaultBrowserStatus = DefaultBrowserStatus(httpIsDefault: false, httpsIsDefault: false)
    @Published private(set) var isRequestingDefault = false
    @Published private(set) var errorMessage: String?

    private let ruleStore: RoutingRuleStore
    private let discoveryService: BrowserDiscoveryService
    private let defaultBrowserService: DefaultBrowserService?
    private var ruleTargetApplicationURLs: [String: URL] = [:]

    init(
        ruleStore: RoutingRuleStore,
        discoveryService: BrowserDiscoveryService,
        defaultBrowserService: DefaultBrowserService? = nil
    ) {
        self.ruleStore = ruleStore
        self.discoveryService = discoveryService
        self.defaultBrowserService = defaultBrowserService
        rules = ruleStore.rules
    }

    var storageWarning: String? { ruleStore.storageWarning }

    func refresh() {
        rules = ruleStore.rules
        let representativeURL = URL(string: "https://example.com")!
        let discoveredBrowsers = discoveryService.candidates(for: representativeURL)
        ruleTargetApplicationURLs = [:]
        for browser in discoveredBrowsers {
            if let bundleIdentifier = browser.bundleIdentifier, !bundleIdentifier.isEmpty,
               ruleTargetApplicationURLs[bundleIdentifier] == nil {
                ruleTargetApplicationURLs[bundleIdentifier] = browser.applicationURL
            }
        }
        detectedBrowsers = BrowserOrdering.orderedCandidates(
            discoveredBrowsers,
            savedOrder: ruleStore.browserOrder,
            pathHints: ruleStore.browserOrderPathHints
        )
        persistNewBrowserIdentifiersIfNeeded(in: discoveredBrowsers)
        updateBrowserChoices()
        if let defaultBrowserService {
            defaultBrowserStatus = defaultBrowserService.status()
        }
    }

    @discardableResult
    func moveBrowsers(from offsets: IndexSet, to destination: Int) -> Bool {
        guard !offsets.isEmpty,
              offsets.allSatisfy(detectedBrowsers.indices.contains),
              (0...detectedBrowsers.count).contains(destination)
        else {
            return false
        }

        var reordered = detectedBrowsers
        reordered.move(fromOffsets: offsets, toOffset: destination)
        let currentIdentifiers = BrowserOrdering.identifiers(
            for: detectedBrowsers,
            savedOrder: ruleStore.browserOrder,
            pathHints: ruleStore.browserOrderPathHints
        )
        let reorderedIdentifiers = BrowserOrdering.identifiers(
            for: reordered,
            savedOrder: ruleStore.browserOrder,
            pathHints: ruleStore.browserOrderPathHints
        )
        let persistedOrder = mergedOrder(
            savedOrder: ruleStore.browserOrder,
            currentIdentifiers: currentIdentifiers,
            reorderedIdentifiers: reorderedIdentifiers
        )

        do {
            try ruleStore.saveBrowserOrder(
                persistedOrder,
                pathHints: BrowserOrdering.updatedPathHints(
                    for: reordered,
                    savedOrder: persistedOrder,
                    existingHints: ruleStore.browserOrderPathHints
                )
            )
            detectedBrowsers = reordered
            updateBrowserChoices()
            errorMessage = nil
            return true
        } catch {
            errorMessage = safeMessage(for: error, fallback: "The browser order could not be updated.")
            return false
        }
    }

    @discardableResult
    func saveRule(
        id: UUID?,
        matchType: RoutingRule.MatchType,
        pattern: String,
        browserBundleIdentifier: String
    ) -> Bool {
        do {
            if let id {
                _ = try ruleStore.update(
                    id: id,
                    matchType: matchType,
                    pattern: pattern,
                    browserBundleIdentifier: browserBundleIdentifier
                )
            } else {
                _ = try ruleStore.create(
                    matchType: matchType,
                    pattern: pattern,
                    browserBundleIdentifier: browserBundleIdentifier
                )
            }
            rules = ruleStore.rules
            errorMessage = nil
            return true
        } catch {
            errorMessage = safeMessage(for: error)
            return false
        }
    }

    @discardableResult
    func deleteRule(id: UUID) -> Bool {
        do {
            try ruleStore.delete(id: id)
            rules = ruleStore.rules
            errorMessage = nil
            return true
        } catch {
            errorMessage = safeMessage(for: error)
            return false
        }
    }

    @discardableResult
    func deleteRules(at offsets: IndexSet) -> Bool {
        let identifiers = offsets.compactMap { rules.indices.contains($0) ? rules[$0].id : nil }
        guard identifiers.count == offsets.count else {
            return false
        }
        for id in identifiers {
            guard deleteRule(id: id) else { return false }
        }
        return true
    }

    func clearError() {
        errorMessage = nil
    }

    func browserName(for bundleIdentifier: String) -> String {
        detectedBrowsers.first(where: { $0.bundleIdentifier == bundleIdentifier })?.displayName ?? "Unavailable browser"
    }

    func isBrowserAvailable(_ bundleIdentifier: String) -> Bool {
        browserChoices.contains(where: { $0.bundleIdentifier == bundleIdentifier })
    }

    func isBrowserEnabled(_ browser: ApplicationCandidate) -> Bool {
        guard let identifier = identifier(for: browser) else { return false }
        return !ruleStore.disabledBrowserIdentifiers.contains(identifier)
    }

    func canDisableBrowser(_ browser: ApplicationCandidate) -> Bool {
        guard isBrowserEnabled(browser) else { return false }
        return detectedBrowsers.filter(isBrowserEnabled).count > 1
    }

    @discardableResult
    func setBrowserEnabled(_ enabled: Bool, for browser: ApplicationCandidate) -> Bool {
        guard let identifier = identifier(for: browser) else { return false }
        let isEnabled = !ruleStore.disabledBrowserIdentifiers.contains(identifier)
        guard enabled != isEnabled else { return true }
        guard enabled || canDisableBrowser(browser) else {
            errorMessage = "At least one available browser must remain enabled."
            return false
        }

        do {
            if ruleStore.browserOrder == nil {
                let identifiers = BrowserOrdering.identifiers(for: detectedBrowsers)
                try ruleStore.saveBrowserOrder(
                    identifiers,
                    pathHints: BrowserOrdering.updatedPathHints(
                        for: detectedBrowsers,
                        savedOrder: identifiers,
                        existingHints: ruleStore.browserOrderPathHints
                    )
                )
            }
            var disabled = ruleStore.disabledBrowserIdentifiers
            if enabled {
                disabled.remove(identifier)
            } else {
                disabled.insert(identifier)
            }
            try ruleStore.saveDisabledBrowserIdentifiers(disabled)
            updateBrowserChoices()
            errorMessage = nil
            return true
        } catch {
            errorMessage = safeMessage(for: error, fallback: "Browser visibility could not be updated.")
            return false
        }
    }

    func requestDefaultBrowser() {
        guard let defaultBrowserService, !isRequestingDefault else { return }
        isRequestingDefault = true
        defaultBrowserService.requestDefault { [weak self] result in
            guard let self else { return }
            self.isRequestingDefault = false
            self.defaultBrowserStatus = defaultBrowserService.status()
            switch result {
            case .success:
                self.errorMessage = nil
            case let .failure(error):
                self.errorMessage = self.safeMessage(for: error, fallback: "LinkGate could not become the default browser.")
            }
        }
    }

    private func safeMessage(for error: Error, fallback: String = "The routing rules could not be updated.") -> String {
        if error is RoutingRuleValidationError || error is RoutingRuleStorageError {
            return error.localizedDescription
        }
        return fallback
    }

    private func persistNewBrowserIdentifiersIfNeeded(in discoveredBrowsers: [ApplicationCandidate]) {
        guard let savedOrder = ruleStore.browserOrder else { return }
        let discoveredIdentifiers = BrowserOrdering.identifiers(
            for: discoveredBrowsers,
            savedOrder: savedOrder,
            pathHints: ruleStore.browserOrderPathHints
        )
        let newIdentifiers = discoveredIdentifiers.filter { !savedOrder.contains($0) }
        let updatedHints = BrowserOrdering.updatedPathHints(
            for: discoveredBrowsers,
            savedOrder: savedOrder,
            existingHints: ruleStore.browserOrderPathHints
        )
        guard !newIdentifiers.isEmpty || updatedHints != ruleStore.browserOrderPathHints else { return }

        do {
            try ruleStore.saveBrowserOrder(savedOrder + newIdentifiers, pathHints: updatedHints)
        } catch {
            errorMessage = safeMessage(for: error, fallback: "The browser order could not be updated.")
        }
    }

    private func updateBrowserChoices() {
        var seenBundleIdentifiers = Set<String>()
        browserChoices = detectedBrowsers.filter { candidate in
            guard let identifier = candidate.bundleIdentifier, !identifier.isEmpty else { return false }
            return ruleTargetApplicationURLs[identifier] == candidate.applicationURL
                && seenBundleIdentifiers.insert(identifier).inserted
                && isBrowserEnabled(candidate)
        }
    }

    private func identifier(for browser: ApplicationCandidate) -> String? {
        guard let index = detectedBrowsers.firstIndex(where: { $0.applicationURL == browser.applicationURL }) else {
            return nil
        }
        return BrowserOrdering.identifiers(
            for: detectedBrowsers,
            savedOrder: ruleStore.browserOrder,
            pathHints: ruleStore.browserOrderPathHints
        )[index]
    }

    private func mergedOrder(
        savedOrder: [String]?,
        currentIdentifiers: [String],
        reorderedIdentifiers: [String]
    ) -> [String] {
        guard let savedOrder else { return reorderedIdentifiers }

        var reorderedIterator = reorderedIdentifiers.makeIterator()
        var result = savedOrder.map { identifier in
            currentIdentifiers.contains(identifier) ? reorderedIterator.next()! : identifier
        }
        while let identifier = reorderedIterator.next() {
            result.append(identifier)
        }
        return result
    }
}
