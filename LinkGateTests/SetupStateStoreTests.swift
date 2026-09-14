import Foundation
import XCTest
@testable import LinkGate

// Acceptance Contract mapping:
// Task 2: setup completion is an independent, versioned UserDefaults marker. Missing,
// malformed, or lower markers require setup; equal or future markers are complete; and a newer
// persisted marker is never downgraded.
final class SetupStateStoreTests: XCTestCase {
    private let storageKey = "LinkGate.setupCompletedVersion"
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LinkGateTests.SetupStateStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testNoMarkerRequiresSetup() {
        XCTAssertTrue(makeStore().needsSetup(currentVersion: 1))
    }

    func testLowerMarkerRequiresSetup() {
        defaults.set(0, forKey: storageKey)

        XCTAssertTrue(makeStore().needsSetup(currentVersion: 1))
    }

    func testCurrentMarkerCompletesSetup() {
        defaults.set(1, forKey: storageKey)

        XCTAssertFalse(makeStore().needsSetup(currentVersion: 1))
    }

    func testFutureMarkerCompletesSetup() {
        defaults.set(2, forKey: storageKey)

        XCTAssertFalse(makeStore().needsSetup(currentVersion: 1))
    }

    func testLowerMarkerRequiresSetupWhenTheRunningVersionAdvances() {
        defaults.set(1, forKey: storageKey)

        XCTAssertTrue(makeStore().needsSetup(currentVersion: 2))
    }

    func testMalformedMarkerRequiresSetup() {
        defaults.set("1", forKey: storageKey)

        XCTAssertTrue(makeStore().needsSetup(currentVersion: 1))
    }

    func testMarkCompleteStoresExactlyTheRequestedCurrentVersion() throws {
        let store = makeStore()

        try store.markSetupCompleted(version: 1)

        XCTAssertEqual(defaults.object(forKey: storageKey) as? Int, 1)
        XCTAssertFalse(store.needsSetup(currentVersion: 1))
    }

    func testMarkCompleteTwiceIsSafe() throws {
        let store = makeStore()

        try store.markSetupCompleted(version: 1)
        XCTAssertNoThrow(try store.markSetupCompleted(version: 1))

        XCTAssertEqual(defaults.object(forKey: storageKey) as? Int, 1)
    }

    func testMarkCompleteNeverDowngradesAFuturePersistedVersion() throws {
        defaults.set(2, forKey: storageKey)

        try makeStore().markSetupCompleted(version: 1)

        XCTAssertEqual(defaults.object(forKey: storageKey) as? Int, 2)
        XCTAssertFalse(makeStore().needsSetup(currentVersion: 1))
    }

    func testExistingLinkGatePreferencesWithoutSetupMarkerStillRequireSetup() {
        defaults.set(["version": 1, "rules": []], forKey: "LinkGate.routingRules")

        XCTAssertTrue(makeStore().needsSetup(currentVersion: 1))
    }

    private func makeStore() -> UserDefaultsSetupStateStore {
        UserDefaultsSetupStateStore(userDefaults: defaults, storageKey: storageKey)
    }
}
