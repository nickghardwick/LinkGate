import Foundation

struct BrowserCandidateResolver {
    func candidate(bundleIdentifier: String, among candidates: [ApplicationCandidate]) -> ApplicationCandidate? {
        guard !bundleIdentifier.isEmpty else { return nil }
        return candidates.first { $0.bundleIdentifier == bundleIdentifier }
    }
}
