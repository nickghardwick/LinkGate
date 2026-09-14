import Foundation
import OSLog

struct HandlerPreservationRecord: Codable, Equatable {
    let sourceVersion: String
    let sourceBuild: String
    let targetVersion: String
    let targetBuild: String
    let applicationURL: URL
    let ownedHTTP: Bool
    let ownedHTTPS: Bool
    let attemptCount: Int

    init(
        sourceVersion: String,
        sourceBuild: String,
        targetVersion: String,
        targetBuild: String,
        applicationURL: URL,
        ownedHTTP: Bool,
        ownedHTTPS: Bool,
        attemptCount: Int
    ) {
        self.sourceVersion = sourceVersion
        self.sourceBuild = sourceBuild
        self.targetVersion = targetVersion
        self.targetBuild = targetBuild
        self.applicationURL = applicationURL
        self.ownedHTTP = ownedHTTP
        self.ownedHTTPS = ownedHTTPS
        self.attemptCount = attemptCount
    }

    private enum CodingKeys: String, CodingKey {
        case sourceVersion
        case sourceBuild
        case targetVersion
        case targetBuild
        case applicationURL
        case ownedHTTP
        case ownedHTTPS
        case attemptCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceVersion = try values.decode(String.self, forKey: .sourceVersion)
        sourceBuild = try values.decode(String.self, forKey: .sourceBuild)
        targetVersion = try values.decode(String.self, forKey: .targetVersion)
        targetBuild = try values.decode(String.self, forKey: .targetBuild)
        applicationURL = try values.decode(URL.self, forKey: .applicationURL)
        ownedHTTP = try values.decode(Bool.self, forKey: .ownedHTTP)
        ownedHTTPS = try values.decode(Bool.self, forKey: .ownedHTTPS)
        attemptCount = try values.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
    }
}

@MainActor
protocol HandlerRestorationScheduling {
    func schedule(after delay: Duration, _ operation: @escaping @MainActor () -> Void)
}

@MainActor
private final class MainActorHandlerRestorationScheduler: HandlerRestorationScheduling {
    func schedule(after delay: Duration, _ operation: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            operation()
        }
    }
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
    case exhausted
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
    private let restorationScheduler: HandlerRestorationScheduling
    private var restorationOperation: HandlerPreservationRestorationOperation?

    convenience init() {
        self.init(
            workspace: nil,
            recordStore: UserDefaultsHandlerPreservationRecordStore(),
            applicationURL: Bundle.main.bundleURL,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            currentBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            restorationScheduler: MainActorHandlerRestorationScheduler()
        )
    }

    convenience init(
        workspace: DefaultBrowserWorkspace?,
        recordStore: HandlerPreservationRecordStoring,
        applicationURL: URL,
        bundleIdentifier: String?,
        currentVersion: String?,
        currentBuild: String?
    ) {
        self.init(
            workspace: workspace,
            recordStore: recordStore,
            applicationURL: applicationURL,
            bundleIdentifier: bundleIdentifier,
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            restorationScheduler: MainActorHandlerRestorationScheduler()
        )
    }

    init(
        workspace: DefaultBrowserWorkspace?,
        recordStore: HandlerPreservationRecordStoring,
        applicationURL: URL,
        bundleIdentifier: String?,
        currentVersion: String?,
        currentBuild: String?,
        restorationScheduler: HandlerRestorationScheduling
    ) {
        self.workspace = workspace ?? NSWorkspaceDefaultBrowserWorkspace()
        self.recordStore = recordStore
        self.applicationURL = applicationURL
        self.bundleIdentifier = bundleIdentifier
        self.currentVersion = currentVersion ?? ""
        self.currentBuild = currentBuild ?? ""
        self.restorationScheduler = restorationScheduler
    }

    func snapshotBeforeInstallation(targetVersion: String, targetBuild: String) {
        LinkGateLog.updater.debug("Capturing handler preservation snapshot targetVersion=\(targetVersion, privacy: .public) targetBuild=\(targetBuild, privacy: .public)")
        recordStore.save(
            HandlerPreservationRecord(
                sourceVersion: currentVersion,
                sourceBuild: currentBuild,
                targetVersion: targetVersion,
                targetBuild: targetBuild,
                applicationURL: applicationURL,
                ownedHTTP: isCurrentApplicationDefault(forScheme: "http"),
                ownedHTTPS: isCurrentApplicationDefault(forScheme: "https"),
                attemptCount: 0
            )
        )
    }

    func restoreIfNeeded(completion: @escaping (HandlerPreservationRestorationSummary) -> Void) {
        guard restorationOperation == nil else {
            LinkGateLog.updater.notice("Handler restoration gated reason=operation-in-progress")
            LinkGateLog.updater.info("Handler restoration completed disposition=gated")
            completion(.init(disposition: .gated, http: .notAttempted, https: .notAttempted))
            return
        }

        guard let record = recordStore.load() else {
            LinkGateLog.updater.debug("Handler restoration has no pending record")
            LinkGateLog.updater.info("Handler restoration completed disposition=no-pending-record")
            completion(.init(disposition: .noPendingRecord, http: .notAttempted, https: .notAttempted))
            return
        }

        // A source build can launch again while Sparkle is waiting to install on quit, and a
        // different copy may launch first. Both cases stay inert so only the recorded bundle
        // location can consume this record.
        guard bundleIdentifier == Self.linkGateBundleIdentifier,
              ApplicationBundleIdentity.refersToSameApplication(record.applicationURL, applicationURL)
        else {
            LinkGateLog.updater.notice("Handler restoration gated reason=identity-or-location-mismatch")
            LinkGateLog.updater.info("Handler restoration completed disposition=gated")
            completion(.init(disposition: .gated, http: .notAttempted, https: .notAttempted))
            return
        }

        guard record.targetVersion == currentVersion, record.targetBuild == currentBuild else {
            // Retain only the still-running source build; any other version at the recorded
            // location cannot be the intended target launch and makes the record stale.
            if record.sourceVersion != currentVersion || record.sourceBuild != currentBuild {
                recordStore.remove()
            }
            LinkGateLog.updater.notice("Handler restoration gated reason=version-or-build-mismatch")
            LinkGateLog.updater.info("Handler restoration completed disposition=gated")
            completion(.init(disposition: .gated, http: .notAttempted, https: .notAttempted))
            return
        }

        guard (0...HandlerPreservationRestorationOperation.maximumAttempts).contains(record.attemptCount) else {
            recordStore.remove()
            LinkGateLog.updater.notice("Handler restoration gated reason=invalid-attempt-count")
            LinkGateLog.updater.info("Handler restoration completed disposition=gated")
            completion(.init(disposition: .gated, http: .notAttempted, https: .notAttempted))
            return
        }

        guard record.attemptCount < HandlerPreservationRestorationOperation.maximumAttempts else {
            recordStore.remove()
            LinkGateLog.updater.notice("Handler restoration exhausted before scheduling")
            LinkGateLog.updater.error("Handler restoration completed disposition=exhausted")
            completion(Self.exhaustedSummary(for: record))
            return
        }

        let operation = HandlerPreservationRestorationOperation(
            workspace: workspace,
            recordStore: recordStore,
            record: record,
            applicationURL: applicationURL,
            scheduler: restorationScheduler,
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

    private static func exhaustedSummary(for record: HandlerPreservationRecord) -> HandlerPreservationRestorationSummary {
        .init(
            disposition: .exhausted,
            http: record.ownedHTTP ? .verificationFailed : .notOwnedBeforeUpdate,
            https: record.ownedHTTPS ? .verificationFailed : .notOwnedBeforeUpdate
        )
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
    static let maximumAttempts = 3
    private static let retryDelays: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1)]

    private let workspace: DefaultBrowserWorkspace
    private let recordStore: HandlerPreservationRecordStoring
    private let applicationURL: URL
    private let scheduler: HandlerRestorationScheduling
    private let isCurrentApplicationDefault: (String) -> Bool
    private let completion: (HandlerPreservationRestorationSummary) -> Void
    private var record: HandlerPreservationRecord
    private var results: [String: HandlerPreservationSchemeResult] = [:]
    private var verifiedSchemes = Set<String>()
    private var schemesToRestore: [String] = []
    private var nextSchemeIndex = 0

    init(
        workspace: DefaultBrowserWorkspace,
        recordStore: HandlerPreservationRecordStoring,
        record: HandlerPreservationRecord,
        applicationURL: URL,
        scheduler: HandlerRestorationScheduling,
        isCurrentApplicationDefault: @escaping (String) -> Bool,
        completion: @escaping (HandlerPreservationRestorationSummary) -> Void
    ) {
        self.workspace = workspace
        self.recordStore = recordStore
        self.record = record
        self.applicationURL = applicationURL
        self.scheduler = scheduler
        self.isCurrentApplicationDefault = isCurrentApplicationDefault
        self.completion = completion
    }

    func start() {
        scheduleNextAttempt()
    }

    private func scheduleNextAttempt() {
        guard record.attemptCount < Self.maximumAttempts else {
            finishExhausted()
            return
        }
        let delay = Self.retryDelays[record.attemptCount]
        scheduler.schedule(after: delay) { [weak self] in
            self?.beginAttempt()
        }
    }

    private func beginAttempt() {
        guard record.attemptCount < Self.maximumAttempts else {
            finishExhausted()
            return
        }

        record = HandlerPreservationRecord(
            sourceVersion: record.sourceVersion,
            sourceBuild: record.sourceBuild,
            targetVersion: record.targetVersion,
            targetBuild: record.targetBuild,
            applicationURL: record.applicationURL,
            ownedHTTP: record.ownedHTTP,
            ownedHTTPS: record.ownedHTTPS,
            attemptCount: record.attemptCount + 1
        )
        recordStore.save(record)
        LinkGateLog.updater.debug("Handler restoration attempt=\(self.record.attemptCount, privacy: .public)")
        schemesToRestore = []
        nextSchemeIndex = 0

        for scheme in ["http", "https"] {
            guard owns(scheme) else {
                results[scheme] = .notOwnedBeforeUpdate
                LinkGateLog.updater.debug("Handler restoration scheme=\(scheme, privacy: .public) result=not-owned-before-update")
                continue
            }
            if isCurrentApplicationDefault(scheme) {
                if results[scheme] == nil || results[scheme] == .registrationFailed || results[scheme] == .verificationFailed {
                    results[scheme] = .alreadyOwnedByCurrentApplication
                }
                verifiedSchemes.insert(scheme)
                LinkGateLog.updater.debug("Handler restoration scheme=\(scheme, privacy: .public) result=already-correct")
            } else {
                verifiedSchemes.remove(scheme)
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
                LinkGateLog.updater.error("Handler restoration scheme=\(scheme, privacy: .public) result=registration-failed")
            } else if self.isCurrentApplicationDefault(scheme) {
                self.results[scheme] = .restored
                self.verifiedSchemes.insert(scheme)
                LinkGateLog.updater.info("Handler restoration scheme=\(scheme, privacy: .public) result=restored")
            } else {
                self.results[scheme] = .verificationFailed
                LinkGateLog.updater.error("Handler restoration scheme=\(scheme, privacy: .public) result=verification-failed")
            }
            self.restoreNextScheme()
        }
    }

    private func finish() {
        guard allOwnedSchemesVerified else {
            scheduleNextAttempt()
            return
        }
        recordStore.remove()
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
        LinkGateLog.updater.info("Handler restoration completed disposition=\(self.diagnosticDisposition(disposition), privacy: .public)")
    }

    private func finishExhausted() {
        recordStore.remove()
        let http = resultForExhaustion(scheme: "http")
        let https = resultForExhaustion(scheme: "https")
        completion(.init(disposition: .exhausted, http: http, https: https))
        LinkGateLog.updater.error("Handler restoration completed disposition=exhausted")
    }

    private func owns(_ scheme: String) -> Bool {
        switch scheme {
        case "http": record.ownedHTTP
        case "https": record.ownedHTTPS
        default: false
        }
    }

    private var allOwnedSchemesVerified: Bool {
        ["http", "https"].allSatisfy { !owns($0) || verifiedSchemes.contains($0) }
    }

    private func resultForExhaustion(scheme: String) -> HandlerPreservationSchemeResult {
        guard owns(scheme) else { return .notOwnedBeforeUpdate }
        return results[scheme] ?? .verificationFailed
    }

    private func diagnosticDisposition(_ disposition: HandlerPreservationRestorationDisposition) -> String {
        switch disposition {
        case .noPendingRecord: "no-pending-record"
        case .gated: "gated"
        case .alreadyPreservedOrNotOwned: "already-preserved-or-not-owned"
        case .restored: "restored"
        case .registrationFailed: "registration-failed"
        case .verificationFailed: "verification-failed"
        case .exhausted: "exhausted"
        }
    }
}
