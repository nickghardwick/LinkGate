import AppKit
import XCTest
@testable import LinkGate

// Acceptance Contract mapping:
// A5: settings inventory reflects current discovery; rules keep stable target IDs and report absent
// targets safely; default-browser status/request behavior is observable without system mutation.
// A6: settings surfaces known storage errors meaningfully and sanitizes arbitrary storage errors.
// Existing routing-rule behavior: save surfaces canonical-store validation/conflict failures instead of
// silently overwriting; browser choices exclude nil/empty IDs and coalesce duplicate IDs by first order.
// Browser ordering acceptance contract: Settings displays the saved global order, native moves persist it,
// newly discovered browsers append, and unavailable identities remain saved for a later reappearance.
// Browser visibility acceptance contract: Settings retains disabled browsers and their saved ordering metadata,
// while rule choices expose only enabled discovered browsers and cannot disable the final usable choice.
@MainActor
final class RoutingSettingsModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LinkGateTests.RoutingSettingsModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testListsStoreRulesInOrderAndRefreshesWithRepresentativeHTTPSURL() throws {
        let store = makeStore()
        let first = try store.create(matchType: .exactDomain, pattern: "first.example", browserBundleIdentifier: "com.example.first")
        let second = try store.create(matchType: .domainFamily, pattern: "second.example", browserBundleIdentifier: "com.example.second")
        let discovery = SettingsFakeDiscovery(results: [])
        let model = RoutingSettingsModel(ruleStore: store, discoveryService: discovery)

        model.refresh()

        XCTAssertEqual(model.rules.map(\.id), [first.id, second.id])
        XCTAssertEqual(discovery.requestedURLs.count, 1)
        XCTAssertEqual(discovery.requestedURLs.first?.scheme?.lowercased(), "https")
    }

    func testRefreshOffersOnlyFirstCandidateForEachNonemptyBundleIdentifier() {
        let first = makeCandidate(url: "/Applications/First.app", name: "First", bundleIdentifier: "com.example.shared")
        let duplicate = makeCandidate(url: "/Applications/Second.app", name: "Second", bundleIdentifier: "com.example.shared")
        let nilIdentifier = makeCandidate(url: "/Applications/Nil.app", name: "Nil", bundleIdentifier: nil)
        let emptyIdentifier = makeCandidate(url: "/Applications/Empty.app", name: "Empty", bundleIdentifier: "")
        let distinct = makeCandidate(url: "/Applications/Distinct.app", name: "Distinct", bundleIdentifier: "com.example.distinct")
        let discovery = SettingsFakeDiscovery(results: [first, duplicate, nilIdentifier, emptyIdentifier, distinct])
        let model = RoutingSettingsModel(ruleStore: makeStore(), discoveryService: discovery)

        model.refresh()

        XCTAssertEqual(model.browserChoices.map(\.applicationURL), [first.applicationURL, distinct.applicationURL])
        XCTAssertEqual(model.browserChoices.map(\.bundleIdentifier), ["com.example.shared", "com.example.distinct"])
    }

    func testRefreshExposesFullDetectedInventoryWhileKeepingValidRuleChoicesDistinct() {
        let first = makeCandidate(url: "/Applications/First.app", name: "First", bundleIdentifier: "com.example.shared")
        let duplicate = makeCandidate(url: "/Applications/Second.app", name: "Second", bundleIdentifier: "com.example.shared")
        let missingIdentifier = makeCandidate(url: "/Applications/Missing.app", name: "Missing", bundleIdentifier: nil)
        let emptyIdentifier = makeCandidate(url: "/Applications/Empty.app", name: "Empty", bundleIdentifier: "")
        let discovery = SettingsFakeDiscovery(results: [first, duplicate, missingIdentifier, emptyIdentifier])
        let model = RoutingSettingsModel(ruleStore: makeStore(), discoveryService: discovery)

        model.refresh()

        XCTAssertEqual(model.detectedBrowsers.map(\.applicationURL), [
            first.applicationURL,
            duplicate.applicationURL,
            missingIdentifier.applicationURL,
            emptyIdentifier.applicationURL,
        ])
        XCTAssertEqual(model.browserChoices.map(\.applicationURL), [first.applicationURL])
    }

    func testMoveBrowsersPersistsGlobalOrderAndReappearingBrowserReturnsToItsSavedPosition() {
        let first = makeCandidate(url: "/Applications/First.app", name: "First", bundleIdentifier: "com.example.first")
        let second = makeCandidate(url: "/Applications/Second.app", name: "Second", bundleIdentifier: "com.example.second")
        let third = makeCandidate(url: "/Applications/Third.app", name: "Third", bundleIdentifier: "com.example.third")
        let newlyDiscovered = makeCandidate(url: "/Applications/New.app", name: "New", bundleIdentifier: "com.example.new")
        let discovery = MutableSettingsDiscovery(results: [first, second, third])
        let store = makeStore()
        let model = RoutingSettingsModel(ruleStore: store, discoveryService: discovery)

        model.refresh()
        XCTAssertTrue(model.moveBrowsers(from: IndexSet(integer: 2), to: 0))
        XCTAssertEqual(model.detectedBrowsers.map(\.bundleIdentifier), [
            "com.example.third", "com.example.first", "com.example.second",
        ])
        XCTAssertEqual(store.browserOrder, [
            "bundle:com.example.third", "bundle:com.example.first", "bundle:com.example.second",
        ])

        discovery.results = [second, newlyDiscovered, first]
        model.refresh()
        XCTAssertEqual(model.detectedBrowsers.map(\.bundleIdentifier), [
            "com.example.first", "com.example.second", "com.example.new",
        ])
        XCTAssertEqual(Array(store.browserOrder?.prefix(3) ?? []), [
            "bundle:com.example.third", "bundle:com.example.first", "bundle:com.example.second",
        ])

        discovery.results = [newlyDiscovered, first, third, second]
        let reloadedModel = RoutingSettingsModel(ruleStore: makeStore(), discoveryService: discovery)
        reloadedModel.refresh()
        XCTAssertEqual(reloadedModel.detectedBrowsers.map(\.bundleIdentifier), [
            "com.example.third", "com.example.first", "com.example.second", "com.example.new",
        ])
        XCTAssertEqual(makeStore().browserOrder, [
            "bundle:com.example.third", "bundle:com.example.first", "bundle:com.example.second", "bundle:com.example.new",
        ])
    }

    func testDuplicateBundleCopiesKeepPathOrderWhenOneTemporarilyDisappears() {
        let firstCopy = makeCandidate(url: "/Applications/Browser A.app", name: "Browser A", bundleIdentifier: "com.example.shared")
        let secondCopy = makeCandidate(url: "/Volumes/External/Browser B.app", name: "Browser B", bundleIdentifier: "com.example.shared")
        let unique = makeCandidate(url: "/Applications/Browser C.app", name: "Browser C", bundleIdentifier: "com.example.unique")
        let discovery = MutableSettingsDiscovery(results: [secondCopy, firstCopy, unique])
        let store = makeStore()
        let model = RoutingSettingsModel(ruleStore: store, discoveryService: discovery)

        model.refresh()
        XCTAssertTrue(model.moveBrowsers(from: IndexSet(integer: 0), to: 2))
        XCTAssertEqual(model.detectedBrowsers.map(\.applicationURL), [firstCopy.applicationURL, secondCopy.applicationURL, unique.applicationURL])
        XCTAssertEqual(store.browserOrder, [
            "path:/Applications/Browser A.app",
            "path:/Volumes/External/Browser B.app",
            "bundle:com.example.unique",
        ])

        discovery.results = [unique, firstCopy]
        model.refresh()
        XCTAssertEqual(model.detectedBrowsers.map(\.applicationURL), [firstCopy.applicationURL, unique.applicationURL])
        XCTAssertEqual(store.browserOrder, [
            "path:/Applications/Browser A.app",
            "path:/Volumes/External/Browser B.app",
            "bundle:com.example.unique",
        ])

        discovery.results = [secondCopy, unique, firstCopy]
        let reloadedModel = RoutingSettingsModel(ruleStore: makeStore(), discoveryService: discovery)
        reloadedModel.refresh()
        XCTAssertEqual(reloadedModel.detectedBrowsers.map(\.applicationURL), [firstCopy.applicationURL, secondCopy.applicationURL, unique.applicationURL])
    }

    func testUniqueOrderedBrowserKeepsPositionWhenNewDuplicateAppearsAfterRelaunch() throws {
        let original = makeCandidate(url: "/Applications/Browser A.app", name: "Browser A", bundleIdentifier: "com.example.shared")
        let unique = makeCandidate(url: "/Applications/Browser C.app", name: "Browser C", bundleIdentifier: "com.example.unique")
        let newlyDuplicatedCopy = makeCandidate(url: "/Volumes/External/Browser B.app", name: "Browser B", bundleIdentifier: "com.example.shared")
        let discovery = MutableSettingsDiscovery(results: [unique, original])
        let store = makeStore()
        let model = RoutingSettingsModel(ruleStore: store, discoveryService: discovery)

        model.refresh()
        XCTAssertTrue(model.moveBrowsers(from: IndexSet(integer: 0), to: 2))
        XCTAssertEqual(store.browserOrder, ["bundle:com.example.shared", "bundle:com.example.unique"])
        XCTAssertTrue(containsJSONValue("/Applications/Browser A.app", in: try storedJSONObject()))

        discovery.results = [newlyDuplicatedCopy, unique, original]
        let reloadedModel = RoutingSettingsModel(ruleStore: makeStore(), discoveryService: discovery)
        reloadedModel.refresh()
        XCTAssertEqual(reloadedModel.detectedBrowsers.map(\.applicationURL), [
            original.applicationURL,
            unique.applicationURL,
            newlyDuplicatedCopy.applicationURL,
        ])
        XCTAssertEqual(makeStore().browserOrder, [
            "bundle:com.example.shared",
            "bundle:com.example.unique",
            "path:/Volumes/External/Browser B.app",
        ])

        discovery.results = [newlyDuplicatedCopy, unique]
        reloadedModel.refresh()
        XCTAssertEqual(reloadedModel.detectedBrowsers.map(\.applicationURL), [unique.applicationURL, newlyDuplicatedCopy.applicationURL])
        XCTAssertEqual(makeStore().browserOrder, [
            "bundle:com.example.shared",
            "bundle:com.example.unique",
            "path:/Volumes/External/Browser B.app",
        ])
        XCTAssertTrue(containsJSONValue("/Applications/Browser A.app", in: try storedJSONObject()))

        discovery.results = [newlyDuplicatedCopy, unique, original]
        reloadedModel.refresh()
        XCTAssertEqual(reloadedModel.detectedBrowsers.map(\.applicationURL), [
            original.applicationURL,
            unique.applicationURL,
            newlyDuplicatedCopy.applicationURL,
        ])

        discovery.results = [unique, original]
        reloadedModel.refresh()
        XCTAssertEqual(reloadedModel.detectedBrowsers.map(\.applicationURL), [original.applicationURL, unique.applicationURL])

        discovery.results = [newlyDuplicatedCopy, unique, original]
        reloadedModel.refresh()
        XCTAssertEqual(reloadedModel.detectedBrowsers.map(\.applicationURL), [
            original.applicationURL,
            unique.applicationURL,
            newlyDuplicatedCopy.applicationURL,
        ])
    }

    func testNoSavedBrowserOrderPreservesDeterministicDiscoveryOrder() {
        let first = makeCandidate(url: "/Applications/First.app", name: "First", bundleIdentifier: "com.example.first")
        let second = makeCandidate(url: "/Applications/Second.app", name: "Second", bundleIdentifier: "com.example.second")
        let store = makeStore()
        let model = RoutingSettingsModel(
            ruleStore: store,
            discoveryService: SettingsFakeDiscovery(results: [second, first])
        )

        model.refresh()

        XCTAssertNil(store.browserOrder)
        XCTAssertEqual(model.detectedBrowsers.map(\.applicationURL), [second.applicationURL, first.applicationURL])
    }

    func testDisablingAndReenablingBrowserPreservesDetectedOrderAndRestoresVisibleRuleChoicePosition() throws {
        let first = makeCandidate(url: "/Applications/First.app", name: "First", bundleIdentifier: "com.example.first")
        let second = makeCandidate(url: "/Applications/Second.app", name: "Second", bundleIdentifier: "com.example.second")
        let third = makeCandidate(url: "/Applications/Third.app", name: "Third", bundleIdentifier: "com.example.third")
        let store = makeStore()
        try store.saveBrowserOrder([
            "bundle:com.example.third",
            "bundle:com.example.first",
            "bundle:com.example.second",
        ])
        let model = RoutingSettingsModel(
            ruleStore: store,
            discoveryService: SettingsFakeDiscovery(results: [second, third, first])
        )

        model.refresh()
        XCTAssertEqual(model.detectedBrowsers.map(\.bundleIdentifier), [
            "com.example.third", "com.example.first", "com.example.second",
        ])
        XCTAssertTrue(model.setBrowserEnabled(false, for: first))

        XCTAssertFalse(model.isBrowserEnabled(first))
        XCTAssertEqual(model.detectedBrowsers.map(\.bundleIdentifier), [
            "com.example.third", "com.example.first", "com.example.second",
        ])
        XCTAssertEqual(model.browserChoices.map(\.bundleIdentifier), [
            "com.example.third", "com.example.second",
        ])
        XCTAssertEqual(store.browserOrder, [
            "bundle:com.example.third",
            "bundle:com.example.first",
            "bundle:com.example.second",
        ])
        XCTAssertEqual(store.disabledBrowserIdentifiers, ["bundle:com.example.first"])

        XCTAssertTrue(model.setBrowserEnabled(true, for: first))
        XCTAssertTrue(model.isBrowserEnabled(first))
        XCTAssertEqual(model.browserChoices.map(\.bundleIdentifier), [
            "com.example.third", "com.example.first", "com.example.second",
        ])
        XCTAssertTrue(store.disabledBrowserIdentifiers.isEmpty)
    }

    func testNewlyDiscoveredBrowserDefaultsToEnabledWhenOtherSavedBrowserIsDisabled() throws {
        let disabled = makeCandidate(url: "/Applications/Disabled.app", name: "Disabled", bundleIdentifier: "com.example.disabled")
        let enabled = makeCandidate(url: "/Applications/Enabled.app", name: "Enabled", bundleIdentifier: "com.example.enabled")
        let newlyDiscovered = makeCandidate(url: "/Applications/New.app", name: "New", bundleIdentifier: "com.example.new")
        let store = makeStore()
        try store.saveBrowserOrder(["bundle:com.example.disabled", "bundle:com.example.enabled"])
        try store.saveDisabledBrowserIdentifiers(["bundle:com.example.disabled"])
        let model = RoutingSettingsModel(
            ruleStore: store,
            discoveryService: SettingsFakeDiscovery(results: [newlyDiscovered, disabled, enabled])
        )

        model.refresh()

        XCTAssertFalse(model.isBrowserEnabled(disabled))
        XCTAssertTrue(model.isBrowserEnabled(enabled))
        XCTAssertTrue(model.isBrowserEnabled(newlyDiscovered))
        XCTAssertEqual(model.browserChoices.map(\.bundleIdentifier), ["com.example.enabled", "com.example.new"])
    }

    func testDisabledDiscoveryFirstCopyMakesSharedBundleUnavailableForRuleChoices() throws {
        let discoveryFirst = makeCandidate(
            url: "/Applications/Browser A.app",
            name: "Browser A",
            bundleIdentifier: "com.example.shared"
        )
        let otherCopy = makeCandidate(
            url: "/Volumes/External/Browser B.app",
            name: "Browser B",
            bundleIdentifier: "com.example.shared"
        )
        let alternate = makeCandidate(
            url: "/Applications/Alternate.app",
            name: "Alternate",
            bundleIdentifier: "com.example.alternate"
        )
        let store = makeStore()
        try store.saveDisabledBrowserIdentifiers(["path:/Applications/Browser A.app"])
        let model = RoutingSettingsModel(
            ruleStore: store,
            discoveryService: SettingsFakeDiscovery(results: [discoveryFirst, otherCopy, alternate])
        )

        model.refresh()

        XCTAssertFalse(model.isBrowserEnabled(discoveryFirst))
        XCTAssertTrue(model.isBrowserEnabled(otherCopy))
        XCTAssertFalse(model.isBrowserAvailable("com.example.shared"))
        XCTAssertEqual(model.browserChoices.map(\.bundleIdentifier), ["com.example.alternate"])
    }

    func testSettingsRefusesToDisableLastCurrentlyDiscoveredEnabledBrowser() {
        let first = makeCandidate(url: "/Applications/First.app", name: "First", bundleIdentifier: "com.example.first")
        let second = makeCandidate(url: "/Applications/Second.app", name: "Second", bundleIdentifier: "com.example.second")
        let store = makeStore()
        let model = RoutingSettingsModel(
            ruleStore: store,
            discoveryService: SettingsFakeDiscovery(results: [first, second])
        )

        model.refresh()
        XCTAssertTrue(model.setBrowserEnabled(false, for: first))
        XCTAssertFalse(model.setBrowserEnabled(false, for: second))

        XCTAssertFalse(model.isBrowserEnabled(first))
        XCTAssertTrue(model.isBrowserEnabled(second))
        XCTAssertEqual(store.disabledBrowserIdentifiers, ["bundle:com.example.first"])
        XCTAssertEqual(model.browserChoices.map(\.bundleIdentifier), ["com.example.second"])
    }

    func testRefreshRetainsRulesAndReportsStaleTargetNameAndAvailabilityFromCurrentInventory() throws {
        let store = makeStore()
        let rule = try store.create(
            matchType: .exactDomain,
            pattern: "example.com",
            browserBundleIdentifier: "com.example.removed"
        )
        let installed = makeCandidate(
            url: "/Applications/Installed.app",
            name: "Installed Browser",
            bundleIdentifier: "com.example.removed"
        )
        let replacement = makeCandidate(
            url: "/Applications/Replacement.app",
            name: "Replacement Browser",
            bundleIdentifier: "com.example.replacement"
        )
        let discovery = MutableSettingsDiscovery(results: [installed])
        let model = RoutingSettingsModel(ruleStore: store, discoveryService: discovery)

        model.refresh()
        XCTAssertEqual(model.browserName(for: rule.browserBundleIdentifier), "Installed Browser")
        XCTAssertTrue(model.isBrowserAvailable(rule.browserBundleIdentifier))

        discovery.results = [replacement]
        model.refresh()

        XCTAssertEqual(model.rules, [rule])
        XCTAssertEqual(store.rules, [rule])
        XCTAssertEqual(model.browserName(for: rule.browserBundleIdentifier), "Unavailable browser")
        XCTAssertFalse(model.isBrowserAvailable(rule.browserBundleIdentifier))
    }

    func testSaveEditAndDeleteDelegateToSharedStoreAndRefreshOrderedRules() throws {
        let store = makeStore()
        let model = RoutingSettingsModel(ruleStore: store, discoveryService: SettingsFakeDiscovery(results: []))

        XCTAssertTrue(model.saveRule(
            id: nil,
            matchType: .exactDomain,
            pattern: "example.com",
            browserBundleIdentifier: "com.example.first"
        ))
        let created = try XCTUnwrap(model.rules.first)
        XCTAssertTrue(model.saveRule(
            id: created.id,
            matchType: .domainFamily,
            pattern: "example.com",
            browserBundleIdentifier: "com.example.changed"
        ))

        XCTAssertEqual(model.rules.map(\.id), [created.id])
        XCTAssertEqual(model.rules.first?.matchType, .domainFamily)
        XCTAssertEqual(model.rules.first?.browserBundleIdentifier, "com.example.changed")
        XCTAssertTrue(model.deleteRule(id: created.id))
        XCTAssertTrue(model.rules.isEmpty)
        XCTAssertTrue(store.rules.isEmpty)
    }

    func testSaveConflictKeepsExistingRulesAndExposesUserFacingError() throws {
        let store = makeStore()
        let existing = try store.create(
            matchType: .exactDomain,
            pattern: "example.com",
            browserBundleIdentifier: "com.example.first"
        )
        let model = RoutingSettingsModel(ruleStore: store, discoveryService: SettingsFakeDiscovery(results: []))

        XCTAssertFalse(model.saveRule(
            id: nil,
            matchType: .exactDomain,
            pattern: "EXAMPLE.COM.",
            browserBundleIdentifier: "com.example.second"
        ))

        XCTAssertEqual(model.rules, [existing])
        XCTAssertFalse(model.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func testKnownStorageErrorIsMeaningfulAndArbitraryStorageErrorIsSanitized() {
        let knownErrorStore = FailingRuleStore(error: RoutingRuleValidationError.emptyBrowserBundleIdentifier)
        let knownErrorModel = RoutingSettingsModel(
            ruleStore: knownErrorStore,
            discoveryService: SettingsFakeDiscovery(results: [])
        )

        XCTAssertFalse(knownErrorModel.saveRule(
            id: nil,
            matchType: .exactDomain,
            pattern: "example.com",
            browserBundleIdentifier: "com.example.browser"
        ))
        XCTAssertEqual(knownErrorModel.errorMessage, "Choose a browser.")

        let unsafeDetail = "private path /Users/person/Secret.app"
        let arbitraryErrorStore = FailingRuleStore(
            error: NSError(domain: "LinkGateTests", code: 99, userInfo: [NSLocalizedDescriptionKey: unsafeDetail])
        )
        let arbitraryErrorModel = RoutingSettingsModel(
            ruleStore: arbitraryErrorStore,
            discoveryService: SettingsFakeDiscovery(results: [])
        )

        XCTAssertFalse(arbitraryErrorModel.saveRule(
            id: nil,
            matchType: .exactDomain,
            pattern: "example.com",
            browserBundleIdentifier: "com.example.browser"
        ))
        XCTAssertFalse(arbitraryErrorModel.errorMessage?.contains(unsafeDetail) ?? true)
        XCTAssertFalse(arbitraryErrorModel.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func testRefreshReadsDefaultStatusButNeverRequestsDefaultMutation() {
        let defaultService = RecordingDefaultBrowserService(
            statusToReturn: DefaultBrowserStatus(httpIsDefault: true, httpsIsDefault: false)
        )
        let model = RoutingSettingsModel(
            ruleStore: makeStore(),
            discoveryService: SettingsFakeDiscovery(results: []),
            defaultBrowserService: defaultService
        )
        let statusCallsBeforeRefresh = defaultService.statusCallCount

        model.refresh()

        XCTAssertEqual(defaultService.statusCallCount, statusCallsBeforeRefresh + 1)
        XCTAssertEqual(defaultService.requestCallCount, 0)
        XCTAssertEqual(model.defaultBrowserStatus, DefaultBrowserStatus(httpIsDefault: true, httpsIsDefault: false))
    }

    func testRequestDefaultBrowserGuardsDuplicatesThenRefreshesStatusAfterSuccess() {
        let defaultService = RecordingDefaultBrowserService(
            statusToReturn: DefaultBrowserStatus(httpIsDefault: false, httpsIsDefault: false)
        )
        let model = RoutingSettingsModel(
            ruleStore: makeStore(),
            discoveryService: SettingsFakeDiscovery(results: []),
            defaultBrowserService: defaultService
        )
        let statusCallsBeforeRequest = defaultService.statusCallCount

        model.requestDefaultBrowser()
        model.requestDefaultBrowser()

        XCTAssertEqual(defaultService.requestCallCount, 1)
        XCTAssertTrue(model.isRequestingDefault)

        defaultService.statusToReturn = DefaultBrowserStatus(httpIsDefault: true, httpsIsDefault: true)
        defaultService.complete(.success(()))

        XCTAssertFalse(model.isRequestingDefault)
        XCTAssertEqual(defaultService.statusCallCount, statusCallsBeforeRequest + 1)
        XCTAssertEqual(model.defaultBrowserStatus, DefaultBrowserStatus(httpIsDefault: true, httpsIsDefault: true))
        XCTAssertNil(model.errorMessage)
    }

    func testRequestDefaultBrowserRefreshesStatusAndSanitizesFailure() {
        let defaultService = RecordingDefaultBrowserService(
            statusToReturn: DefaultBrowserStatus(httpIsDefault: true, httpsIsDefault: false)
        )
        let model = RoutingSettingsModel(
            ruleStore: makeStore(),
            discoveryService: SettingsFakeDiscovery(results: []),
            defaultBrowserService: defaultService
        )
        let statusCallsBeforeRequest = defaultService.statusCallCount
        let unsafeDetail = "mach service unavailable at /private/var/run/secret"

        model.requestDefaultBrowser()
        defaultService.complete(.failure(NSError(
            domain: "LinkGateTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: unsafeDetail]
        )))

        XCTAssertFalse(model.isRequestingDefault)
        XCTAssertEqual(defaultService.statusCallCount, statusCallsBeforeRequest + 1)
        XCTAssertEqual(model.defaultBrowserStatus, DefaultBrowserStatus(httpIsDefault: true, httpsIsDefault: false))
        XCTAssertFalse(model.errorMessage?.contains(unsafeDetail) ?? true)
        XCTAssertFalse(model.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    // V1-A Task 3: status is an OS-derived value. Refresh must read every supported
    // domain state and must not turn an approval requirement into a generic error.
    func testRefreshPublishesEveryLaunchAtLoginDomainStatus() {
        for expectedStatus in [
            LaunchAtLoginStatus.disabled,
            .enabled,
            .requiresApproval,
            .unavailable,
        ] {
            let launchService = RecordingLaunchAtLoginService(status: expectedStatus)
            let model = RoutingSettingsModel(
                ruleStore: makeStore(),
                discoveryService: SettingsFakeDiscovery(results: []),
                launchAtLoginService: launchService,
                setupStateStore: RecordingSetupStateStore(needsSetup: false)
            )

            model.refresh()

            XCTAssertEqual(model.launchAtLoginStatus, expectedStatus)
            XCTAssertGreaterThanOrEqual(launchService.statusCallCount, 1)
            XCTAssertNil(model.errorMessage)
        }
    }

    // V1-A Tasks 3 and 6: the requested state is never assumed. Both a user action
    // and a later Settings refresh must publish the service's next queried state.
    func testLaunchAtLoginEnableAndDisableRequeryActualStatus() {
        let launchService = RecordingLaunchAtLoginService(status: .disabled)
        let model = RoutingSettingsModel(
            ruleStore: makeStore(),
            discoveryService: SettingsFakeDiscovery(results: []),
            launchAtLoginService: launchService,
            setupStateStore: RecordingSetupStateStore(needsSetup: false)
        )
        model.refresh()
        let callsBeforeEnable = launchService.statusCallCount

        model.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(launchService.enableCallCount, 1)
        XCTAssertEqual(launchService.statusCallCount, callsBeforeEnable + 1)
        XCTAssertEqual(model.launchAtLoginStatus, .enabled)

        let callsBeforeDisable = launchService.statusCallCount
        model.setLaunchAtLoginEnabled(false)

        XCTAssertEqual(launchService.disableCallCount, 1)
        XCTAssertEqual(launchService.statusCallCount, callsBeforeDisable + 1)
        XCTAssertEqual(model.launchAtLoginStatus, .disabled)

        launchService.statusToReturn = .requiresApproval
        model.refresh()
        XCTAssertEqual(model.launchAtLoginStatus, .requiresApproval)

        launchService.statusToReturn = .disabled
        model.refresh()
        XCTAssertEqual(model.launchAtLoginStatus, .disabled)
    }

    // V1-A Task 3: redundant requests and development/noncanonical copies must not
    // mutate real registration state at LinkGate's boundary.
    func testLaunchAtLoginRequestsAreNoOpsWhenAlreadyInRequestedStateOrMutationIsProhibited() {
        let enabledService = RecordingLaunchAtLoginService(status: .enabled)
        let enabledModel = RoutingSettingsModel(
            ruleStore: makeStore(),
            discoveryService: SettingsFakeDiscovery(results: []),
            launchAtLoginService: enabledService,
            setupStateStore: RecordingSetupStateStore(needsSetup: false)
        )
        enabledModel.refresh()
        enabledModel.setLaunchAtLoginEnabled(true)
        XCTAssertEqual(enabledService.enableCallCount, 0)
        XCTAssertEqual(enabledModel.launchAtLoginStatus, .enabled)

        let disabledService = RecordingLaunchAtLoginService(status: .disabled)
        let disabledModel = RoutingSettingsModel(
            ruleStore: makeStore(),
            discoveryService: SettingsFakeDiscovery(results: []),
            launchAtLoginService: disabledService,
            setupStateStore: RecordingSetupStateStore(needsSetup: false)
        )
        disabledModel.refresh()
        disabledModel.setLaunchAtLoginEnabled(false)
        XCTAssertEqual(disabledService.disableCallCount, 0)
        XCTAssertEqual(disabledModel.launchAtLoginStatus, .disabled)

        let developmentService = RecordingLaunchAtLoginService(
            status: .disabled,
            canChangeRegistration: false
        )
        let developmentModel = RoutingSettingsModel(
            ruleStore: makeStore(),
            discoveryService: SettingsFakeDiscovery(results: []),
            launchAtLoginService: developmentService,
            setupStateStore: RecordingSetupStateStore(needsSetup: false)
        )
        developmentModel.refresh()
        developmentModel.setLaunchAtLoginEnabled(true)
        XCTAssertEqual(developmentService.enableCallCount, 0)
        XCTAssertEqual(developmentModel.launchAtLoginStatus, .disabled)
    }

    // V1-A Task 3: failures still re-query the operating system and expose only a
    // safe user-facing message. Approval is a state, never a failed registration.
    func testLaunchAtLoginFailureRequeriesStatusAndSanitizesError() {
        let unsafeDetail = "registration failed at /Users/person/private-login-item"
        let launchService = RecordingLaunchAtLoginService(
            status: .disabled,
            enableError: NSError(
                domain: "LinkGateTests",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: unsafeDetail]
            )
        )
        let model = RoutingSettingsModel(
            ruleStore: makeStore(),
            discoveryService: SettingsFakeDiscovery(results: []),
            launchAtLoginService: launchService,
            setupStateStore: RecordingSetupStateStore(needsSetup: false)
        )
        model.refresh()
        let callsBeforeRequest = launchService.statusCallCount

        model.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(launchService.enableCallCount, 1)
        XCTAssertEqual(launchService.statusCallCount, callsBeforeRequest + 1)
        XCTAssertEqual(model.launchAtLoginStatus, .disabled)
        XCTAssertFalse(model.errorMessage?.contains(unsafeDetail) ?? true)
        XCTAssertFalse(model.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        launchService.enableError = nil
        launchService.statusAfterEnable = .requiresApproval
        model.setLaunchAtLoginEnabled(true)
        XCTAssertEqual(model.launchAtLoginStatus, .requiresApproval)
        XCTAssertNil(model.errorMessage)
    }

    // V1-A Task 3: unregistration has the same re-query and sanitization rule as
    // registration; a failed disable cannot be reported as disabled optimistically.
    func testLaunchAtLoginDisableFailureRequeriesStatusAndSanitizesError() {
        let unsafeDetail = "unregistration failed at /Users/person/private-login-item"
        let launchService = RecordingLaunchAtLoginService(
            status: .enabled,
            disableError: NSError(
                domain: "LinkGateTests",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: unsafeDetail]
            )
        )
        let model = RoutingSettingsModel(
            ruleStore: makeStore(),
            discoveryService: SettingsFakeDiscovery(results: []),
            launchAtLoginService: launchService,
            setupStateStore: RecordingSetupStateStore(needsSetup: false)
        )
        model.refresh()
        let callsBeforeRequest = launchService.statusCallCount

        model.setLaunchAtLoginEnabled(false)

        XCTAssertEqual(launchService.disableCallCount, 1)
        XCTAssertEqual(launchService.statusCallCount, callsBeforeRequest + 1)
        XCTAssertEqual(model.launchAtLoginStatus, .enabled)
        XCTAssertFalse(model.errorMessage?.contains(unsafeDetail) ?? true)
        XCTAssertFalse(model.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func testLaunchAtLoginApprovalActionDelegatesWithoutChangingStatus() {
        let launchService = RecordingLaunchAtLoginService(status: .requiresApproval)
        let model = RoutingSettingsModel(
            ruleStore: makeStore(),
            discoveryService: SettingsFakeDiscovery(results: []),
            launchAtLoginService: launchService,
            setupStateStore: RecordingSetupStateStore(needsSetup: false)
        )
        model.refresh()

        model.openLoginItemsSettings()

        XCTAssertEqual(launchService.openSettingsCallCount, 1)
        XCTAssertEqual(model.launchAtLoginStatus, .requiresApproval)
    }

    // V1-A Task 3: setup status is independent from browser/default/login actions.
    // Only Done asks the durable store to complete the current version.
    func testSetupCompletionIsExplicitAndPersistenceFailureOnlyDismissesThisProcess() {
        let requiredStore = RecordingSetupStateStore(needsSetup: true)
        let model = RoutingSettingsModel(
            ruleStore: makeStore(),
            discoveryService: SettingsFakeDiscovery(results: []),
            launchAtLoginService: RecordingLaunchAtLoginService(status: .disabled),
            setupStateStore: requiredStore
        )

        model.refresh()
        XCTAssertTrue(model.setupIsIncomplete)
        model.completeSetup()
        XCTAssertEqual(requiredStore.markedVersions, [1])
        XCTAssertFalse(model.setupIsIncomplete)

        let failingStore = RecordingSetupStateStore(
            needsSetup: true,
            markError: NSError(domain: "LinkGateTests", code: 11)
        )
        let failingModel = RoutingSettingsModel(
            ruleStore: makeStore(),
            discoveryService: SettingsFakeDiscovery(results: []),
            launchAtLoginService: RecordingLaunchAtLoginService(status: .disabled),
            setupStateStore: failingStore
        )
        failingModel.refresh()
        failingModel.completeSetup()
        XCTAssertEqual(failingStore.markedVersions, [1])
        XCTAssertFalse(failingModel.setupIsIncomplete)
        XCTAssertFalse(failingStore.durablyCompleted)
    }

    // V1-A Task 3: no operational action is an onboarding acknowledgement.
    func testOperationalActionsAndRefreshDoNotCompleteSetup() {
        let setupStore = RecordingSetupStateStore(needsSetup: true)
        let launchService = RecordingLaunchAtLoginService(status: .disabled)
        let defaultService = RecordingDefaultBrowserService(
            statusToReturn: DefaultBrowserStatus(httpIsDefault: false, httpsIsDefault: false)
        )
        let model = RoutingSettingsModel(
            ruleStore: makeStore(),
            discoveryService: SettingsFakeDiscovery(results: []),
            defaultBrowserService: defaultService,
            launchAtLoginService: launchService,
            setupStateStore: setupStore
        )
        model.refresh()
        model.setLaunchAtLoginEnabled(true)
        model.requestDefaultBrowser()
        defaultService.complete(.success(()))
        model.refresh()

        XCTAssertTrue(model.setupIsIncomplete)
        XCTAssertTrue(setupStore.markedVersions.isEmpty)
    }

    func testDeleteRulesAtMultipleDisplayedOffsetsPreservesCorrectSurvivorOrder() throws {
        let store = makeStore()
        let first = try store.create(matchType: .exactDomain, pattern: "first.example", browserBundleIdentifier: "com.example.first")
        _ = try store.create(matchType: .exactDomain, pattern: "second.example", browserBundleIdentifier: "com.example.second")
        let third = try store.create(matchType: .exactDomain, pattern: "third.example", browserBundleIdentifier: "com.example.third")
        _ = try store.create(matchType: .exactDomain, pattern: "fourth.example", browserBundleIdentifier: "com.example.fourth")
        let model = RoutingSettingsModel(ruleStore: store, discoveryService: SettingsFakeDiscovery(results: []))

        XCTAssertTrue(model.deleteRules(at: IndexSet([1, 3])))

        XCTAssertEqual(model.rules.map(\.id), [first.id, third.id])
        XCTAssertEqual(store.rules.map(\.id), [first.id, third.id])
    }

    private func makeStore() -> UserDefaultsRoutingRuleStore {
        UserDefaultsRoutingRuleStore(
            userDefaults: defaults,
            storageKey: "LinkGateTests.routingSettings.\(suiteName!)"
        )
    }

    private func storedJSONObject() throws -> [String: Any] {
        let storageKey = "LinkGateTests.routingSettings.\(suiteName!)"
        let data = try XCTUnwrap(defaults.data(forKey: storageKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func containsJSONValue(_ value: String, in object: Any) -> Bool {
        if let string = object as? String {
            return string == value
        }
        if let dictionary = object as? [String: Any] {
            return dictionary.values.contains { containsJSONValue(value, in: $0) }
        }
        if let array = object as? [Any] {
            return array.contains { containsJSONValue(value, in: $0) }
        }
        return false
    }

    private func makeCandidate(url: String, name: String, bundleIdentifier: String?) -> ApplicationCandidate {
        ApplicationCandidate(
            applicationURL: URL(fileURLWithPath: url),
            displayName: name,
            bundleIdentifier: bundleIdentifier,
            icon: NSImage(size: NSSize(width: 16, height: 16))
        )
    }
}

private final class SettingsFakeDiscovery: BrowserDiscoveryService {
    let results: [ApplicationCandidate]
    private(set) var requestedURLs: [URL] = []

    init(results: [ApplicationCandidate]) {
        self.results = results
    }

    func candidates(for url: URL) -> [ApplicationCandidate] {
        requestedURLs.append(url)
        return results
    }
}

private final class MutableSettingsDiscovery: BrowserDiscoveryService {
    var results: [ApplicationCandidate]

    init(results: [ApplicationCandidate]) {
        self.results = results
    }

    func candidates(for url: URL) -> [ApplicationCandidate] {
        results
    }
}

private final class FailingRuleStore: RoutingRuleStore {
    let rules: [RoutingRule] = []
    let error: Error
    let storageWarning: String? = nil

    init(error: Error) {
        self.error = error
    }

    func create(matchType: RoutingRule.MatchType, pattern: String, browserBundleIdentifier: String) throws -> RoutingRule {
        throw error
    }

    func update(id: UUID, matchType: RoutingRule.MatchType, pattern: String, browserBundleIdentifier: String) throws -> RoutingRule {
        throw error
    }

    func delete(id: UUID) throws {
        throw error
    }
}

@MainActor
private final class RecordingDefaultBrowserService: DefaultBrowserService {
    var statusToReturn: DefaultBrowserStatus
    private(set) var statusCallCount = 0
    private(set) var requestCallCount = 0
    private var completion: ((Result<Void, Error>) -> Void)?

    init(statusToReturn: DefaultBrowserStatus) {
        self.statusToReturn = statusToReturn
    }

    func status() -> DefaultBrowserStatus {
        statusCallCount += 1
        return statusToReturn
    }

    func requestDefault(completion: @escaping (Result<Void, Error>) -> Void) {
        requestCallCount += 1
        self.completion = completion
    }

    func complete(_ result: Result<Void, Error>) {
        let completion = completion
        self.completion = nil
        completion?(result)
    }
}

@MainActor
private final class RecordingLaunchAtLoginService: LaunchAtLoginService {
    var statusToReturn: LaunchAtLoginStatus
    var canChangeRegistration: Bool
    var enableError: Error?
    var disableError: Error?
    var statusAfterEnable: LaunchAtLoginStatus?
    var statusAfterDisable: LaunchAtLoginStatus?
    private(set) var statusCallCount = 0
    private(set) var enableCallCount = 0
    private(set) var disableCallCount = 0
    private(set) var openSettingsCallCount = 0

    init(
        status: LaunchAtLoginStatus,
        canChangeRegistration: Bool = true,
        enableError: Error? = nil,
        disableError: Error? = nil
    ) {
        statusToReturn = status
        self.canChangeRegistration = canChangeRegistration
        self.enableError = enableError
        self.disableError = disableError
    }

    var status: LaunchAtLoginStatus {
        statusCallCount += 1
        return statusToReturn
    }

    func enable() throws {
        enableCallCount += 1
        if let enableError { throw enableError }
        statusToReturn = statusAfterEnable ?? .enabled
    }

    func disable() throws {
        disableCallCount += 1
        if let disableError { throw disableError }
        statusToReturn = statusAfterDisable ?? .disabled
    }

    func openLoginItemsSettings() {
        openSettingsCallCount += 1
    }
}

private final class RecordingSetupStateStore: SetupStateStore {
    var needsSetupValue: Bool
    var markError: Error?
    private(set) var markedVersions: [Int] = []
    private(set) var durablyCompleted = false

    init(needsSetup: Bool, markError: Error? = nil) {
        needsSetupValue = needsSetup
        self.markError = markError
    }

    func needsSetup(currentVersion: Int) -> Bool {
        needsSetupValue
    }

    func markSetupCompleted(version: Int) throws {
        markedVersions.append(version)
        if let markError { throw markError }
        durablyCompleted = true
        needsSetupValue = false
    }
}
