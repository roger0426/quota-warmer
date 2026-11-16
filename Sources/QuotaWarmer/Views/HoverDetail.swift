import SwiftUI
import AppKit

// iStat Menus–style hover windows: hovering a provider card in the menu-bar
// panel opens a separate floating window beside the panel with more detail
// (ring gauges, the last 24 hours, update / warm-up times).
//
// It is its own borderless window rather than an in-panel overlay, so it is
// never clipped by the panel's rounded shape. It never becomes key (and
// ignores the mouse), so showing it can't trigger the panel's
// close-on-resign-key.

@MainActor
final class HoverDetailPresenter {
    static let shared = HoverDetailPresenter()

    private var window: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    /// Identifies which hover source owns the window, so a late "hide" from a
    /// card the cursor already left can't close the next card's window.
    private(set) var ownerID: String?

    func show(_ content: AnyView, ownerID: String, anchor: NSRect, beside host: NSWindow) {
        let panel = window ?? makeWindow()
        window = panel
        self.ownerID = ownerID
        hosting?.rootView = content
        guard let hosting else { return }
        let size = hosting.fittingSize
        panel.setContentSize(size)

        let hostFrame = host.frame
        let visible = (host.screen ?? NSScreen.main)?.visibleFrame ?? hostFrame
        // Prefer the left side (the panel usually sits near the right end of
        // the menu bar); fall back to the right when there is no room.
        var x = hostFrame.minX - size.width - 8
        if x < visible.minX + 4 { x = hostFrame.maxX + 8 }
        var y = anchor.maxY - size.height
        y = min(max(y, visible.minY + 4), visible.maxY - size.height - 4)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFront(nil)
    }

    func hide(ownerID: String? = nil) {
        if let ownerID, ownerID != self.ownerID { return }
        self.ownerID = nil
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSPanel {
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .ignoresCycle]
        self.hosting = hosting
        return panel
    }
}

/// Remembers the AppKit view behind a SwiftUI view, to find its screen rect.
private final class AnchorBox { weak var view: NSView? }

private struct AnchorReader: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

private struct HoverDetailModifier<Detail: View>: ViewModifier {
    let id: String
    let delay: TimeInterval
    @ViewBuilder let detail: () -> Detail

    @State private var box = AnchorBox()
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(AnchorReader(box: box))
            .onHover { inside in
                hovering = inside
                if inside {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard hovering, let view = box.view, let window = view.window, window.isVisible else { return }
                        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
                        HoverDetailPresenter.shared.show(AnyView(detail()), ownerID: id, anchor: rect, beside: window)
                    }
                } else {
                    HoverDetailPresenter.shared.hide(ownerID: id)
                }
            }
            .onDisappear { HoverDetailPresenter.shared.hide(ownerID: id) }
    }
}

extension View {
    /// Shows `detail` in a floating window beside the panel while hovered.
    func hoverDetail<Detail: View>(id: String, delay: TimeInterval = 0.45, @ViewBuilder _ detail: @escaping () -> Detail) -> some View {
        modifier(HoverDetailModifier(id: id, delay: delay, detail: detail))
    }
}

// MARK: - Provider detail

/// The hover window for one account: rings, last 24 hours, status lines.
struct ProviderDetailView: View {
    let tool: ProviderID
    @ObservedObject var state: ToolState
    @AppStorage(QuotaDisplay.colorfulBarsKey) private var colorfulBars = true
    @AppStorage(QuotaUsageLevel.warningPercentKey) private var warningPercent = QuotaUsageLevel.defaultWarningPercent
    @State private var samples: [QuotaSample] = []

    private static let width: CGFloat = 292

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            rings
            historySection
            statusSection
        }
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
        .background(VibrancyBackground(material: .hudWindow, cornerRadius: DS.R.xl))
        .overlay(
            RoundedRectangle(cornerRadius: DS.R.xl, style: .continuous)
                .strokeBorder(DS.C.border, lineWidth: 0.5)
        )
        .task(id: tool.storageKey) {
            samples = await UsageHistoryStore.shared.samples(for: tool, since: Date().addingTimeInterval(-24 * 3600))
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(tool.kind.glyphAssetName)
                .resizable().renderingMode(.template).scaledToFit()
                .frame(width: 15, height: 15)
                .foregroundStyle(DS.C.text)
            Text(verbatim: tool.displayName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DS.C.text)
            Spacer()
            Text(modeText)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DS.C.textSub)
        }
    }

    private var modeText: LocalizedStringKey {
        switch state.mode {
        case .off: return "Off"
        case .monitor: return "Monitor"
        case .autoWarm: return "Auto-warm"
        }
    }

    // MARK: Rings

    private var rings: some View {
        HStack(spacing: 0) {
            ring(title: "Session", metric: state.primaryMetric, resetAt: state.resetAt)
            ring(title: "Weekly", metric: state.weeklyMetric, resetAt: state.weeklyMetric?.resetAt)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.lg, style: .continuous))
    }

    private func ring(title: LocalizedStringKey, metric: QuotaMetric?, resetAt: Date?) -> some View {
        let remaining = metric?.remainingFraction ?? 0
        let mode = state.displayMode
        let fraction = QuotaDisplay.barFraction(remainingFraction: remaining, hasMetric: metric != nil, mode: mode)
        let level = QuotaDisplay.colorLevel(remainingFraction: remaining, hasMetric: metric != nil, settling: false, colorful: colorfulBars,
                                            warningPercent: warningPercent)
        let color = level.map(DS.C.usage) ?? DS.C.barPlain
        return VStack(spacing: 5) {
            RingGauge(fraction: fraction, color: color, lineWidth: 7) {
                VStack(spacing: 0) {
                    Text(metric.map { "\(QuotaDisplay.percent(remainingFraction: $0.remainingFraction, mode: mode))%" } ?? "–")
                        .font(DS.mono(15, weight: .bold))
                        .foregroundStyle(DS.C.text)
                    Text(mode == .remaining ? LocalizedStringKey("left") : LocalizedStringKey("used"))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(DS.C.textMuted)
                }
            }
            .frame(width: 66, height: 66)
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DS.C.text)
            Text(resetAt.map { resetText($0) } ?? String(localized: "Not started"))
                .font(.system(size: 9.5))
                .foregroundStyle(DS.C.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private func resetText(_ date: Date) -> String {
        let style: Date.FormatStyle = Calendar.current.isDateInToday(date)
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).hour().minute()
        return String(localized: "Resets \(date.formatted(style))")
    }

    // MARK: Last 24 hours

    private var historySection: some View {
        let buckets = HourBucket.make(samples, hours: 24, now: Date())
        let peak = buckets.compactMap(\.session).max()
        return VStack(alignment: .leading, spacing: 6) {
            DetailSectionTitle(title: "Last 24 Hours", value: peak.map { String(localized: "peak \(Int(($0 * 100).rounded()))%") })
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(buckets) { bucket in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(DS.C.track)
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(barColor(used: bucket.session ?? 0))
                            .frame(height: 44 * (bucket.session ?? 0))
                        if let weekly = bucket.weekly {
                            // Weekly level as a white tick with a dark
                            // outline, so it reads on light and dark.
                            Rectangle()
                                .fill(DS.C.knob)
                                .frame(height: 2)
                                .overlay(Rectangle().strokeBorder(DS.C.knobStroke, lineWidth: 0.5))
                                .offset(y: -44 * weekly + 1)
                        }
                    }
                    .frame(height: 44)
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 10) {
                legend(barColor(used: 0), "<\(clampedWarning)%")
                legend(barColor(used: 1), "≥\(clampedWarning)%")
                legend(DS.C.knob, "Weekly used", outlined: true)
                Spacer()
                Text("now").font(.system(size: 9)).foregroundStyle(DS.C.textMuted)
            }
        }
    }

    private var clampedWarning: Int { QuotaUsageLevel.clampedWarningPercent(warningPercent) }

    /// Session bars use the same blue/red rule as the panel bars.
    private func barColor(used: Double) -> Color {
        let level = QuotaDisplay.colorLevel(remainingFraction: 1 - used, hasMetric: true, settling: false,
                                            colorful: colorfulBars, warningPercent: warningPercent)
        return level.map(DS.C.usage) ?? DS.C.barPlain
    }

    private func legend(_ color: Color, _ text: LocalizedStringKey, outlined: Bool = false) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(outlined ? DS.C.knobStroke : .clear, lineWidth: 0.5))
            Text(text).font(.system(size: 9)).foregroundStyle(DS.C.textSub)
        }
    }

    // MARK: Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            DetailSectionTitle(title: "Status", value: nil)
            statusRow("Quota check", ToolStatusCopy.refreshHint(for: state))
            statusRow("Warm-up", ToolStatusCopy.warmHint(for: state))
            if let issue = ToolStatusCopy.providerIssue(for: state) {
                statusRow("Issue", issue, color: DS.C.red)
            }
        }
    }

    private func statusRow(_ title: LocalizedStringKey, _ value: String, color: Color = DS.C.textSub) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(DS.C.text)
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 10.5))
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// iStat-style section title: plain uppercase label, optional value at right.
struct DetailSectionTitle: View {
    let title: LocalizedStringKey
    let value: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(DS.C.textSub)
            Spacer()
            if let value {
                Text(value)
                    .font(DS.mono(10, weight: .semibold))
                    .foregroundStyle(DS.C.textSub)
            }
        }
    }
}

/// Thick ring gauge with a centered label (iStat battery / CPU rings).
struct RingGauge<Label: View>: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 6
    @ViewBuilder var label: () -> Label

    var body: some View {
        ZStack {
            Circle().stroke(DS.C.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            label()
        }
        .padding(lineWidth / 2)
    }
}

/// Highest session / weekly used fraction seen in each hour.
struct HourBucket: Identifiable {
    let id: Int
    let session: Double?
    let weekly: Double?

    static func make(_ samples: [QuotaSample], hours: Int, now: Date) -> [HourBucket] {
        let start = now.addingTimeInterval(-Double(hours) * 3600)
        var session = [Double?](repeating: nil, count: hours)
        var weekly = [Double?](repeating: nil, count: hours)
        for sample in samples where sample.t >= start && sample.t <= now {
            let index = min(hours - 1, Int(sample.t.timeIntervalSince(start) / 3600))
            if let s = sample.s { session[index] = max(session[index] ?? 0, s) }
            if let w = sample.w { weekly[index] = max(weekly[index] ?? 0, w) }
        }
        return (0..<hours).map { HourBucket(id: $0, session: session[$0], weekly: weekly[$0]) }
    }
}
