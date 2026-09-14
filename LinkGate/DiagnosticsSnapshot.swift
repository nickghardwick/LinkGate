import Foundation

struct DiagnosticsSnapshot: Equatable {
    struct Browser: Equatable {
        let bundleIdentifier: String
        let location: DiagnosticLocation.Classification?
        let locationOrdinal: Int?
    }

    let applicationVersion: String
    let applicationBuild: String
    let macOSVersion: String
    let applicationLocation: DiagnosticLocation.Classification
    let defaultBrowserStatus: DefaultBrowserDiagnosticStatus
    let launchAtLoginStatus: LaunchAtLoginStatus
    let enabledBrowsers: [Browser]
    let disabledBrowserCount: Int
    let ruleCount: Int
    let updateState: UpdateDiagnosticState

    var renderedText: String {
        var lines = [
            "LinkGate diagnostics",
            "App",
            "- Version: \(applicationVersion) (\(applicationBuild))",
            "- macOS: \(macOSVersion)",
            "- Location: \(applicationLocation.rawValue)",
            "Launch",
            "- At login: \(launchAtLoginText)",
            "Default handlers",
            "- HTTP: \(handlerText(for: defaultBrowserStatus.http))",
            "- HTTPS: \(handlerText(for: defaultBrowserStatus.https))",
            "Browsers",
        ]

        if enabledBrowsers.isEmpty {
            lines.append("- Enabled: none")
        } else {
            lines.append("- Enabled (\(enabledBrowsers.count)):")
            lines.append(contentsOf: enabledBrowsers.map { "  - \(browserText(for: $0))" })
        }

        lines.append(contentsOf: [
            "- Disabled detected: \(disabledBrowserCount)",
            "Routing",
            "- Rules: \(ruleCount)",
            "Updates",
            "- Automatic checks: \(yesNo(updateState.automaticallyChecksForUpdates, enabled: "enabled", disabled: "disabled"))",
            "- Automatic downloads: \(yesNo(updateState.automaticallyDownloadsUpdates, enabled: "enabled", disabled: "disabled"))",
            "- Can check now: \(yesNo(updateState.canCheckForUpdates))",
            "- Update session in progress: \(yesNo(updateState.sessionInProgress))",
            "Handler preservation",
        ])

        guard let restoration = updateState.latestHandlerPreservationResult,
              restoration.disposition != .noPendingRecord
        else {
            lines.append("- Result: none this launch")
            return lines.joined(separator: "\n")
        }

        lines.append("- Result: \(restorationDispositionText(restoration.disposition))")
        lines.append("- HTTP: \(restorationSchemeText(restoration.http))")
        lines.append("- HTTPS: \(restorationSchemeText(restoration.https))")
        return lines.joined(separator: "\n")
    }

    private var launchAtLoginText: String {
        switch launchAtLoginStatus {
        case .disabled: "disabled"
        case .enabled: "enabled"
        case .requiresApproval: "requires approval"
        case .unavailable: "unavailable"
        }
    }

    private func handlerText(for identity: DefaultBrowserDiagnosticStatus.HandlerIdentity) -> String {
        switch identity {
        case .exactCurrentApplication:
            "current LinkGate bundle"
        case let .sameBundleIdentifierAtDifferentLocation(location):
            "LinkGate at \(location.rawValue)"
        case let .otherApplication(bundleIdentifier):
            "other application (\(bundleIdentifier))"
        case .unresolved:
            "unresolved"
        }
    }

    private func browserText(for browser: Browser) -> String {
        guard let location = browser.location else { return browser.bundleIdentifier }
        let ordinal = browser.locationOrdinal.map { " #\($0)" } ?? ""
        return "\(browser.bundleIdentifier) (\(location.rawValue)\(ordinal))"
    }

    private func restorationDispositionText(_ disposition: HandlerPreservationRestorationDisposition) -> String {
        switch disposition {
        case .noPendingRecord: "none this launch"
        case .gated: "gated"
        case .alreadyPreservedOrNotOwned: "already preserved or not owned"
        case .restored: "restored"
        case .registrationFailed: "registration failed"
        case .verificationFailed: "verification failed"
        case .exhausted: "exhausted"
        }
    }

    private func restorationSchemeText(_ result: HandlerPreservationSchemeResult) -> String {
        switch result {
        case .notAttempted: "not attempted"
        case .notOwnedBeforeUpdate: "not owned before update"
        case .alreadyOwnedByCurrentApplication: "already owned by current application"
        case .restored: "restored"
        case .registrationFailed: "registration failed"
        case .verificationFailed: "verification failed"
        }
    }

    private func yesNo(_ value: Bool, enabled: String = "yes", disabled: String = "no") -> String {
        value ? enabled : disabled
    }
}
