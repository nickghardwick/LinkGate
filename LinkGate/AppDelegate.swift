import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let routingRuleStore: RoutingRuleStore
    let browserDiscoveryService: BrowserDiscoveryService
    private let selectionCoordinator: SelectionCoordinator
    private let incomingURLHandler: IncomingURLHandler
    private let chooserPanelController: ChooserPanelController
    private let settingsPresenter: () -> Void
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
        let coordinator = SelectionCoordinator(
            discoveryService: discoveryService,
            openingService: openingService,
            ruleProvider: routingRuleStore,
            browserOrderStore: routingRuleStore
        )

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
                defaultBrowserService: defaultBrowserService
            )
        )
        settingsPresenter = { settingsController.showWindow(nil) }
        super.init()
    }

    init(
        selectionCoordinator: SelectionCoordinator,
        incomingURLHandler: IncomingURLHandler,
        chooserPanelController: ChooserPanelController,
        routingRuleStore: RoutingRuleStore? = nil,
        browserDiscoveryService: BrowserDiscoveryService? = nil,
        settingsPresenter: (() -> Void)? = nil
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
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard statusItemController == nil else {
            return
        }

        statusItemController = StatusItemController(
            settingsPresenter: { [weak self] in self?.showSettings() },
            applicationTerminator: { NSApp.terminate(nil) }
        )
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            incomingURLHandler.handleIncomingURL(url)
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
