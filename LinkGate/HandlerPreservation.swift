import Foundation

struct HandlerPreservationRecord: Codable, Equatable {
    let sourceVersion: String
    let sourceBuild: String
    let targetVersion: String
    let targetBuild: String
    let applicationURL: URL
    let ownedHTTP: Bool
    let ownedHTTPS: Bool
}

@MainActor
protocol HandlerPreservationRecordStoring {
    func load() -> HandlerPreservationRecord?
    func save(_ record: HandlerPreservationRecord)
    func remove()
}

@MainActor
protocol HandlerPreservationManaging: AnyObject {
    func snapshotBeforeInstallation(targetVersion: String, targetBuild: String)
    func restoreIfNeeded(completion: @escaping (HandlerPreservationRestorationSummary) -> Void)
}

@MainActor
final class UserDefaultsHandlerPreservationRecordStore: HandlerPreservationRecordStoring {
    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "handlerPreservationRecord"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func load() -> HandlerPreservationRecord? {
        guard let data = userDefaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(HandlerPreservationRecord.self, from: data)
    }

    func save(_ record: HandlerPreservationRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    func remove() {
        userDefaults.removeObject(forKey: storageKey)
    }
}

enum HandlerPreservationSchemeResult: Equatable {
    case notAttempted
    case notOwnedBeforeUpdate
    case alreadyOwnedByCurrentApplication
    case restored
    case registrationFailed
    case verificationFailed
}

enum HandlerPreservationRestorationDisposition: Equatable {
    case noPendingRecord
    case gated
    case alreadyPreservedOrNotOwned
    case restored
    case registrationFailed
    case verificationFailed
}

struct HandlerPreservationRestorationSummary: Equatable {
    let disposition: HandlerPreservationRestorationDisposition
    let http: HandlerPreservationSchemeResult
    let https: HandlerPreservationSchemeResult
}

@MainActor
final class HandlerPreservationController: HandlerPreservationManaging {
    private static let linkGateBundleIdentifier = "com.nickghardwick.LinkGate"

    private let workspace: DefaultBrowserWorkspace
    private let recordStore: HandlerPreservationRecordStoring
    private let applicationURL: URL
    private let bundleIdentifier: String?
    private let currentVersion: String
    private let currentBuild: String
    private var restorationOperation: HandlerPreservationRestorationOperation?

    convenience init() {
        self.init(
            workspace: nil,
            recordStore: UserDefaultsHandlerPreservationRecordStore(),
            applicationURL: Bundle.main.bundleURL,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            currentBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    init(
        workspace: DefaultBrowserWorkspace?,
        recordStore: HandlerPreservationRecordStoring,
        applicationURL: URL,
        bundleIdentifier: String?,
        currentVersion: String?,
        currentBuild: String?
    ) {
        self.workspace = workspace ?? NSWorkspaceDefaultBrowserWorkspace()
        self.recordStore = recordStore
        self.applicationURL = applicationURL
        self.bundleIdentifier = bundleIdentifier
        self.currentVersion = currentVersion ?? ""
        self.currentBuild = currentBuild ?? ""
    }

    func snapshotBeforeInstallation(targetVersion: String, targetBuild: String) {
        recordStore.save(
            HandlerPreservationRecord(
                sourceVersion: currentVersion,
                sourceBuild: currentBuild,
                targetVersion: targetVersion,
                targetBuild: targetBuild,
                applicationURL: applicationURL,
                ownedHTTP: isCurrentApplicationDefault(forScheme: "http"),
                ownedHTTPS: isCurrentApplicationDefault(forScheme: "https")
            )
        )
    }

    func restoreIfNeeded(completion: @escaping (HandlerPreservationRestorationSummary) -> Void) {
        guard let record = recordStore.load() else {
            completion(.init(disposition: .noPendingRecord, http: .notAttempted, https: .notAttempted))
            return
        }

        // A source build can launch again while Sparkle is waiting to install on quit, and a
        // different copy may launch first. Both cases stay inert so only the recorded bundle
        // location can consume this record. There is no retry loop: the exact target launch
        // consumes the record before at most one restoration attempt.
        guard bundleIdentifier == Self.linkGateBundleIdentifier,
              ApplicationBundleIdentity.refersToSameApplication(record.applicationURL, applicationURL)
        else {
            completion(.init(disposition: .gated, http: .notAttempted, https: .notAttempted))
            return
        }

        guard record.targetVersion == currentVersion, record.targetBuild == currentBuild else {
            // Retain only the still-running source build; any other version at the recorded
            // location cannot be the intended target launch and makes the record stale.
            if record.sourceVersion != currentVersion || record.sourceBuild != currentBuild {
                recordStore.remove()
            }
            completion(.init(disposition: .gated, http: .notAttempted, https: .notAttempted))
            return
        }

        // Consume at the exact target launch before changing Launch Services so this one-shot
        // state can never reset defaults again on a later ordinary launch.
        recordStore.remove()
        let operation = HandlerPreservationRestorationOperation(
            workspace: workspace,
            applicationURL: applicationURL,
            ownedHTTP: record.ownedHTTP,
            ownedHTTPS: record.ownedHTTPS,
            isCurrentApplicationDefault: { [weak self] scheme in
                self?.isCurrentApplicationDefault(forScheme: scheme) ?? false
            },
            completion: { [weak self] summary in
                self?.restorationOperation = nil
                completion(summary)
            }
        )
        restorationOperation = operation
        operation.start()
    }

    private func isCurrentApplicationDefault(forScheme scheme: String) -> Bool {
        guard let expectedBundleIdentifier = bundleIdentifier,
              let schemeURL = URL(string: "\(scheme)://example.com"),
              let resolvedURL = workspace.applicationURL(toOpen: schemeURL),
              ApplicationBundleIdentity.refersToSameApplication(resolvedURL, applicationURL)
        else { return false }
        return workspace.bundleIdentifier(at: resolvedURL) == expectedBundleIdentifier
    }
}

@MainActor
private final class HandlerPreservationRestorationOperation {
    private let workspace: DefaultBrowserWorkspace
    private let applicationURL: URL
    private let ownedSchemes: [String: Bool]
    private let isCurrentApplicationDefault: (String) -> Bool
    private let completion: (HandlerPreservationRestorationSummary) -> Void
    private var results: [String: HandlerPreservationSchemeResult] = [:]
    private var schemesToRestore: [String] = []
    private var nextSchemeIndex = 0

    init(
        workspace: DefaultBrowserWorkspace,
        applicationURL: URL,
        ownedHTTP: Bool,
        ownedHTTPS: Bool,
        isCurrentApplicationDefault: @escaping (String) -> Bool,
        completion: @escaping (HandlerPreservationRestorationSummary) -> Void
    ) {
        self.workspace = workspace
        self.applicationURL = applicationURL
        ownedSchemes = ["http": ownedHTTP, "https": ownedHTTPS]
        self.isCurrentApplicationDefault = isCurrentApplicationDefault
        self.completion = completion
    }

    func start() {
        for scheme in ["http", "https"] {
            guard ownedSchemes[scheme] == true else {
                results[scheme] = .notOwnedBeforeUpdate
                continue
            }
            if isCurrentApplicationDefault(scheme) {
                results[scheme] = .alreadyOwnedByCurrentApplication
            } else {
                schemesToRestore.append(scheme)
            }
        }
        restoreNextScheme()
    }

    private func restoreNextScheme() {
        guard nextSchemeIndex < schemesToRestore.count else {
            finish()
            return
        }
        let scheme = schemesToRestore[nextSchemeIndex]
        nextSchemeIndex += 1
        workspace.setDefaultApplication(at: applicationURL, forScheme: scheme) { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.results[scheme] = .registrationFailed
            } else if self.isCurrentApplicationDefault(scheme) {
                self.results[scheme] = .restored
            } else {
                self.results[scheme] = .verificationFailed
            }
            self.restoreNextScheme()
        }
    }

    private func finish() {
        let http = results["http"] ?? .notAttempted
        let https = results["https"] ?? .notAttempted
        let disposition: HandlerPreservationRestorationDisposition
        if [http, https].contains(.verificationFailed) {
            disposition = .verificationFailed
        } else if [http, https].contains(.registrationFailed) {
            disposition = .registrationFailed
        } else if [http, https].contains(.restored) {
            disposition = .restored
        } else {
            disposition = .alreadyPreservedOrNotOwned
        }
        completion(.init(disposition: disposition, http: http, https: https))
    }
}
