import AppKit
import XCTest
@testable import LinkGate

// Acceptance Contract mapping
// 4: one candidate remains selectable and zero candidates produces an actionable state.
// 5: one active URL is retained while later URLs are queued FIFO.
// 6: selection explicitly opens the exact intercepted URL with the selected original application URL.
// 7: a successful open removes only the active item and advances or returns to idle.
// 8: a failed open retains the active URL, refreshes candidate availability, shows a sanitized error when
//    candidates remain, and permits another attempt.
// 9: cancellation discards only the active item, performs no open, and advances FIFO.
// 12: state and platform-service interactions are testable without real application launches.
// 5, 7, 8, 9, 12: asynchronous opening completion, cancellation, and later arrivals preserve the active item and FIFO queue.
// 5, 8, 11, 12: each active queue item has a distinct presentation identity that survives opening failure and retry for that item.
// Phase 03 Acceptance Contract mapping:
// 10: a resolved rule opens directly, without chooser presentation, using the exact intercepted URL
//     and original discovered application URL.
// 11: no rule or an unavailable rule target retains the existing chooser and never mutates rules.
// 12: direct completion/failure uses the same recoverable FIFO lifecycle; arrivals during a direct
//     open remain queued and identical chooser presentations retain distinct identities.
// Phase 04 Acceptance Contract mapping:
// A1, A4: launch failures re-discover candidates for the same untouched URL; retry and queue behavior
//          remains FIFO, automatic-routing rules are retained, and stale completion callbacks are ignored.
// Browser ordering acceptance contract: chooser candidates consume the persisted global identity order;
// numeric shortcuts are assigned from this displayed candidate index by ChooserView.
@MainActor
final class SelectionCoordinatorTests: XCTestCase {
    func testFirstArrivalImmediatelyBeginsDiscoveryAndShowsSingleCandidateChooser() {
        let firstURL = URL(string: "https://example.com/first")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = FakeDiscovery(results: [firstURL: [candidate]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)

        coordinator.receiveIncomingURL(firstURL)

        XCTAssertEqual(discovery.requestedURLs, [firstURL])
        XCTAssertEqual(coordinator.activeURL, firstURL)
        assertChoosing(coordinator, url: firstURL, candidates: [candidate], isOpening: false, errorMessage: nil)
        XCTAssertTrue(opener.requests.isEmpty)
    }

    func testLaterArrivalsRemainFIFOAndDoNotReplaceActiveURL() {
        let firstURL = URL(string: "https://example.com/first")!
        let secondURL = URL(string: "https://example.com/second")!
        let thirdURL = URL(string: "https://example.com/third")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = FakeDiscovery(results: [firstURL: [candidate], secondURL: [candidate], thirdURL: [candidate]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)

        coordinator.receiveIncomingURL(firstURL)
        coordinator.receiveIncomingURL(secondURL)
        coordinator.receiveIncomingURL(thirdURL)

        XCTAssertEqual(coordinator.activeURL, firstURL)
        XCTAssertEqual(discovery.requestedURLs, [firstURL])
        coordinator.cancelActiveURL()
        XCTAssertEqual(coordinator.activeURL, secondURL)
        XCTAssertEqual(discovery.requestedURLs, [firstURL, secondURL])
        coordinator.cancelActiveURL()
        XCTAssertEqual(coordinator.activeURL, thirdURL)
        XCTAssertEqual(discovery.requestedURLs, [firstURL, secondURL, thirdURL])
        XCTAssertTrue(opener.requests.isEmpty)
    }

    func testIdenticalQueuedURLsReceiveDistinctPresentationIdentitiesWhenActivated() {
        let repeatedURL = URL(string: "https://example.com/repeated")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = FakeDiscovery(results: [repeatedURL: [candidate]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)

        coordinator.receiveIncomingURL(repeatedURL)
        coordinator.receiveIncomingURL(repeatedURL)
        let firstPresentationID = try! XCTUnwrap(choosingPresentationID(coordinator))
        coordinator.cancelActiveURL()
        let secondPresentationID = try! XCTUnwrap(choosingPresentationID(coordinator))

        XCTAssertEqual(coordinator.activeURL, repeatedURL)
        XCTAssertNotEqual(firstPresentationID, secondPresentationID)
        assertChoosing(coordinator, url: repeatedURL, candidates: [candidate], isOpening: false, errorMessage: nil)
    }

    func testSuccessfulOpeningAdvancesOnlyActiveItemThenReturnsIdle() async {
        let firstURL = URL(string: "https://example.com/first")!
        let secondURL = URL(string: "https://example.com/second")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = FakeDiscovery(results: [firstURL: [candidate], secondURL: [candidate]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)
        coordinator.receiveIncomingURL(firstURL)
        coordinator.receiveIncomingURL(secondURL)

        coordinator.select(candidate)
        assertChoosing(coordinator, url: firstURL, candidates: [candidate], isOpening: true, errorMessage: nil)
        opener.completeFirst(with: .success(()))

        await assertEventuallyChoosing(coordinator, url: secondURL, candidates: [candidate], isOpening: false, errorMessage: nil)
        XCTAssertEqual(coordinator.activeURL, secondURL)
        coordinator.select(candidate)
        opener.completeFirst(with: .success(()))

        await assertEventuallyIdle(coordinator)
        XCTAssertNil(coordinator.activeURL)
    }

    func testBackgroundOpeningCompletionEventuallyAdvancesStateOnMainActor() async {
        let firstURL = URL(string: "https://example.com/first")!
        let secondURL = URL(string: "https://example.com/second")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = FakeDiscovery(results: [firstURL: [candidate], secondURL: [candidate]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)
        coordinator.receiveIncomingURL(firstURL)
        coordinator.receiveIncomingURL(secondURL)
        coordinator.select(candidate)
        let completion = opener.retainedCompletion(at: 0)
        let stateUpdated = expectation(description: "background completion advances the FIFO queue")
        let observer = Task { @MainActor in
            for _ in 0..<100 {
                if coordinator.activeURL == secondURL {
                    stateUpdated.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        await Task.detached {
            completion.complete(.success(()))
        }.value
        await fulfillment(of: [stateUpdated], timeout: 1)
        _ = await observer.value

        XCTAssertEqual(coordinator.activeURL, secondURL)
        assertChoosing(coordinator, url: secondURL, candidates: [candidate], isOpening: false, errorMessage: nil)
    }

    func testCancelDuringOpeningPreservesActiveURLAndQueueUntilCompletion() async {
        let activeURL = URL(string: "https://example.com/active")!
        let queuedURL = URL(string: "https://example.com/queued")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = FakeDiscovery(results: [activeURL: [candidate], queuedURL: [candidate]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)
        coordinator.receiveIncomingURL(activeURL)
        coordinator.receiveIncomingURL(queuedURL)
        coordinator.select(candidate)

        coordinator.cancelActiveURL()

        XCTAssertEqual(coordinator.activeURL, activeURL)
        XCTAssertEqual(discovery.requestedURLs, [activeURL])
        XCTAssertEqual(opener.requests.count, 1)
        assertChoosing(coordinator, url: activeURL, candidates: [candidate], isOpening: true, errorMessage: nil)
        opener.completeFirst(with: .success(()))

        await assertEventuallyChoosing(coordinator, url: queuedURL, candidates: [candidate], isOpening: false, errorMessage: nil)
        XCTAssertEqual(coordinator.activeURL, queuedURL)
        XCTAssertEqual(discovery.requestedURLs, [activeURL, queuedURL])
        XCTAssertEqual(opener.requests.count, 1)
    }

    func testArrivalsDuringOpeningRemainFIFOBehindActiveURL() async {
        let activeURL = URL(string: "https://example.com/active")!
        let secondURL = URL(string: "https://example.com/second")!
        let thirdURL = URL(string: "https://example.com/third")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = FakeDiscovery(results: [
            activeURL: [candidate],
            secondURL: [candidate],
            thirdURL: [candidate],
        ])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)
        coordinator.receiveIncomingURL(activeURL)
        coordinator.select(candidate)

        coordinator.receiveIncomingURL(secondURL)
        coordinator.receiveIncomingURL(thirdURL)

        XCTAssertEqual(coordinator.activeURL, activeURL)
        XCTAssertEqual(discovery.requestedURLs, [activeURL])
        assertChoosing(coordinator, url: activeURL, candidates: [candidate], isOpening: true, errorMessage: nil)
        opener.completeFirst(with: .success(()))

        await assertEventuallyChoosing(coordinator, url: secondURL, candidates: [candidate], isOpening: false, errorMessage: nil)
        XCTAssertEqual(coordinator.activeURL, secondURL)
        XCTAssertEqual(discovery.requestedURLs, [activeURL, secondURL])
        coordinator.cancelActiveURL()

        XCTAssertEqual(coordinator.activeURL, thirdURL)
        XCTAssertEqual(discovery.requestedURLs, [activeURL, secondURL, thirdURL])
        assertChoosing(coordinator, url: thirdURL, candidates: [candidate], isOpening: false, errorMessage: nil)
    }

    func testOpeningFailureRestoresCancellableChooserAndCancelAdvancesQueue() async {
        let activeURL = URL(string: "https://example.com/active")!
        let queuedURL = URL(string: "https://example.com/queued")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = FakeDiscovery(results: [activeURL: [candidate], queuedURL: [candidate]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)
        coordinator.receiveIncomingURL(activeURL)
        coordinator.receiveIncomingURL(queuedURL)
        coordinator.select(candidate)
        opener.completeFirst(with: .failure(TestError.openFailed))

        await assertEventuallyChoosing(
            coordinator,
            url: activeURL,
            candidates: [candidate],
            isOpening: false,
            errorMessage: "The selected application could not open this link."
        )
        coordinator.cancelActiveURL()

        XCTAssertEqual(opener.requests.count, 1)
        XCTAssertEqual(coordinator.activeURL, queuedURL)
        XCTAssertEqual(discovery.requestedURLs, [activeURL, activeURL, queuedURL])
        assertChoosing(coordinator, url: queuedURL, candidates: [candidate], isOpening: false, errorMessage: nil)
    }

    func testCancelDiscardsOnlyActiveURLWithoutOpeningAndAdvancesQueue() {
        let firstURL = URL(string: "https://example.com/first")!
        let secondURL = URL(string: "https://example.com/second")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = FakeDiscovery(results: [firstURL: [candidate], secondURL: [candidate]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)
        coordinator.receiveIncomingURL(firstURL)
        coordinator.receiveIncomingURL(secondURL)

        coordinator.cancelActiveURL()

        XCTAssertTrue(opener.requests.isEmpty)
        XCTAssertEqual(coordinator.activeURL, secondURL)
        assertChoosing(coordinator, url: secondURL, candidates: [candidate], isOpening: false, errorMessage: nil)
        coordinator.cancelActiveURL()
        XCTAssertNil(coordinator.activeURL)
        assertIdle(coordinator)
        XCTAssertTrue(opener.requests.isEmpty)
    }

    func testZeroCandidatesShowsCloseableErrorAndCloseAdvancesQueue() {
        let emptyURL = URL(string: "https://empty.example/path")!
        let queuedURL = URL(string: "https://queued.example/path")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = FakeDiscovery(results: [emptyURL: [], queuedURL: [candidate]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)
        coordinator.receiveIncomingURL(emptyURL)
        coordinator.receiveIncomingURL(queuedURL)

        assertNoCandidates(coordinator, url: emptyURL)
        coordinator.cancelActiveURL()

        XCTAssertTrue(opener.requests.isEmpty)
        XCTAssertEqual(coordinator.activeURL, queuedURL)
        assertChoosing(coordinator, url: queuedURL, candidates: [candidate], isOpening: false, errorMessage: nil)
    }

    func testSelectionUsesExactOriginalURLsAndIgnoresDuplicateSelectionWhileOpening() {
        let complexURLString = "https://example.com:8443/a%20path/%E2%9C%93?first=one%20two&encoded=%2Fvalue#section%20two"
        let complexURL = URL(string: complexURLString)!
        let candidate = makeCandidate(url: URL(fileURLWithPath: "/Applications/Browser.app"), name: "Browser")
        let discovery = FakeDiscovery(results: [complexURL: [candidate]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)
        coordinator.receiveIncomingURL(complexURL)

        coordinator.select(candidate)
        coordinator.select(candidate)

        XCTAssertEqual(opener.requests.count, 1)
        XCTAssertEqual(opener.requests[0].url.absoluteString, complexURLString)
        XCTAssertEqual(opener.requests[0].applicationURL, candidate.applicationURL)
        assertChoosing(coordinator, url: complexURL, candidates: [candidate], isOpening: true, errorMessage: nil)
    }

    func testFailedOpeningRetainsExactURLCandidatesAndQueuePosition() async {
        let complexURLString = "https://example.com:8443/a%20path/%E2%9C%93?first=one%20two&encoded=%2Fvalue#section%20two"
        let complexURL = URL(string: complexURLString)!
        let queuedURL = URL(string: "https://queued.example/path")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = FakeDiscovery(results: [complexURL: [candidate], queuedURL: [candidate]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)
        coordinator.receiveIncomingURL(complexURL)
        coordinator.receiveIncomingURL(queuedURL)
        let presentationID = try! XCTUnwrap(choosingPresentationID(coordinator))

        coordinator.select(candidate)
        XCTAssertEqual(opener.requests.first?.url.absoluteString, complexURLString)
        XCTAssertEqual(opener.requests.first?.applicationURL, candidate.applicationURL)
        assertChoosing(coordinator, url: complexURL, candidates: [candidate], isOpening: true, errorMessage: nil)
        XCTAssertEqual(choosingPresentationID(coordinator), presentationID)
        opener.completeFirst(with: .failure(TestError.openFailed))

        await assertEventuallyChoosing(
            coordinator,
            url: complexURL,
            candidates: [candidate],
            isOpening: false,
            errorMessage: "The selected application could not open this link."
        )
        XCTAssertEqual(coordinator.activeURL, complexURL)
        XCTAssertEqual(choosingPresentationID(coordinator), presentationID)
        coordinator.select(candidate)
        assertChoosing(coordinator, url: complexURL, candidates: [candidate], isOpening: true, errorMessage: nil)
        XCTAssertEqual(choosingPresentationID(coordinator), presentationID)
        opener.completeFirst(with: .failure(TestError.openFailed))
        await assertEventuallyChoosing(
            coordinator,
            url: complexURL,
            candidates: [candidate],
            isOpening: false,
            errorMessage: "The selected application could not open this link."
        )
        XCTAssertEqual(choosingPresentationID(coordinator), presentationID)
        XCTAssertEqual(discovery.requestedURLs, [complexURL, complexURL, complexURL])
    }

    func testFailedManualOpeningRefreshesCandidatesAndRetriesWithReplacementUsingExactURL() async {
        let complexURLString = "https://example.com:8443/a%20path/%E2%9C%93?first=one%20two&encoded=%2Fvalue#section%20two"
        let complexURL = URL(string: complexURLString)!
        let removedCandidate = makeCandidate(url: URL(fileURLWithPath: "/Applications/Removed.app"), name: "Removed")
        let replacementCandidate = makeCandidate(url: URL(fileURLWithPath: "/Applications/Replacement.app"), name: "Replacement")
        let discovery = RefreshingFakeDiscovery(snapshots: [
            complexURL: [[removedCandidate], [replacementCandidate]],
        ])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)
        coordinator.receiveIncomingURL(complexURL)
        let presentationID = try! XCTUnwrap(choosingPresentationID(coordinator))

        coordinator.select(removedCandidate)
        XCTAssertEqual(opener.requests.first?.url.absoluteString, complexURLString)
        XCTAssertEqual(opener.requests.first?.applicationURL, removedCandidate.applicationURL)
        assertChoosing(coordinator, url: complexURL, candidates: [removedCandidate], isOpening: true, errorMessage: nil)
        XCTAssertEqual(choosingPresentationID(coordinator), presentationID)
        opener.completeFirst(with: .failure(TestError.openFailed))

        await assertEventuallyChoosing(
            coordinator,
            url: complexURL,
            candidates: [replacementCandidate],
            isOpening: false,
            errorMessage: "The selected application could not open this link."
        )
        XCTAssertEqual(coordinator.activeURL, complexURL)
        XCTAssertEqual(choosingPresentationID(coordinator), presentationID)
        XCTAssertEqual(discovery.requestedURLs, [complexURL, complexURL])
        coordinator.select(replacementCandidate)
        assertChoosing(coordinator, url: complexURL, candidates: [replacementCandidate], isOpening: true, errorMessage: nil)
        XCTAssertEqual(choosingPresentationID(coordinator), presentationID)
        XCTAssertEqual(opener.requests.map(\.url.absoluteString), [complexURLString, complexURLString])
        XCTAssertEqual(opener.requests.map(\.applicationURL), [removedCandidate.applicationURL, replacementCandidate.applicationURL])
        guard opener.requests.count == 2 else {
            return
        }
        opener.completeFirst(with: .success(()))

        await assertEventuallyIdle(coordinator)
    }

    func testFailedManualOpeningRediscoversNoCandidatesForTheSameURL() async {
        let incomingURL = URL(string: "https://example.com/path?query=value#fragment")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = RefreshingFakeDiscovery(snapshots: [incomingURL: [[candidate], []]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)

        coordinator.receiveIncomingURL(incomingURL)
        coordinator.select(candidate)
        opener.completeFirst(with: .failure(TestError.openFailed))

        await assertEventuallyNoCandidates(coordinator, url: incomingURL)
        XCTAssertEqual(coordinator.activeURL, incomingURL)
        XCTAssertEqual(discovery.requestedURLs, [incomingURL, incomingURL])
        XCTAssertEqual(opener.requests.count, 1)
    }

    func testFailurePermitsRetryAndSelectingAnotherCandidateBeforeAdvancing() async {
        let activeURL = URL(string: "https://example.com/active")!
        let queuedURL = URL(string: "https://example.com/queued")!
        let firstCandidate = makeCandidate(url: URL(fileURLWithPath: "/Applications/First.app"), name: "First")
        let secondCandidate = makeCandidate(url: URL(fileURLWithPath: "/Applications/Second.app"), name: "Second")
        let discovery = FakeDiscovery(results: [activeURL: [firstCandidate, secondCandidate], queuedURL: [firstCandidate]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)
        coordinator.receiveIncomingURL(activeURL)
        coordinator.receiveIncomingURL(queuedURL)

        coordinator.select(firstCandidate)
        opener.completeFirst(with: .failure(TestError.openFailed))
        await assertEventuallyChoosing(
            coordinator,
            url: activeURL,
            candidates: [firstCandidate, secondCandidate],
            isOpening: false,
            errorMessage: "The selected application could not open this link."
        )
        coordinator.select(firstCandidate)
        opener.completeFirst(with: .failure(TestError.openFailed))
        await assertEventuallyChoosing(
            coordinator,
            url: activeURL,
            candidates: [firstCandidate, secondCandidate],
            isOpening: false,
            errorMessage: "The selected application could not open this link."
        )
        coordinator.select(secondCandidate)

        XCTAssertEqual(opener.requests.map(\.applicationURL), [
            firstCandidate.applicationURL,
            firstCandidate.applicationURL,
            secondCandidate.applicationURL,
        ])
        XCTAssertEqual(coordinator.activeURL, activeURL)
        opener.completeFirst(with: .success(()))

        await assertEventuallyChoosing(coordinator, url: queuedURL, candidates: [firstCandidate], isOpening: false, errorMessage: nil)
        XCTAssertEqual(coordinator.activeURL, queuedURL)
        XCTAssertEqual(discovery.requestedURLs, [activeURL, activeURL, activeURL, queuedURL])
    }

    func testFailureThenRetryAndCancelAdvancesQueuedArrivalsInFIFOOrder() async {
        let activeURL = URL(string: "https://example.com/active")!
        let queuedURL = URL(string: "https://example.com/queued")!
        let laterURL = URL(string: "https://example.com/later")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = RefreshingFakeDiscovery(snapshots: [
            activeURL: [[candidate], [candidate], [candidate]],
            queuedURL: [[candidate]],
            laterURL: [[candidate]],
        ])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)
        coordinator.receiveIncomingURL(activeURL)
        coordinator.receiveIncomingURL(queuedURL)

        coordinator.select(candidate)
        opener.completeFirst(with: .failure(TestError.openFailed))
        await assertEventuallyChoosing(
            coordinator,
            url: activeURL,
            candidates: [candidate],
            isOpening: false,
            errorMessage: "The selected application could not open this link."
        )
        coordinator.receiveIncomingURL(laterURL)
        coordinator.select(candidate)
        opener.completeFirst(with: .failure(TestError.openFailed))
        await assertEventuallyChoosing(
            coordinator,
            url: activeURL,
            candidates: [candidate],
            isOpening: false,
            errorMessage: "The selected application could not open this link."
        )

        XCTAssertEqual(discovery.requestedURLs, [activeURL, activeURL, activeURL])
        XCTAssertEqual(opener.requests.map(\.applicationURL), [candidate.applicationURL, candidate.applicationURL])
        XCTAssertEqual(coordinator.activeURL, activeURL)
        coordinator.cancelActiveURL()

        await assertEventuallyChoosing(coordinator, url: queuedURL, candidates: [candidate], isOpening: false, errorMessage: nil)
        XCTAssertEqual(coordinator.activeURL, queuedURL)
        coordinator.cancelActiveURL()
        assertChoosing(coordinator, url: laterURL, candidates: [candidate], isOpening: false, errorMessage: nil)
        XCTAssertEqual(discovery.requestedURLs, [activeURL, activeURL, activeURL, queuedURL, laterURL])
    }

    func testResolvedRuleOpensDirectlyWithoutChooserUsingExactURLAndOriginalCandidateURL() {
        let incomingURLString = "HTTPS://Shop.Example.com./promo/a%2Fb?first=one%20two#section"
        let incomingURL = URL(string: incomingURLString)!
        let matchedCandidate = makeCandidate(
            url: URL(fileURLWithPath: "/Applications/Chosen Browser.app"),
            name: "Renamed Browser"
        )
        let otherCandidate = makeCandidate(
            url: URL(fileURLWithPath: "/Applications/Other Browser.app"),
            name: "Other"
        )
        let discovery = FakeDiscovery(results: [incomingURL: [otherCandidate, matchedCandidate]])
        let opener = RecordingOpener()
        let coordinator = routedCoordinator(
            discovery: discovery,
            opener: opener,
            rules: [makeRule(matchType: .urlPrefix, pattern: "https://shop.example.com/promo", target: matchedCandidate.bundleIdentifier!)]
        )

        coordinator.receiveIncomingURL(incomingURL)

        XCTAssertEqual(discovery.requestedURLs, [incomingURL])
        XCTAssertEqual(coordinator.activeURL, incomingURL)
        XCTAssertNil(choosingPresentationID(coordinator), "A direct opening must not present the chooser.")
        XCTAssertEqual(opener.requests.count, 1)
        XCTAssertEqual(opener.requests[0].url.absoluteString, incomingURLString)
        XCTAssertEqual(opener.requests[0].applicationURL, matchedCandidate.applicationURL)
    }

    func testNoMatchingRuleFallsBackToExistingChooserWithoutOpening() {
        let incomingURL = URL(string: "https://example.com/path")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = FakeDiscovery(results: [incomingURL: [candidate]])
        let opener = RecordingOpener()
        let coordinator = routedCoordinator(
            discovery: discovery,
            opener: opener,
            rules: [makeRule(matchType: .exactDomain, pattern: "unrelated.example", target: candidate.bundleIdentifier!)]
        )

        coordinator.receiveIncomingURL(incomingURL)

        assertChoosing(coordinator, url: incomingURL, candidates: [candidate], isOpening: false, errorMessage: nil)
        XCTAssertTrue(opener.requests.isEmpty)
    }

    func testUnavailableRuleTargetFallsBackToChooserAndLeavesProviderRulesUntouched() {
        let incomingURL = URL(string: "https://example.com/path")!
        let candidate = makeCandidate(name: "Available")
        let rule = makeRule(matchType: .exactDomain, pattern: "example.com", target: "com.example.removed")
        let ruleProvider = StaticRuleProvider(rules: [rule])
        let discovery = FakeDiscovery(results: [incomingURL: [candidate]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(
            discoveryService: discovery,
            openingService: opener,
            ruleProvider: ruleProvider,
            routingEvaluator: RoutingEvaluator(),
            candidateResolver: BrowserCandidateResolver()
        )

        coordinator.receiveIncomingURL(incomingURL)

        assertChoosing(coordinator, url: incomingURL, candidates: [candidate], isOpening: false, errorMessage: nil)
        XCTAssertTrue(opener.requests.isEmpty)
        XCTAssertEqual(ruleProvider.rules, [rule])
    }

    func testDirectOpeningFailureReturnsSameActiveURLAndCandidatesToActionableChooser() async {
        let incomingURL = URL(string: "https://example.com/path?query=value#fragment")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = FakeDiscovery(results: [incomingURL: [candidate]])
        let opener = RecordingOpener()
        let coordinator = routedCoordinator(
            discovery: discovery,
            opener: opener,
            rules: [makeRule(matchType: .exactDomain, pattern: "example.com", target: candidate.bundleIdentifier!)]
        )

        coordinator.receiveIncomingURL(incomingURL)
        XCTAssertNil(choosingPresentationID(coordinator))
        opener.completeFirst(with: .failure(TestError.openFailed))

        await assertEventuallyChoosing(
            coordinator,
            url: incomingURL,
            candidates: [candidate],
            isOpening: false,
            errorMessage: "The selected application could not open this link."
        )
        XCTAssertEqual(discovery.requestedURLs, [incomingURL, incomingURL])
    }

    func testFailedDirectOpeningRediscoversNoCandidatesAndRetainsRule() async {
        let incomingURL = URL(string: "https://example.com/path?query=value#fragment")!
        let candidate = makeCandidate(name: "Browser")
        let rule = makeRule(matchType: .exactDomain, pattern: "example.com", target: candidate.bundleIdentifier!)
        let ruleProvider = StaticRuleProvider(rules: [rule])
        let discovery = RefreshingFakeDiscovery(snapshots: [incomingURL: [[candidate], []]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(
            discoveryService: discovery,
            openingService: opener,
            ruleProvider: ruleProvider,
            routingEvaluator: RoutingEvaluator(),
            candidateResolver: BrowserCandidateResolver()
        )

        coordinator.receiveIncomingURL(incomingURL)
        XCTAssertNil(choosingPresentationID(coordinator))
        opener.completeFirst(with: .failure(TestError.openFailed))

        await assertEventuallyNoCandidates(coordinator, url: incomingURL)
        XCTAssertEqual(discovery.requestedURLs, [incomingURL, incomingURL])
        XCTAssertEqual(ruleProvider.rules, [rule])
    }

    func testStaleCompletionAfterFailureAndRetryDoesNotReplaceCurrentOpening() async {
        let incomingURL = URL(string: "https://example.com/path")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = RefreshingFakeDiscovery(snapshots: [incomingURL: [[candidate], [candidate]]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(discoveryService: discovery, openingService: opener)

        coordinator.receiveIncomingURL(incomingURL)
        coordinator.select(candidate)
        let originalCompletion = opener.retainedCompletion(at: 0)
        originalCompletion.complete(.failure(TestError.openFailed))
        await assertEventuallyChoosing(
            coordinator,
            url: incomingURL,
            candidates: [candidate],
            isOpening: false,
            errorMessage: "The selected application could not open this link."
        )
        coordinator.select(candidate)

        originalCompletion.complete(.success(()))
        await Task.yield()
        await Task.yield()

        assertChoosing(coordinator, url: incomingURL, candidates: [candidate], isOpening: true, errorMessage: nil)
        opener.retainedCompletion(at: 1).complete(.success(()))
        await assertEventuallyIdle(coordinator)
    }

    func testDirectSuccessAdvancesFIFOAndArrivalsDuringOpeningRemainQueued() async {
        let directURL = URL(string: "https://example.com/direct")!
        let queuedURL = URL(string: "https://example.com/queued")!
        let laterURL = URL(string: "https://example.com/later")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = FakeDiscovery(results: [
            directURL: [candidate],
            queuedURL: [candidate],
            laterURL: [candidate],
        ])
        let opener = RecordingOpener()
        let coordinator = routedCoordinator(
            discovery: discovery,
            opener: opener,
            rules: [makeRule(matchType: .urlPrefix, pattern: "https://example.com/direct", target: candidate.bundleIdentifier!)]
        )

        coordinator.receiveIncomingURL(directURL)
        coordinator.receiveIncomingURL(queuedURL)
        coordinator.receiveIncomingURL(laterURL)

        XCTAssertEqual(coordinator.activeURL, directURL)
        XCTAssertEqual(discovery.requestedURLs, [directURL])
        XCTAssertEqual(opener.requests.count, 1)
        coordinator.cancelActiveURL()
        XCTAssertEqual(coordinator.activeURL, directURL, "Cancellation during direct opening must be ignored.")
        opener.completeFirst(with: .success(()))

        await assertEventuallyChoosing(coordinator, url: queuedURL, candidates: [candidate], isOpening: false, errorMessage: nil)
        XCTAssertEqual(discovery.requestedURLs, [directURL, queuedURL])
        coordinator.cancelActiveURL()
        XCTAssertEqual(coordinator.activeURL, laterURL)
        XCTAssertEqual(discovery.requestedURLs, [directURL, queuedURL, laterURL])
    }

    func testIdenticalQueuedChooserURLsAfterDirectOpeningReceiveDistinctPresentations() async {
        let directURL = URL(string: "https://example.com/direct")!
        let repeatedChooserURL = URL(string: "https://example.com/chooser")!
        let candidate = makeCandidate(name: "Browser")
        let discovery = FakeDiscovery(results: [directURL: [candidate], repeatedChooserURL: [candidate]])
        let opener = RecordingOpener()
        let coordinator = routedCoordinator(
            discovery: discovery,
            opener: opener,
            rules: [makeRule(matchType: .urlPrefix, pattern: "https://example.com/direct", target: candidate.bundleIdentifier!)]
        )

        coordinator.receiveIncomingURL(directURL)
        coordinator.receiveIncomingURL(repeatedChooserURL)
        coordinator.receiveIncomingURL(repeatedChooserURL)
        opener.completeFirst(with: .success(()))

        await assertEventuallyChoosing(coordinator, url: repeatedChooserURL, candidates: [candidate], isOpening: false, errorMessage: nil)
        let firstPresentationID = try! XCTUnwrap(choosingPresentationID(coordinator))
        coordinator.cancelActiveURL()
        let secondPresentationID = try! XCTUnwrap(choosingPresentationID(coordinator))

        XCTAssertEqual(coordinator.activeURL, repeatedChooserURL)
        XCTAssertNotEqual(firstPresentationID, secondPresentationID)
    }

    func testSavedBrowserOrderControlsChooserDisplayAndSecondShortcutPosition() {
        let incomingURL = URL(string: "https://example.com/ordered")!
        let first = makeCandidate(url: URL(fileURLWithPath: "/Applications/First.app"), name: "First")
        let second = makeCandidate(url: URL(fileURLWithPath: "/Applications/Second.app"), name: "Second")
        let third = makeCandidate(url: URL(fileURLWithPath: "/Applications/Third.app"), name: "Third")
        let discovery = FakeDiscovery(results: [incomingURL: [second, third, first]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(
            discoveryService: discovery,
            openingService: opener,
            browserOrderStore: StaticBrowserOrderStore(browserOrder: [
                "bundle:example.third", "bundle:example.first",
            ])
        )

        coordinator.receiveIncomingURL(incomingURL)

        // ChooserView assigns shortcut 2 to this second displayed candidate.
        assertChoosing(coordinator, url: incomingURL, candidates: [third, first, second], isOpening: false, errorMessage: nil)
        coordinator.select(first)
        XCTAssertEqual(opener.requests.first?.applicationURL, first.applicationURL)
    }

    func testDisabledBrowserIsRemovedFromOrderedChooserAndShortcutsFollowVisibleCandidates() {
        let incomingURL = URL(string: "https://example.com/filtered")!
        let first = makeCandidate(url: URL(fileURLWithPath: "/Applications/First.app"), name: "First")
        let second = makeCandidate(url: URL(fileURLWithPath: "/Applications/Second.app"), name: "Second")
        let third = makeCandidate(url: URL(fileURLWithPath: "/Applications/Third.app"), name: "Third")
        let discovery = FakeDiscovery(results: [incomingURL: [second, third, first]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(
            discoveryService: discovery,
            openingService: opener,
            browserOrderStore: StaticBrowserOrderStore(
                browserOrder: ["bundle:example.third", "bundle:example.first", "bundle:example.second"],
                disabledBrowserIdentifiers: ["bundle:example.third"]
            )
        )

        coordinator.receiveIncomingURL(incomingURL)

        // ChooserView enumerates this filtered list, so First owns shortcut 1 and Second owns shortcut 2.
        assertChoosing(coordinator, url: incomingURL, candidates: [first, second], isOpening: false, errorMessage: nil)
        coordinator.select(second)
        XCTAssertEqual(opener.requests.first?.applicationURL, second.applicationURL)
    }

    func testRuleTargetDisabledByItsExactCandidateIdentityFallsBackToFilteredChooserWithoutSubstitution() {
        let incomingURL = URL(string: "https://example.com/disabled-rule-target")!
        let discoveryFirst = makeCandidate(
            url: URL(fileURLWithPath: "/Applications/Browser A.app"),
            name: "Browser A",
            bundleIdentifier: "com.example.shared"
        )
        let otherCopy = makeCandidate(
            url: URL(fileURLWithPath: "/Volumes/External/Browser B.app"),
            name: "Browser B",
            bundleIdentifier: "com.example.shared"
        )
        let rule = makeRule(matchType: .exactDomain, pattern: "example.com", target: "com.example.shared")
        let ruleProvider = StaticRuleProvider(rules: [rule])
        let coordinator = SelectionCoordinator(
            discoveryService: FakeDiscovery(results: [incomingURL: [discoveryFirst, otherCopy]]),
            openingService: RecordingOpener(),
            ruleProvider: ruleProvider,
            routingEvaluator: RoutingEvaluator(),
            candidateResolver: BrowserCandidateResolver(),
            browserOrderStore: StaticBrowserOrderStore(
                browserOrder: nil,
                disabledBrowserIdentifiers: ["path:/Applications/Browser A.app"]
            )
        )

        coordinator.receiveIncomingURL(incomingURL)

        assertChoosing(coordinator, url: incomingURL, candidates: [otherCopy], isOpening: false, errorMessage: nil)
        XCTAssertEqual(ruleProvider.rules, [rule])
    }

    func testReenablingRuleTargetRestoresItsOriginalDirectOpeningBehavior() {
        let incomingURL = URL(string: "https://example.com/reenabled-rule-target")!
        let target = makeCandidate(name: "Target", bundleIdentifier: "com.example.target")
        let alternate = makeCandidate(
            url: URL(fileURLWithPath: "/Applications/Alternate.app"),
            name: "Alternate",
            bundleIdentifier: "com.example.alternate"
        )
        let rule = makeRule(matchType: .exactDomain, pattern: "example.com", target: "com.example.target")
        let visibilityStore = StaticBrowserOrderStore(
            browserOrder: nil,
            disabledBrowserIdentifiers: ["bundle:com.example.target"]
        )
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(
            discoveryService: FakeDiscovery(results: [incomingURL: [target, alternate]]),
            openingService: opener,
            ruleProvider: StaticRuleProvider(rules: [rule]),
            routingEvaluator: RoutingEvaluator(),
            candidateResolver: BrowserCandidateResolver(),
            browserOrderStore: visibilityStore
        )

        coordinator.receiveIncomingURL(incomingURL)
        assertChoosing(coordinator, url: incomingURL, candidates: [alternate], isOpening: false, errorMessage: nil)
        coordinator.cancelActiveURL()
        visibilityStore.disabledBrowserIdentifiers = []

        coordinator.receiveIncomingURL(incomingURL)

        XCTAssertNil(choosingPresentationID(coordinator))
        XCTAssertEqual(opener.requests.count, 1)
        XCTAssertEqual(opener.requests.first?.applicationURL, target.applicationURL)
    }

    func testAllDiscoveredCandidatesDisabledProducesNoCandidatesWithoutOpeningAnotherBrowser() {
        let incomingURL = URL(string: "https://example.com/no-enabled-candidates")!
        let first = makeCandidate(url: URL(fileURLWithPath: "/Applications/First.app"), name: "First")
        let second = makeCandidate(url: URL(fileURLWithPath: "/Applications/Second.app"), name: "Second")
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(
            discoveryService: FakeDiscovery(results: [incomingURL: [first, second]]),
            openingService: opener,
            browserOrderStore: StaticBrowserOrderStore(
                browserOrder: nil,
                disabledBrowserIdentifiers: ["bundle:example.first", "bundle:example.second"]
            )
        )

        coordinator.receiveIncomingURL(incomingURL)

        assertNoCandidates(coordinator, url: incomingURL)
        XCTAssertTrue(opener.requests.isEmpty)
    }

    func testMissingSavedBrowserDoesNotAppearUntilItReturnsToItsSavedChooserPosition() {
        let firstURL = URL(string: "https://example.com/missing")!
        let secondURL = URL(string: "https://example.com/reappearing")!
        let first = makeCandidate(url: URL(fileURLWithPath: "/Applications/First.app"), name: "First")
        let second = makeCandidate(url: URL(fileURLWithPath: "/Applications/Second.app"), name: "Second")
        let third = makeCandidate(url: URL(fileURLWithPath: "/Applications/Third.app"), name: "Third")
        let newlyDiscovered = makeCandidate(url: URL(fileURLWithPath: "/Applications/New.app"), name: "New")
        let discovery = FakeDiscovery(results: [
            firstURL: [second, newlyDiscovered, first],
            secondURL: [newlyDiscovered, second, third, first],
        ])
        let coordinator = SelectionCoordinator(
            discoveryService: discovery,
            openingService: RecordingOpener(),
            browserOrderStore: StaticBrowserOrderStore(browserOrder: [
                "bundle:example.third", "bundle:example.first", "bundle:example.second",
            ])
        )

        coordinator.receiveIncomingURL(firstURL)
        assertChoosing(coordinator, url: firstURL, candidates: [first, second, newlyDiscovered], isOpening: false, errorMessage: nil)
        coordinator.receiveIncomingURL(secondURL)
        coordinator.cancelActiveURL()

        assertChoosing(coordinator, url: secondURL, candidates: [third, first, second, newlyDiscovered], isOpening: false, errorMessage: nil)
    }

    func testDirectRuleWithDuplicateBundleCandidatesKeepsDiscoveryFirstTargetDespiteChooserOrder() {
        let incomingURL = URL(string: "https://example.com/direct")!
        let discoveryFirst = makeCandidate(
            url: URL(fileURLWithPath: "/Applications/Browser A.app"),
            name: "Browser A",
            bundleIdentifier: "com.example.shared"
        )
        let otherCopy = makeCandidate(
            url: URL(fileURLWithPath: "/Volumes/External/Browser B.app"),
            name: "Browser B",
            bundleIdentifier: "com.example.shared"
        )
        let discovery = FakeDiscovery(results: [incomingURL: [discoveryFirst, otherCopy]])
        let opener = RecordingOpener()
        let coordinator = SelectionCoordinator(
            discoveryService: discovery,
            openingService: opener,
            ruleProvider: StaticRuleProvider(rules: [
                makeRule(matchType: .exactDomain, pattern: "example.com", target: "com.example.shared"),
            ]),
            browserOrderStore: StaticBrowserOrderStore(browserOrder: [
                "path:/Volumes/External/Browser B.app",
                "path:/Applications/Browser A.app",
            ])
        )

        coordinator.receiveIncomingURL(incomingURL)

        XCTAssertNil(choosingPresentationID(coordinator))
        XCTAssertEqual(opener.requests.first?.applicationURL, discoveryFirst.applicationURL)
    }

    private func routedCoordinator(
        discovery: BrowserDiscoveryService,
        opener: BrowserOpeningService,
        rules: [RoutingRule]
    ) -> SelectionCoordinator {
        SelectionCoordinator(
            discoveryService: discovery,
            openingService: opener,
            ruleProvider: StaticRuleProvider(rules: rules),
            routingEvaluator: RoutingEvaluator(),
            candidateResolver: BrowserCandidateResolver()
        )
    }

    private func makeRule(
        matchType: RoutingRule.MatchType,
        pattern: String,
        target: String
    ) -> RoutingRule {
        RoutingRule(id: UUID(), matchType: matchType, pattern: pattern, browserBundleIdentifier: target)
    }

    private func makeCandidate(
        url: URL = URL(fileURLWithPath: "/Applications/Browser.app"),
        name: String,
        bundleIdentifier: String? = nil
    ) -> ApplicationCandidate {
        ApplicationCandidate(
            applicationURL: url,
            displayName: name,
            bundleIdentifier: bundleIdentifier ?? "example.\(name.lowercased())",
            icon: NSImage(size: NSSize(width: 16, height: 16))
        )
    }

    private func assertEventuallyIdle(
        _ coordinator: SelectionCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let stateUpdated = expectation(description: "coordinator becomes idle")
        let observer = Task { @MainActor in
            for _ in 0..<100 {
                if case .idle = coordinator.state {
                    stateUpdated.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        await fulfillment(of: [stateUpdated], timeout: 1)
        _ = await observer.value
        assertIdle(coordinator, file: file, line: line)
    }

    private func assertEventuallyChoosing(
        _ coordinator: SelectionCoordinator,
        url: URL,
        candidates: [ApplicationCandidate],
        isOpening: Bool,
        errorMessage: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let stateUpdated = expectation(description: "coordinator enters expected choosing state")
        let observer = Task { @MainActor in
            for _ in 0..<100 {
                if self.isChoosing(
                    coordinator,
                    url: url,
                    candidates: candidates,
                    isOpening: isOpening,
                    errorMessage: errorMessage
                ) {
                    stateUpdated.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        await fulfillment(of: [stateUpdated], timeout: 1)
        _ = await observer.value
        assertChoosing(
            coordinator,
            url: url,
            candidates: candidates,
            isOpening: isOpening,
            errorMessage: errorMessage,
            file: file,
            line: line
        )
    }

    private func assertEventuallyNoCandidates(
        _ coordinator: SelectionCoordinator,
        url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let stateUpdated = expectation(description: "coordinator enters no-candidates state")
        let observer = Task { @MainActor in
            for _ in 0..<100 {
                if case let .noCandidates(actualURL) = coordinator.state, actualURL == url {
                    stateUpdated.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        await fulfillment(of: [stateUpdated], timeout: 1)
        _ = await observer.value
        assertNoCandidates(coordinator, url: url, file: file, line: line)
    }

    private func isChoosing(
        _ coordinator: SelectionCoordinator,
        url: URL,
        candidates: [ApplicationCandidate],
        isOpening: Bool,
        errorMessage: String?
    ) -> Bool {
        guard case let .choosing(context) = coordinator.state else {
            return false
        }
        return context.url == url
            && context.candidates.map(\.applicationURL) == candidates.map(\.applicationURL)
            && context.isOpening == isOpening
            && context.errorMessage == errorMessage
    }

    private func choosingPresentationID(_ coordinator: SelectionCoordinator) -> UUID? {
        guard case let .choosing(context) = coordinator.state else {
            return nil
        }
        return context.presentationID
    }

    private func assertIdle(_ coordinator: SelectionCoordinator, file: StaticString = #filePath, line: UInt = #line) {
        guard case .idle = coordinator.state else {
            return XCTFail("Expected idle state, got \(coordinator.state)", file: file, line: line)
        }
    }

    private func assertNoCandidates(
        _ coordinator: SelectionCoordinator,
        url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .noCandidates(actualURL) = coordinator.state else {
            return XCTFail("Expected no-candidates state, got \(coordinator.state)", file: file, line: line)
        }
        XCTAssertEqual(actualURL, url, file: file, line: line)
    }

    private func assertChoosing(
        _ coordinator: SelectionCoordinator,
        url: URL,
        candidates: [ApplicationCandidate],
        isOpening: Bool,
        errorMessage: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .choosing(context) = coordinator.state else {
            return XCTFail("Expected choosing state, got \(coordinator.state)", file: file, line: line)
        }
        XCTAssertEqual(context.url, url, file: file, line: line)
        XCTAssertEqual(context.candidates.map(\.applicationURL), candidates.map(\.applicationURL), file: file, line: line)
        XCTAssertEqual(context.isOpening, isOpening, file: file, line: line)
        XCTAssertEqual(context.errorMessage, errorMessage, file: file, line: line)
    }
}

private final class FakeDiscovery: BrowserDiscoveryService {
    let results: [URL: [ApplicationCandidate]]
    private(set) var requestedURLs: [URL] = []

    init(results: [URL: [ApplicationCandidate]]) {
        self.results = results
    }

    func candidates(for url: URL) -> [ApplicationCandidate] {
        requestedURLs.append(url)
        return results[url] ?? []
    }
}

private final class RefreshingFakeDiscovery: BrowserDiscoveryService {
    private var snapshots: [URL: [[ApplicationCandidate]]]
    private(set) var requestedURLs: [URL] = []

    init(snapshots: [URL: [[ApplicationCandidate]]]) {
        self.snapshots = snapshots
    }

    func candidates(for url: URL) -> [ApplicationCandidate] {
        requestedURLs.append(url)
        guard var remainingSnapshots = snapshots[url], !remainingSnapshots.isEmpty else {
            return []
        }
        let snapshot = remainingSnapshots.removeFirst()
        snapshots[url] = remainingSnapshots
        return snapshot
    }
}

private final class StaticRuleProvider: RoutingRuleProviding {
    let rules: [RoutingRule]

    init(rules: [RoutingRule]) {
        self.rules = rules
    }
}

private final class StaticBrowserOrderStore: BrowserOrderStoring {
    let browserOrder: [String]?
    var disabledBrowserIdentifiers: Set<String>

    init(browserOrder: [String]?, disabledBrowserIdentifiers: Set<String> = []) {
        self.browserOrder = browserOrder
        self.disabledBrowserIdentifiers = disabledBrowserIdentifiers
    }

    func saveBrowserOrder(_ identifiers: [String]) throws {}

    func saveDisabledBrowserIdentifiers(_ identifiers: Set<String>) throws {
        disabledBrowserIdentifiers = identifiers
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

    func retainedCompletion(at index: Int) -> CompletionRelay {
        CompletionRelay(completion: completions[index])
    }

}

private final class CompletionRelay: @unchecked Sendable {
    private let completion: (Result<Void, Error>) -> Void

    init(completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
    }

    func complete(_ result: Result<Void, Error>) {
        completion(result)
    }
}

private enum TestError: Error {
    case openFailed
}
