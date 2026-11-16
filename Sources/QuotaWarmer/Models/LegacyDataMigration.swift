import Foundation

/// One-time copy of settings and data from the upstream identity
/// (`com.quotawarmer.app`) into this fork's (`AppIdentity`). Runs at launch,
/// before `AppState` reads any setting.
///
/// - Copies, never moves: an upstream install keeps working untouched.
/// - Idempotent without a marker key: settings are copied only while this
///   fork's domain has no settings of its own, and the folder only while this
///   fork's folder does not exist. (A marker key would make a fresh install look
///   like an upgrade to `OnboardingFlow.hasPriorSettings`.)
/// - Not copied: logs (rotated, diagnostic only), Keychain items (this fork
///   keeps no token copy), notification permission and the login item, which
///   macOS ties to the bundle identifier.
enum LegacyDataMigration {
    struct Result: Equatable {
        var settingsCopied = 0
        var folderCopied = false
    }

    @discardableResult
    static func runAtLaunch() -> Result {
        // Only the real app: tests and other hosts have a different identifier.
        guard Bundle.main.bundleIdentifier == AppIdentity.bundleID else { return Result() }
        let result = Result(
            settingsCopied: copySettings(
                from: UserDefaults.standard.persistentDomain(forName: AppIdentity.legacyBundleID),
                into: UserDefaults.standard,
                currentKeys: Array(UserDefaults.standard.persistentDomain(forName: AppIdentity.bundleID)?.keys ?? [:].keys)),
            folderCopied: copyFolder(from: AppIdentity.legacySupportDirectory, to: AppIdentity.supportDirectory)
        )
        if result.settingsCopied > 0 || result.folderCopied {
            DiagnosticLogger.append("legacy_migration settings=\(result.settingsCopied) folder=\(result.folderCopied)")
        }
        return result
    }

    /// Copies the legacy settings when this fork has none of its own yet.
    /// Returns how many keys were written.
    static func copySettings(from legacy: [String: Any]?, into defaults: UserDefaults, currentKeys: [String]) -> Int {
        guard let legacy, !legacy.isEmpty else { return 0 }
        guard !OnboardingFlow.hasPriorSettings(keys: currentKeys) else { return 0 }
        var copied = 0
        for (key, value) in legacy where !OnboardingFlow.isSystemKey(key) {
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied
    }

    /// Copies the legacy data folder when this fork's folder does not exist yet.
    static func copyFolder(from legacy: URL, to current: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        guard !fileManager.fileExists(atPath: current.path) else { return false }
        do {
            try fileManager.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: legacy, to: current)
            return true
        } catch {
            return false
        }
    }
}
