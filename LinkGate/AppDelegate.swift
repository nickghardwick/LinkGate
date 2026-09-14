import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let routingRuleStore: RoutingRuleStore
    let browserDiscoveryService: BrowserDiscoveryService
    private let selectionCoordinator: SelectionCoordinator
    private let incomingURLHandler: IncomingURLHandler
    private let chooserPanelController: ChooserPanelController
    private let settingsPresenter: () -> Void
    private let updateController: UpdateController?
    private let updateChecking: any UpdateChecking
    private let handlerPreservationRestoring: (any HandlerPreservationRestoring)?
    private let diagnosticsController: DiagnosticsController?
    private let setupStateStore: (any SetupStateStore)?
    private var statusItemController: StatusItemController?

    override init() {
        let workspaceProvider = NSWorkspaceApplicationProvider()
        let metadataProvider = BundleApplicationMetadataProvider()
        let discoveryService = NSWorkspaceBrowserDiscoveryService(
            workspace: workspaceProvider,
            metadataProvider: metadataProvider,
            currentApplicationURL: Bundle.main.bundleURL,
            currentBundleIdentifier: Bundle.main.bundleIdentifier
        )
        let openingService = NSWorkspaceBrowserOpeningService()
        let routingRuleStore = UserDefaultsRoutingRuleStore()
        let defaultBrowserService = NSWorkspaceDefaultBrowserService()
        let launchAtLoginService = SMAppServiceLaunchAtLoginService()
        let setupStateStore = UserDefaultsSetupStateStore()
        let coordinator = SelectionCoordinator(
            discoveryService: discoveryService,
            openingService: openingService,
            ruleProvider: routingRuleStore,
            browserOrderStore: routingRuleStore
        )
        let updateController = UpdateController()

        self.routingRuleStore = routingRuleStore
        browserDiscoveryService = discoveryService
        selectionCoordinator = coordinator
        // This complete pipeline exists before AppKit can deliver a launch URL.
        incomingURLHandler = IncomingURLHandler(destination: coordinator)
        chooserPanelController = ChooserPanelController(coordinator: coordinator)
        let settingsController = SettingsWindowController(
            model: RoutingSettingsModel(
                ruleStore: routingRuleStore,
                discoveryService: discoveryService,
                defaultBrowserService: defaultBrowserService,
                launchAtLoginService: launchAtLoginService,
                setupStateStore: setupStateStore
            )
        )
        settingsPresenter = { settingsController.showWindow(nil) }
        self.setupStateStore = setupStateStore
        self.updateController = updateController
        updateChecking = updateController
        handlerPreservationRestoring = updateController
        let operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
        diagnosticsController = DiagnosticsController(
            ruleStore: routingRuleStore,
            browserDiscovery: discoveryService,
            defaultBrowserStatus: { defaultBrowserService.diagnosticStatus() },
            launchAtLoginStatus: { launchAtLoginService.status },
            updateDiagnosticState: { updateController.diagnosticState },
            applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            applicationBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            macOSVersion: "\(operatingSystemVersion.majorVersion).\(operatingSystemVersion.minorVersion).\(operatingSystemVersion.patchVersion)",
            applicationURL: Bundle.main.bundleURL
        )
        super.init()
    }

    init(
        selectionCoordinator: SelectionCoordinator,
        incomingURLHandler: IncomingURLHandler,
        chooserPanelController: ChooserPanelController,
        routingRuleStore: RoutingRuleStore? = nil,
        browserDiscoveryService: BrowserDiscoveryService? = nil,
        settingsPresenter: (() -> Void)? = nil,
        updateChecking: any UpdateChecking,
        handlerPreservationRestoring: (any HandlerPreservationRestoring)? = nil,
        setupStateStore: (any SetupStateStore)? = nil
    ) {
        self.routingRuleStore = routingRuleStore ?? UserDefaultsRoutingRuleStore()
        self.browserDiscoveryService = browserDiscoveryService ?? NSWorkspaceBrowserDiscoveryService(
            workspace: NSWorkspaceApplicationProvider(),
            metadataProvider: BundleApplicationMetadataProvider(),
            currentApplicationURL: Bundle.main.bundleURL,
            currentBundleIdentifier: Bundle.main.bundleIdentifier
        )
        self.selectionCoordinator = selectionCoordinator
        self.incomingURLHandler = incomingURLHandler
        self.chooserPanelController = chooserPanelController
        self.settingsPresenter = settingsPresenter ?? {}
        self.updateController = nil
        self.updateChecking = updateChecking
        self.handlerPreservationRestoring = handlerPreservationRestoring
        self.setupStateStore = setupStateStore
        diagnosticsController = nil
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard statusItemController == nil else {
            return
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let location = DiagnosticLocation.description(for: Bundle.main.bundleURL)
        LinkGateLog.app.info("Launched version=\(version, privacy: .public) build=\(build, privacy: .public) location=\(location, privacy: .public)")

        handlerPreservationRestoring?.restorePreservedHandlersIfNeeded()

        statusItemController = StatusItemController(
            settingsPresenter: { [weak self] in self?.showSettings() },
            updateChecking: updateChecking,
            copyDiagnostics: { [weak self] in self?.diagnosticsController?.copyDiagnostics() },
            applicationTerminator: { NSApp.terminate(nil) }
        )

        if setupStateStore?.needsSetup(currentVersion: currentSetupVersion) == true {
            LinkGateLog.app.info("First-run setup presented")
            showSettings()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if incomingURLHandler.handleIncomingURL(url) {
                LinkGateLog.app.info("Accepted incoming link scheme=\(DiagnosticURL.scheme(of: url), privacy: .public)")
            }
        }
    }

    func showSettings() {
        settingsPresenter()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if selectionCoordinator.activeURL == nil {
            showSettings()
        }
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if selectionCoordinator.activeURL == nil {
            showSettings()
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
