import AppKit
import OSLog

struct DefaultBrowserStatus: Equatable {
    let httpIsDefault: Bool
    let httpsIsDefault: Bool

    var isDefault: Bool { httpIsDefault && httpsIsDefault }
}

struct DefaultBrowserDiagnosticStatus: Equatable {
    enum HandlerIdentity: Equatable {
        case exactCurrentApplication
        case sameBundleIdentifierAtDifferentLocation(DiagnosticLocation.Classification)
        case otherApplication(bundleIdentifier: String)
        case unresolved
    }

    let http: HandlerIdentity
    let https: HandlerIdentity
}

enum ApplicationBundleIdentity {
    static func refersToSameApplication(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedApplicationPath(lhs) == normalizedApplicationPath(rhs)
    }

    private static func normalizedApplicationPath(_ url: URL) -> String {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}

@MainActor
protocol DefaultBrowserService {
    func status() -> DefaultBrowserStatus
    func requestDefault(completion: @escaping (Result<Void, Error>) -> Void)
}

@MainActor
protocol DefaultBrowserWorkspace {
    func applicationURL(toOpen url: URL) -> URL?
    func bundleIdentifier(at url: URL) -> String?
    func setDefaultApplication(at url: URL, forScheme scheme: String, completion: @escaping (Error?) -> Void)
}

@MainActor
final class NSWorkspaceDefaultBrowserService: DefaultBrowserService {
    private enum Ownership: String {
        case exact
        case wrongCopy = "wrong-copy"
        case otherApplication = "other-application"
        case unresolved
    }

    private let workspace: DefaultBrowserWorkspace
    private let applicationURL: URL
    private let bundleIdentifier: String?

    init(
        workspace: DefaultBrowserWorkspace? = nil,
        applicationURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.workspace = workspace ?? NSWorkspaceDefaultBrowserWorkspace()
        self.applicationURL = applicationURL
        self.bundleIdentifier = bundleIdentifier
    }

    func status() -> DefaultBrowserStatus {
        DefaultBrowserStatus(
            httpIsDefault: diagnosticIdentity(forScheme: "http") == .exactCurrentApplication,
            httpsIsDefault: diagnosticIdentity(forScheme: "https") == .exactCurrentApplication
        )
    }

    func diagnosticStatus() -> DefaultBrowserDiagnosticStatus {
        DefaultBrowserDiagnosticStatus(
            http: diagnosticIdentity(forScheme: "http"),
            https: diagnosticIdentity(forScheme: "https")
        )
    }

    func requestDefault(completion: @escaping (Result<Void, Error>) -> Void) {
        if ownership(forScheme: "http") == .exact {
            requestHTTPSIfNeeded(completion: completion)
            return
        }

        LinkGateLog.defaultBrowser.info("Default handler registration started scheme=http")
        workspace.setDefaultApplication(at: applicationURL, forScheme: "http") { [weak self] error in
            guard let self else { return }
            if let error {
                LinkGateLog.defaultBrowser.error("Default handler registration failed scheme=http category=\(DiagnosticError.category(for: error, operation: .defaultHandler), privacy: .public)")
                completion(.failure(error))
                return
            }
            LinkGateLog.defaultBrowser.info("Default handler registration succeeded scheme=http")
            self.requestHTTPSIfNeeded(completion: completion)
        }
    }

    private func requestHTTPSIfNeeded(completion: @escaping (Result<Void, Error>) -> Void) {
        guard ownership(forScheme: "https") != .exact else {
            completion(.success(()))
            return
        }
        LinkGateLog.defaultBrowser.info("Default handler registration started scheme=https")
        workspace.setDefaultApplication(at: applicationURL, forScheme: "https") { error in
            if let error {
                LinkGateLog.defaultBrowser.error("Default handler registration failed scheme=https category=\(DiagnosticError.category(for: error, operation: .defaultHandler), privacy: .public)")
            } else {
                LinkGateLog.defaultBrowser.info("Default handler registration succeeded scheme=https")
            }
            completion(error.map(Result.failure) ?? .success(()))
        }
    }

    private func ownership(forScheme scheme: String) -> Ownership {
        switch diagnosticIdentity(forScheme: scheme) {
        case .exactCurrentApplication:
            .exact
        case .sameBundleIdentifierAtDifferentLocation:
            .wrongCopy
        case .otherApplication:
            .otherApplication
        case .unresolved:
            .unresolved
        }
    }

    private func diagnosticIdentity(forScheme scheme: String) -> DefaultBrowserDiagnosticStatus.HandlerIdentity {
        guard let expectedBundleIdentifier = bundleIdentifier,
              let schemeURL = URL(string: "\(scheme)://example.com"),
              let resolvedURL = workspace.applicationURL(toOpen: schemeURL),
              let resolvedBundleIdentifier = workspace.bundleIdentifier(at: resolvedURL)
        else {
            logOwnership(.unresolved, forScheme: scheme)
            return .unresolved
        }

        if ApplicationBundleIdentity.refersToSameApplication(resolvedURL, applicationURL) {
            if resolvedBundleIdentifier == expectedBundleIdentifier {
                logOwnership(.exact, forScheme: scheme)
                return .exactCurrentApplication
            }
            logOwnership(.otherApplication, forScheme: scheme)
            return .otherApplication(bundleIdentifier: resolvedBundleIdentifier)
        }

        if resolvedBundleIdentifier == expectedBundleIdentifier {
            logOwnership(.wrongCopy, forScheme: scheme)
            return .sameBundleIdentifierAtDifferentLocation(
                DiagnosticLocation.classification(for: resolvedURL)
            )
        }

        logOwnership(.otherApplication, forScheme: scheme)
        return .otherApplication(bundleIdentifier: resolvedBundleIdentifier)
    }

    private func logOwnership(_ ownership: Ownership, forScheme scheme: String) {
        LinkGateLog.defaultBrowser.debug("Default handler ownership scheme=\(scheme, privacy: .public) state=\(ownership.rawValue, privacy: .public)")
    }
}

@MainActor
final class NSWorkspaceDefaultBrowserWorkspace: DefaultBrowserWorkspace {
    func applicationURL(toOpen url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    func bundleIdentifier(at url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }

    func setDefaultApplication(at url: URL, forScheme scheme: String, completion: @escaping (Error?) -> Void) {
        NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: scheme) { error in
            Task { @MainActor in
                completion(error)
            }
        }
    }
}
