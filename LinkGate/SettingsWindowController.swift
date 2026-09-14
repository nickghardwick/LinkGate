import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let model: RoutingSettingsModel
    private var observers: [NSObjectProtocol] = []
    private let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
    private var applicationActivationObserver: NSObjectProtocol?
    private var hasCenteredWindow = false

    init(model: RoutingSettingsModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LinkGate Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RoutingSettingsView(model: model))
        super.init(window: window)
        observeBrowserInventoryChanges()
        observeApplicationActivation()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        observers.forEach(workspaceNotificationCenter.removeObserver)
        if let applicationActivationObserver {
            NotificationCenter.default.removeObserver(applicationActivationObserver)
        }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
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

    @objc private func windowWillClose(_ notification: Notification) {
        model.dismissSetupForCurrentProcess()
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

    private func observeApplicationActivation() {
        applicationActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window?.isVisible == true else { return }
                self.model.refresh()
            }
        }
    }
}
