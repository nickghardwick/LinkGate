import Combine
import CoreFoundation
import Foundation

protocol RoutingRuleProviding: AnyObject {
    var rules: [RoutingRule] { get }
}

protocol RoutingRuleStore: RoutingRuleProviding, BrowserOrderStoring {
    var storageWarning: String? { get }

    func create(matchType: RoutingRule.MatchType, pattern: String, browserBundleIdentifier: String) throws -> RoutingRule
    func update(id: UUID, matchType: RoutingRule.MatchType, pattern: String, browserBundleIdentifier: String) throws -> RoutingRule
    func delete(id: UUID) throws
}

extension RoutingRuleStore {
    var storageWarning: String? { nil }
}

enum RoutingRuleStorageError: LocalizedError {
    case readOnlyStorage
    case invalidBrowserOrder
    case invalidBrowserVisibility

    var errorDescription: String? {
        switch self {
        case .readOnlyStorage:
            "Saved routing rules could not be updated."
        case .invalidBrowserOrder:
            "The browser order is invalid."
        case .invalidBrowserVisibility:
            "The browser visibility settings are invalid."
        }
    }
}

final class UserDefaultsRoutingRuleStore: ObservableObject, RoutingRuleStore {
    @Published private(set) var rules: [RoutingRule]
    @Published private(set) var browserOrder: [String]?
    @Published private(set) var browserOrderPathHints: [String: String]
    @Published private(set) var disabledBrowserIdentifiers: Set<String>
    @Published private(set) var storageWarning: String?

    private enum Entry {
        case rule(RoutingRule, raw: Any)
        case opaque(Any)
    }

    private enum StorageState {
        case fresh
        case legacy(originalData: Data)
        case versionOne(envelope: [String: Any])
        case readOnly
    }

    private static let versionKey = "version"
    private static let rulesKey = "rules"
    private static let browserOrderKey = "browserOrder"
    private static let browserOrderPathHintsKey = "browserOrderPathHints"
    private static let disabledBrowserIdentifiersKey = "disabledBrowserIdentifiers"
    // This metadata prevents invalid duplicate/conflicting records from becoming
    // active merely because a valid neighbor is later edited or deleted.
    private static let quarantinedRuleIndexesKey = "quarantinedRuleIndexes"

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let validator: RoutingRuleValidator
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var entries: [Entry]
    private var storageState: StorageState

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "LinkGate.routingRules",
        validator: RoutingRuleValidator = RoutingRuleValidator(),
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.validator = validator
        self.encoder = encoder
        self.decoder = decoder

        let loaded = Self.load(from: userDefaults, key: storageKey, validator: validator, decoder: decoder)
        rules = loaded.rules
        browserOrder = loaded.browserOrder
        browserOrderPathHints = loaded.browserOrderPathHints
        disabledBrowserIdentifiers = loaded.disabledBrowserIdentifiers
        entries = loaded.entries
        storageState = loaded.storageState
        storageWarning = loaded.warning
    }

    func create(matchType: RoutingRule.MatchType, pattern: String, browserBundleIdentifier: String) throws -> RoutingRule {
        try ensureWritable()
        let rule = try validator.makeRule(
            matchType: matchType,
            pattern: pattern,
            browserBundleIdentifier: browserBundleIdentifier,
            existingRules: rules
        )
        try save(replacing: rules + [rule])
        return rule
    }

    func update(id: UUID, matchType: RoutingRule.MatchType, pattern: String, browserBundleIdentifier: String) throws -> RoutingRule {
        try ensureWritable()
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            throw RoutingRuleValidationError.ruleNotFound
        }
        let rule = try validator.makeRule(
            id: id,
            matchType: matchType,
            pattern: pattern,
            browserBundleIdentifier: browserBundleIdentifier,
            existingRules: rules,
            excludingRuleID: id
        )
        var updated = rules
        updated[index] = rule
        try save(replacing: updated)
        return rule
    }

    func delete(id: UUID) throws {
        try ensureWritable()
        guard rules.contains(where: { $0.id == id }) else {
            throw RoutingRuleValidationError.ruleNotFound
        }
        try save(replacing: rules.filter { $0.id != id })
    }

    func saveBrowserOrder(_ identifiers: [String]) throws {
        try saveBrowserOrder(identifiers, pathHints: browserOrderPathHints)
    }

    func saveBrowserOrder(_ identifiers: [String], pathHints: [String: String]) throws {
        try ensureWritable()
        guard BrowserOrdering.isValidOrder(identifiers), BrowserOrdering.isValidPathHints(pathHints) else {
            throw RoutingRuleStorageError.invalidBrowserOrder
        }

        let envelope = try envelopeForWriting()
        var updatedEnvelope = envelope
        populateRuleFields(in: &updatedEnvelope, entries: entries)
        updatedEnvelope[Self.browserOrderKey] = identifiers
        if pathHints.isEmpty {
            updatedEnvelope.removeValue(forKey: Self.browserOrderPathHintsKey)
        } else {
            updatedEnvelope[Self.browserOrderPathHintsKey] = pathHints
        }
        try write(updatedEnvelope)
        browserOrder = identifiers
        browserOrderPathHints = pathHints
        storageState = .versionOne(envelope: updatedEnvelope)
    }

    func saveDisabledBrowserIdentifiers(_ identifiers: Set<String>) throws {
        try ensureWritable()
        guard BrowserOrdering.isValidOrder(identifiers.sorted()) else {
            throw RoutingRuleStorageError.invalidBrowserVisibility
        }

        var envelope = try envelopeForWriting()
        populateRuleFields(in: &envelope, entries: entries)
        if identifiers.isEmpty {
            envelope.removeValue(forKey: Self.disabledBrowserIdentifiersKey)
        } else {
            envelope[Self.disabledBrowserIdentifiersKey] = identifiers.sorted()
        }
        try write(envelope)
        disabledBrowserIdentifiers = identifiers
        storageState = .versionOne(envelope: envelope)
    }

    private func ensureWritable() throws {
        guard case .readOnly = storageState else { return }
        throw RoutingRuleStorageError.readOnlyStorage
    }

    private func save(replacing updatedRules: [RoutingRule]) throws {
        var replacementByID = Dictionary(uniqueKeysWithValues: updatedRules.map { ($0.id, $0) })
        var persistedEntries: [Entry] = []

        for entry in entries {
            switch entry {
            case let .opaque(raw):
                persistedEntries.append(.opaque(raw))
            case let .rule(existing, raw):
                guard let replacement = replacementByID.removeValue(forKey: existing.id) else { continue }
                persistedEntries.append(.rule(replacement, raw: replacement == existing ? raw : try rawObject(for: replacement)))
            }
        }
        for rule in updatedRules where replacementByID.removeValue(forKey: rule.id) != nil {
            persistedEntries.append(.rule(rule, raw: try rawObject(for: rule)))
        }

        var envelope = try envelopeForWriting()

        populateRuleFields(in: &envelope, entries: persistedEntries)

        try write(envelope)
        entries = persistedEntries
        rules = updatedRules
        storageState = .versionOne(envelope: envelope)
    }

    private func envelopeForWriting() throws -> [String: Any] {
        switch storageState {
        case .versionOne(let existingEnvelope):
            return existingEnvelope
        case .legacy(let originalData):
            let backupKey = storageKey + ".legacyBackup"
            if userDefaults.object(forKey: backupKey) == nil {
                userDefaults.set(originalData, forKey: backupKey)
            }
            return [:]
        case .fresh:
            return [:]
        case .readOnly:
            throw RoutingRuleStorageError.readOnlyStorage
        }
    }

    private func write(_ envelope: [String: Any]) throws {
        userDefaults.set(try JSONSerialization.data(withJSONObject: envelope), forKey: storageKey)
    }

    private func populateRuleFields(in envelope: inout [String: Any], entries: [Entry]) {
        envelope[Self.versionKey] = 1
        envelope[Self.rulesKey] = entries.map { entry in
            switch entry {
            case let .rule(_, raw), let .opaque(raw): raw
            }
        }
        let quarantinedIndexes = entries.enumerated().compactMap { index, entry in
            if case .opaque = entry { index } else { nil }
        }
        if quarantinedIndexes.isEmpty {
            envelope.removeValue(forKey: Self.quarantinedRuleIndexesKey)
        } else {
            envelope[Self.quarantinedRuleIndexesKey] = quarantinedIndexes
        }
    }

    private func rawObject(for rule: RoutingRule) throws -> Any {
        try JSONSerialization.jsonObject(with: encoder.encode(rule))
    }

    private static func load(
        from defaults: UserDefaults,
        key: String,
        validator: RoutingRuleValidator,
        decoder: JSONDecoder
    ) -> (rules: [RoutingRule], browserOrder: [String]?, browserOrderPathHints: [String: String], disabledBrowserIdentifiers: Set<String>, entries: [Entry], storageState: StorageState, warning: String?) {
        guard let storedValue = defaults.object(forKey: key) else {
            return ([], nil, [:], [], [], .fresh, nil)
        }
        guard let data = storedValue as? Data,
              let root = try? JSONSerialization.jsonObject(with: data)
        else {
            return ([], nil, [:], [], [], .readOnly, "Saved routing rules could not be read safely.")
        }

        if let objects = root as? [Any] {
            let parsed = parseEntries(objects, validator: validator, decoder: decoder, quarantinedIndexes: [])
            return (parsed.rules, nil, [:], [], parsed.entries, .legacy(originalData: data), parsed.warning)
        }

        guard let envelope = root as? [String: Any],
              isVersionOne(envelope[versionKey]),
              let objects = envelope[rulesKey] as? [Any]
        else {
            return ([], nil, [:], [], [], .readOnly, "Saved routing rules could not be read safely.")
        }
        let quarantinedIndexes = Set((envelope[quarantinedRuleIndexesKey] as? [NSNumber] ?? []).compactMap { index in
            let value = index.intValue
            return index.doubleValue == Double(value) && value >= 0 ? value : nil
        })
        let parsed = parseEntries(objects, validator: validator, decoder: decoder, quarantinedIndexes: quarantinedIndexes)
        let storedBrowserOrder = envelope[browserOrderKey] as? [String]
        let browserOrder = storedBrowserOrder.flatMap { BrowserOrdering.isValidOrder($0) ? $0 : nil }
        let storedPathHints = envelope[browserOrderPathHintsKey] as? [String: String]
        let browserOrderPathHints = storedPathHints.flatMap { BrowserOrdering.isValidPathHints($0) ? $0 : nil } ?? [:]
        let storedDisabledIdentifiers = envelope[disabledBrowserIdentifiersKey] as? [String]
        let validDisabledIdentifiers = storedDisabledIdentifiers.flatMap {
            BrowserOrdering.isValidOrder($0) ? Set($0) : nil
        }
        let disabledBrowserIdentifiers = validDisabledIdentifiers ?? []
        let browserOrderWarning = envelope[browserOrderKey] != nil && browserOrder == nil
            ? "Saved browser order could not be loaded."
            : nil
        let pathHintsWarning = envelope[browserOrderPathHintsKey] != nil && storedPathHints == nil || storedPathHints.map { !BrowserOrdering.isValidPathHints($0) } == true
            ? "Saved browser order hints could not be loaded."
            : nil
        let visibilityWarning = envelope[disabledBrowserIdentifiersKey] != nil && validDisabledIdentifiers == nil
            ? "Saved browser visibility could not be loaded."
            : nil
        let warning = [parsed.warning, browserOrderWarning, pathHintsWarning, visibilityWarning].compactMap { $0 }.joined(separator: " ")
        return (parsed.rules, browserOrder, browserOrderPathHints, disabledBrowserIdentifiers, parsed.entries, .versionOne(envelope: envelope), warning.isEmpty ? nil : warning)
    }

    private static func isVersionOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return false
        }
        return number.doubleValue == 1 && number.doubleValue.rounded(.towardZero) == 1
    }

    private static func parseEntries(
        _ objects: [Any],
        validator: RoutingRuleValidator,
        decoder: JSONDecoder,
        quarantinedIndexes: Set<Int>
    ) -> (rules: [RoutingRule], entries: [Entry], warning: String?) {
        var validRules: [RoutingRule] = []
        var identifiers = Set<UUID>()
        var entries: [Entry] = []
        var skippedRecord = false

        for (index, object) in objects.enumerated() {
            guard !quarantinedIndexes.contains(index),
                  let ruleData = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]),
                  let decoded = try? decoder.decode(RoutingRule.self, from: ruleData),
                  !identifiers.contains(decoded.id),
                  let rule = try? validator.makeRule(
                    id: decoded.id,
                    matchType: decoded.matchType,
                    pattern: decoded.pattern,
                    browserBundleIdentifier: decoded.browserBundleIdentifier,
                    existingRules: validRules
                  )
            else {
                entries.append(.opaque(object))
                skippedRecord = true
                continue
            }
            identifiers.insert(rule.id)
            validRules.append(rule)
            entries.append(.rule(rule, raw: object))
        }
        return (validRules, entries, skippedRecord ? "Some saved routing rules could not be loaded." : nil)
    }
}
