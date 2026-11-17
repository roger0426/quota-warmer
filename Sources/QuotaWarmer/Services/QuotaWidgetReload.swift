import Foundation
import WidgetKit

/// Tells WidgetKit to redraw the quota widget after `status.json` changed.
/// WidgetKit budgets reloads, and the app rewrites the file on every poll, so
/// a reload is requested only when something the widget shows is different,
/// or when the widget's copy is about to look stale. The widget dims a
/// reading older than 30 minutes, so while usage stays flat it still needs a
/// fresh `fetchedAt` before then (at most ~58 reloads a day while awake).
enum QuotaWidgetReload {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastSignature = ""
    nonisolated(unsafe) private static var lastReloadAt = Date.distantPast
    static let freshnessRefresh: TimeInterval = 25 * 60

    static func reloadIfChanged(_ file: QuotaStatusFile) {
        let signature = "\(file.warningPercent ?? 0)#\(file.unusedAlert.map { "\($0.days)/\($0.percent)" } ?? "-")#" + file.providers.map { provider in
            [
                provider.id, provider.name, provider.mode, provider.displayMode,
                window(provider.session), window(provider.weekly)
            ].joined(separator: ",")
        }.joined(separator: "|")

        lock.lock()
        let now = Date()
        let changed = signature != lastSignature || now.timeIntervalSince(lastReloadAt) >= freshnessRefresh
        lastSignature = signature
        if changed { lastReloadAt = now }
        lock.unlock()
        guard changed else { return }
        // The file is written on a background queue just before this; give
        // the write a moment so the widget reads the new contents.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private static func window(_ window: QuotaStatusWindow?) -> String {
        guard let window else { return "-" }
        return "\(window.usedPercent)/\(window.settling)"
    }
}
