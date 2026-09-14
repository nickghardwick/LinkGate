import AppKit

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
            httpIsDefault: isDefault(forScheme: "http"),
            httpsIsDefault: isDefault(forScheme: "https")
        )
    }

    func requestDefault(completion: @escaping (Result<Void, Error>) -> Void) {
        if isDefault(forScheme: "http") {
            requestHTTPSIfNeeded(completion: completion)
            return
        }

        workspace.setDefaultApplication(at: applicationURL, forScheme: "http") { [weak self] error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            self.requestHTTPSIfNeeded(completion: completion)
        }
    }

    private func requestHTTPSIfNeeded(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isDefault(forScheme: "https") else {
            completion(.success(()))
            return
        }
        workspace.setDefaultApplication(at: applicationURL, forScheme: "https") { error in
            completion(error.map(Result.failure) ?? .success(()))
        }
    }

    private func isDefault(forScheme scheme: String) -> Bool {
        guard let expectedBundleIdentifier = bundleIdentifier,
              let schemeURL = URL(string: "\(scheme)://example.com"),
              let resolvedURL = workspace.applicationURL(toOpen: schemeURL),
              ApplicationBundleIdentity.refersToSameApplication(resolvedURL, applicationURL)
        else { return false }
        return workspace.bundleIdentifier(at: resolvedURL) == expectedBundleIdentifier
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
