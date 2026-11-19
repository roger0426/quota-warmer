import Charts
import SwiftUI

/// Prompt-cache behavior of the local Claude transcripts: conversations whose
/// cache is still warm, how a window's requests used the cache, and whether
/// each side's TTL is the cheaper one. Data comes from `CacheMonitor`, which
/// keeps scanning in the background and stores a rollup of its own.
struct CacheTabView: View {
    @ObservedObject var monitor: CacheMonitor
    @AppStorage("cacheRange") private var rangeRaw = CacheRange.week.rawValue
    @AppStorage("cacheSide") private var sideRaw = CacheSide.main.rawValue
    @AppStorage("cacheTTLRange") private var ttlRangeRaw = CacheTTLRange.month.rawValue
    @State private var offset = 0

    private var range: CacheRange { CacheRange(rawValue: rangeRaw) ?? .week }
    private var side: CacheSide { CacheSide(rawValue: sideRaw) ?? .main }
    private var ttlRange: CacheTTLRange { CacheTTLRange(rawValue: ttlRangeRaw) ?? .month }
    private var calendar: Calendar { .current }

    private var oldest: Date? {
        monitor.rollup.sortedDayKeys.first.flatMap { CostRollup.date(fromDayKey: $0, calendar: calendar) }
    }

    var body: some View {
        let window = RangeWindow.calendar(days: range.days, offset: offset, calendar: calendar)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DS.Page.spacing) {
                RangeHeader(
                    window: window,
                    canGoBack: window.canGoBack(oldest: oldest),
                    partialNote: window.isPartial(oldest: oldest)
                        ? oldest.map { String(localized: "Stored data starts \($0.formatted(.dateTime.month(.abbreviated).day())).") }
                        : nil,
                    pillLabel: range.label,
                    pillHelp: String(localized: "Range: \(range.longLabel). Click to change."),
                    onStep: { offset = max($0, 0) },
                    onCycle: {
                        rangeRaw = range.next.rawValue
                        offset = 0
                    }
                )
                if window.isCurrent, !monitor.rows.isEmpty {
                    LiveSessionsCard(rows: monitor.rows)
                }
                let cell = monitor.rollup.total(dayKeys: window.dayKeys(calendar: calendar), side: side)
                if monitor.rollup.total(dayKeys: window.dayKeys(calendar: calendar), side: .main).isEmpty,
                   monitor.rollup.total(dayKeys: window.dayKeys(calendar: calendar), side: .subagent).isEmpty {
                    Text(monitor.isLoading ? "Reading local logs…" : "No cache activity in this range.")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.C.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .dsCard()
                } else {
                    windowCard(cell: cell, window: window)
                }
                ttlCard
            }
            .padding(.horizontal, DS.Page.side)
            .padding(.top, DS.Page.top)
            .padding(.bottom, DS.Page.bottom)
            .reportsPanelHeight()
        }
        .onAppear { monitor.setFocused(true) }
        .onDisappear { monitor.setFocused(false) }
    }

    // MARK: This window

    private func windowCard(cell: CacheCell, window: RangeWindow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("This window").dsSectionLabel()
                Spacer()
                sidePicker
            }
            if cell.isEmpty {
                Text(side == .main ? "No main-conversation requests in this range." : "No subagent requests in this range.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.C.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    tile(cell.tokenHitRate.map(Self.percent1) ?? "–", "Token hit rate",
                         help: String(localized: "Cache-read tokens as a share of all input-side tokens (input + cache read + cache write)."))
                    tile(cell.writeShare.map(CostFormat.percent) ?? "–", "Write share of input $",
                         help: String(localized: "Cache writes as a share of input-side API-equivalent cost. High means the cache is often rebuilt rather than read."))
                    tile(CostFormat.usd(cell.rewriteCost), "Rewrite cost",
                         help: String(localized: "Writes that rebuilt a prefix the previous request had cached (expired, model or prefix changed). API-equivalent; subscription quota impact unknown."))
                }
                writesChart(window: window)
                outcomes(cell)
                gapsLine(cell)
            }
        }
        .padding(DS.Page.cardPadding)
        .dsCard()
    }

    private var sidePicker: some View {
        HStack(spacing: 2) {
            ForEach(CacheSide.allCases) { option in
                let selected = option == side
                Button(action: { sideRaw = option.rawValue }) {
                    Text(option.label)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(selected ? DS.C.surface : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(selected ? DS.C.border : .clear, lineWidth: 1))
                        .foregroundStyle(selected ? DS.C.text : DS.C.textMuted)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(DS.C.surfaceHigh, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func tile(_ value: String, _ title: LocalizedStringKey, help: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(DS.C.text)
                .monospacedDigit()
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.C.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HelpMark(text: help)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private struct WriteBar: Identifiable {
        let x: Date
        let value: Double
        var id: Double { x.timeIntervalSince1970 }
    }

    private func writesChart(window: RangeWindow) -> some View {
        let hourly = range == .today
        let bars: [WriteBar] = hourly
            ? monitor.rollup.hourly(from: window.start, to: window.end, side: side).map { WriteBar(x: $0.hour, value: $0.cell.writeCost) }
            : window.dayKeys(calendar: calendar).compactMap { key in
                CostRollup.date(fromDayKey: key, calendar: calendar).map {
                    WriteBar(x: $0, value: monitor.rollup.total(dayKeys: [key], side: side).writeCost)
                }
            }
        let peak = bars.map(\.value).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(hourly ? "Cache writes per hour" : "Cache writes per day")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.C.textSub)
                Spacer()
                Text("max \(CostFormat.usd(peak))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.C.textMuted)
            }
            Chart(bars) { bar in
                BarMark(x: .value("Time", bar.x, unit: hourly ? .hour : .day),
                        y: .value("Write cost", bar.value), width: .ratio(0.7))
                    .foregroundStyle(DS.C.historyBoth)
            }
            .chartXScale(domain: window.start...window.end)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(DS.C.border)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: range == .week ? 7 : 5)) { _ in
                    AxisValueLabel(format: hourly ? .dateTime.hour() : (range == .week ? .dateTime.weekday(.abbreviated) : .dateTime.month(.abbreviated).day()))
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.C.textMuted)
                }
            }
            .frame(height: 80)
        }
    }

    private struct Outcome: Identifiable {
        let label: LocalizedStringKey
        let count: Int
        let color: Color
        let help: String
        var id: String { help }
    }

    private func outcomes(_ cell: CacheCell) -> some View {
        var items = [
            Outcome(label: "Hit", count: cell.hits, color: DS.C.green,
                    help: String(localized: "The cached prefix was still warm and was read.")),
            Outcome(label: "Expired", count: cell.expired, color: DS.C.red,
                    help: String(localized: "The gap outlasted the TTL, so the prefix was written again.")),
            Outcome(label: "Model Δ", count: cell.modelChanges, color: DS.C.yellow,
                    help: String(localized: "The model changed; caches are per model, so the prefix was written again.")),
        ]
        if cell.prefixChanges > 0 {
            items.append(Outcome(label: "Prefix Δ", count: cell.prefixChanges, color: DS.C.usageBlue,
                                 help: String(localized: "The prefix changed (e.g. compaction or an edited system prompt).")))
        }
        items.append(Outcome(label: "Unknown", count: cell.unknown, color: DS.C.textMuted.opacity(0.6),
                             help: String(localized: "Neither a read nor an explained rewrite, e.g. a short prefix below the cache minimum.")))
        let total = items.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Next request after a gap")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.C.textSub)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(items.filter { $0.count > 0 }) { item in
                        Rectangle().fill(item.color)
                            .frame(width: max(geo.size.width * Double(item.count) / Double(max(total, 1)), 2))
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .background(DS.C.track)
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            FlowRow(spacing: 10) {
                ForEach(items) { item in
                    HStack(spacing: 4) {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                        Text(item.label)
                            .font(.system(size: 10))
                            .foregroundStyle(DS.C.textSub)
                        Text(verbatim: item.count.formatted())
                            .font(DS.mono(10, weight: .semibold))
                            .foregroundStyle(DS.C.text)
                    }
                    .help(item.help)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func gapsLine(_ cell: CacheCell) -> some View {
        let help: String = side == .main
            ? (cell.gaps[1] < 50
                ? String(localized: "Only \(cell.gaps[1]) gaps of 5–60m in this range: the 1h write premium has few chances to pay back.")
                : String(localized: "Gaps of 5–60m are where a 1h TTL pays back its higher write price."))
            : String(localized: "Grouped per subagent run; reuse across runs of the same agent type is not counted.")
        return HStack(spacing: 4) {
            Text(verbatim: "Gaps: <5m \(cell.gaps[0].formatted()) · 5–60m \(cell.gaps[1].formatted()) · >60m \(cell.gaps[2].formatted())")
                .font(DS.mono(10))
                .foregroundStyle(DS.C.textSub)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HelpMark(text: help)
        }
    }

    // MARK: TTL

    private var ttlCard: some View {
        let rollup = monitor.rollup
        let keys = ttlRange == .month
            ? CostRollup.dayKeys(endingAt: Date(), count: 30, calendar: calendar)
            : rollup.sortedDayKeys
        let verdicts = CacheSide.allCases.map { rollup.verdict(dayKeys: keys, side: $0, calendar: calendar) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TTL").dsSectionLabel()
                HelpMark(text: String(localized: "What the input side would have cost with the other TTL (main conversation 5m, subagents 1h), at API prices. API-equivalent; subscription quota impact unknown."))
                Spacer()
                Button { ttlRangeRaw = ttlRange.next.rawValue } label: {
                    Text(verbatim: ttlRange.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.C.text)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(DS.C.surfaceHigh, in: Capsule())
                        .overlay(Capsule().stroke(DS.C.border, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
                .help(String(localized: "TTL range: \(ttlRange.longLabel). Click to change."))
            }
            if let first = verdicts.first, first.outcome == .notEnoughData {
                HStack(spacing: 4) {
                    Text(monitor.isLoading && rollup.isEmpty ? "Reading local logs…" : "Not enough data yet")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.C.textMuted)
                    HelpMark(text: String(localized: "A verdict needs at least \(CacheVerdict.minimumDays) days and \(CacheVerdict.minimumRequests) requests; this range has \(first.spanDays) days and \(first.totalRequests) requests."))
                }
            } else {
                ForEach(verdicts, id: \.side) { verdict in
                    verdictRow(verdict)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(updatedText(now: context.date))
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.C.textMuted)
            }
        }
        .padding(DS.Page.cardPadding)
        .dsCard()
    }

    private func verdictRow(_ verdict: CacheVerdict) -> some View {
        let side = verdict.side
        let current = Self.ttlLabel(side.defaultTTL)
        let other = Self.ttlLabel(side.alternativeTTL)
        let headline: String
        switch verdict.outcome {
        case .keep: headline = String(localized: "\(side.title): keep \(current)")
        case .switchTTL: headline = String(localized: "\(side.title): \(other) is cheaper")
        case .aboutTheSame: headline = String(localized: "\(side.title): about the same")
        case .noRequests, .notEnoughData: headline = String(localized: "\(side.title): no requests in this range")
        }
        let detail: String? = verdict.relativeDelta.map { relative in
            let sign = verdict.weeklyDelta >= 0 ? "+" : "−"
            let money = CostFormat.usd(abs(verdict.weeklyDelta))
            let pct = "\(sign)\(Int((abs(relative) * 100).rounded()))%"
            return String(localized: "\(other): \(sign)\(money)/wk (\(pct))")
        }
        let color: Color = verdict.outcome == .switchTTL ? DS.C.yellow : DS.C.text
        return HStack(alignment: .firstTextBaseline) {
            Text(verbatim: headline)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(color)
            Spacer(minLength: 8)
            if let detail {
                Text(verbatim: detail)
                    .font(DS.mono(10.5))
                    .foregroundStyle(DS.C.textSub)
                    .underline(pattern: .dot)
                    .help(String(localized: "Over \(verdict.spanDays) days and \(verdict.requests.formatted()) \(side.title.lowercased()) requests; positive means \(other) would cost more."))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func updatedText(now: Date) -> String {
        guard let updated = monitor.updatedAt else { return String(localized: "Scanning local logs…") }
        let seconds = max(Int(now.timeIntervalSince(updated)), 0)
        if seconds < 60 { return String(localized: "Updated \(seconds)s ago") }
        return String(localized: "Updated \(seconds / 60)m ago")
    }

    static func ttlLabel(_ seconds: Double) -> String {
        seconds >= 3600 ? "\(Int(seconds / 3600))h" : "\(Int(seconds / 60))m"
    }

    static func percent1(_ fraction: Double) -> String {
        (fraction * 100).formatted(.number.precision(.fractionLength(1))) + "%"
    }
}

// MARK: - Live sessions

private struct LiveSessionsCard: View {
    let rows: [LiveCacheRow]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let live = rows.filter { $0.expiry > context.date }
            if !live.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Live sessions · \(live.count)").dsSectionLabel()
                    ForEach(live) { row in
                        LiveRow(row: row, now: context.date)
                    }
                }
                .padding(DS.Page.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsCard()
            }
        }
    }
}

private struct LiveRow: View {
    let row: LiveCacheRow
    let now: Date

    private var remaining: TimeInterval { row.expiry.timeIntervalSince(now) }

    private var color: Color {
        if remaining > 1800 { return DS.C.green }
        if remaining > 300 { return DS.C.yellow }
        return DS.C.red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\(row.project) · \(row.slug)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(verbatim: Self.countdown(remaining))
                    .font(DS.mono(12, weight: .semibold))
                    .foregroundStyle(color)
                    .monospacedDigit()
            }
            HStack(spacing: 0) {
                Text(verbatim: statusLine)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.C.textMuted)
                    .lineLimit(1)
                    .help(row.inferredTTL ? String(localized: "TTL inferred from the gaps between requests.") : "")
                Spacer(minLength: 8)
                if let cost = row.rewriteCost {
                    Text("If it expires: ≈ \(CostFormat.usd(cost))")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.C.textSub)
                        .underline(pattern: .dot)
                        .help(String(localized: "Writing the \(TokenFormat.compact(row.prefixTokens))-token cached prefix again at the cache-write price. API-equivalent; subscription quota impact unknown."))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusLine: String {
        var parts = [row.side.title, CacheTabView.ttlLabel(row.ttl) + (row.inferredTTL ? "?" : "")]
        parts.append(remaining > 300 ? String(localized: "Warm") : String(localized: "Expiring soon"))
        if row.toolPending { parts.append(String(localized: "Tool running")) }
        return parts.joined(separator: " · ")
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// Lays children out left to right, wrapping to a new line when full.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - Ranges

enum CacheRange: String, CaseIterable {
    case today, week, month

    var days: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    var next: CacheRange {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var label: String {
        switch self {
        case .today: return String(localized: "Today")
        case .week: return String(localized: "7D")
        case .month: return String(localized: "30D")
        }
    }

    var longLabel: String {
        switch self {
        case .today: return String(localized: "one day")
        case .week: return String(localized: "7 days")
        case .month: return String(localized: "30 days")
        }
    }
}

enum CacheTTLRange: String, CaseIterable {
    case month, all

    var next: CacheTTLRange { self == .month ? .all : .month }
    var label: String { self == .month ? String(localized: "30D") : String(localized: "All") }
    var longLabel: String { self == .month ? String(localized: "last 30 days") : String(localized: "all stored days") }
}

extension CacheSide {
    var title: String { self == .main ? String(localized: "Main") : String(localized: "Subagent") }
    var label: LocalizedStringKey { self == .main ? "Main" : "Subagent" }
}
