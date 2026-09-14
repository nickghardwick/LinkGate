import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuItemValidation {
    let menu: NSMenu

    let statusItem: NSStatusItem
    private let settingsPresenter: () -> Void
    private let updateChecking: any UpdateChecking
    private let applicationTerminator: () -> Void

    init(
        settingsPresenter: @escaping () -> Void,
        updateChecking: any UpdateChecking,
        applicationTerminator: @escaping () -> Void
    ) {
        self.settingsPresenter = settingsPresenter
        self.updateChecking = updateChecking
        self.applicationTerminator = applicationTerminator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()
        super.init()

        if let image = NSImage(named: "StatusItemIcon") {
            image.isTemplate = true
            statusItem.button?.image = image
        }
        statusItem.button?.setAccessibilityLabel("LinkGate")

        menu.addItem(
            NSMenuItem(
                title: "Settings…",
                action: #selector(showSettings),
                keyEquivalent: ""
            )
        )
        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updateItem.isEnabled = updateChecking.canCheckForUpdates
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit LinkGate",
                action: #selector(quit),
                keyEquivalent: ""
            )
        )
        for item in menu.items where !item.isSeparatorItem {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func showSettings() {
        settingsPresenter()
    }

    @objc private func checkForUpdates() {
        guard updateChecking.canCheckForUpdates else {
            return
        }
        updateChecking.checkForUpdates()
    }

    @objc private func quit() {
        applicationTerminator()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) {
            return updateChecking.canCheckForUpdates
        }
        return true
    }
}
