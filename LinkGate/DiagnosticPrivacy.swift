import Foundation

enum DiagnosticURL {
    static func scheme(of url: URL) -> String {
        url.scheme?.lowercased() ?? "unknown"
    }
}

enum DiagnosticLocation {
    enum Classification: String {
        case applications = "Applications"
        case userApplications = "User Applications"
        case developmentCopy = "Development copy"
        case other = "Other location"
    }

    static func description(for applicationURL: URL) -> String {
        classification(for: applicationURL).rawValue
    }

    static func classification(for applicationURL: URL) -> Classification {
        let path = sanitizedPath(for: applicationURL)

        if path == "/Applications" || path.hasPrefix("/Applications/") {
            return .applications
        }

        if path == "~/Applications" || path.hasPrefix("~/Applications/") {
            return .userApplications
        }

        if path == "~/Library/Developer" || path.hasPrefix("~/Library/Developer/") {
            return .developmentCopy
        }

        return .other
    }

    static func sanitizedPath(for applicationURL: URL) -> String {
        let path = applicationURL.standardizedFileURL.path

        if path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path {
            return "~"
        }

        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path + "/"
        if path.hasPrefix(homePath) {
            return "~" + path.dropFirst(homePath.count - 1)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.count >= 2, components[0] == "Users" {
            return "~/" + components.dropFirst(2).joined(separator: "/")
        }

        return path
    }
}

enum DiagnosticError {
    enum Operation {
        case browserOpen
        case defaultHandler
    }

    static func category(for _: Error, operation: Operation) -> String {
        switch operation {
        case .browserOpen:
            "browser-open-failed"
        case .defaultHandler:
            "default-handler-failed"
        }
    }
}
