import Foundation
import XCTest
@testable import LinkGate

// Acceptance Contract mapping:
// P1: Immediately before Sparkle installs an update, capture HTTP and HTTPS ownership independently
// through the public workspace seam. Ownership requires the current bundle instance, not merely a
// matching bundle identifier.
// P2: On the matching post-update launch, restore only schemes the replaced app owned. Each
// registration must target the current bundle and must be verified by a second exact-path lookup.
// P3: A preservation record is bounded one-shot update state. Records for another target
// version/build or bundle location must not mutate Launch Services. A valid target record remains
// persisted across transient verification failure and is consumed only after exact-path success or
// finite terminal exhaustion; it cannot reset defaults again on subsequent normal launches.
// P4: A structured restoration summary distinguishes no record, gated/no-mutation, restoration,
// and terminal exhaustion without treating a successful registration callback as proof.
@MainActor
final class HandlerPreservationTests: XCTestCase {
    private let bundleIdentifier = "com.nickghardwick.LinkGate"
    private let applicationURL = URL(fileURLWithPath: "/Applications/LinkGate.app")
    private let alternateLinkGateURL = URL(fileURLWithPath: "/repo/Debug/LinkGate.app")
    private let otherBrowserURL = URL(fileURLWithPath: "/Applications/Other Browser.app")
    private let sourceVersion = "0.1.6"
    private let sourceBuild = "8"
    private let targetVersion = "0.1.7"
    private let targetBuild = "9"

    func testSnapshotRecordsOwnershipForBothSchemesWhenCurrentBundleOwnsBoth() {
        let workspace = makeWorkspace(http: applicationURL, https: applicationURL)
        let store = HandlerPreservationRecordStoreFake()
        let preservation = makePreservation(workspace: workspace, store: store)

        preservation.snapshotBeforeInstallation(targetVersion: targetVersion, targetBuild: targetBuild)

        XCTAssertEqual(
            store.record,
            HandlerPreservationRecord(
                sourceVersion: sourceVersion,
                sourceBuild: sourceBuild,
                targetVersion: targetVersion,
                targetBuild: targetBuild,
                applicationURL: applicationURL,
                ownedHTTP: true,
                ownedHTTPS: true,
                attemptCount: 0
            )
        )
        XCTAssertEqual(workspace.lookupSchemes, ["http", "https"])
        XCTAssertTrue(workspace.setDefaultCalls.isEmpty)
    }

    func testSnapshotRecordsSchemeOwnershipIndependently() {
        let workspace = makeWorkspace(http: applicationURL, https: otherBrowserURL)
        let store = HandlerPreservationRecordStoreFake()
        let preservation = makePreservation(workspace: workspace, store: store)

        preservation.snapshotBeforeInstallation(targetVersion: targetVersion, targetBuild: targetBuild)

        XCTAssertEqual(store.record?.ownedHTTP, true)
        XCTAssertEqual(store.record?.ownedHTTPS, false)
    }

    func testSnapshotDoesNotTreatSameIdentifierAtAlternateLocationAsOwned() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: alternateLinkGateURL)
        let store = HandlerPreservationRecordStoreFake()
        let preservation = makePreservation(workspace: workspace, store: store)

        preservation.snapshotBeforeInstallation(targetVersion: targetVersion, targetBuild: targetBuild)

        XCTAssertEqual(store.record?.ownedHTTP, false)
        XCTAssertEqual(store.record?.ownedHTTPS, false)
    }

    func testRestoreClaimsPreviouslyOwnedHTTPWhenAlternateSameIdentifierOwnsItAfterUpdate() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: otherBrowserURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord(ownedHTTP: true, ownedHTTPS: false))
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }

        XCTAssertEqual(workspace.setDefaultCalls, [.init(applicationURL: applicationURL, scheme: "http")])
        XCTAssertNil(summary)

        workspace.applicationsToOpen["http"] = applicationURL
        workspace.completeSetDefault(forScheme: "http", error: nil)

        XCTAssertEqual(summary?.disposition, .restored)
        XCTAssertEqual(summary?.http, .restored)
        XCTAssertEqual(summary?.https, .notOwnedBeforeUpdate)
        XCTAssertNil(store.record)
    }

    func testRestoreClaimsPreviouslyOwnedHTTPSWhenAlternateSameIdentifierOwnsItAfterUpdate() {
        let workspace = makeWorkspace(http: otherBrowserURL, https: alternateLinkGateURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord(ownedHTTP: false, ownedHTTPS: true))
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }

        XCTAssertEqual(workspace.setDefaultCalls, [.init(applicationURL: applicationURL, scheme: "https")])
        workspace.applicationsToOpen["https"] = applicationURL
        workspace.completeSetDefault(forScheme: "https", error: nil)

        XCTAssertEqual(summary?.disposition, .restored)
        XCTAssertEqual(summary?.http, .notOwnedBeforeUpdate)
        XCTAssertEqual(summary?.https, .restored)
        XCTAssertNil(store.record)
    }

    func testRestoreHandlesPreviouslyOwnedSchemesIndependentlyInHTTPThenHTTPSOrder() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: alternateLinkGateURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord(ownedHTTP: true, ownedHTTPS: true))
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }
        XCTAssertEqual(workspace.setDefaultCalls, [.init(applicationURL: applicationURL, scheme: "http")])

        workspace.applicationsToOpen["http"] = applicationURL
        workspace.completeSetDefault(forScheme: "http", error: nil)
        XCTAssertEqual(
            workspace.setDefaultCalls,
            [
                .init(applicationURL: applicationURL, scheme: "http"),
                .init(applicationURL: applicationURL, scheme: "https"),
            ]
        )

        workspace.applicationsToOpen["https"] = applicationURL
        workspace.completeSetDefault(forScheme: "https", error: nil)

        XCTAssertEqual(summary?.disposition, .restored)
        XCTAssertEqual(summary?.http, .restored)
        XCTAssertEqual(summary?.https, .restored)
        XCTAssertNil(store.record)
    }

    func testRestoreDoesNotStealSchemesNotOwnedBeforeUpdate() {
        let workspace = makeWorkspace(http: otherBrowserURL, https: otherBrowserURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord(ownedHTTP: false, ownedHTTPS: false))
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }

        XCTAssertTrue(workspace.setDefaultCalls.isEmpty)
        XCTAssertEqual(summary?.disposition, .alreadyPreservedOrNotOwned)
        XCTAssertEqual(summary?.http, .notOwnedBeforeUpdate)
        XCTAssertEqual(summary?.https, .notOwnedBeforeUpdate)
        XCTAssertNil(store.record)
    }

    func testRestoreDoesNotRegisterSchemesAlreadyPreservedByCurrentBundle() {
        let workspace = makeWorkspace(http: applicationURL, https: applicationURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord(ownedHTTP: true, ownedHTTPS: true))
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }

        XCTAssertTrue(workspace.setDefaultCalls.isEmpty)
        XCTAssertEqual(summary?.disposition, .alreadyPreservedOrNotOwned)
        XCTAssertEqual(summary?.http, .alreadyOwnedByCurrentApplication)
        XCTAssertEqual(summary?.https, .alreadyOwnedByCurrentApplication)
        XCTAssertNil(store.record)
    }

    func testStaleTargetVersionRecordDoesNotMutateHandlers() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: alternateLinkGateURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord())
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: "0.1.8",
            currentBuild: "10"
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }

        XCTAssertTrue(workspace.setDefaultCalls.isEmpty)
        XCTAssertEqual(summary?.disposition, .gated)
        XCTAssertEqual(summary?.http, .notAttempted)
        XCTAssertEqual(summary?.https, .notAttempted)
    }

    func testSourceVersionRecordIsRetainedAndInertUntilTheExpectedUpdatedLaunch() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: alternateLinkGateURL)
        let record = makeRecord()
        let store = HandlerPreservationRecordStoreFake(record: record)
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: sourceVersion,
            currentBuild: sourceBuild
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }

        XCTAssertTrue(workspace.setDefaultCalls.isEmpty)
        XCTAssertEqual(summary?.disposition, .gated)
        XCTAssertEqual(summary?.http, .notAttempted)
        XCTAssertEqual(summary?.https, .notAttempted)
        XCTAssertEqual(store.record, record)
    }

    func testRecordForAnotherBundleLocationDoesNotMutateHandlers() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: alternateLinkGateURL)
        let store = HandlerPreservationRecordStoreFake(
            record: makeRecord(applicationURL: URL(fileURLWithPath: "/Applications/LinkGate Old.app"))
        )
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }

        XCTAssertTrue(workspace.setDefaultCalls.isEmpty)
        XCTAssertEqual(summary?.disposition, .gated)
        XCTAssertEqual(summary?.http, .notAttempted)
        XCTAssertEqual(summary?.https, .notAttempted)
        XCTAssertNotNil(store.record)
    }

    func testUnrelatedVersionRecordForCurrentLocationIsDiscardedAndInert() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: alternateLinkGateURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord())
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: "0.1.5",
            currentBuild: "7"
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }

        XCTAssertTrue(workspace.setDefaultCalls.isEmpty)
        XCTAssertEqual(summary?.disposition, .gated)
        XCTAssertEqual(summary?.http, .notAttempted)
        XCTAssertEqual(summary?.https, .notAttempted)
        XCTAssertNil(store.record)
    }

    func testRecordDoesNotMutateHandlersWhenCurrentBundleIdentifierIsNotLinkGate() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: alternateLinkGateURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord())
        let preservation = HandlerPreservationController(
            workspace: workspace,
            recordStore: store,
            applicationURL: applicationURL,
            bundleIdentifier: "com.example.OtherApplication",
            currentVersion: targetVersion,
            currentBuild: targetBuild
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }

        XCTAssertTrue(workspace.setDefaultCalls.isEmpty)
        XCTAssertEqual(summary?.disposition, .gated)
        XCTAssertEqual(summary?.http, .notAttempted)
        XCTAssertEqual(summary?.https, .notAttempted)
    }

    func testNoPendingRecordDoesNotMutateHandlers() {
        let workspace = makeWorkspace(http: otherBrowserURL, https: otherBrowserURL)
        let store = HandlerPreservationRecordStoreFake()
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }

        XCTAssertTrue(workspace.setDefaultCalls.isEmpty)
        XCTAssertEqual(summary?.disposition, .noPendingRecord)
        XCTAssertEqual(summary?.http, .notAttempted)
        XCTAssertEqual(summary?.https, .notAttempted)
    }

    func testFailedVerificationKeepsTheTargetRecordAndSchedulesTheConfiguredRetry() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: otherBrowserURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord(ownedHTTP: true, ownedHTTPS: false))
        let scheduler = ManualHandlerRestorationScheduler()
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild,
            scheduler: scheduler
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }

        XCTAssertTrue(workspace.setDefaultCalls.isEmpty)
        XCTAssertEqual(scheduler.scheduledDelays, [.milliseconds(250)])
        XCTAssertNotNil(store.record)

        scheduler.runNext()
        workspace.completeSetDefault(forScheme: "http", error: nil)

        XCTAssertNil(summary)
        XCTAssertEqual(store.record?.attemptCount, 1)
        XCTAssertEqual(scheduler.scheduledDelays, [.milliseconds(500)])
    }

    func testTransientVerificationFailureRetriesAndConsumesOnlyAfterExactPathVerification() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: otherBrowserURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord(ownedHTTP: true, ownedHTTPS: false))
        let scheduler = ManualHandlerRestorationScheduler()
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild,
            scheduler: scheduler
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }
        scheduler.runNext()
        workspace.completeSetDefault(forScheme: "http", error: nil)

        XCTAssertNotNil(store.record)
        XCTAssertNil(summary)
        XCTAssertEqual(workspace.setDefaultCalls, [.init(applicationURL: applicationURL, scheme: "http")])

        scheduler.runNext()
        workspace.applicationsToOpen["http"] = applicationURL
        workspace.completeSetDefault(forScheme: "http", error: nil)

        XCTAssertEqual(
            workspace.setDefaultCalls,
            [
                .init(applicationURL: applicationURL, scheme: "http"),
                .init(applicationURL: applicationURL, scheme: "http"),
            ]
        )
        XCTAssertEqual(summary?.disposition, .restored)
        XCTAssertEqual(summary?.http, .restored)
        XCTAssertEqual(summary?.https, .notOwnedBeforeUpdate)
        XCTAssertNil(store.record)
    }

    func testRegistrationFailureRemainsPendingForTheNextBoundedAttempt() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: otherBrowserURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord(ownedHTTP: true, ownedHTTPS: false))
        let scheduler = ManualHandlerRestorationScheduler()
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild,
            scheduler: scheduler
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }
        scheduler.runNext()
        workspace.completeSetDefault(
            forScheme: "http",
            error: NSError(domain: "LinkGateTests", code: 17)
        )

        XCTAssertNil(summary)
        XCTAssertEqual(store.record?.attemptCount, 1)
        XCTAssertEqual(scheduler.scheduledDelays, [.milliseconds(500)])

        scheduler.runNext()
        workspace.applicationsToOpen["http"] = applicationURL
        workspace.completeSetDefault(forScheme: "http", error: nil)

        XCTAssertEqual(summary?.disposition, .restored)
        XCTAssertNil(store.record)
    }

    func testNaturalHandlerRecoveryBeforeRetryReportsVerifiedSuccessInsteadOfStaleFailure() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: otherBrowserURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord(ownedHTTP: true, ownedHTTPS: false))
        let scheduler = ManualHandlerRestorationScheduler()
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild,
            scheduler: scheduler
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }
        scheduler.runNext()
        workspace.completeSetDefault(forScheme: "http", error: nil)

        // Launch Services can converge without LinkGate issuing a second registration.
        workspace.applicationsToOpen["http"] = applicationURL
        scheduler.runNext()

        XCTAssertEqual(workspace.setDefaultCalls, [.init(applicationURL: applicationURL, scheme: "http")])
        XCTAssertEqual(summary?.http, .alreadyOwnedByCurrentApplication)
        XCTAssertEqual(summary?.https, .notOwnedBeforeUpdate)
        XCTAssertTrue(
            summary.map { [.restored, .alreadyPreservedOrNotOwned].contains($0.disposition) } ?? false,
            "A later exact-path lookup must supersede the first transient verification failure."
        )
        XCTAssertNil(store.record)
    }

    func testRetryDoesNotReregisterSchemeThatVerifiedOnAnEarlierAttempt() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: alternateLinkGateURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord(ownedHTTP: true, ownedHTTPS: true))
        let scheduler = ManualHandlerRestorationScheduler()
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild,
            scheduler: scheduler
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }
        scheduler.runNext()

        workspace.applicationsToOpen["http"] = applicationURL
        workspace.completeSetDefault(forScheme: "http", error: nil)
        workspace.completeSetDefault(forScheme: "https", error: nil)

        XCTAssertNotNil(store.record)
        XCTAssertEqual(
            workspace.setDefaultCalls,
            [
                .init(applicationURL: applicationURL, scheme: "http"),
                .init(applicationURL: applicationURL, scheme: "https"),
            ]
        )

        scheduler.runNext()
        workspace.applicationsToOpen["https"] = applicationURL
        workspace.completeSetDefault(forScheme: "https", error: nil)

        XCTAssertEqual(
            workspace.setDefaultCalls,
            [
                .init(applicationURL: applicationURL, scheme: "http"),
                .init(applicationURL: applicationURL, scheme: "https"),
                .init(applicationURL: applicationURL, scheme: "https"),
            ]
        )
        XCTAssertEqual(summary?.disposition, .restored)
        XCTAssertNil(store.record)
    }

    func testRetryReregistersPreviouslyVerifiedSchemeWhenItIsDisplacedBeforeTheNextAttempt() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: alternateLinkGateURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord(ownedHTTP: true, ownedHTTPS: true))
        let scheduler = ManualHandlerRestorationScheduler()
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild,
            scheduler: scheduler
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }
        scheduler.runNext()
        workspace.applicationsToOpen["http"] = applicationURL
        workspace.completeSetDefault(forScheme: "http", error: nil)
        workspace.completeSetDefault(forScheme: "https", error: nil)

        // Launch Services can still displace a handler that verified earlier in the recovery
        // window. A later attempt must re-resolve every owned scheme before declaring success.
        workspace.applicationsToOpen["http"] = alternateLinkGateURL
        scheduler.runNext()

        XCTAssertEqual(
            workspace.setDefaultCalls,
            [
                .init(applicationURL: applicationURL, scheme: "http"),
                .init(applicationURL: applicationURL, scheme: "https"),
                .init(applicationURL: applicationURL, scheme: "http"),
            ]
        )

        workspace.applicationsToOpen["http"] = applicationURL
        workspace.completeSetDefault(forScheme: "http", error: nil)
        workspace.applicationsToOpen["https"] = applicationURL
        workspace.completeSetDefault(forScheme: "https", error: nil)

        XCTAssertEqual(
            workspace.setDefaultCalls,
            [
                .init(applicationURL: applicationURL, scheme: "http"),
                .init(applicationURL: applicationURL, scheme: "https"),
                .init(applicationURL: applicationURL, scheme: "http"),
                .init(applicationURL: applicationURL, scheme: "https"),
            ]
        )
        XCTAssertEqual(summary?.disposition, .restored)
        XCTAssertNil(store.record)
    }

    func testRetriesNeverRegisterASchemeThatWasNotOwnedBeforeUpdate() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: otherBrowserURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord(ownedHTTP: true, ownedHTTPS: false))
        let scheduler = ManualHandlerRestorationScheduler()
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild,
            scheduler: scheduler
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }
        scheduler.runNext()
        workspace.completeSetDefault(forScheme: "http", error: nil)
        scheduler.runNext()
        workspace.applicationsToOpen["http"] = applicationURL
        workspace.completeSetDefault(forScheme: "http", error: nil)

        XCTAssertTrue(workspace.setDefaultCalls.allSatisfy { $0.scheme == "http" })
        XCTAssertEqual(summary?.https, .notOwnedBeforeUpdate)
        XCTAssertNil(store.record)
    }

    func testRetryExhaustionConsumesRecordAfterThreeFailedVerificationAttempts() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: otherBrowserURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord(ownedHTTP: true, ownedHTTPS: false))
        let scheduler = ManualHandlerRestorationScheduler()
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild,
            scheduler: scheduler
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }
        scheduler.runNext()
        workspace.completeSetDefault(forScheme: "http", error: nil)
        scheduler.runNext()
        workspace.completeSetDefault(forScheme: "http", error: nil)

        XCTAssertEqual(store.record?.attemptCount, 2)
        XCTAssertEqual(scheduler.scheduledDelays, [.seconds(1)])

        scheduler.runNext()
        workspace.completeSetDefault(forScheme: "http", error: nil)

        XCTAssertEqual(summary?.disposition, .exhausted)
        XCTAssertEqual(summary?.http, .verificationFailed)
        XCTAssertEqual(summary?.https, .notOwnedBeforeUpdate)
        XCTAssertNil(store.record)
        XCTAssertTrue(scheduler.scheduledDelays.isEmpty)
        XCTAssertEqual(workspace.setDefaultCalls.count, 3)
    }

    func testPersistedAttemptCountCannotResetTheFiniteRetryBudgetAfterRelaunch() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: otherBrowserURL)
        let store = HandlerPreservationRecordStoreFake(
            record: makeRecord(ownedHTTP: true, ownedHTTPS: false, attemptCount: 2)
        )
        let scheduler = ManualHandlerRestorationScheduler()
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild,
            scheduler: scheduler
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }
        scheduler.runNext()
        workspace.completeSetDefault(forScheme: "http", error: nil)

        XCTAssertEqual(workspace.setDefaultCalls.count, 1)
        XCTAssertEqual(summary?.disposition, .exhausted)
        XCTAssertNil(store.record)
        XCTAssertTrue(scheduler.scheduledDelays.isEmpty)
    }

    func testMalformedNegativeAttemptCountIsDiscardedWithoutSchedulingOrMutatingHandlers() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: alternateLinkGateURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord(attemptCount: -1))
        let scheduler = ManualHandlerRestorationScheduler()
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild,
            scheduler: scheduler
        )
        var summary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { summary = $0 }

        XCTAssertTrue(workspace.setDefaultCalls.isEmpty)
        XCTAssertTrue(scheduler.scheduledDelays.isEmpty)
        XCTAssertEqual(summary?.disposition, .gated)
        XCTAssertNil(store.record)
    }

    func testCompletedRecordCannotResetAHandlerOnLaterNormalLaunch() {
        let workspace = makeWorkspace(http: alternateLinkGateURL, https: otherBrowserURL)
        let store = HandlerPreservationRecordStoreFake(record: makeRecord(ownedHTTP: true, ownedHTTPS: false))
        let preservation = makePreservation(
            workspace: workspace,
            store: store,
            currentVersion: targetVersion,
            currentBuild: targetBuild
        )
        var firstSummary: HandlerPreservationRestorationSummary?

        preservation.restoreIfNeeded { firstSummary = $0 }
        workspace.applicationsToOpen["http"] = applicationURL
        workspace.completeSetDefault(forScheme: "http", error: nil)

        XCTAssertEqual(firstSummary?.disposition, .restored)
        XCTAssertNil(store.record)

        workspace.applicationsToOpen["http"] = otherBrowserURL
        var secondSummary: HandlerPreservationRestorationSummary?
        preservation.restoreIfNeeded { secondSummary = $0 }

        XCTAssertEqual(secondSummary?.disposition, .noPendingRecord)
        XCTAssertEqual(workspace.setDefaultCalls.count, 1)
    }

    func testUserDefaultsStorePersistsAndRemovesOnlyTheOneShotRecord() {
        let suiteName = "LinkGateTests.HandlerPreservation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "LinkGateTests.handlerPreservation"
        let expectedRecord = makeRecord()

        let writer = UserDefaultsHandlerPreservationRecordStore(
            userDefaults: defaults,
            storageKey: storageKey
        )
        writer.save(expectedRecord)

        let reader = UserDefaultsHandlerPreservationRecordStore(
            userDefaults: defaults,
            storageKey: storageKey
        )
        XCTAssertEqual(reader.load(), expectedRecord)

        reader.remove()

        XCTAssertNil(UserDefaultsHandlerPreservationRecordStore(
            userDefaults: defaults,
            storageKey: storageKey
        ).load())
    }

    func testLegacyPreservationRecordWithoutAttemptCountDecodesAsPending() throws {
        let legacyJSON = """
        {
          "sourceVersion": "0.1.6",
          "sourceBuild": "8",
          "targetVersion": "0.1.7",
          "targetBuild": "9",
          "applicationURL": "file:///Applications/LinkGate.app",
          "ownedHTTP": true,
          "ownedHTTPS": false
        }
        """

        let record = try JSONDecoder().decode(
            HandlerPreservationRecord.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(record.attemptCount, 0)
    }

    private func makePreservation(
        workspace: HandlerPreservationWorkspaceFake,
        store: HandlerPreservationRecordStoreFake,
        currentVersion: String? = nil,
        currentBuild: String? = nil,
        scheduler: (any HandlerRestorationScheduling)? = nil
    ) -> HandlerPreservationController {
        HandlerPreservationController(
            workspace: workspace,
            recordStore: store,
            applicationURL: applicationURL,
            bundleIdentifier: bundleIdentifier,
            currentVersion: currentVersion ?? sourceVersion,
            currentBuild: currentBuild ?? sourceBuild,
            restorationScheduler: scheduler ?? ImmediateHandlerRestorationScheduler()
        )
    }

    private func makeWorkspace(http: URL, https: URL) -> HandlerPreservationWorkspaceFake {
        HandlerPreservationWorkspaceFake(
            applicationsToOpen: ["http": http, "https": https],
            bundleIdentifiers: [
                applicationURL: bundleIdentifier,
                alternateLinkGateURL: bundleIdentifier,
                otherBrowserURL: "com.example.OtherBrowser",
            ]
        )
    }

    private func makeRecord(
        applicationURL: URL? = nil,
        ownedHTTP: Bool = true,
        ownedHTTPS: Bool = true,
        attemptCount: Int = 0
    ) -> HandlerPreservationRecord {
        HandlerPreservationRecord(
            sourceVersion: sourceVersion,
            sourceBuild: sourceBuild,
            targetVersion: targetVersion,
            targetBuild: targetBuild,
            applicationURL: applicationURL ?? self.applicationURL,
            ownedHTTP: ownedHTTP,
            ownedHTTPS: ownedHTTPS,
            attemptCount: attemptCount
        )
    }
}

@MainActor
private final class ImmediateHandlerRestorationScheduler: HandlerRestorationScheduling {
    func schedule(after delay: Duration, _ operation: @escaping @MainActor () -> Void) {
        operation()
    }
}

@MainActor
private final class ManualHandlerRestorationScheduler: HandlerRestorationScheduling {
    private(set) var scheduledDelays: [Duration] = []
    private var operations: [@MainActor () -> Void] = []

    func schedule(after delay: Duration, _ operation: @escaping @MainActor () -> Void) {
        scheduledDelays.append(delay)
        operations.append(operation)
    }

    func runNext() {
        XCTAssertFalse(operations.isEmpty, "Expected a scheduled restoration operation.")
        guard !operations.isEmpty else { return }
        let operation = operations.removeFirst()
        scheduledDelays.removeFirst()
        operation()
    }
}

@MainActor
private final class HandlerPreservationRecordStoreFake: HandlerPreservationRecordStoring {
    var record: HandlerPreservationRecord?

    init(record: HandlerPreservationRecord? = nil) {
        self.record = record
    }

    func load() -> HandlerPreservationRecord? {
        record
    }

    func save(_ record: HandlerPreservationRecord) {
        self.record = record
    }

    func remove() {
        record = nil
    }
}

@MainActor
private final class HandlerPreservationWorkspaceFake: DefaultBrowserWorkspace {
    struct SetDefaultCall: Equatable {
        let applicationURL: URL
        let scheme: String
    }

    var applicationsToOpen: [String: URL]
    var bundleIdentifiers: [URL: String]
    private(set) var lookupSchemes: [String] = []
    private(set) var setDefaultCalls: [SetDefaultCall] = []
    private var completions: [String: (Error?) -> Void] = [:]

    init(
        applicationsToOpen: [String: URL],
        bundleIdentifiers: [URL: String]
    ) {
        self.applicationsToOpen = applicationsToOpen
        self.bundleIdentifiers = bundleIdentifiers
    }

    func applicationURL(toOpen url: URL) -> URL? {
        let scheme = url.scheme ?? ""
        lookupSchemes.append(scheme)
        return applicationsToOpen[scheme]
    }

    func bundleIdentifier(at url: URL) -> String? {
        bundleIdentifiers[url]
    }

    func setDefaultApplication(
        at url: URL,
        forScheme scheme: String,
        completion: @escaping (Error?) -> Void
    ) {
        setDefaultCalls.append(.init(applicationURL: url, scheme: scheme))
        completions[scheme] = completion
    }

    func completeSetDefault(forScheme scheme: String, error: Error?) {
        let completion = completions.removeValue(forKey: scheme)
        completion?(error)
    }
}
