import AppKit
import OSLog

struct DefaultBrowserStatus: Equatable {
    let httpIsDefault: Bool
    let httpsIsDefault: Bool

    var isDefault: Bool { httpIsDefault && httpsIsDefault }
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
            httpIsDefault: ownership(forScheme: "http") == .exact,
            httpsIsDefault: ownership(forScheme: "https") == .exact
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
        guard let expectedBundleIdentifier = bundleIdentifier,
              let schemeURL = URL(string: "\(scheme)://example.com"),
              let resolvedURL = workspace.applicationURL(toOpen: schemeURL)
        else {
            logOwnership(.unresolved, forScheme: scheme)
            return .unresolved
        }

        let ownership: Ownership
        if ApplicationBundleIdentity.refersToSameApplication(resolvedURL, applicationURL) {
            ownership = workspace.bundleIdentifier(at: resolvedURL) == expectedBundleIdentifier ? .exact : .otherApplication
        } else if workspace.bundleIdentifier(at: resolvedURL) == expectedBundleIdentifier {
            ownership = .wrongCopy
        } else {
            ownership = .otherApplication
        }
        logOwnership(ownership, forScheme: scheme)
        return ownership
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
