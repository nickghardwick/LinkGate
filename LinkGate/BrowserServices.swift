import AppKit

protocol WorkspaceApplicationProviding {
    func applicationURLs(toOpen url: URL) -> [URL]
}

protocol ApplicationMetadataProviding {
    func metadata(for applicationURL: URL) -> ApplicationMetadata
}

protocol BrowserDiscoveryService {
    func candidates(for url: URL) -> [ApplicationCandidate]
}

protocol BrowserOpeningService {
    func open(
        _ url: URL,
        withApplicationAt applicationURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

final class NSWorkspaceApplicationProvider: WorkspaceApplicationProviding {
    func applicationURLs(toOpen url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
    }
}

final class BundleApplicationMetadataProvider: ApplicationMetadataProviding {
    func metadata(for applicationURL: URL) -> ApplicationMetadata {
        let bundle = Bundle(url: applicationURL)
        let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String

        return ApplicationMetadata(
            displayName: displayName,
            bundleIdentifier: bundle?.bundleIdentifier,
            icon: NSWorkspace.shared.icon(forFile: applicationURL.path)
        )
    }
}

final class NSWorkspaceBrowserDiscoveryService: BrowserDiscoveryService {
    private let workspace: WorkspaceApplicationProviding
    private let metadataProvider: ApplicationMetadataProviding
    private let currentApplicationURL: URL?
    private let currentBundleIdentifier: String?

    init(
        workspace: WorkspaceApplicationProviding,
        metadataProvider: ApplicationMetadataProviding,
        currentApplicationURL: URL?,
        currentBundleIdentifier: String?
    ) {
        self.workspace = workspace
        self.metadataProvider = metadataProvider
        self.currentApplicationURL = currentApplicationURL
        self.currentBundleIdentifier = currentBundleIdentifier
    }

    func candidates(for url: URL) -> [ApplicationCandidate] {
        let currentApplicationURL = currentApplicationURL.map(normalizedApplicationURL)
        var seenApplicationURLs = Set<URL>()

        return workspace.applicationURLs(toOpen: url).compactMap { applicationURL in
            let normalizedURL = normalizedApplicationURL(applicationURL)
            guard normalizedURL != currentApplicationURL, seenApplicationURLs.insert(normalizedURL).inserted else {
                return nil
            }

            let metadata = metadataProvider.metadata(for: applicationURL)
            if let currentBundleIdentifier, metadata.bundleIdentifier == currentBundleIdentifier {
                return nil
            }

            return ApplicationCandidate(
                applicationURL: applicationURL,
                displayName: metadata.displayName ?? applicationURL.deletingPathExtension().lastPathComponent,
                bundleIdentifier: metadata.bundleIdentifier,
                icon: metadata.icon ?? NSImage(named: NSImage.applicationIconName)!
            )
        }
    }
}

final class NSWorkspaceBrowserOpeningService: BrowserOpeningService {
    func open(
        _ url: URL,
        withApplicationAt applicationURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            completion(error.map(Result.failure) ?? .success(()))
        }
    }
}
