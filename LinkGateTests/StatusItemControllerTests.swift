import AppKit
import XCTest
@testable import LinkGate

// Acceptance Contract mapping:
// A2: The persistent menu-bar item exposes only Settings… and Quit LinkGate (with an optional
// separator). Its native NSMenu commands dispatch to the supplied settings and termination
// actions, without terminating the XCTest host.
@MainActor
final class StatusItemControllerTests: XCTestCase {
    func testStatusItemUsesLinkGateTemplateMark() {
        let controller = StatusItemController(
            settingsPresenter: {},
            applicationTerminator: {}
        )

        let image = controller.statusItem.button?.image
        XCTAssertEqual(image?.name(), NSImage.Name("StatusItemIcon"))
        XCTAssertEqual(image?.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(image?.isTemplate, true)
    }

    func testMinimalNativeMenuDispatchesSettingsAndQuitCommands() {
        var settingsPresentationCount = 0
        var terminationCount = 0
        let controller = StatusItemController(
            settingsPresenter: { settingsPresentationCount += 1 },
            applicationTerminator: { terminationCount += 1 }
        )
        let actionableItems = controller.menu.items.filter { !$0.isSeparatorItem }

        XCTAssertEqual(actionableItems.map(\.title), ["Settings…", "Quit LinkGate"])
        XCTAssertEqual(actionableItems.count, 2)

        controller.menu.performActionForItem(at: 0)
        controller.menu.performActionForItem(at: controller.menu.items.count - 1)

        XCTAssertEqual(settingsPresentationCount, 1)
        XCTAssertEqual(terminationCount, 1)
    }
}
