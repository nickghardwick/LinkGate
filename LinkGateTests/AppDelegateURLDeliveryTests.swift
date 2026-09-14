import AppKit
import XCTest
@testable import LinkGate

// Acceptance Contract mapping
// A1: AppDelegate iterates every URL in one AppKit delivery array through IncomingURLHandler,
// forwards all accepted URLs unchanged and in order. Cold- and warm-running deliveries converge
// on the same SelectionCoordinator without replaying an arrival.
// A2: Manual cold launch/reopen presents Settings only while idle; URL delivery and active URL work
// never present unrelated Settings windows, and closing all windows does not terminate the utility.
// A3: URL receipt itself does not activate LinkGate. The chooser owns activation when user input
// is needed, so an automatic route remains unobtrusive.
// A4: Lifecycle notifications and incoming URLs never initiate an update check. The only update
// command is the user-invoked status-menu command.
// A5: The production AppDelegate invokes pending default-handler restoration at launch through a
// narrow capability. Restoration is independent of manual update checking and URL delivery.
// Required natural AppDelegate composition initializer:
// @MainActor init(
//     selectionCoordinator: SelectionCoordinator,
//     incomingURLHandler: IncomingURLHandler,
//     chooserPanelController: ChooserPanelController,
//     updateChecking: any UpdateChecking,
//     handlerPreservationRestoring: (any HandlerPreservationRestoring)?
// )
@MainActor
final class AppDelegateURLDeliveryTests: XCTestCase {
    func testDeliversEveryAcceptedURLFromOneAppKitEventInOrder() {
        let destination = RecordingDestination()
        let handler = IncomingURLHandler(destination: destination)
        let delegate = makeDelegate(handler: handler)
        let firstAccepted = URL(string: "HTTP://example.com/first")!
        let secondAccepted = URL(string: "https://example.com/a%20path?first=one&second=two#fragment")!
        let thirdAccepted = URL(string: "hTtPs://example.com/third")!
        let deliveredURLs = [
            URL(string: "mailto:person@example.com")!,
            firstAccepted,
            URL(string: "ftp://example.com/file.txt")!,
            secondAccepted,
            thirdAccepted,
        ]

        delegate.application(NSApplication.shared, open: deliveredURLs)

        XCTAssertEqual(destination.receivedURLs, [firstAccepted, secondAccepted, thirdAccepted])
        XCTAssertEqual(destination.receivedURLs[1].absoluteString, secondAccepted.absoluteString)
    }

    func testRejectsUnsupportedURLsFromOneAppKitEvent() {
        let destination = RecordingDestination()
        let handler = IncomingURLHandler(destination: destination)
        let delegate = makeDelegate(handler: handler)
        let deliveredURLs = [
            URL(string: "mailto:person@example.com")!,
            URL(string: "ftp://example.com/file.txt")!,
            URL(string: "linkgate-test://example.com/item")!,
        ]

        delegate.application(NSApplication.shared, open: deliveredURLs)

        XCTAssertTrue(destination.receivedURLs.isEmpty)
    }

    func testColdAndWarmDeliveriesEnterTheSameCoordinatorExactlyOnceInFIFOOrder() {
        let firstURL = URL(string: "HTTP://example.com/cold?arrival=one")!
        let repeatedURL = URL(string: "https://example.com/warm?arrival=two")!
        let candidate = makeCandidate(bundleIdentifier: "com.example.browser")
        let discovery = RecordingDiscovery(candidates: [candidate])
        let coordinator = SelectionCoordinator(
            discoveryService: discovery,
            openingService: UnusedOpeningService()
        )
        let delegate = makeDelegate(
            coordinator: coordinator,
            handler: IncomingURLHandler(destination: coordinator)
        )

        // AppKit launch notification delivery may precede the first URL arrival. Repeating it
        // must not replace the coordinator or replay any future arrival.
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.application(NSApplication.shared, open: [firstURL, repeatedURL])
        delegate.application(NSApplication.shared, open: [repeatedURL])

        XCTAssertEqual(discovery.requestedURLs, [firstURL])
        assertChoosing(coordinator, url: firstURL)

        coordinator.cancelActiveURL()
        XCTAssertEqual(discovery.requestedURLs, [firstURL, repeatedURL])
        let firstRepeatedPresentationID = choosingPresentationID(coordinator)
        assertChoosing(coordinator, url: repeatedURL)

        coordinator.cancelActiveURL()
        XCTAssertEqual(discovery.requestedURLs, [firstURL, repeatedURL, repeatedURL])
        XCTAssertNotEqual(firstRepeatedPresentationID, choosingPresentationID(coordinator))
        assertChoosing(coordinator, url: repeatedURL)

        coordinator.cancelActiveURL()
        XCTAssertNil(coordinator.activeURL)
    }

    func testColdAndWarmAutomaticDeliveriesUseTheSameDirectRoutingPathExactlyOnce() async {
        let firstURL = URL(string: "https://example.com/cold/path?one=1#first")!
        let secondURL = URL(string: "https://example.com/warm/path?two=2#second")!
        let candidate = makeCandidate(bundleIdentifier: "com.example.browser")
        let discovery = RecordingDiscovery(candidates: [candidate])
        let opener = RetainingOpeningService()
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
        let delegate = makeDelegate(
            coordinator: coordinator,
            handler: IncomingURLHandler(destination: coordinator)
        )

        delegate.application(NSApplication.shared, open: [firstURL])
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.application(NSApplication.shared, open: [secondURL])

        XCTAssertEqual(opener.requests.map(\.url), [firstURL])
        XCTAssertEqual(opener.requests.map(\.applicationURL), [candidate.applicationURL])
        opener.completeFirst(with: .success(()))
        await assertEventuallyOpeningDirectly(coordinator, url: secondURL)
        XCTAssertEqual(opener.requests.map(\.url), [firstURL, secondURL])
        XCTAssertEqual(discovery.requestedURLs, [firstURL, secondURL])

        opener.completeFirst(with: .success(()))
        await assertEventuallyIdle(coordinator)
    }

    // V1-A Task 5: incomplete versioned setup is presented once only after the
    // ordinary launch infrastructure has been initialized. A repeated AppKit launch
    // notification is not a second onboarding presentation.
    func testLaunchPresentsIncompleteSetupOnceAndStillRestoresInfrastructure() {
        let setupStore = AppDelegateSetupStateStore(needsSetup: true)
        let restorer = HandlerPreservationRestoreRecorder()
        var settingsPresentationCount = 0
        let delegate = makeDelegate(
            settingsPresenter: { settingsPresentationCount += 1 },
            handlerPreservationRestoring: restorer,
            setupStateStore: setupStore
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(restorer.restoreCallCount, 1)
        XCTAssertEqual(setupStore.needsSetupCallVersions, [1])
        XCTAssertEqual(settingsPresentationCount, 1)
        XCTAssertTrue(setupStore.markedVersions.isEmpty)
    }

    // V1-A Task 5 migration: an existing preferences domain without the independent
    // completion marker is still setup-incomplete; a completed marker suppresses only
    // automatic setup on that later process launch.
    func testLaunchPresentsMarkerlessSetupButNotCompletedSetupOnLaterProcess() {
        let markerlessStore = AppDelegateSetupStateStore(needsSetup: true)
        var markerlessPresentations = 0
        let firstProcess = makeDelegate(
            settingsPresenter: { markerlessPresentations += 1 },
            setupStateStore: markerlessStore
        )
        firstProcess.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let completedStore = AppDelegateSetupStateStore(needsSetup: false)
        var completedPresentations = 0
        let laterProcess = makeDelegate(
            settingsPresenter: { completedPresentations += 1 },
            setupStateStore: completedStore
        )
        laterProcess.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(markerlessPresentations, 1)
        XCTAssertEqual(completedPresentations, 0)
        XCTAssertTrue(markerlessStore.markedVersions.isEmpty)
        XCTAssertTrue(completedStore.markedVersions.isEmpty)
    }

    // V1-A Task 5 regression: opening Settings for setup must not intercept or
    // rewrite an incoming HTTP(S) link delivered while Settings is visible.
    func testIncomingURLDeliveryRemainsFunctionalWhileIncompleteSetupIsPresented() {
        let destination = RecordingDestination()
        let incomingURL = URL(string: "https://example.com/path%20with%20encoding?x=1#fragment")!
        var settingsPresentationCount = 0
        let delegate = makeDelegate(
            handler: IncomingURLHandler(destination: destination),
            settingsPresenter: { settingsPresentationCount += 1 },
            setupStateStore: AppDelegateSetupStateStore(needsSetup: true)
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.application(NSApplication.shared, open: [incomingURL])

        XCTAssertEqual(settingsPresentationCount, 1)
        XCTAssertEqual(destination.receivedURLs, [incomingURL])
        XCTAssertEqual(destination.receivedURLs.first?.absoluteString, incomingURL.absoluteString)
    }

    func testManualUntitledOpenAndReopenWhileIdlePresentSettingsAndSuppressUntitledWindows() {
        var settingsPresentationCount = 0
        let delegate = makeDelegate(settingsPresenter: { settingsPresentationCount += 1 })

        XCTAssertFalse(delegate.applicationShouldOpenUntitledFile(NSApplication.shared))
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))

        XCTAssertEqual(settingsPresentationCount, 3)
    }

    func testURLDeliveryNeverPresentsSettings() {
        var settingsPresentationCount = 0
        let delegate = makeDelegate(settingsPresenter: { settingsPresentationCount += 1 })

        delegate.application(NSApplication.shared, open: [URL(string: "https://example.com/path")!])

        XCTAssertEqual(settingsPresentationCount, 0)
    }

    func testRepeatedLifecycleNotificationsNeverInitiateAnUpdateCheck() {
        let updateChecker = UpdateCheckRecorder(canCheckForUpdates: true)
        let delegate = makeDelegate(updateChecker: updateChecker)

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(updateChecker.checkCount, 0)
    }

    func testLaunchRestoresPendingHandlersWithoutInitiatingAnUpdateCheck() {
        let updateChecker = UpdateCheckRecorder(canCheckForUpdates: true)
        let handlerRestorer = HandlerPreservationRestoreRecorder()
        let delegate = makeDelegate(
            updateChecker: updateChecker,
            handlerPreservationRestoring: handlerRestorer
        )

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(handlerRestorer.restoreCallCount, 1)
        XCTAssertEqual(updateChecker.checkCount, 0)
    }

    func testLaunchRestorationIsOneShotAndDoesNotBlockIncomingURLDelivery() {
        let destination = RecordingDestination()
        let handler = IncomingURLHandler(destination: destination)
        let updateChecker = UpdateCheckRecorder(canCheckForUpdates: true)
        let handlerRestorer = HandlerPreservationRestoreRecorder()
        let delegate = makeDelegate(
            handler: handler,
            updateChecker: updateChecker,
            handlerPreservationRestoring: handlerRestorer
        )
        let incomingURL = URL(string: "https://example.com/during-restoration?arrival=one")!

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.application(NSApplication.shared, open: [incomingURL])

        XCTAssertEqual(handlerRestorer.restoreCallCount, 1)
        XCTAssertEqual(updateChecker.checkCount, 0)
        XCTAssertEqual(destination.receivedURLs, [incomingURL])
    }

    func testURLDeliveryNeverInitiatesAnUpdateCheck() {
        let updateChecker = UpdateCheckRecorder(canCheckForUpdates: true)
        let delegate = makeDelegate(updateChecker: updateChecker)

        delegate.application(NSApplication.shared, open: [URL(string: "https://example.com/path")!])

        XCTAssertEqual(updateChecker.checkCount, 0)
    }

    func testManualOpenAndReopenDoNotDisplaceChoosingRequest() {
        let candidate = makeCandidate(bundleIdentifier: "com.example.browser")
        let discovery = FixedDiscovery(candidates: [candidate])
        let coordinator = SelectionCoordinator(
            discoveryService: discovery,
            openingService: UnusedOpeningService()
        )
        var settingsPresentationCount = 0
        let delegate = makeDelegate(
            coordinator: coordinator,
            handler: IncomingURLHandler(destination: coordinator),
            settingsPresenter: { settingsPresentationCount += 1 }
        )
        let incomingURL = URL(string: "https://example.com/choosing")!
        coordinator.receiveIncomingURL(incomingURL)

        XCTAssertFalse(delegate.applicationShouldOpenUntitledFile(NSApplication.shared))
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))

        XCTAssertEqual(settingsPresentationCount, 0)
        assertChoosing(coordinator, url: incomingURL)
    }

    func testManualOpenAndReopenDoNotDisplaceOpeningOrNoCandidateRequests() {
        let candidate = makeCandidate(bundleIdentifier: "com.example.browser")
        let openingService = RetainingOpeningService()
        let openingURL = URL(string: "https://example.com/opening")!
        let openingCoordinator = SelectionCoordinator(
            discoveryService: FixedDiscovery(candidates: [candidate]),
            openingService: openingService,
            ruleProvider: FixedRuleProvider(rules: [
                RoutingRule(
                    id: UUID(),
                    matchType: .exactDomain,
                    pattern: "example.com",
                    browserBundleIdentifier: "com.example.browser"
                )
            ])
        )
        var openingSettingsPresentationCount = 0
        let openingDelegate = makeDelegate(
            coordinator: openingCoordinator,
            handler: IncomingURLHandler(destination: openingCoordinator),
            settingsPresenter: { openingSettingsPresentationCount += 1 }
        )
        openingCoordinator.receiveIncomingURL(openingURL)

        XCTAssertFalse(openingDelegate.applicationShouldOpenUntitledFile(NSApplication.shared))
        XCTAssertFalse(openingDelegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(openingSettingsPresentationCount, 0)
        assertOpeningDirectly(openingCoordinator, url: openingURL)

        let noCandidateURL = URL(string: "https://example.com/no-candidates")!
        let noCandidateCoordinator = SelectionCoordinator(
            discoveryService: EmptyDiscoveryService(),
            openingService: UnusedOpeningService()
        )
        var noCandidateSettingsPresentationCount = 0
        let noCandidateDelegate = makeDelegate(
            coordinator: noCandidateCoordinator,
            handler: IncomingURLHandler(destination: noCandidateCoordinator),
            settingsPresenter: { noCandidateSettingsPresentationCount += 1 }
        )
        noCandidateCoordinator.receiveIncomingURL(noCandidateURL)

        XCTAssertFalse(noCandidateDelegate.applicationShouldOpenUntitledFile(NSApplication.shared))
        XCTAssertFalse(noCandidateDelegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(noCandidateSettingsPresentationCount, 0)
        assertNoCandidates(noCandidateCoordinator, url: noCandidateURL)
    }

    func testApplicationStaysRunningAfterLastWindowCloses() {
        let delegate = makeDelegate()

        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    private func makeDelegate(
        coordinator: SelectionCoordinator? = nil,
        handler: IncomingURLHandler,
        settingsPresenter: (() -> Void)? = nil,
        updateChecker: (any UpdateChecking)? = nil,
        handlerPreservationRestoring: (any HandlerPreservationRestoring)? = nil,
        setupStateStore: (any SetupStateStore)? = nil
    ) -> AppDelegate {
        let coordinator = coordinator ?? SelectionCoordinator(
            discoveryService: EmptyDiscoveryService(),
            openingService: UnusedOpeningService()
        )
        let panelController = ChooserPanelController(
            coordinator: coordinator,
            applicationActivator: { _ in }
        )
        let updateChecking = updateChecker ?? UpdateCheckRecorder(canCheckForUpdates: true)
        return AppDelegate(
            selectionCoordinator: coordinator,
            incomingURLHandler: handler,
            chooserPanelController: panelController,
            settingsPresenter: settingsPresenter,
            updateChecking: updateChecking,
            handlerPreservationRestoring: handlerPreservationRestoring,
            setupStateStore: setupStateStore
        )
    }

    private func makeDelegate(
        settingsPresenter: @escaping () -> Void,
        updateChecker: (any UpdateChecking)? = nil,
        handlerPreservationRestoring: (any HandlerPreservationRestoring)? = nil,
        setupStateStore: (any SetupStateStore)? = nil
    ) -> AppDelegate {
        let coordinator = SelectionCoordinator(
            discoveryService: EmptyDiscoveryService(),
            openingService: UnusedOpeningService()
        )
        return makeDelegate(
            coordinator: coordinator,
            handler: IncomingURLHandler(destination: coordinator),
            settingsPresenter: settingsPresenter,
            updateChecker: updateChecker,
            handlerPreservationRestoring: handlerPreservationRestoring,
            setupStateStore: setupStateStore
        )
    }

    private func makeDelegate(
        updateChecker: any UpdateChecking,
        handlerPreservationRestoring: (any HandlerPreservationRestoring)? = nil
    ) -> AppDelegate {
        makeDelegate(
            settingsPresenter: {},
            updateChecker: updateChecker,
            handlerPreservationRestoring: handlerPreservationRestoring
        )
    }

    private func makeDelegate() -> AppDelegate {
        makeDelegate(settingsPresenter: {})
    }

    private func makeCandidate(bundleIdentifier: String) -> ApplicationCandidate {
        ApplicationCandidate(
            applicationURL: URL(fileURLWithPath: "/Applications/Browser.app"),
            displayName: "Browser",
            bundleIdentifier: bundleIdentifier,
            icon: NSImage(size: NSSize(width: 16, height: 16))
        )
    }

    private func assertChoosing(_ coordinator: SelectionCoordinator, url: URL, file: StaticString = #filePath, line: UInt = #line) {
        guard case let .choosing(context) = coordinator.state else {
            return XCTFail("Expected choosing state, got \(coordinator.state)", file: file, line: line)
        }
        XCTAssertEqual(context.url, url, file: file, line: line)
        XCTAssertFalse(context.isOpening, file: file, line: line)
    }

    private func assertOpeningDirectly(_ coordinator: SelectionCoordinator, url: URL, file: StaticString = #filePath, line: UInt = #line) {
        guard case let .openingDirectly(context) = coordinator.state else {
            return XCTFail("Expected opening-directly state, got \(coordinator.state)", file: file, line: line)
        }
        XCTAssertEqual(context.url, url, file: file, line: line)
        XCTAssertTrue(context.isOpening, file: file, line: line)
    }

    private func assertNoCandidates(_ coordinator: SelectionCoordinator, url: URL, file: StaticString = #filePath, line: UInt = #line) {
        guard case let .noCandidates(actualURL) = coordinator.state else {
            return XCTFail("Expected no-candidates state, got \(coordinator.state)", file: file, line: line)
        }
        XCTAssertEqual(actualURL, url, file: file, line: line)
    }

    private func assertEventuallyOpeningDirectly(_ coordinator: SelectionCoordinator, url: URL) async {
        let reachedState = expectation(description: "coordinator opens queued automatic route")
        let observer = Task { @MainActor in
            for _ in 0..<100 {
                if case let .openingDirectly(context) = coordinator.state, context.url == url {
                    reachedState.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        await fulfillment(of: [reachedState], timeout: 1)
        _ = await observer.value
    }

    private func assertEventuallyIdle(_ coordinator: SelectionCoordinator) async {
        let reachedState = expectation(description: "coordinator becomes idle")
        let observer = Task { @MainActor in
            for _ in 0..<100 {
                if case .idle = coordinator.state {
                    reachedState.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        await fulfillment(of: [reachedState], timeout: 1)
        _ = await observer.value
    }

    private func choosingPresentationID(_ coordinator: SelectionCoordinator) -> UUID? {
        guard case let .choosing(context) = coordinator.state else {
            return nil
        }
        return context.presentationID
    }
}

@MainActor
private final class UpdateCheckRecorder: UpdateChecking {
    var canCheckForUpdates: Bool
    private(set) var checkCount = 0

    init(canCheckForUpdates: Bool) {
        self.canCheckForUpdates = canCheckForUpdates
    }

    func checkForUpdates() {
        checkCount += 1
    }
}

@MainActor
private final class HandlerPreservationRestoreRecorder: HandlerPreservationRestoring {
    private(set) var restoreCallCount = 0

    func restorePreservedHandlersIfNeeded() {
        restoreCallCount += 1
    }
}

private final class AppDelegateSetupStateStore: SetupStateStore {
    let needsSetupValue: Bool
    private(set) var needsSetupCallVersions: [Int] = []
    private(set) var markedVersions: [Int] = []

    init(needsSetup: Bool) {
        needsSetupValue = needsSetup
    }

    func needsSetup(currentVersion: Int) -> Bool {
        needsSetupCallVersions.append(currentVersion)
        return needsSetupValue
    }

    func markSetupCompleted(version: Int) throws {
        markedVersions.append(version)
    }
}

private final class RecordingDestination: IncomingURLReceiving {
    private(set) var receivedURLs: [URL] = []

    func receiveIncomingURL(_ url: URL) {
        receivedURLs.append(url)
    }
}

private final class EmptyDiscoveryService: BrowserDiscoveryService {
    func candidates(for url: URL) -> [ApplicationCandidate] {
        return []
    }
}

private final class UnusedOpeningService: BrowserOpeningService {
    func open(
        _ url: URL,
        withApplicationAt applicationURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        XCTFail("URL delivery tests must not invoke browser opening.")
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

private final class RecordingDiscovery: BrowserDiscoveryService {
    let candidatesToReturn: [ApplicationCandidate]
    private(set) var requestedURLs: [URL] = []

    init(candidates: [ApplicationCandidate]) {
        candidatesToReturn = candidates
    }

    func candidates(for url: URL) -> [ApplicationCandidate] {
        requestedURLs.append(url)
        return candidatesToReturn
    }
}

private final class RetainingOpeningService: BrowserOpeningService {
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

private final class FixedRuleProvider: RoutingRuleProviding {
    let rules: [RoutingRule]

    init(rules: [RoutingRule]) {
        self.rules = rules
    }
}
