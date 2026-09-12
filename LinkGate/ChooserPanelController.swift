import AppKit
import Combine
import SwiftUI

@MainActor
final class ChooserPanelController: NSObject, NSWindowDelegate {
    private static let contentSize = NSSize(width: 480, height: 480)

    private let coordinator: SelectionCoordinator
    private let panel: ChooserPanel
    private let hostingView: NSHostingView<ChooserView>
    private let applicationActivator: (NSApplication) -> Void
    private var stateSubscription: AnyCancellable?
    private var centeredPresentationID: UUID?
    private var activatedPresentationID: UUID?
    private var openingPresentationID: UUID?
    private var presentedNoCandidates = false

    init(
        coordinator: SelectionCoordinator,
        applicationActivator: @escaping @MainActor (NSApplication) -> Void = { $0.activate(ignoringOtherApps: true) }
    ) {
        self.coordinator = coordinator
        self.applicationActivator = applicationActivator
        panel = ChooserPanel(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        hostingView = NSHostingView(rootView: ChooserView(coordinator: coordinator))
        super.init()

        panel.contentView = hostingView
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        stateSubscription = coordinator.$state.sink { [weak self] state in
            MainActor.assumeIsolated {
                self?.recordOpeningTransition(for: state)
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.updatePanel(for: self.coordinator.state)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        coordinator.cancelActiveURL()
        return false
    }

    private func updatePanel(for state: SelectionCoordinator.State) {
        guard requiresPresentation(state) else {
            panel.orderOut(nil)
            presentedNoCandidates = false
            return
        }

        if shouldRecenter(for: state) {
            sizeAndCenterPanel(on: activeScreen())
            if case let .choosing(context) = state {
                centeredPresentationID = context.presentationID
            }
        }
        let shouldActivate = requiresActivation(for: state)
        if shouldActivate {
            applicationActivator(NSApp)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func requiresActivation(for state: SelectionCoordinator.State) -> Bool {
        switch state {
        case let .choosing(context):
            if context.isOpening {
                return false
            }

            let shouldActivate = activatedPresentationID != context.presentationID
                || openingPresentationID == context.presentationID
            activatedPresentationID = context.presentationID
            openingPresentationID = nil
            return shouldActivate
        case .noCandidates:
            defer { presentedNoCandidates = true }
            return !presentedNoCandidates
        case .idle, .discovering, .openingDirectly:
            return false
        }
    }

    private func recordOpeningTransition(for state: SelectionCoordinator.State) {
        guard case let .choosing(context) = state, context.isOpening else {
            return
        }

        openingPresentationID = context.presentationID
    }

    private func shouldRecenter(for state: SelectionCoordinator.State) -> Bool {
        guard panel.isVisible else {
            return true
        }

        // A new chooser presentation receives a new identity. Opening and error
        // updates retain that identity, so they leave the panel where the user put it.
        if case let .choosing(context) = state {
            return centeredPresentationID != context.presentationID
        }

        return false
    }

    private func requiresPresentation(_ state: SelectionCoordinator.State) -> Bool {
        switch state {
        case .choosing, .noCandidates:
            true
        case .idle, .discovering, .openingDirectly:
            false
        }
    }

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return mouseScreen
        }

        if let keyWindow = NSApp.keyWindow,
           keyWindow !== panel,
           let keyWindowScreen = keyWindow.screen {
            return keyWindowScreen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    private func sizeAndCenterPanel(on screen: NSScreen?) {
        let visibleFrame = screen?.visibleFrame ?? .zero
        let maximumWidth = max(320, visibleFrame.width - 48)
        let maximumHeight = max(180, visibleFrame.height - 48)
        let contentSize = NSSize(
            width: min(Self.contentSize.width, maximumWidth),
            height: min(Self.contentSize.height, maximumHeight)
        )
        panel.setContentSize(contentSize)

        guard !visibleFrame.isEmpty else {
            return
        }

        let panelFrame = panel.frame
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - (panelFrame.width / 2),
                y: visibleFrame.midY - (panelFrame.height / 2)
            )
        )
    }
}

private final class ChooserPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
