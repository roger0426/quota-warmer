import Foundation
import WidgetKit

/// Tells WidgetKit to redraw the quota widget after `status.json` changed.
/// WidgetKit budgets reloads, and the app rewrites the file on every poll, so
/// a reload is requested only when something the widget shows is different.
enum QuotaWidgetReload {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastSignature = ""

    static func reloadIfChanged(_ file: QuotaStatusFile) {
        let signature = "\(file.warningPercent ?? 0)#\(file.unusedAlert.map { "\($0.days)/\($0.percent)" } ?? "-")#" + file.providers.map { provider in
            [
                provider.id, provider.name, provider.mode, provider.displayMode,
                window(provider.session), window(provider.weekly)
            ].joined(separator: ",")
        }.joined(separator: "|")

        lock.lock()
        let changed = signature != lastSignature
        lastSignature = signature
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
