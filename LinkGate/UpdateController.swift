import Sparkle

@MainActor
protocol UpdateChecking: AnyObject {
    var canCheckForUpdates: Bool { get }

    func checkForUpdates()
}

@MainActor
protocol HandlerPreservationRestoring: AnyObject {
    func restorePreservedHandlersIfNeeded()
}

@MainActor
final class UpdateController: NSObject, UpdateChecking, HandlerPreservationRestoring, SPUUpdaterDelegate {
    private let handlerPreservation: any HandlerPreservationManaging
    private var updater: SPUStandardUpdaterController!
    private(set) var latestHandlerPreservationResult: HandlerPreservationRestorationSummary?

    override init() {
        handlerPreservation = HandlerPreservationController()
        super.init()
        updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    init(
        handlerPreservation: any HandlerPreservationManaging,
        startingUpdater: Bool = true
    ) {
        self.handlerPreservation = handlerPreservation
        super.init()
        updater = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        updater.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    func restorePreservedHandlersIfNeeded() {
        handlerPreservation.restoreIfNeeded { [weak self] result in
            self?.latestHandlerPreservationResult = result
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        handlerPreservation.snapshotBeforeInstallation(
            targetVersion: item.displayVersionString,
            targetBuild: item.versionString
        )
    }
}
