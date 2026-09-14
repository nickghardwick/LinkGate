import Sparkle
import OSLog

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
        LinkGateLog.updater.info("Manual update check requested")
        updater.checkForUpdates(nil)
    }

    func restorePreservedHandlersIfNeeded() {
        LinkGateLog.updater.debug("Handler restoration requested")
        handlerPreservation.restoreIfNeeded { [weak self] result in
            self?.latestHandlerPreservationResult = result
            let disposition = Self.diagnosticDisposition(for: result.disposition)
            if Self.isFailedRestoration(result.disposition) {
                LinkGateLog.updater.error("Handler restoration completed disposition=\(disposition, privacy: .public)")
            } else {
                LinkGateLog.updater.info("Handler restoration completed disposition=\(disposition, privacy: .public)")
            }
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        LinkGateLog.updater.info("Update installation announced targetVersion=\(item.displayVersionString, privacy: .public) targetBuild=\(item.versionString, privacy: .public)")
        LinkGateLog.updater.debug("Handler snapshot requested")
        handlerPreservation.snapshotBeforeInstallation(
            targetVersion: item.displayVersionString,
            targetBuild: item.versionString
        )
    }

    private static func diagnosticDisposition(for disposition: HandlerPreservationRestorationDisposition) -> String {
        switch disposition {
        case .noPendingRecord: "no-pending-record"
        case .gated: "gated"
        case .alreadyPreservedOrNotOwned: "already-preserved-or-not-owned"
        case .restored: "restored"
        case .registrationFailed: "registration-failed"
        case .verificationFailed: "verification-failed"
        case .exhausted: "exhausted"
        }
    }

    private static func isFailedRestoration(_ disposition: HandlerPreservationRestorationDisposition) -> Bool {
        switch disposition {
        case .registrationFailed, .verificationFailed, .exhausted:
            true
        case .noPendingRecord, .gated, .alreadyPreservedOrNotOwned, .restored:
            false
        }
    }
}
