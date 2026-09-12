import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let model: RoutingSettingsModel
    private var observers: [NSObjectProtocol] = []
    private let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
    private var hasCenteredWindow = false

    init(model: RoutingSettingsModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LinkGate Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RoutingSettingsView(model: model))
        super.init(window: window)
        observeBrowserInventoryChanges()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        observers.forEach(workspaceNotificationCenter.removeObserver)
    }

    override func showWindow(_ sender: Any?) {
        model.refresh()
        super.showWindow(sender)
        if !hasCenteredWindow {
            window?.center()
            hasCenteredWindow = true
        }
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func observeBrowserInventoryChanges() {
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window?.isVisible == true else { return }
                self.model.refresh()
            }
        }
        observers = [
            workspaceNotificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: refresh),
            workspaceNotificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: refresh),
            workspaceNotificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: refresh),
            workspaceNotificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: refresh),
        ]
    }
}
