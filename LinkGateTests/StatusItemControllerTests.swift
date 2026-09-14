import AppKit
import XCTest
@testable import LinkGate

// Acceptance Contract mapping:
// Task 4 acceptance mapping:
// 1: The persistent menu-bar item exposes Settings…, Check for Updates…, Copy Diagnostics, a
// separator, and Quit LinkGate. Its native NSMenu commands dispatch only to the supplied narrow
// capabilities, without terminating the XCTest host.
@MainActor
final class StatusItemControllerTests: XCTestCase {
    func testStatusItemUsesLinkGateTemplateMark() {
        let controller = StatusItemController(
            settingsPresenter: {},
            updateChecking: UpdateCheckRecorder(canCheckForUpdates: true),
            copyDiagnostics: {},
            applicationTerminator: {}
        )

        let image = controller.statusItem.button?.image
        XCTAssertEqual(image?.name(), NSImage.Name("StatusItemIcon"))
        XCTAssertEqual(image?.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(image?.isTemplate, true)
    }

    func testNativeMenuOrdersAndDispatchesSettingsUpdateCopyAndQuitCommands() {
        var settingsPresentationCount = 0
        var diagnosticsCopyCount = 0
        var terminationCount = 0
        let updateChecker = UpdateCheckRecorder(canCheckForUpdates: true)
        let controller = StatusItemController(
            settingsPresenter: { settingsPresentationCount += 1 },
            updateChecking: updateChecker,
            copyDiagnostics: { diagnosticsCopyCount += 1 },
            applicationTerminator: { terminationCount += 1 }
        )

        XCTAssertEqual(
            controller.menu.items.map { $0.isSeparatorItem ? "separator" : $0.title },
            ["Settings…", "Check for Updates…", "Copy Diagnostics", "separator", "Quit LinkGate"]
        )
        XCTAssertTrue(controller.menu.items[1].isEnabled)
        XCTAssertTrue(controller.menu.items[2].isEnabled)

        controller.menu.performActionForItem(at: 0)
        controller.menu.performActionForItem(at: 1)
        controller.menu.performActionForItem(at: 2)
        controller.menu.performActionForItem(at: 4)

        XCTAssertEqual(settingsPresentationCount, 1)
        XCTAssertEqual(updateChecker.checkCount, 1)
        XCTAssertEqual(diagnosticsCopyCount, 1)
        XCTAssertEqual(terminationCount, 1)
    }

    func testUpdateCommandIsDisabledAndCannotDispatchWhenCheckingIsUnavailable() {
        var diagnosticsCopyCount = 0
        let updateChecker = UpdateCheckRecorder(canCheckForUpdates: false)
        let controller = StatusItemController(
            settingsPresenter: {},
            updateChecking: updateChecker,
            copyDiagnostics: { diagnosticsCopyCount += 1 },
            applicationTerminator: {}
        )

        XCTAssertFalse(controller.menu.items[1].isEnabled)
        XCTAssertTrue(controller.menu.items[2].isEnabled)

        controller.menu.performActionForItem(at: 1)
        controller.menu.performActionForItem(at: 2)

        XCTAssertEqual(updateChecker.checkCount, 0)
        XCTAssertEqual(diagnosticsCopyCount, 1)
    }

    func testUpdateCommandValidationTracksCurrentAvailability() {
        let updateChecker = UpdateCheckRecorder(canCheckForUpdates: true)
        let controller = StatusItemController(
            settingsPresenter: {},
            updateChecking: updateChecker,
            copyDiagnostics: {},
            applicationTerminator: {}
        )
        let updateItem = controller.menu.items[1]

        XCTAssertTrue(controller.validateMenuItem(updateItem))

        updateChecker.canCheckForUpdates = false

        XCTAssertFalse(controller.validateMenuItem(updateItem))
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
