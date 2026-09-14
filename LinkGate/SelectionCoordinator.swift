import Combine
import Foundation
import OSLog

@MainActor
final class SelectionCoordinator: ObservableObject, IncomingURLReceiving {
    enum State {
        case idle
        case discovering(URL)
        case choosing(SelectionContext)
        case openingDirectly(SelectionContext)
        case noCandidates(URL)
    }

    struct SelectionContext {
        let url: URL
        let candidates: [ApplicationCandidate]
        let presentationID: UUID
        let isOpening: Bool
        let errorMessage: String?
    }

    @Published private(set) var state: State = .idle

    private let discoveryService: BrowserDiscoveryService
    private let openingService: BrowserOpeningService
    private let ruleProvider: RoutingRuleProviding
    private let routingEvaluator: RoutingEvaluator
    private let candidateResolver: BrowserCandidateResolver
    private let browserOrderStore: BrowserOrderStoring?
    private var pendingURLs: [URL] = []
    private var activeOpeningRequestID: UUID?

    var activeURL: URL? {
        switch state {
        case .idle:
            nil
        case let .discovering(url), let .noCandidates(url):
            url
        case let .choosing(context), let .openingDirectly(context):
            context.url
        }
    }

    init(
        discoveryService: BrowserDiscoveryService,
        openingService: BrowserOpeningService,
        ruleProvider: RoutingRuleProviding? = nil,
        routingEvaluator: RoutingEvaluator? = nil,
        candidateResolver: BrowserCandidateResolver? = nil,
        browserOrderStore: BrowserOrderStoring? = nil
    ) {
        self.discoveryService = discoveryService
        self.openingService = openingService
        self.ruleProvider = ruleProvider ?? EmptyRoutingRuleProvider.shared
        self.routingEvaluator = routingEvaluator ?? RoutingEvaluator()
        self.candidateResolver = candidateResolver ?? BrowserCandidateResolver()
        self.browserOrderStore = browserOrderStore
    }

    func receiveIncomingURL(_ url: URL) {
        guard activeURL == nil else {
            pendingURLs.append(url)
            LinkGateLog.routing.debug("Queued incoming link pendingCount=\(self.pendingURLs.count, privacy: .public)")
            return
        }

        begin(url)
    }

    func select(_ candidate: ApplicationCandidate) {
        guard case let .choosing(context) = state,
              !context.isOpening,
              context.candidates.contains(where: { $0.applicationURL == candidate.applicationURL })
        else {
            return
        }

        submitOpening(
            SelectionContext(
                url: context.url,
                candidates: context.candidates,
                presentationID: context.presentationID,
                isOpening: true,
                errorMessage: nil
            ),
            candidate: candidate,
            directly: false
        )
    }

    func cancelActiveURL() {
        guard activeURL != nil else {
            return
        }

        if case let .choosing(context) = state, context.isOpening {
            return
        }
        if case .openingDirectly = state {
            return
        }

        finishActiveURL()
    }

    private func begin(_ url: URL) {
        state = .discovering(url)

        let discoveredCandidates = discoveryService.candidates(for: url)
        if discoveredCandidates.isEmpty {
            state = .noCandidates(url)
            LinkGateLog.browser.notice("No eligible browser candidates available")
            return
        }

        let candidates = orderedCandidates(discoveredCandidates)
        if candidates.isEmpty {
            state = .noCandidates(url)
            LinkGateLog.browser.notice("No visible browser candidates available")
            return
        }
        if let rule = routingEvaluator.matchingRule(for: url, rules: ruleProvider.rules),
                  let candidate = candidateResolver.candidate(
                    bundleIdentifier: rule.browserBundleIdentifier,
                    among: discoveredCandidates
                  ), candidates.contains(where: { $0.applicationURL == candidate.applicationURL }) {
            LinkGateLog.routing.info("Direct route selected browserBundleID=\(candidate.bundleIdentifier ?? "unknown", privacy: .public)")
            submitOpening(
                SelectionContext(
                    url: url,
                    candidates: candidates,
                    presentationID: UUID(),
                    isOpening: true,
                    errorMessage: nil
                ),
                candidate: candidate,
                directly: true
            )
        } else {
            LinkGateLog.routing.info("Browser chooser required")
            state = .choosing(
                SelectionContext(
                    url: url,
                    candidates: candidates,
                    presentationID: UUID(),
                    isOpening: false,
                    errorMessage: nil
                )
            )
        }
    }

    private func handleOpeningResult(
        _ result: Result<Void, Error>,
        requestURL: URL,
        applicationURL: URL,
        requestID: UUID
    ) {
        let context: SelectionContext
        let wasDirect: Bool
        switch state {
        case let .choosing(currentContext):
            context = currentContext
            wasDirect = false
        case let .openingDirectly(currentContext):
            context = currentContext
            wasDirect = true
        default:
            return
        }
        guard context.isOpening,
              context.url == requestURL,
              context.candidates.contains(where: { $0.applicationURL == applicationURL }),
              activeOpeningRequestID == requestID
        else {
            return
        }

        activeOpeningRequestID = nil
        switch result {
        case .success:
            LinkGateLog.browser.info("Browser open succeeded source=\(wasDirect ? "direct" : "chooser", privacy: .public) browserBundleID=\(self.applicationBundleIdentifier(for: applicationURL, in: context.candidates), privacy: .public)")
            finishActiveURL()
        case let .failure(error):
            LinkGateLog.browser.error("Browser open failed source=\(wasDirect ? "direct" : "chooser", privacy: .public) browserBundleID=\(self.applicationBundleIdentifier(for: applicationURL, in: context.candidates), privacy: .public) category=\(DiagnosticError.category(for: error, operation: .browserOpen), privacy: .public)")
            let refreshedCandidates = orderedCandidates(discoveryService.candidates(for: context.url))
            if refreshedCandidates.isEmpty {
                state = .noCandidates(context.url)
                LinkGateLog.browser.notice("No browser candidates available after open failure")
            } else {
                state = .choosing(
                    SelectionContext(
                        url: context.url,
                        candidates: refreshedCandidates,
                        presentationID: wasDirect ? UUID() : context.presentationID,
                        isOpening: false,
                        errorMessage: "The selected application could not open this link."
                    )
                )
            }
        }
    }

    private func submitOpening(_ context: SelectionContext, candidate: ApplicationCandidate, directly: Bool) {
        state = directly ? .openingDirectly(context) : .choosing(context)
        LinkGateLog.browser.info("Browser open started source=\(directly ? "direct" : "chooser", privacy: .public) browserBundleID=\(candidate.bundleIdentifier ?? "unknown", privacy: .public)")
        let requestID = UUID()
        activeOpeningRequestID = requestID
        openingService.open(context.url, withApplicationAt: candidate.applicationURL) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.handleOpeningResult(
                    result,
                    requestURL: context.url,
                    applicationURL: candidate.applicationURL,
                    requestID: requestID
                )
            }
        }
    }

    private func finishActiveURL() {
        guard !pendingURLs.isEmpty else {
            state = .idle
            return
        }

        begin(pendingURLs.removeFirst())
    }

    private func applicationBundleIdentifier(for applicationURL: URL, in candidates: [ApplicationCandidate]) -> String {
        candidates.first(where: { $0.applicationURL == applicationURL })?.bundleIdentifier ?? "unknown"
    }

    private func orderedCandidates(_ candidates: [ApplicationCandidate]) -> [ApplicationCandidate] {
        guard let browserOrderStore else {
            return candidates
        }

        guard let savedOrder = browserOrderStore.browserOrder else {
            return BrowserOrdering.visibleCandidates(
                candidates,
                savedOrder: nil,
                pathHints: browserOrderStore.browserOrderPathHints,
                disabledIdentifiers: browserOrderStore.disabledBrowserIdentifiers
            )
        }

        let newIdentifiers = BrowserOrdering.identifiers(
            for: candidates,
            savedOrder: savedOrder,
            pathHints: browserOrderStore.browserOrderPathHints
        )
            .filter { !savedOrder.contains($0) }
        let updatedHints = BrowserOrdering.updatedPathHints(
            for: candidates,
            savedOrder: savedOrder,
            existingHints: browserOrderStore.browserOrderPathHints
        )
        if !newIdentifiers.isEmpty || updatedHints != browserOrderStore.browserOrderPathHints {
            try? browserOrderStore.saveBrowserOrder(savedOrder + newIdentifiers, pathHints: updatedHints)
        }
        let ordered = BrowserOrdering.orderedCandidates(candidates, savedOrder: savedOrder, pathHints: updatedHints)
        return BrowserOrdering.visibleCandidates(
            ordered,
            savedOrder: savedOrder,
            pathHints: updatedHints,
            disabledIdentifiers: browserOrderStore.disabledBrowserIdentifiers
        )
    }
}

private final class EmptyRoutingRuleProvider: RoutingRuleProviding {
    static let shared = EmptyRoutingRuleProvider()
    let rules: [RoutingRule] = []
}
