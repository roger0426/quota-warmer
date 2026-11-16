import AppKit
import SwiftUI

/// Builds the menu-bar status-item image from `AppState`. Drives the AppKit
/// `NSStatusItem` button (see `AppDelegate`) — we use a plain status item rather
/// than `MenuBarExtra` so the icon supports both a left-click panel and a
/// right-click menu. Both pinned tools are composited into one `NSImage`.
@MainActor
enum MenuBarStatus {
    static func image(for appState: AppState) -> NSImage {
        let items = composeItems(appState)
        let image = items.isEmpty ? fallbackImage(appState) : MenuBarComposer.image(for: items)
        image.isTemplate = false
        return image
    }

    /// Everything the image depends on, as a string. Equal keys draw identical
    /// images, so the caller can skip rebuilding.
    static func contentKey(for appState: AppState) -> String {
        let items = composeItems(appState)
        guard !items.isEmpty else { return "fallback|\(isHealthy(appState))" }
        return items.map { item in
            "\(item.assetName)|\(item.text)|\(item.badge ?? "-")|\(item.dimmed)|\(item.gauge.map(\.key) ?? "-")"
        }.joined(separator: "||")
    }

    /// Spoken summary for the status item: the drawn image has no accessibility
    /// of its own.
    static func accessibilityLabel(for appState: AppState) -> String {
        let items = composeItems(appState)
        guard !items.isEmpty else {
            let summary = isHealthy(appState)
                ? String(localized: "all healthy") : String(localized: "needs attention")
            return "QuotaWarmer, \(summary)"
        }
        return "QuotaWarmer, " + items.map(\.spoken).joined(separator: "; ")
    }

    private static func isHealthy(_ appState: AppState) -> Bool {
        guard !appState.globalPassive, !appState.watcherStale else { return false }
        return appState.toolStates.values.allSatisfy { state in
            if !state.isMonitored { return true }
            return state.sourceHealth == .healthy && state.freshness == .fresh
        }
    }

    /// Tools the user has pinned to the menu bar, shown side by side. Order
    /// follows `AppState.providers` so the layout is stable.
    private static func visibleTools(_ appState: AppState) -> [ProviderID] {
        appState.providers.filter { appState.state(for: $0).menuBarVisible }
    }

    private static func composeItems(_ appState: AppState) -> [MenuBarComposer.Item] {
        let style = QuotaDisplay.MenuBarStyle.stored()
        let warningPercent = QuotaUsageLevel.storedWarningPercent()
        let colorful = UserDefaults.standard.object(forKey: QuotaDisplay.colorfulBarsKey) as? Bool ?? true
        return visibleTools(appState).map { tool in
            let st = appState.state(for: tool)
            // Dim only when data is expired or unhealthy — stale (5–30min) is
            // recent enough with a 5-minute refresh interval and should not dim.
            let prominent = st.isWarming || (st.isMonitored && st.sourceHealth == .healthy
                && st.freshness != .expired && st.freshness != .unknown)

            // Idle 5h windows drop their sliding projected reset, rolled-over
            // windows report restored quota, and settling windows show only the
            // countdown — see `QuotaDisplay.menuBarText`. The percent follows
            // the tool's remaining/used display mode.
            let text = QuotaDisplay.menuBarText(
                QuotaDisplay.MenuBarInput(
                    isWarming: st.isWarming,
                    sessionSettling: st.sessionSettling,
                    timeUntilReset: st.timeUntilReset,
                    isIdleFiveHourWindow: st.primaryMetric?.isIdleFiveHourWindow == true,
                    primaryWindowRolledOver: st.primaryWindowRolledOver,
                    remainingFraction: st.primaryMetric?.remainingFraction
                ),
                mode: st.displayMode
            )

            // Gauge style: two bars instead of text, so a tight account
            // stands out at a glance; the panel has the numbers.
            let gauge: MenuBarComposer.Gauge? = style == .gauge ? MenuBarComposer.Gauge(
                session: QuotaDisplay.gaugeUsedFraction(remainingFraction: st.primaryMetric?.remainingFraction,
                                                        settling: st.sessionSettling),
                weekly: QuotaDisplay.gaugeUsedFraction(remainingFraction: st.weeklyMetric?.remainingFraction,
                                                       settling: false),
                warningPercent: warningPercent,
                colorful: colorful
            ) : nil

            return MenuBarComposer.Item(
                assetName: tool.kind.glyphAssetName,
                // An added account is told apart from the default by its
                // initial, in the logo's corner.
                badge: tool.badge,
                text: gauge == nil ? text : "",
                gauge: gauge,
                spoken: "\(tool.shortName) \(text), \(spokenStatus(st, appState: appState))",
                // Neutral menu-bar-white text (the colored status dot conveys
                // state), not a saturated color.
                textColor: .white,
                dimmed: !prominent
            )
        }
    }

    /// Words for the account's state (the menu bar draws no status dot;
    /// dimming shows stale or failing data).
    private static func spokenStatus(_ state: ToolState, appState: AppState) -> String {
        if appState.globalPassive { return String(localized: "paused") }
        if !state.isMonitored { return String(localized: "off") }
        if state.sourceHealth == .healthy && state.freshness == .fresh {
            return state.mode == .monitor ? String(localized: "monitoring") : String(localized: "healthy")
        }
        if state.sourceHealth == .authFailure || state.sourceHealth == .unavailable {
            return String(localized: "needs attention")
        }
        return String(localized: "stale")
    }

    /// Shown when no tool is pinned to the menu bar: a flame glyph plus an
    /// overall-health dot, so the status item is never blank.
    private static func fallbackImage(_ appState: AppState) -> NSImage {
        let healthy = isHealthy(appState)
        let size = NSSize(width: 21, height: 18)
        return NSImage(size: size, flipped: false) { _ in
            let glyphRect = NSRect(x: 0, y: 1, width: 14, height: 14)
            if let flame = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                let img = flame.withSymbolConfiguration(cfg) ?? flame
                img.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSColor(calibratedRed: 0.90, green: 0.38, blue: 0.05, alpha: 1).setFill()
                glyphRect.fill(using: .sourceAtop)
            }
            let dot: CGFloat = 6
            let dotRect = NSRect(x: glyphRect.maxX + 1, y: (size.height - dot) / 2, width: dot, height: dot)
            (healthy ? NSColor.systemGreen : NSColor.systemRed).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
    }
}

/// Draws one or more provider glyphs (white, with the account initial) plus
/// their quota text into a single NSImage for use as the menu-bar label.
private enum MenuBarComposer {
    struct Item {
        let assetName: String
        /// Account initial at the logo's bottom-right; nil for the default account.
        let badge: String?
        let text: String
        /// Bars style; nil draws the text style.
        let gauge: Gauge?
        /// Words for VoiceOver, e.g. "Claude 46% left, healthy".
        let spoken: String
        let textColor: NSColor
        let dimmed: Bool
    }

    /// Two vertical bars after the logo: 5-hour, then weekly, filled from
    /// the bottom with the share used. Blue, red from the warning level.
    struct Gauge {
        let session: Double?
        let weekly: Double?
        let warningPercent: Int
        let colorful: Bool

        var key: String {
            "\(session.map { "\(Int(($0 * 100).rounded()))" } ?? "-")/\(weekly.map { "\(Int(($0 * 100).rounded()))" } ?? "-")/\(warningPercent)/\(colorful)"
        }
    }

    private static let barWidth: CGFloat = 4
    private static let barHeight: CGFloat = 14
    private static let barGap: CGFloat = 2
    /// Logo + both bars.
    private static let gaugeWidth: CGFloat = 3 + barWidth + barGap + barWidth

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let height: CGFloat = 18
    private static let glyph: CGFloat = 15
    private static let glyphGap: CGFloat = 3
    /// Space between accounts; the bars already end each one, so no divider.
    private static let itemGap: CGFloat = 8

    static func image(for items: [Item]) -> NSImage {
        var widths: [CGFloat] = []
        var total: CGFloat = 0
        for (index, item) in items.enumerated() {
            var w = glyph
            if item.gauge != nil { w += gaugeWidth }
            let tw = textWidth(item.text)
            if tw > 0 { w += glyphGap + tw }
            widths.append(w)
            total += w
            if index < items.count - 1 { total += itemGap }
        }
        total = max(total, glyph)

        let size = NSSize(width: ceil(total), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for (index, item) in items.enumerated() {
                draw(item, at: x)
                x += widths[index] + itemGap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func textWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func draw(_ item: Item, at originX: CGFloat) {
        let alpha: CGFloat = item.dimmed ? 0.6 : 1.0
        let logoRect = NSRect(x: originX, y: (height - glyph) / 2, width: glyph, height: glyph)

        if let source = NSImage(named: item.assetName) {
            source.draw(
                in: logoRect,
                from: .zero,
                operation: .sourceOver,
                fraction: alpha,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            // Recolor the monochrome glyph to white, preserving its alpha.
            NSColor.white.withAlphaComponent(alpha).setFill()
            logoRect.fill(using: .sourceAtop)
        }

        // Account initial at the glyph's bottom-right corner: a white disc
        // with the letter cut out in black.
        if let badge = item.badge {
            let size: CGFloat = 8.5
            let rect = NSRect(x: logoRect.maxX - size + 1.5, y: logoRect.minY - 1, width: size, height: size)
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 6.5, weight: .heavy),
                .foregroundColor: NSColor.black.withAlphaComponent(alpha)
            ]
            let letter = badge as NSString
            let letterSize = letter.size(withAttributes: attrs)
            letter.draw(at: NSPoint(x: rect.midX - letterSize.width / 2, y: rect.midY - letterSize.height / 2), withAttributes: attrs)
        }

        var textX = logoRect.maxX + glyphGap
        if let gauge = item.gauge {
            var x = logoRect.maxX + 3
            for used in [gauge.session, gauge.weekly] {
                drawBar(used: used, gauge: gauge, x: x, alpha: alpha)
                x += barWidth + barGap
            }
            textX = logoRect.maxX + gaugeWidth + glyphGap
        }

        guard !item.text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: item.textColor.withAlphaComponent(alpha)
        ]
        let textSize = (item.text as NSString).size(withAttributes: attrs)
        let textY = (height - textSize.height) / 2
        (item.text as NSString).draw(
            at: NSPoint(x: textX, y: textY),
            withAttributes: attrs
        )
    }

    private static func drawBar(used: Double?, gauge: Gauge, x: CGFloat, alpha: CGFloat) {
        let track = NSRect(x: x, y: (height - barHeight) / 2, width: barWidth, height: barHeight)
        let radius: CGFloat = 1.5
        NSColor.white.withAlphaComponent(0.28 * alpha).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        guard let used, used > 0 else { return }
        let percent = Int((used * 100).rounded())
        let color: NSColor
        if !gauge.colorful {
            color = .white
        } else if percent >= QuotaUsageLevel.clampedWarningPercent(gauge.warningPercent) {
            color = NSColor(calibratedRed: 0.94, green: 0.31, blue: 0.43, alpha: 1)   // DS usageRed (dark)
        } else {
            color = NSColor(calibratedRed: 0.29, green: 0.55, blue: 0.94, alpha: 1)   // DS usageBlue (dark)
        }
        // At least a sliver, so 1–5% still reads as "some used".
        let fill = NSRect(x: x, y: track.minY, width: barWidth, height: max(1.5, barHeight * min(used, 1)))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).addClip()
        color.withAlphaComponent(alpha).setFill()
        fill.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
