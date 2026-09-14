import Sparkle
import XCTest
@testable import LinkGate

// Acceptance Contract mapping:
// U1: Sparkle's standard updater delegate receives the immediate pre-install callback and forwards
// the appcast item's display version and build version to LinkGate's narrow preservation boundary.
// The test constructs no custom Sparkle user driver and starts no update check or network work.
@MainActor
final class UpdateControllerTests: XCTestCase {
    func testWillInstallUpdateSnapshotsTheSparkleTargetDisplayVersionAndBuild() {
        let preservation = HandlerPreservationRecorder()
        let controller = UpdateController(
            handlerPreservation: preservation,
            startingUpdater: false
        )
        let sparkleController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let item = makeAppcastItem(displayVersion: "0.1.7", buildVersion: "9")

        controller.updater(sparkleController.updater, willInstallUpdate: item)

        XCTAssertEqual(preservation.snapshotTargets, ["0.1.7", "9"])
        XCTAssertEqual(preservation.restoreCallCount, 0)
    }

    private func makeAppcastItem(displayVersion: String, buildVersion: String) -> SUAppcastItem {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(displayVersion, forKey: "displayVersionString")
        archiver.encode(URL(fileURLWithPath: "/tmp/LinkGate-test-update.zip"), forKey: "fileURL")
        archiver.encode("application", forKey: "SUAppcastItemInstallationType")
        archiver.encode(buildVersion, forKey: "versionString")
        archiver.encode([String: String](), forKey: "propertiesDictionary")
        let data = archiver.encodedData
        let unarchiver = try! NSKeyedUnarchiver(forReadingFrom: data)
        defer { unarchiver.finishDecoding() }
        return SUAppcastItem(coder: unarchiver)!
    }
}

@MainActor
private final class HandlerPreservationRecorder: HandlerPreservationManaging {
    private(set) var snapshotTargets: [String] = []
    private(set) var restoreCallCount = 0

    func snapshotBeforeInstallation(targetVersion: String, targetBuild: String) {
        snapshotTargets = [targetVersion, targetBuild]
    }

    func restoreIfNeeded(completion: @escaping (HandlerPreservationRestorationSummary) -> Void) {
        restoreCallCount += 1
        completion(.init(disposition: .noPendingRecord, http: .notAttempted, https: .notAttempted))
    }
}
