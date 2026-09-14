import CoreFoundation
import Foundation

let currentSetupVersion = 1

protocol SetupStateStore {
    func needsSetup(currentVersion: Int) -> Bool
    func markSetupCompleted(version: Int) throws
}

enum SetupStateStoreError: Error, Equatable {
    case persistenceFailed
}

final class UserDefaultsSetupStateStore: SetupStateStore {
    static let defaultStorageKey = "LinkGate.setupCompletedVersion"

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = UserDefaultsSetupStateStore.defaultStorageKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func needsSetup(currentVersion: Int) -> Bool {
        guard let completedVersion = storedVersion else { return true }
        return completedVersion < currentVersion
    }

    func markSetupCompleted(version: Int) throws {
        if let completedVersion = storedVersion, completedVersion >= version {
            return
        }

        userDefaults.set(version, forKey: storageKey)
        guard let persistedVersion = storedVersion, persistedVersion >= version else {
            throw SetupStateStoreError.persistenceFailed
        }
    }

    private var storedVersion: Int? {
        guard let value = userDefaults.object(forKey: storageKey) as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(value),
              let version = value as? Int
        else {
            return nil
        }
        return version
    }
}
