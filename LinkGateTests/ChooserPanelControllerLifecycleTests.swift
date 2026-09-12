import AppKit
import XCTest
@testable import LinkGate

// Acceptance Contract mapping:
// A3: Receiving an automatically routed URL must not activate LinkGate. A chooser or recoverable
// error that needs human input activates exactly once, while an in-progress selection does not
// activate again. A later queued chooser is a distinct interaction and may activate once.
// A4: This exercises the approved ChooserPanelController applicationActivator injection rather
// than NSApplication global state.
@MainActor
final class ChooserPanelControllerLifecycleTests: XCTestCase {
    func testSynchronousCancellationPreventsDeferredChooserActivation() async {
        let url = URL(string: "https://example.com/cancel-immediately")!
        let candidate = makeCandidate()
        let coordinator = SelectionCoordinator(
            discoveryService: FixedDiscovery(candidates: [candidate]),
            openingService: RecordingOpener()
        )
        var activationCount = 0
        let panelController = ChooserPanelController(
            coordinator: coordinator,
            applicationActivator: { _ in activationCount += 1 }
        )

        coordinator.receiveIncomingURL(url)
        coordinator.cancelActiveURL()
        await settlePublisherTasks()

        guard case .idle = coordinator.state else {
            return XCTFail("Expected synchronous cancellation to leave the coordinator idle.")
        }
        XCTAssertEqual(activationCount, 0)
        withExtendedLifetime(panelController) {}
    }

    func testAutomaticRouteDoesNotActivateLinkGate() async {
        let url = URL(string: "https://example.com/automatic")!
        let candidate = makeCandidate()
        let discovery = FixedDiscovery(candidates: [candidate])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(
            discoveryService: discovery,
            openingService: opener,
            ruleProvider: FixedRuleProvider(rules: [
                RoutingRule(
                    id: UUID(),
                    matchType: .exactDomain,
                    pattern: "example.com",
                    browserBundleIdentifier: "com.example.browser"
                )
            ])
        )
        var activationCount = 0
        let panelController = ChooserPanelController(
            coordinator: coordinator,
            applicationActivator: { _ in activationCount += 1 }
        )

        coordinator.receiveIncomingURL(url)

        await assertEventually { opener.requests.count == 1 }
        await settlePublisherTasks()
        XCTAssertEqual(opener.requests.map(\.url), [url])
        XCTAssertEqual(activationCount, 0)
        withExtendedLifetime(panelController) {}
    }

    func testChooserActivatesOnceAndSelectionDoesNotReactivateIt() async {
        let url = URL(string: "https://example.com/choose")!
        let candidate = makeCandidate()
        let coordinator = SelectionCoordinator(
            discoveryService: FixedDiscovery(candidates: [candidate]),
            openingService: RecordingOpener()
        )
        var activationCount = 0
        let panelController = ChooserPanelController(
            coordinator: coordinator,
            applicationActivator: { _ in activationCount += 1 }
        )

        coordinator.receiveIncomingURL(url)

        await assertEventually { activationCount == 1 }
        coordinator.select(candidate)
        await assertEventually {
            guard case let .choosing(context) = coordinator.state else { return false }
            return context.url == url && context.isOpening
        }
        await settlePublisherTasks()

        XCTAssertEqual(activationCount, 1)
        withExtendedLifetime(panelController) {}
    }

    func testDirectFailureAndNextQueuedChooserEachActivateOnce() async {
        let directURL = URL(string: "https://example.com/direct")!
        let queuedURL = URL(string: "https://example.org/queued")!
        let candidate = makeCandidate()
        let discovery = FixedDiscovery(candidates: [candidate])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(
            discoveryService: discovery,
            openingService: opener,
            ruleProvider: FixedRuleProvider(rules: [
                RoutingRule(
                    id: UUID(),
                    matchType: .exactDomain,
                    pattern: "example.com",
                    browserBundleIdentifier: "com.example.browser"
                )
            ])
        )
        var activationCount = 0
        let panelController = ChooserPanelController(
            coordinator: coordinator,
            applicationActivator: { _ in activationCount += 1 }
        )

        coordinator.receiveIncomingURL(directURL)
        coordinator.receiveIncomingURL(queuedURL)
        await assertEventually { opener.requests.count == 1 }
        await settlePublisherTasks()
        XCTAssertEqual(activationCount, 0)

        opener.completeFirst(with: .failure(OpeningError.failed))
        await assertEventually {
            guard case let .choosing(context) = coordinator.state else { return false }
            return context.url == directURL && context.errorMessage != nil
        }
        await assertEventually { activationCount == 1 }

        coordinator.cancelActiveURL()
        await assertEventually {
            guard case let .choosing(context) = coordinator.state else { return false }
            return context.url == queuedURL && !context.isOpening
        }
        await assertEventually { activationCount == 2 }
        await settlePublisherTasks()

        XCTAssertEqual(activationCount, 2)
        withExtendedLifetime(panelController) {}
    }

    func testNoCandidatesActivatesOnceForAnActionableError() async {
        let url = URL(string: "https://example.com/no-candidates")!
        let coordinator = SelectionCoordinator(
            discoveryService: FixedDiscovery(candidates: []),
            openingService: RecordingOpener()
        )
        var activationCount = 0
        let panelController = ChooserPanelController(
            coordinator: coordinator,
            applicationActivator: { _ in activationCount += 1 }
        )

        coordinator.receiveIncomingURL(url)

        await assertEventually {
            guard case let .noCandidates(activeURL) = coordinator.state else { return false }
            return activeURL == url
        }
        await assertEventually { activationCount == 1 }
        await settlePublisherTasks()

        XCTAssertEqual(activationCount, 1)
        withExtendedLifetime(panelController) {}
    }

    func testDirectFailureRefreshingToNoCandidatesActivatesOnceForRecovery() async {
        let url = URL(string: "https://example.com/direct-failure")!
        let candidate = makeCandidate()
        let discovery = SequencedDiscovery(snapshots: [[candidate], []])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(
            discoveryService: discovery,
            openingService: opener,
            ruleProvider: FixedRuleProvider(rules: [
                RoutingRule(
                    id: UUID(),
                    matchType: .exactDomain,
                    pattern: "example.com",
                    browserBundleIdentifier: "com.example.browser"
                )
            ])
        )
        var activationCount = 0
        let panelController = ChooserPanelController(
            coordinator: coordinator,
            applicationActivator: { _ in activationCount += 1 }
        )

        coordinator.receiveIncomingURL(url)
        await assertEventually { opener.requests.count == 1 }
        await settlePublisherTasks()
        XCTAssertEqual(activationCount, 0)

        opener.completeFirst(with: .failure(OpeningError.failed))
        await assertEventually {
            guard case let .noCandidates(activeURL) = coordinator.state else { return false }
            return activeURL == url
        }
        await assertEventually { activationCount == 1 }
        await settlePublisherTasks()

        XCTAssertEqual(activationCount, 1)
        withExtendedLifetime(panelController) {}
    }

    private func assertEventually(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let fulfilled = expectation(description: "lifecycle condition becomes true")
        let observer = Task { @MainActor in
            for _ in 0..<100 {
                if condition() {
                    fulfilled.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        await fulfillment(of: [fulfilled], timeout: 1)
        _ = await observer.value
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func settlePublisherTasks() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func makeCandidate() -> ApplicationCandidate {
        ApplicationCandidate(
            applicationURL: URL(fileURLWithPath: "/Applications/Browser.app"),
            displayName: "Browser",
            bundleIdentifier: "com.example.browser",
            icon: NSImage(size: NSSize(width: 16, height: 16))
        )
    }
}

private final class FixedDiscovery: BrowserDiscoveryService {
    let candidatesToReturn: [ApplicationCandidate]

    init(candidates: [ApplicationCandidate]) {
        candidatesToReturn = candidates
    }

    func candidates(for url: URL) -> [ApplicationCandidate] {
        candidatesToReturn
    }
}

private final class FixedRuleProvider: RoutingRuleProviding {
    let rules: [RoutingRule]

    init(rules: [RoutingRule]) {
        self.rules = rules
    }
}

private final class SequencedDiscovery: BrowserDiscoveryService {
    private var snapshots: [[ApplicationCandidate]]

    init(snapshots: [[ApplicationCandidate]]) {
        self.snapshots = snapshots
    }

    func candidates(for url: URL) -> [ApplicationCandidate] {
        guard !snapshots.isEmpty else {
            return []
        }
        return snapshots.removeFirst()
    }
}

private final class RecordingOpener: BrowserOpeningService {
    struct Request {
        let url: URL
        let applicationURL: URL
    }

    private(set) var requests: [Request] = []
    private var completions: [(Result<Void, Error>) -> Void] = []

    func open(
        _ url: URL,
        withApplicationAt applicationURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        requests.append(Request(url: url, applicationURL: applicationURL))
        completions.append(completion)
    }

    func completeFirst(with result: Result<Void, Error>) {
        completions.removeFirst()(result)
    }
}

private enum OpeningError: Error {
    case failed
}
