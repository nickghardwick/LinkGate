import AppKit
import XCTest
@testable import LinkGate

// V1-A Tasks 5 and 6 acceptance mapping:
// - A visible Settings window refreshes the OS-authoritative login-item state when LinkGate
//   becomes active again after System Settings.
// - Closing Settings without Done hides setup for the rest of this process without persisting;
//   the same incomplete store requires setup in a later process.
@MainActor
final class FirstRunSetupTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LinkGateTests.FirstRunSetupTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testVisibleSettingsRefreshesEveryExternalLaunchAtLoginTransitionOnActivation() async {
        let launchService = SetupLaunchAtLoginService(status: .disabled)
        let setupStore = SetupCompletionStore(needsSetup: true)
        let model = makeModel(launchService: launchService, setupStore: setupStore)
        let controller = SettingsWindowController(model: model)
        controller.showWindow(nil)
        defer { controller.close() }

        XCTAssertEqual(model.launchAtLoginStatus, .disabled)

        launchService.statusToReturn = .enabled
        await activateApplicationAndWait()
        XCTAssertEqual(model.launchAtLoginStatus, .enabled)

        launchService.statusToReturn = .requiresApproval
        await activateApplicationAndWait()
        XCTAssertEqual(model.launchAtLoginStatus, .requiresApproval)

        launchService.statusToReturn = .disabled
        await activateApplicationAndWait()
        XCTAssertEqual(model.launchAtLoginStatus, .disabled)
        XCTAssertGreaterThanOrEqual(launchService.statusCallCount, 4)
    }

    func testClosingIncompleteSetupDismissesOnlyThisProcessAndDoesNotReopenOnActivation() async {
        let launchService = SetupLaunchAtLoginService(status: .disabled)
        let setupStore = SetupCompletionStore(needsSetup: true)
        let model = makeModel(launchService: launchService, setupStore: setupStore)
        let controller = SettingsWindowController(model: model)
        controller.showWindow(nil)
        await settleSettingsPresentation()

        XCTAssertTrue(model.setupIsIncomplete)
        XCTAssertTrue(controller.window?.isVisible == true)
        XCTAssertEqual(model.launchAtLoginStatus, .disabled)
        let statusQueriesBeforeClose = launchService.statusCallCount

        controller.close()
        launchService.statusToReturn = .enabled
        await activateApplicationAndWait()

        XCTAssertFalse(model.setupIsIncomplete)
        XCTAssertTrue(setupStore.markedVersions.isEmpty)
        XCTAssertFalse(controller.window?.isVisible == true)
        XCTAssertEqual(model.launchAtLoginStatus, .disabled)
        XCTAssertEqual(launchService.statusCallCount, statusQueriesBeforeClose)

        controller.showWindow(nil)
        await settleSettingsPresentation()
        XCTAssertTrue(controller.window?.isVisible == true)
        XCTAssertFalse(model.setupIsIncomplete)
        XCTAssertTrue(setupStore.markedVersions.isEmpty)

        let laterProcessModel = makeModel(launchService: launchService, setupStore: setupStore)
        XCTAssertTrue(laterProcessModel.setupIsIncomplete)
        controller.close()
    }

    private func makeModel(
        launchService: SetupLaunchAtLoginService,
        setupStore: SetupCompletionStore
    ) -> RoutingSettingsModel {
        RoutingSettingsModel(
            ruleStore: UserDefaultsRoutingRuleStore(
                userDefaults: defaults,
                storageKey: "LinkGateTests.firstRunSetup.\(suiteName!)"
            ),
            discoveryService: SetupBrowserDiscovery(),
            launchAtLoginService: launchService,
            setupStateStore: setupStore
        )
    }

    private func activateApplicationAndWait() async {
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    private func settleSettingsPresentation() async {
        for _ in 0..<10 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}

@MainActor
private final class SetupLaunchAtLoginService: LaunchAtLoginService {
    var statusToReturn: LaunchAtLoginStatus
    private(set) var statusCallCount = 0

    init(status: LaunchAtLoginStatus) {
        statusToReturn = status
    }

    var status: LaunchAtLoginStatus {
        statusCallCount += 1
        return statusToReturn
    }

    var canChangeRegistration: Bool { false }

    func enable() throws {
        XCTFail("Setup controller tests must not request login-item registration.")
    }

    func disable() throws {
        XCTFail("Setup controller tests must not request login-item unregistration.")
    }

    func openLoginItemsSettings() {
        XCTFail("Setup controller tests must not open System Settings.")
    }
}

private final class SetupCompletionStore: SetupStateStore {
    let needsSetupValue: Bool
    private(set) var markedVersions: [Int] = []

    init(needsSetup: Bool) {
        needsSetupValue = needsSetup
    }

    func needsSetup(currentVersion: Int) -> Bool {
        needsSetupValue
    }

    func markSetupCompleted(version: Int) throws {
        markedVersions.append(version)
    }
}

private final class SetupBrowserDiscovery: BrowserDiscoveryService {
    func candidates(for url: URL) -> [ApplicationCandidate] {
        []
    }
}
