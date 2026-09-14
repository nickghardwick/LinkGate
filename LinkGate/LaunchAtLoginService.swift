import Foundation
import OSLog
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

@MainActor
protocol LaunchAtLoginService {
    var status: LaunchAtLoginStatus { get }
    var canChangeRegistration: Bool { get }

    func enable() throws
    func disable() throws
    func openLoginItemsSettings()
}

/// The small ServiceManagement boundary keeps XCTest from touching the real login-item state.
@MainActor
protocol SMAppServiceAdapter {
    var status: SMAppService.Status { get }

    func register() throws
    func unregister() throws
    func openLoginItemsSettings()
}

@MainActor
final class MainAppSMAppServiceAdapter: SMAppServiceAdapter {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: SMAppService.Status { service.status }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class SMAppServiceLaunchAtLoginService: LaunchAtLoginService {
    private static let canonicalApplicationPath = "/Applications/LinkGate.app"

    private let adapter: SMAppServiceAdapter

    let canChangeRegistration: Bool

    init(
        adapter: SMAppServiceAdapter? = nil,
        applicationURL: URL = Bundle.main.bundleURL
    ) {
        self.adapter = adapter ?? MainAppSMAppServiceAdapter()
        canChangeRegistration = Self.normalizedPath(applicationURL) == Self.canonicalApplicationPath
    }

    var status: LaunchAtLoginStatus {
        let status = Self.map(adapter.status)
        LinkGateLog.launchAtLogin.debug("Login-item status queried state=\(Self.logValue(for: status), privacy: .public)")
        return status
    }

    func enable() throws {
        guard canChangeRegistration, status != .enabled else { return }

        LinkGateLog.launchAtLogin.info("Login-item registration requested")
        defer { _ = status }
        do {
            try adapter.register()
            LinkGateLog.launchAtLogin.info("Login-item registration succeeded")
        } catch {
            LinkGateLog.launchAtLogin.error("Login-item registration failed category=login-item-registration-failed")
            throw error
        }
    }

    func disable() throws {
        guard canChangeRegistration, status != .disabled else { return }

        LinkGateLog.launchAtLogin.info("Login-item unregistration requested")
        defer { _ = status }
        do {
            try adapter.unregister()
            LinkGateLog.launchAtLogin.info("Login-item unregistration succeeded")
        } catch {
            LinkGateLog.launchAtLogin.error("Login-item unregistration failed category=login-item-unregistration-failed")
            throw error
        }
    }

    func openLoginItemsSettings() {
        adapter.openLoginItemsSettings()
    }

    private static func map(_ status: SMAppService.Status) -> LaunchAtLoginStatus {
        switch status {
        case .notRegistered:
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func logValue(for status: LaunchAtLoginStatus) -> String {
        switch status {
        case .disabled: "disabled"
        case .enabled: "enabled"
        case .requiresApproval: "requires-approval"
        case .unavailable: "unavailable"
        }
    }
}
