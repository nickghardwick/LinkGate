import AppKit

@MainActor
final class StatusItemController: NSObject {
    let menu: NSMenu

    let statusItem: NSStatusItem
    private let settingsPresenter: () -> Void
    private let applicationTerminator: () -> Void

    init(
        settingsPresenter: @escaping () -> Void,
        applicationTerminator: @escaping () -> Void
    ) {
        self.settingsPresenter = settingsPresenter
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

    @objc private func quit() {
        applicationTerminator()
    }
}
