import Foundation

/// Names this fork uses in macOS and on disk. They differ from upstream
/// QuotaWarmer (`com.quotawarmer.app`, `~/Library/Application Support/QuotaWarmer`),
/// so the two builds never share settings, history, logs or the widget's
/// `status.json`. The widget extension cannot import this file; its copy of the
/// folder name lives in `QuotaWidget.swift` and `QuotaWarmerWidget.entitlements`.
enum AppIdentity {
    static let bundleID = "io.github.roger0426.quotawarmer"
    /// Upstream's identifier. Settings and data are copied from it once
    /// (`LegacyDataMigration`), and never written back.
    static let legacyBundleID = "com.quotawarmer.app"

    /// Folder name under `~/Library/Application Support` and `~/Library/Logs`.
    static let dataFolderName = bundleID
    static let legacyDataFolderName = "QuotaWarmer"

    /// `~/Library/Application Support/<dataFolderName>/`
    static var supportDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent(dataFolderName, isDirectory: true)
    }

    /// `~/Library/Application Support/QuotaWarmer/` (upstream and builds before the rename).
    static var legacySupportDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent(legacyDataFolderName, isDirectory: true)
    }

    /// `~/Library/Logs/<dataFolderName>/`
    static var logsDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library.appendingPathComponent("Logs/\(dataFolderName)", isDirectory: true)
    }
}
