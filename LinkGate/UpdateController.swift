import Sparkle

@MainActor
protocol UpdateChecking: AnyObject {
    var canCheckForUpdates: Bool { get }

    func checkForUpdates()
}

@MainActor
final class UpdateController: UpdateChecking {
    private let updater: SPUStandardUpdaterController

    init() {
        updater = SPUStandardUpdaterController(
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        updater.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        updater.checkForUpdates(nil)
    }
}
