import Foundation
import XCTest
@testable import LinkGate

// Acceptance Contract mapping:
// 7: canonical create/update reject duplicate identities, preserve edits in place, and permit self-edits.
// 8: persisted rules contain canonical browser bundle identifiers, not application paths or display names.
// 9: ordered CRUD reloads deterministically; malformed bytes and invalid/conflicting persisted entries
//    (including individually Codable-malformed and duplicate-stable-ID entries) are safely ignored
//    while valid entries remain available.
// Phase 04 A6: persistence distinguishes legacy and versioned data, preserves recoverable raw records,
// and refuses to overwrite storage it cannot safely understand.
// Browser ordering acceptance contract: a version-one envelope optionally carries a canonical global
// browser identity order; legacy rules migrate with their original bytes backed up, while malformed or
// unsupported persistence cannot cause an unsafe overwrite.
// Browser visibility acceptance contract: a version-one envelope optionally carries disabled browser
// identities; absent visibility data defaults every discovered browser to enabled and invalid data is
// ignored with a warning without making the stored rule payload unsafe to use.
final class RoutingRuleStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let storageKey = "LinkGateTests.routingRules"

    override func setUp() {
        super.setUp()
        suiteName = "LinkGateTests.RoutingRuleStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testCreateReadAndReinstantiationPreserveOrderedCanonicalRules() throws {
        let store = makeStore()

        let first = try store.create(
            matchType: .domainFamily,
            pattern: " Example.COM. ",
            browserBundleIdentifier: "com.example.first"
        )
        let second = try store.create(
            matchType: .urlPrefix,
            pattern: "https://shop.example.com/promo",
            browserBundleIdentifier: "com.example.second"
        )

        XCTAssertEqual(store.rules.map(\.id), [first.id, second.id])
        XCTAssertEqual(store.rules.map(\.pattern), ["example.com", "https://shop.example.com/promo"])
        XCTAssertEqual(store.rules.map(\.browserBundleIdentifier), ["com.example.first", "com.example.second"])

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.rules, store.rules)
    }

    func testUpdateReplacesRuleInPlaceAndAllowsItsOwnCanonicalIdentity() throws {
        let store = makeStore()
        let first = try store.create(
            matchType: .exactDomain,
            pattern: "example.com",
            browserBundleIdentifier: "com.example.first"
        )
        let second = try store.create(
            matchType: .domainFamily,
            pattern: "other.example",
            browserBundleIdentifier: "com.example.second"
        )

        let updated = try store.update(
            id: first.id,
            matchType: .exactDomain,
            pattern: "EXAMPLE.COM.",
            browserBundleIdentifier: "com.example.changed"
        )

        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(store.rules.map(\.id), [first.id, second.id])
        XCTAssertEqual(store.rules[0].pattern, "example.com")
        XCTAssertEqual(store.rules[0].browserBundleIdentifier, "com.example.changed")
    }

    func testCreatePersistsTrimmedBrowserBundleIdentifier() throws {
        let store = makeStore()

        let created = try store.create(
            matchType: .exactDomain,
            pattern: "example.com",
            browserBundleIdentifier: "  com.example.browser  "
        )

        XCTAssertEqual(created.browserBundleIdentifier, "com.example.browser")
        XCTAssertEqual(store.rules.first?.browserBundleIdentifier, "com.example.browser")
        XCTAssertEqual(makeStore().rules.first?.browserBundleIdentifier, "com.example.browser")
    }

    func testDuplicateCreateAndEditIntoAnotherIdentityAreRejectedWithoutOverwritingStoredRules() throws {
        let store = makeStore()
        let first = try store.create(
            matchType: .exactDomain,
            pattern: "example.com",
            browserBundleIdentifier: "com.example.first"
        )
        let second = try store.create(
            matchType: .domainFamily,
            pattern: "other.example",
            browserBundleIdentifier: "com.example.second"
        )
        let before = store.rules

        XCTAssertThrowsError(
            try store.create(
                matchType: .exactDomain,
                pattern: "EXAMPLE.COM.",
                browserBundleIdentifier: "com.example.replacement"
            )
        )
        XCTAssertThrowsError(
            try store.update(
                id: second.id,
                matchType: .exactDomain,
                pattern: "example.com",
                browserBundleIdentifier: "com.example.replacement"
            )
        )

        XCTAssertEqual(store.rules, before)
        XCTAssertEqual(store.rules.first?.id, first.id)
    }

    func testDeleteRemovesOnlyRequestedRuleAndPreservesSurvivorOrderAcrossReload() throws {
        let store = makeStore()
        let first = try store.create(matchType: .exactDomain, pattern: "first.example", browserBundleIdentifier: "com.example.first")
        let second = try store.create(matchType: .exactDomain, pattern: "second.example", browserBundleIdentifier: "com.example.second")
        let third = try store.create(matchType: .exactDomain, pattern: "third.example", browserBundleIdentifier: "com.example.third")

        try store.delete(id: second.id)

        XCTAssertEqual(store.rules.map(\.id), [first.id, third.id])
        XCTAssertEqual(makeStore().rules.map(\.id), [first.id, third.id])
    }

    func testUndecodablePersistedBytesLoadAsEmptyRulesWithoutThrowing() {
        defaults.set(Data([0x00, 0xFF, 0x01]), forKey: storageKey)

        let store = makeStore()

        XCTAssertTrue(store.rules.isEmpty)
    }

    func testReloadSkipsInvalidAndConflictingPersistedEntriesButKeepsValidOrder() throws {
        let first = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "first.example",
            browserBundleIdentifier: "com.example.first"
        )
        let invalidDomain = RoutingRule(
            id: UUID(),
            matchType: .domainFamily,
            pattern: "https://not-a-hostname.example",
            browserBundleIdentifier: "com.example.invalid"
        )
        let duplicateIdentity = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "FIRST.EXAMPLE.",
            browserBundleIdentifier: "com.example.duplicate"
        )
        let emptyBundleIdentifier = RoutingRule(
            id: UUID(),
            matchType: .urlPrefix,
            pattern: "https://valid.example/path",
            browserBundleIdentifier: ""
        )
        let finalValid = RoutingRule(
            id: UUID(),
            matchType: .urlPrefix,
            pattern: "HTTPS://Final.Example./path",
            browserBundleIdentifier: "com.example.final"
        )
        defaults.set(
            try JSONEncoder().encode([first, invalidDomain, duplicateIdentity, emptyBundleIdentifier, finalValid]),
            forKey: storageKey
        )

        let store = makeStore()

        XCTAssertEqual(store.rules.map(\.id), [first.id, finalValid.id])
        XCTAssertEqual(store.rules.map(\.pattern), ["first.example", "https://final.example/path"])
        XCTAssertEqual(store.rules.map(\.browserBundleIdentifier), ["com.example.first", "com.example.final"])
    }

    func testReloadSkipsIndividuallyCodableMalformedObjectBetweenValidRules() throws {
        let first = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "first.example",
            browserBundleIdentifier: "com.example.first"
        )
        let final = RoutingRule(
            id: UUID(),
            matchType: .domainFamily,
            pattern: "final.example",
            browserBundleIdentifier: "com.example.final"
        )
        let malformed: [String: Any] = [
            "id": "not-a-uuid",
            "matchType": "exactDomain",
            "pattern": "malformed.example",
            "browserBundleIdentifier": "com.example.malformed",
        ]
        let firstObject = try jsonObject(from: first)
        let finalObject = try jsonObject(from: final)
        defaults.set(
            try JSONSerialization.data(withJSONObject: [firstObject, malformed, finalObject]),
            forKey: storageKey
        )

        let store = makeStore()

        XCTAssertEqual(store.rules.map(\.id), [first.id, final.id])
    }

    func testReloadSkipsDuplicateStableIDWhilePreservingOtherUniqueValidRules() throws {
        let duplicatedID = UUID()
        let first = RoutingRule(
            id: duplicatedID,
            matchType: .exactDomain,
            pattern: "first.example",
            browserBundleIdentifier: "com.example.first"
        )
        let duplicateID = RoutingRule(
            id: duplicatedID,
            matchType: .domainFamily,
            pattern: "duplicate.example",
            browserBundleIdentifier: "com.example.duplicate"
        )
        let final = RoutingRule(
            id: UUID(),
            matchType: .urlPrefix,
            pattern: "https://final.example/path",
            browserBundleIdentifier: "com.example.final"
        )
        defaults.set(
            try JSONEncoder().encode([first, duplicateID, final]),
            forKey: storageKey
        )

        let store = makeStore()

        XCTAssertEqual(store.rules.map(\.id), [first.id, final.id])
        XCTAssertEqual(store.rules.map(\.pattern), ["first.example", "https://final.example/path"])
    }

    func testFreshDefaultsStayEmptyUntilFirstSaveThenUseVersionOneEnvelope() throws {
        XCTAssertNil(defaults.data(forKey: storageKey))

        let store = makeStore()

        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertNil(defaults.data(forKey: storageKey))

        let created = try store.create(
            matchType: .exactDomain,
            pattern: "fresh.example",
            browserBundleIdentifier: "com.example.fresh"
        )

        XCTAssertEqual(version(of: try storedJSONObject()), 1)
        XCTAssertEqual(decodedRules(from: try storedJSONObject()), [created])
        XCTAssertNil(defaults.data(forKey: "\(storageKey).legacyBackup"))
    }

    func testBrowserOrderPersistsAcrossStoreReinstantiationInVersionOneEnvelope() throws {
        let store = makeStore()
        let expectedOrder = ["bundle:com.example.third", "bundle:com.example.first", "path:/Applications/No-ID.app"]

        try store.saveBrowserOrder(expectedOrder)

        XCTAssertEqual(store.browserOrder, expectedOrder)
        XCTAssertEqual(browserOrder(from: try storedJSONObject()), expectedOrder)
        XCTAssertEqual(makeStore().browserOrder, expectedOrder)
        XCTAssertEqual(version(of: try storedJSONObject()), 1)
    }

    func testDisabledBrowserIdentifiersPersistAcrossStoreReinstantiationInVersionOneEnvelope() throws {
        let store = makeStore()
        let expectedDisabledIdentifiers: Set<String> = [
            "bundle:com.example.hidden",
            "path:/Applications/Hidden Copy.app",
        ]

        try store.saveDisabledBrowserIdentifiers(expectedDisabledIdentifiers)

        XCTAssertEqual(store.disabledBrowserIdentifiers, expectedDisabledIdentifiers)
        XCTAssertEqual(disabledBrowserIdentifiers(from: try storedJSONObject()), expectedDisabledIdentifiers)
        XCTAssertEqual(makeStore().disabledBrowserIdentifiers, expectedDisabledIdentifiers)
        XCTAssertEqual(version(of: try storedJSONObject()), 1)
    }

    func testAbsentVisibilityDataInVersionOneAndLegacyPayloadsDefaultsAllBrowsersToEnabled() throws {
        let versionOneRule = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "version-one.example",
            browserBundleIdentifier: "com.example.version-one"
        )
        defaults.set(
            try versionOneData(ruleObjects: [try jsonObject(from: versionOneRule)]),
            forKey: storageKey
        )

        XCTAssertTrue(makeStore().disabledBrowserIdentifiers.isEmpty)

        let legacyRule = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "legacy.example",
            browserBundleIdentifier: "com.example.legacy"
        )
        defaults.set(try JSONEncoder().encode([legacyRule]), forKey: storageKey)

        XCTAssertTrue(makeStore().disabledBrowserIdentifiers.isEmpty)
    }

    func testInvalidVersionOneVisibilityDataDefaultsToEnabledAndWarnsWithoutOverwritingStorage() throws {
        let validRule = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "valid.example",
            browserBundleIdentifier: "com.example.valid"
        )
        let originalBytes = try versionOneData(
            ruleObjects: [try jsonObject(from: validRule)],
            additionalFields: ["disabledBrowserIdentifiers": ["not": "an identity list"]]
        )
        defaults.set(originalBytes, forKey: storageKey)

        let store = makeStore()

        XCTAssertEqual(store.rules, [validRule])
        XCTAssertTrue(store.disabledBrowserIdentifiers.isEmpty)
        XCTAssertTrue(store.storageWarning?.localizedCaseInsensitiveContains("visibility") ?? false)
        XCTAssertEqual(defaults.data(forKey: storageKey), originalBytes)
    }

    func testLegacyArrayLoadsWithoutMutationAndFirstSaveBacksUpOriginalBytesBeforeVersionOneMigration() throws {
        let legacy = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "legacy.example",
            browserBundleIdentifier: "com.example.legacy"
        )
        let originalBytes = try JSONEncoder().encode([legacy])
        defaults.set(originalBytes, forKey: storageKey)

        let store = makeStore()

        XCTAssertEqual(store.rules, [legacy])
        XCTAssertEqual(defaults.data(forKey: storageKey), originalBytes)
        XCTAssertNil(defaults.data(forKey: "\(storageKey).legacyBackup"))

        let added = try store.create(
            matchType: .domainFamily,
            pattern: "new.example",
            browserBundleIdentifier: "com.example.new"
        )

        XCTAssertEqual(defaults.data(forKey: "\(storageKey).legacyBackup"), originalBytes)
        XCTAssertEqual(version(of: try storedJSONObject()), 1)
        XCTAssertEqual(decodedRules(from: try storedJSONObject()), [legacy, added])

        _ = try makeStore().update(
            id: added.id,
            matchType: .domainFamily,
            pattern: "updated.example",
            browserBundleIdentifier: "com.example.updated"
        )
        XCTAssertEqual(defaults.data(forKey: "\(storageKey).legacyBackup"), originalBytes)
    }

    func testSavingBrowserOrderMigratesLegacyRulesWithoutDroppingThemAndBacksUpOriginalBytes() throws {
        let legacy = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "legacy.example",
            browserBundleIdentifier: "com.example.legacy"
        )
        let originalBytes = try JSONEncoder().encode([legacy])
        defaults.set(originalBytes, forKey: storageKey)
        let expectedOrder = ["bundle:com.example.second", "bundle:com.example.first"]
        let store = makeStore()

        try store.saveBrowserOrder(expectedOrder)

        XCTAssertEqual(defaults.data(forKey: "\(storageKey).legacyBackup"), originalBytes)
        XCTAssertEqual(makeStore().rules, [legacy])
        XCTAssertEqual(makeStore().browserOrder, expectedOrder)
        XCTAssertEqual(browserOrder(from: try storedJSONObject()), expectedOrder)
    }

    func testVersionOneReloadAndEditsRoundTripStableOrderIDsAndUnavailableBrowserTargets() throws {
        let first = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "first.example",
            browserBundleIdentifier: "com.example.first"
        )
        let unavailable = RoutingRule(
            id: UUID(),
            matchType: .domainFamily,
            pattern: "unavailable.example",
            browserBundleIdentifier: "com.example.removed-browser"
        )
        let third = RoutingRule(
            id: UUID(),
            matchType: .urlPrefix,
            pattern: "https://third.example/path",
            browserBundleIdentifier: "com.example.third"
        )
        defaults.set(try versionOneData(ruleObjects: try [first, unavailable, third].map(jsonObject)), forKey: storageKey)

        let store = makeStore()

        XCTAssertEqual(store.rules, [first, unavailable, third])

        let updatedThird = try store.update(
            id: third.id,
            matchType: .urlPrefix,
            pattern: "https://third.example/updated",
            browserBundleIdentifier: "com.example.updated"
        )
        let reloaded = makeStore()

        XCTAssertEqual(version(of: try storedJSONObject()), 1)
        XCTAssertEqual(reloaded.rules.map(\.id), [first.id, unavailable.id, third.id])
        XCTAssertEqual(reloaded.rules, [first, unavailable, updatedThird])
        XCTAssertEqual(reloaded.rules[1].browserBundleIdentifier, "com.example.removed-browser")
    }

    func testMalformedVersionOneBrowserOrderFallsBackToNoSavedOrderWithoutDiscardingValidRules() throws {
        let validRule = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "valid.example",
            browserBundleIdentifier: "com.example.valid"
        )
        let originalBytes = try versionOneData(
            ruleObjects: [try jsonObject(from: validRule)],
            browserOrder: ["bundle:com.example.valid", "not-a-browser-identity", "bundle:com.example.valid"]
        )
        defaults.set(originalBytes, forKey: storageKey)

        let store = makeStore()

        XCTAssertEqual(store.rules, [validRule])
        XCTAssertNil(store.browserOrder)
        XCTAssertEqual(defaults.data(forKey: storageKey), originalBytes)
    }

    func testMalformedVersionOneBrowserOrderPathHintsPreserveValidRulesAndOrderWithoutOverwritingStorage() throws {
        let validRule = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "valid.example",
            browserBundleIdentifier: "com.example.valid"
        )
        let expectedOrder = ["bundle:com.example.valid"]
        let originalBytes = try versionOneData(
            ruleObjects: [try jsonObject(from: validRule)],
            browserOrder: expectedOrder,
            additionalFields: [
                "browserOrderPathHints": ["bundle:com.example.valid": "relative/not-a-normalized-path"],
            ]
        )
        defaults.set(originalBytes, forKey: storageKey)

        let store = makeStore()

        XCTAssertEqual(store.rules, [validRule])
        XCTAssertEqual(store.browserOrder, expectedOrder)
        XCTAssertTrue(store.browserOrderPathHints.isEmpty)
        XCTAssertTrue(store.storageWarning?.contains("hints") ?? false)
        XCTAssertEqual(defaults.data(forKey: storageKey), originalBytes)
    }

    func testEditingVersionOneRulePreservesSavedBrowserOrder() throws {
        let rule = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "original.example",
            browserBundleIdentifier: "com.example.original"
        )
        let expectedOrder = ["bundle:com.example.second", "bundle:com.example.first"]
        defaults.set(
            try versionOneData(ruleObjects: [try jsonObject(from: rule)], browserOrder: expectedOrder),
            forKey: storageKey
        )
        let store = makeStore()

        _ = try store.update(
            id: rule.id,
            matchType: .exactDomain,
            pattern: "updated.example",
            browserBundleIdentifier: "com.example.updated"
        )

        XCTAssertEqual(makeStore().browserOrder, expectedOrder)
        XCTAssertEqual(browserOrder(from: try storedJSONObject()), expectedOrder)
    }

    func testPartialMalformedAndUnknownVersionOneRecordsSurviveUpdateAndDeleteOfValidRules() throws {
        let edited = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "edited.example",
            browserBundleIdentifier: "com.example.edited"
        )
        let deleted = RoutingRule(
            id: UUID(),
            matchType: .domainFamily,
            pattern: "deleted.example",
            browserBundleIdentifier: "com.example.deleted"
        )
        let malformed: [String: Any] = [
            "id": "not-a-uuid",
            "matchType": "exactDomain",
            "pattern": "malformed.example",
            "browserBundleIdentifier": "com.example.malformed",
        ]
        let unknown: [String: Any] = [
            "recordVersion": 99,
            "opaque": ["keep": true, "nested": ["value": "unreadable-by-v1"]],
        ]
        defaults.set(
            try versionOneData(ruleObjects: [try jsonObject(from: edited), malformed, try jsonObject(from: deleted), unknown]),
            forKey: storageKey
        )
        let store = makeStore()

        XCTAssertEqual(store.rules, [edited, deleted])

        let updated = try store.update(
            id: edited.id,
            matchType: .exactDomain,
            pattern: "updated.example",
            browserBundleIdentifier: "com.example.updated"
        )
        try store.delete(id: deleted.id)

        XCTAssertEqual(
            try rawRuleObjects(from: storedJSONObject()).map(canonicalJSON),
            [try canonicalJSON(jsonObject(from: updated)), try canonicalJSON(malformed), try canonicalJSON(unknown)]
        )
        XCTAssertEqual(makeStore().rules, [updated])
    }

    func testRejectedDuplicateAndPrimitiveRecordsStayInertAndRecoverableAcrossValidEditsAndDeletes() throws {
        let retained = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "retained.example",
            browserBundleIdentifier: "com.example.retained"
        )
        let deleted = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "deleted.example",
            browserBundleIdentifier: "com.example.deleted"
        )
        let duplicateID = RoutingRule(
            id: retained.id,
            matchType: .domainFamily,
            pattern: "duplicate-id.example",
            browserBundleIdentifier: "com.example.duplicate-id"
        )
        let duplicateIdentity = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "DELETED.EXAMPLE.",
            browserBundleIdentifier: "com.example.duplicate-identity"
        )
        let malformedPrimitive = "not-a-routing-rule"
        defaults.set(
            try versionOneData(ruleObjects: [
                try jsonObject(from: retained),
                malformedPrimitive,
                try jsonObject(from: duplicateID),
                try jsonObject(from: deleted),
                NSNull(),
                try jsonObject(from: duplicateIdentity),
            ]),
            forKey: storageKey
        )
        let store = makeStore()

        XCTAssertEqual(store.rules, [retained, deleted])

        let updated = try store.update(
            id: retained.id,
            matchType: .exactDomain,
            pattern: "updated.example",
            browserBundleIdentifier: "com.example.updated"
        )
        try store.delete(id: deleted.id)

        let persistedPayload = try storedJSONObject()
        XCTAssertEqual(makeStore().rules, [updated])
        XCTAssertTrue(containsRule(id: duplicateID.id, pattern: duplicateID.pattern, in: persistedPayload))
        XCTAssertTrue(containsRule(id: duplicateIdentity.id, pattern: duplicateIdentity.pattern, in: persistedPayload))
        XCTAssertTrue(containsJSONValue(malformedPrimitive, in: persistedPayload))
        XCTAssertTrue(containsJSONNull(in: persistedPayload))
    }

    func testUnreadableWrongTypeAndFutureVersionPayloadsRefuseCreatesWithoutChangingOriginalBytes() throws {
        let validRule = RoutingRule(
            id: UUID(),
            matchType: .exactDomain,
            pattern: "future.example",
            browserBundleIdentifier: "com.example.future"
        )
        let wrongType = try JSONSerialization.data(withJSONObject: ["version": 1, "rules": "not-an-array"])
        let unknownFutureVersion = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "rules": [try jsonObject(from: validRule)],
        ])
        let booleanVersion = try JSONSerialization.data(withJSONObject: ["version": true, "rules": []])
        let fractionalVersion = try JSONSerialization.data(withJSONObject: ["version": 1.5, "rules": []])
        let unreadable = Data([0x00, 0xFF, 0x01])

        for originalBytes in [unreadable, wrongType, unknownFutureVersion, booleanVersion, fractionalVersion] {
            defaults.set(originalBytes, forKey: storageKey)
            let store = makeStore()

            XCTAssertTrue(store.rules.isEmpty)
            XCTAssertThrowsError(
                try store.create(
                    matchType: .exactDomain,
                    pattern: "should-not-overwrite.example",
                    browserBundleIdentifier: "com.example.new"
                )
            )
            XCTAssertThrowsError(
                try store.saveBrowserOrder(["bundle:com.example.browser"])
            )
            XCTAssertEqual(defaults.data(forKey: storageKey), originalBytes)
        }

        defaults.set("wrong-user-defaults-type", forKey: storageKey)
        let wrongTypeStore = makeStore()

        XCTAssertTrue(wrongTypeStore.rules.isEmpty)
        XCTAssertThrowsError(
            try wrongTypeStore.create(
                matchType: .exactDomain,
                pattern: "should-not-overwrite-string.example",
                browserBundleIdentifier: "com.example.new"
            )
        )
        XCTAssertThrowsError(
            try wrongTypeStore.saveBrowserOrder(["bundle:com.example.browser"])
        )
        XCTAssertEqual(defaults.string(forKey: storageKey), "wrong-user-defaults-type")
    }

    private func jsonObject(from rule: RoutingRule) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
    }

    private func versionOneData(
        ruleObjects: [Any],
        browserOrder: [String]? = nil,
        additionalFields: [String: Any] = [:]
    ) throws -> Data {
        var payload: [String: Any] = ["version": 1, "rules": ruleObjects]
        if let browserOrder {
            payload["browserOrder"] = browserOrder
        }
        for (key, value) in additionalFields {
            payload[key] = value
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func storedJSONObject() throws -> [String: Any] {
        let data = try XCTUnwrap(defaults.data(forKey: storageKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func version(of payload: [String: Any]) -> Int? {
        payload["version"] as? Int
    }

    private func rawRuleObjects(from payload: [String: Any]) -> [Any] {
        payload["rules"] as? [Any] ?? []
    }

    private func browserOrder(from payload: [String: Any]) -> [String]? {
        payload["browserOrder"] as? [String]
    }

    private func disabledBrowserIdentifiers(from payload: [String: Any]) -> Set<String>? {
        guard let identifiers = payload["disabledBrowserIdentifiers"] as? [String] else {
            return nil
        }
        return Set(identifiers)
    }

    private func decodedRules(from payload: [String: Any]) -> [RoutingRule] {
        rawRuleObjects(from: payload).compactMap { object in
            guard let data = try? JSONSerialization.data(withJSONObject: object) else {
                return nil
            }
            return try? JSONDecoder().decode(RoutingRule.self, from: data)
        }
    }

    private func canonicalJSON(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func containsRule(id: UUID, pattern: String, in object: Any) -> Bool {
        if let dictionary = object as? [String: Any],
           let persistedID = dictionary["id"] as? String,
           UUID(uuidString: persistedID) == id,
           dictionary["pattern"] as? String == pattern {
            return true
        }
        if let dictionary = object as? [String: Any] {
            return dictionary.values.contains { containsRule(id: id, pattern: pattern, in: $0) }
        }
        if let array = object as? [Any] {
            return array.contains { containsRule(id: id, pattern: pattern, in: $0) }
        }
        return false
    }

    private func containsJSONValue(_ value: String, in object: Any) -> Bool {
        if let string = object as? String {
            return string == value
        }
        if let dictionary = object as? [String: Any] {
            return dictionary.values.contains { containsJSONValue(value, in: $0) }
        }
        if let array = object as? [Any] {
            return array.contains { containsJSONValue(value, in: $0) }
        }
        return false
    }

    private func containsJSONNull(in object: Any) -> Bool {
        if object is NSNull {
            return true
        }
        if let dictionary = object as? [String: Any] {
            return dictionary.values.contains { containsJSONNull(in: $0) }
        }
        if let array = object as? [Any] {
            return array.contains { containsJSONNull(in: $0) }
        }
        return false
    }

    private func makeStore() -> UserDefaultsRoutingRuleStore {
        UserDefaultsRoutingRuleStore(userDefaults: defaults, storageKey: storageKey)
    }
}
