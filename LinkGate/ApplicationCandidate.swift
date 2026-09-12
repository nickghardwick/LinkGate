import AppKit

struct ApplicationMetadata {
    let displayName: String?
    let bundleIdentifier: String?
    let icon: NSImage?
}

struct ApplicationCandidate: Identifiable {
    let applicationURL: URL
    let displayName: String
    let bundleIdentifier: String?
    let icon: NSImage

    var id: URL { applicationURL }
}

func normalizedApplicationURL(_ url: URL) -> URL {
    let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
    return URL(fileURLWithPath: resolvedURL.path, isDirectory: false)
}
