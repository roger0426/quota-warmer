import Charts
import SwiftUI

/// API-equivalent value of the local CLI logs: what the same tokens would cost
/// at API prices, split by token kind and model, plus what each weekly quota
/// period was worth. Totals are per tool, not per account: logs carry no
/// account, and accounts whose CLI writes to one folder (an Orca profile's
/// `projects` symlinked to `~/.claude/projects`) cannot be told apart, so each
/// log folder (`ToolState.tokenLogKey`) is counted once. Data is each folder's
/// stored `CostRollup`, so days whose logs the CLI already deleted stay
/// visible. Not a bill.
struct CostTabView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("costRange") private var rangeRaw = CostRange.week.rawValue
    @AppStorage("costTool") private var toolRaw = HistoryTabView.allKey
    @State private var weeklySamples: [QuotaSample] = []

    private var range: CostRange { CostRange(rawValue: rangeRaw) ?? .week }

    private var kinds: [ToolID] {
        ToolID.allCases.filter { kind in appState.providers.contains { $0.kind == kind } }
    }

    /// nil = All.
    private var selectedKind: ToolID? {
        kinds.first { $0.rawValue == toolRaw }
    }

    private var selectedProviders: [ProviderID] {
        appState.providers.filter { selectedKind == nil || $0.kind == selectedKind }
    }

    /// One rollup per log folder among the selected accounts.
    private var rollup: CostRollup {
        var seen = Set<String>()
        var rollups: [CostRollup] = []
        for tool in selectedProviders {
            let state = appState.state(for: tool)
            guard let stored = state.costRollup,
                  seen.insert(state.tokenLogKey ?? tool.storageKey).inserted else { continue }
            rollups.append(stored)
        }
        return CostRollup.combined(rollups)
    }

    private var isLoading: Bool {
        selectedProviders.contains { appState.state(for: $0).costRollup == nil }
    }

    /// Names of accounts that share a log folder, one entry per such folder.
    private var sharedFolders: [String] {
        var seen = Set<String>()
        return selectedProviders.compactMap { tool in
            let state = appState.state(for: tool)
            guard !state.tokenLogSharedWith.isEmpty,
                  seen.insert(state.tokenLogKey ?? tool.storageKey).inserted else { return nil }
            return ([tool.shortName] + state.tokenLogSharedWith).formatted(.list(type: .and))
        }
    }

    /// The account whose weekly quota the tool's cost can be set against:
    /// only when the selected tool has one account and nobody else writes to
    /// its log folder.
    private var weeklyTool: ProviderID? {
        guard selectedKind != nil, selectedProviders.count == 1, let tool = selectedProviders.first,
              appState.state(for: tool).tokenLogSharedWith.isEmpty else { return nil }
        return tool
    }

    private var weeklyLoadKey: String {
        guard let tool = weeklyTool else { return "none" }
        let fetched = appState.state(for: tool).lastSuccessfulFetch?.timeIntervalSince1970 ?? 0
        return "\(tool.storageKey)|\(Int(fetched))"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DS.Page.spacing) {
                PanelHeader(title: "Cost") { rangePicker }
                toolPicker
                Text("API-equivalent value of this Mac's CLI logs · not a bill")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.C.textMuted)
                ForEach(sharedFolders, id: \.self) { names in
                    Text("\(names) share one log folder; their tokens are counted once.")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.C.textMuted)
                }
                CostContent(rollup: rollup, range: range, isLoading: isLoading)
                weeklySection
            }
            .padding(.horizontal, DS.Page.side)
            .padding(.top, DS.Page.top)
            .padding(.bottom, DS.Page.bottom)
            .reportsPanelHeight()
        }
        .task(id: weeklyLoadKey) {
            guard let tool = weeklyTool else {
                weeklySamples = []
                return
            }
            let since = Date().addingTimeInterval(-5 * tool.weeklyWindowDuration)
            weeklySamples = await UsageHistoryStore.shared.samples(for: tool, since: since)
        }
        .task {
            // Show the stored rollup before this launch's first scan finishes.
            for tool in appState.providers where appState.state(for: tool).costRollup == nil {
                let key = tool.tokenLogKey
                let stored = await Task.detached(priority: .utility) {
                    CostRollupStore.shared.rollup(storageKey: key)
                }.value
                let state = appState.state(for: tool)
                if state.costRollup == nil, !stored.isEmpty {
                    state.costRollup = stored
                    state.tokenLogKey = key
                }
            }
        }
    }

    @ViewBuilder
    private var weeklySection: some View {
        if let tool = weeklyTool {
            let state = appState.state(for: tool)
            if let weekly = state.weeklyMetric, let resetAt = weekly.resetAt {
                WeeklyValueCard(
                    resetAt: resetAt,
                    periods: WeeklyQuotaValue.periods(
                        rollup: state.costRollup ?? CostRollup(),
                        resetAt: resetAt,
                        duration: tool.weeklyWindowDuration,
                        samples: weeklySamples,
                        currentUsed: 1 - weekly.remainingFraction
                    )
                )
            }
        } else {
            let note: LocalizedStringKey = selectedKind == nil
                ? "Pick Claude or Codex to see what its weekly quota was worth."
                : "Weekly quota value needs a tool with one account and its own log folder; these accounts' tokens can't be told apart."
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(DS.C.textMuted)
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(CostRange.allCases) { option in
                let selected = option == range
                Button(action: { rangeRaw = option.rawValue }) {
                    Text(option.label)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(selected ? DS.C.surface : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(selected ? DS.C.border : .clear, lineWidth: 1))
                        .foregroundStyle(selected ? DS.C.text : DS.C.textMuted)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(Text(option.longLabel))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(DS.C.surfaceHigh, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var toolPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(title: "All", selected: selectedKind == nil, color: DS.C.ink) {
                    toolRaw = HistoryTabView.allKey
                } icon: {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                ForEach(kinds, id: \.self) { kind in
                    chip(title: LocalizedStringKey(kind.shortName), selected: kind == selectedKind, color: DS.C.history(kind)) {
                        toolRaw = kind.rawValue
                    } icon: {
                        Image(kind.glyphAssetName)
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 12, height: 12)
                    }
                }
            }
        }
    }

    private func chip<Icon: View>(
        title: LocalizedStringKey,
        selected: Bool,
        color: Color,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon()
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(selected ? DS.C.onInk : DS.C.textSub)
            .background(selected ? color : DS.C.surfaceHigh, in: Capsule())
            .overlay(Capsule().stroke(selected ? .clear : DS.C.border, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

enum CostRange: String, CaseIterable, Identifiable {
    case today, week, month, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return String(localized: "Today")
        case .week: return String(localized: "7D")
        case .month: return String(localized: "30D")
        case .all: return String(localized: "All")
        }
    }

    var longLabel: String {
        switch self {
        case .today: return String(localized: "today")
        case .week: return String(localized: "last 7 days")
        case .month: return String(localized: "last 30 days")
        case .all: return String(localized: "all stored days")
        }
    }
}

extension CostComponent {
    var label: LocalizedStringKey {
        switch self {
        case .cacheRead: return "Cache read"
        case .cacheWrite: return "Cache write"
        case .output: return "Output"
        case .input: return "Input"
        }
    }

    var plotName: String {
        switch self {
        case .cacheRead: return String(localized: "Cache read")
        case .cacheWrite: return String(localized: "Cache write")
        case .output: return String(localized: "Output")
        case .input: return String(localized: "Input")
        }
    }

    var color: Color {
        switch self {
        case .cacheRead: return DS.C.green
        case .cacheWrite: return DS.C.historyBoth
        case .output: return DS.C.accent(.claude)
        case .input: return DS.C.usageBlue
        }
    }
}

enum CostFormat {
    static func usd(_ value: Double) -> String {
        let digits = value >= 1000 ? 0 : 2
        return value.formatted(.currency(code: "USD").precision(.fractionLength(digits)))
    }

    static func usdWhole(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    static func percent(_ fraction: Double) -> String {
        if fraction > 0, fraction < 0.01 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }
}

// MARK: - Range content

private struct CostBar: Identifiable {
    let x: Date
    let component: CostComponent
    let value: Double

    var id: String { "\(x.timeIntervalSince1970)-\(component.rawValue)" }
}

private struct CostContent: View {
    let rollup: CostRollup
    let range: CostRange
    let isLoading: Bool

    private var calendar: Calendar { .current }

    private var dayKeys: [String] {
        switch range {
        case .today: return CostRollup.dayKeys(endingAt: Date(), count: 1, calendar: calendar)
        case .week: return CostRollup.dayKeys(endingAt: Date(), count: 7, calendar: calendar)
        case .month: return CostRollup.dayKeys(endingAt: Date(), count: 30, calendar: calendar)
        case .all: return rollup.sortedDayKeys
        }
    }

    private var summary: CostPeriodSummary { rollup.summary(dayKeys: dayKeys) }

    var body: some View {
        let summary = self.summary
        if summary.totalTokens == 0 {
            Text(isLoading ? "Reading local logs…" : "No local usage in this range.")
                .font(.system(size: 11))
                .foregroundStyle(DS.C.textMuted)
                .frame(maxWidth: .infinity, minHeight: 80)
                .dsCard()
        } else {
            summaryCard(summary)
            compositionCard(summary)
            chartCard
            modelCard(summary)
        }
    }

    private var title: String {
        switch range {
        case .all:
            if let first = rollup.sortedDayKeys.first.flatMap({ CostRollup.date(fromDayKey: $0, calendar: calendar) }) {
                return String(localized: "since \(first.formatted(.dateTime.month(.abbreviated).day()))")
            }
            return range.longLabel
        default:
            return range.longLabel
        }
    }

    private func summaryCard(_ summary: CostPeriodSummary) -> some View {
        let todayKey = CostRollup.dayKey(Date(), calendar: calendar)
        let yesterdayKey = CostRollup.dayKey(calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date(), calendar: calendar)
        let sideKey = range == .today ? yesterdayKey : todayKey
        let sideCost = rollup.summary(dayKeys: [sideKey]).cost.total
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("API equivalent · \(title)")
                    .dsSectionLabel()
                Text(CostFormat.usd(summary.cost.total))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(DS.C.text)
                    .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                statRow("Tokens", TokenFormat.compact(summary.totalTokens))
                statRow("Cache hit", summary.cacheHitRate.map(CostFormat.percent) ?? "–")
                statRow(range == .today ? "Yesterday" : "Today", CostFormat.usd(sideCost))
            }
        }
        .padding(DS.Page.cardPadding)
        .dsCard()
    }

    private func statRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(DS.C.textMuted)
            Text(value)
                .font(DS.mono(11, weight: .semibold))
                .foregroundStyle(DS.C.text)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }

    private func compositionCard(_ summary: CostPeriodSummary) -> some View {
        let total = summary.cost.total
        return VStack(alignment: .leading, spacing: 10) {
            Text("Cost by token type").dsSectionLabel()
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(CostComponent.allCases) { component in
                        let share = total > 0 ? summary.cost[component] / total : 0
                        if share > 0 {
                            Rectangle()
                                .fill(component.color)
                                .frame(width: max(geo.size.width * share, 2))
                        }
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .background(DS.C.track)
                .clipShape(Capsule())
            }
            .frame(height: 10)
            .accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                ForEach(CostComponent.allCases) { component in
                    let value = summary.cost[component]
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(component.color).frame(width: 8, height: 8)
                        Text(component.label)
                            .font(.system(size: 10.5))
                            .foregroundStyle(DS.C.text)
                        Spacer(minLength: 4)
                        Text(verbatim: "\(CostFormat.usd(value))  \(CostFormat.percent(total > 0 ? value / total : 0))")
                            .font(DS.mono(10.5))
                            .foregroundStyle(DS.C.text)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(DS.Page.cardPadding)
        .dsCard()
    }

    // MARK: Chart

    private var chartTitle: LocalizedStringKey {
        switch range {
        case .today: return "Hourly"
        case .week, .month: return "Daily"
        case .all: return "Weekly"
        }
    }

    private var bars: [CostBar] {
        let today = calendar.startOfDay(for: Date())
        switch range {
        case .today:
            let end = calendar.date(byAdding: .day, value: 1, to: today) ?? Date()
            return rollup.hourlyCosts(from: today, to: end).flatMap { Self.split($0.hour, $0.cost) }
        case .week, .month:
            return zip(dayKeys, rollup.dailyCosts(dayKeys: dayKeys)).flatMap { key, cost in
                CostRollup.date(fromDayKey: key, calendar: calendar).map { Self.split($0, cost) } ?? []
            }
        case .all:
            var weeks: [Date: CostSplit] = [:]
            for (key, cost) in zip(dayKeys, rollup.dailyCosts(dayKeys: dayKeys)) {
                guard let day = CostRollup.date(fromDayKey: key, calendar: calendar),
                      let week = calendar.dateInterval(of: .weekOfYear, for: day)?.start else { continue }
                weeks[week, default: CostSplit()] += cost
            }
            return weeks.keys.sorted().flatMap { Self.split($0, weeks[$0] ?? CostSplit()) }
        }
    }

    private static func split(_ x: Date, _ cost: CostSplit) -> [CostBar] {
        CostComponent.allCases.map { CostBar(x: x, component: $0, value: cost[$0]) }
    }

    private var unit: Calendar.Component {
        switch range {
        case .today: return .hour
        case .week, .month: return .day
        case .all: return .weekOfYear
        }
    }

    private var chartCard: some View {
        let bars = self.bars
        let peak = Dictionary(grouping: bars, by: \.x).values.map { $0.reduce(0) { $0 + $1.value } }.max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(chartTitle).dsSectionLabel()
                Spacer()
                Text("max \(CostFormat.usd(peak))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.C.textMuted)
            }
            Chart(bars) { bar in
                BarMark(
                    x: .value("Time", bar.x, unit: unit),
                    y: .value("Cost", bar.value),
                    width: .ratio(0.7)
                )
                .foregroundStyle(by: .value("Kind", bar.component.plotName))
            }
            .chartForegroundStyleScale(
                domain: CostComponent.allCases.map(\.plotName),
                range: CostComponent.allCases.map(\.color)
            )
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(DS.C.border)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: range == .week ? 7 : 5)) { _ in
                    AxisValueLabel(format: xFormat)
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.C.textMuted)
                }
            }
            .frame(height: 90)
        }
        .padding(DS.Page.cardPadding)
        .dsCard()
    }

    private var xFormat: Date.FormatStyle {
        switch range {
        case .today: return .dateTime.hour()
        case .week: return .dateTime.weekday(.abbreviated)
        case .month, .all: return .dateTime.month(.abbreviated).day()
        }
    }

    // MARK: Models

    private func modelCard(_ summary: CostPeriodSummary) -> some View {
        let priced = summary.models.filter { $0.costUSD > 0 }
        let top = priced.first?.costUSD ?? 0
        let total = summary.cost.total
        let unpriced = summary.unpricedModels
        return VStack(alignment: .leading, spacing: 7) {
            Text("By model").dsSectionLabel()
            ForEach(priced.prefix(6)) { row in
                HStack(spacing: 8) {
                    Text(row.model)
                        .font(DS.mono(10.5))
                        .foregroundStyle(DS.C.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 140, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(DS.C.track)
                            .overlay(alignment: .leading) {
                                Capsule().fill(DS.C.accent(.claude))
                                    .frame(width: max(geo.size.width * (top > 0 ? row.costUSD / top : 0), 2))
                            }
                    }
                    .frame(height: 6)
                    .accessibilityHidden(true)
                    Text(CostFormat.usd(row.costUSD))
                        .font(DS.mono(10.5))
                        .foregroundStyle(DS.C.text)
                        .frame(width: 64, alignment: .trailing)
                    Text(CostFormat.percent(total > 0 ? row.costUSD / total : 0))
                        .font(.system(size: 10.5))
                        .foregroundStyle(DS.C.textMuted)
                        .frame(width: 30, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
            if !unpriced.isEmpty {
                let names = unpriced.prefix(3).map(\.model).joined(separator: ", ")
                let tokens = TokenFormat.compact(unpriced.reduce(0) { $0 + $1.unpricedTokens })
                Text("⚠ Unpriced: \(tokens) tokens (\(names)) are not in the total")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.C.costWarn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(DS.Page.cardPadding)
        .dsCard()
    }
}

// MARK: - Weekly quota value

private struct WeeklyValueCard: View {
    let resetAt: Date
    let periods: [WeeklyQuotaValue]

    var body: some View {
        let current = periods.last { $0.isCurrent }
        let peak = periods.map(\.costUSD).max() ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Weekly quota · API equivalent").dsSectionLabel()
                Spacer()
                Text("resets \(resetAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.C.textMuted)
            }
            HStack(alignment: .top, spacing: 40) {
                stat("This week", current.map { CostFormat.usd($0.costUSD) } ?? "–", color: DS.C.usageBlue)
                stat("Quota used", current?.usedFraction.map(CostFormat.percent) ?? "–", color: DS.C.text)
            }
            if periods.isEmpty {
                Text("No stored usage for these weeks yet.")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.C.textMuted)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(periods) { period in
                        VStack(spacing: 4) {
                            Text(label(period))
                                .font(DS.mono(9))
                                .foregroundStyle(DS.C.text)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(DS.C.usageBlue)
                                .frame(width: 40, height: max(56 * (peak > 0 ? period.costUSD / peak : 0), 2))
                            Text(period.isCurrent ? String(localized: "Now") : period.start.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.system(size: 9.5, weight: period.isCurrent ? .bold : .regular))
                                .foregroundStyle(DS.C.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Text("This Mac's logs only · web apps and other devices not included")
                .font(.system(size: 9.5))
                .foregroundStyle(DS.C.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Page.cardPadding)
        .dsCard()
    }

    private func label(_ period: WeeklyQuotaValue) -> String {
        let money = CostFormat.usdWhole(period.costUSD)
        guard let used = period.usedFraction else { return money }
        return "\(money) · \(CostFormat.percent(used))"
    }

    private func stat(_ title: LocalizedStringKey, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(DS.C.textMuted)
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }
}
