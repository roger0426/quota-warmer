import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Session-only display state — never persisted, so every popover open
    // starts with both provider sections expanded (empty = nothing collapsed).
    @State private var collapsedTools: Set<ProviderID> = []

    var body: some View {
        // Fixed, non-scrolling overview — only Settings scrolls. The panel
        // fits this content's height (see `AppState.panelHeight`).
        VStack(spacing: 0) {
            // Missing-CLI banner (moved here with the per-account tabs gone).
            if appState.showOnboarding {
                OnboardingView()
                    .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: DS.Page.spacing) {
                PanelHeader(title: "QuotaWarmer") { automationControl }
                if let warning = appState.watcherStatusText { watcherWarning(warning) }
                if !outcomeTools.isEmpty { statusCard }
                providerList
            }
            .padding(.horizontal, DS.Page.side)
            .padding(.top, DS.Page.top)
            .padding(.bottom, DS.Page.bottom)
        }
        .reportsPanelHeight()
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Shown only when no quota check has succeeded recently (moved here from
    /// the removed footer strip).
    private func watcherWarning(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(DS.C.yellow)
        .help("QuotaWarmer hasn't completed a quota check recently — it may be offline or blocked.")
    }

    private var automationControl: some View {
        let paused = appState.globalPassive
        let helpText: LocalizedStringKey = paused ? "Resume automatic warmups" : "Pause all automatic warmups"
        let stateColor = paused ? DS.C.red : DS.C.green

        let fetching = appState.providers.contains { appState.state(for: $0).isFetchingQuota }
        return HStack(spacing: 7) {
            // Double-arrow icon (the per-tool buttons use a single arrow) = "both".
            // While refreshing it stays the same icon, just dimmed and not clickable.
            IconButton(
                systemName: "arrow.triangle.2.circlepath",
                help: "Refresh every account's quota now",
                size: 26,
                isDisabled: fetching,
                shortcut: "r"
            ) {
                Task {
                    await withTaskGroup(of: Void.self) { group in
                        for tool in appState.providers {
                            group.addTask { await appState.refreshQuotaManually(for: tool) }
                        }
                    }
                }
            }
            .opacity(fetching ? 0.4 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: fetching)
            // One control for the global state: a green pause while warm-ups
            // run, a red play while they are paused. The icon shape (and the
            // help / accessibility text) carries the state, not just the color.
            IconButton(
                systemName: paused ? "play.fill" : "pause.fill",
                help: helpText,
                tint: stateColor,
                border: stateColor.opacity(0.30),
                size: 26
            ) { appState.globalPassive.toggle() }
        }
        .help(helpText)
    }

    /// One card per provider, so each reads as its own panel.
    private var providerList: some View {
        VStack(spacing: DS.Page.spacing) {
            ForEach(appState.providers) { tool in
                providerRow(tool)
                    .dsCard()
            }
        }
    }

    private func providerRow(_ tool: ProviderID) -> some View {
        let state = appState.state(for: tool)
        let collapsed = collapsedTools.contains(tool)
        return VStack(alignment: .leading, spacing: collapsed ? 0 : 10) {
            // iStat-style section title (glyph + uppercase name) on the left, the
            // same mode / refresh / pin controls on the right.
            HStack(spacing: 6) {
                Button(action: { toggleCollapsed(tool) }) {
                    HStack(spacing: 5) {
                        StatSectionTitle(title: tool.shortName, glyph: tool.kind.glyphAssetName)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(DS.C.textMuted)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                    }
                    // The label's natural bounds are just the glyphs — pad the
                    // hit area out to a comfortably tappable rectangle instead
                    // of relying on precise glyph-edge hits.
                    .padding(.vertical, 4)
                    .padding(.trailing, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(Text(collapsed ? "Expand \(tool.shortName) section" : "Collapse \(tool.shortName) section"))
                Spacer(minLength: 6)
                ToolModeMenu(mode: state.mode, compact: true) { appState.setMode($0, for: tool) }
                    .fixedSize()
                // Warm this account now. Percent direction and the menu-bar
                // pin moved to Settings → Accounts.
                IconButton(
                    systemName: "bolt.fill",
                    help: "Warm \(tool.shortName) now",
                    tint: DS.C.accent(tool),
                    size: 26,
                    isDisabled: state.isWarming
                ) { appState.activate(tool) }
                .opacity(state.isWarming ? 0.4 : 1)
                IconButton(
                    systemName: state.isFetchingQuota ? "hourglass" : state.quotaBackoffActive ? "clock.arrow.circlepath" : "arrow.clockwise",
                    help: "Refresh \(tool.shortName) quota now",
                    size: 26,
                    // Only an in-flight fetch disables Refresh. Disabling it
                    // during a rate-limit backoff made the control dead for the
                    // whole retry window — which is exactly when the user wants
                    // to retry. `refreshQuotaManually` forces through it.
                    isDisabled: state.isFetchingQuota
                ) { Task { await appState.refreshQuotaManually(for: tool) } }
            }

            if !collapsed {
                if let issue = providerIssue(state) {
                    Text(issue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.C.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                windowRow(state, title: String(localized: "Session"), name: String(localized: "\(tool.shortName) 5-hour window"), metric: state.primaryMetric,
                          resetAt: state.resetAt, windowDuration: tool.windowDuration,
                          settling: state.sessionSettling)
                windowRow(state, title: String(localized: "Weekly"), name: String(localized: "\(tool.shortName) weekly window"), metric: state.weeklyMetric,
                          resetAt: state.weeklyMetric?.resetAt, windowDuration: tool.weeklyWindowDuration)
                if let credits = state.quotaSnapshot?.resetCredits, !credits.isEmpty {
                    Rectangle()
                        .fill(DS.C.borderSoft)
                        .frame(height: 1)
                    ResetCreditsRow(credits: credits, now: Date()) { await appState.useResetCredit($0, for: tool) }
                }
                if state.mode == .autoWarm {
                    // Only when something needs the user; the routine
                    // "waiting for the next window" line is left out.
                    AutoWarmStatusLine(toolState: state, attentionOnly: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, collapsed ? 5 : 10)
    }

    private func toggleCollapsed(_ tool: ProviderID) {
        if collapsedTools.contains(tool) {
            collapsedTools.remove(tool)
        } else {
            collapsedTools.insert(tool)
        }
    }

    private func windowRow(_ state: ToolState, title: String, name: String, metric: QuotaMetric?, resetAt: Date?, windowDuration: TimeInterval, settling: Bool = false) -> some View {
        let quotaLeft = metric?.remainingFraction ?? 0
        // A just-opened window the provider transiently reports as near-empty:
        // show the reset countdown but neither the bogus "0% left" nor the
        // "behind pace / runs out" alarm until the real number settles.
        let settlingActive = settling && metric != nil
        // An idle (not-yet-started) 5h window only carries a sliding "if you
        // started now" projection, not a real boundary — rendering it as
        // "Resets in 4h 56m" makes a window that hasn't opened look active. Drop
        // the projected reset so the row falls back to "Not started yet".
        let effectiveReset = metric?.isIdleFiveHourWindow == true ? nil : resetAt
        let leftText = ToolStatusCopy.quotaLeftText(for: state, metric: metric, settling: settlingActive)
        let pace = QuotaPace.compute(
            quotaLeft: settlingActive ? 1 : quotaLeft,
            resetAt: effectiveReset,
            windowDuration: windowDuration,
            now: Date(),
            fallbackResetText: fallbackResetText(state, metric: metric)
        )
        return QuotaWindowRow(
            title: title,
            accessibilityName: name,
            hasMetric: metric != nil,
            quotaLeft: settlingActive ? (pace.timeLeftFraction ?? quotaLeft) : quotaLeft,
            leftText: leftText,
            pace: pace,
            refreshing: state.isFetchingQuota || settlingActive,
            statusColor: ToolStatusCopy.rowStatusColor(for: state, hasMetric: metric != nil),
            compact: true,
            displayMode: state.displayMode,
            settling: settlingActive,
            inline: true
        )
    }

    private func fallbackResetText(_ state: ToolState, metric: QuotaMetric?) -> String {
        ToolStatusCopy.resetFallback(for: state, metric: metric)
    }

    private func providerIssue(_ state: ToolState) -> String? {
        ToolStatusCopy.providerIssue(for: state)
    }

    // MARK: - Last warm-up status card ("did it actually work?")

    private var outcomeTools: [ProviderID] {
        // Only show a row once an actual warm-up outcome exists. Mode is already
        // visible in each provider row (its colored dot + status text), so the
        // Auto-warm state no longer adds a card here — that previously made the
        // panel grow/shrink on every mode toggle and jolt the scroll position.
        // A confirmed warm-up is routine (the bars already show the open
        // window), so the card appears only while one is pending or needs action.
        appState.providers.filter { tool in
            switch appState.state(for: tool).lastWarmupOutcome {
            case .none, .confirmed: return false
            case .pending, .unverified, .failed: return true
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(outcomeTools) { tool in
                outcomeRow(tool)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func outcomeRow(_ tool: ProviderID) -> some View {
        let state = appState.state(for: tool)
        let info = outcomeInfo(state.lastWarmupOutcome, mode: state.mode)
        return HStack(alignment: .center, spacing: 7) {
            StatusDot(color: info.color, size: 7)
            // One line per tool keeps the overview inside the fixed panel height.
            Text(tool.shortName)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(DS.C.text)
            Text(info.message)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DS.C.textSub)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(info.message)
            Spacer(minLength: 6)
            if info.showWarm {
                Button(action: { appState.activate(tool) }) {
                    Text("Warm")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(DS.C.accent(tool), in: Capsule())
                        .foregroundStyle(DS.C.onAccent)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(state.isWarming)
                .accessibilityLabel(Text("Warm \(tool.shortName) now"))
            }
        }
    }

    private func outcomeInfo(_ outcome: WarmupOutcome, mode: ToolMode) -> (color: Color, message: String, showWarm: Bool) {
        switch outcome {
        case .none:
            if mode == .autoWarm {
                return (DS.C.green, String(localized: "Auto-warm on — the next fresh window will be claimed automatically."), false)
            }
            return (DS.C.textMuted, String(localized: "No warm-up yet."), false)
        case .pending:
            return (DS.C.yellow, String(localized: "Warm-up sent — verifying the window opened…"), false)
        case .confirmed(let at, let resetAt):
            var message = String(localized: "Window claimed at \(shortClock(at))")
            if let resetAt, resetAt > Date() {
                let remaining = quotaDurationText(Int(resetAt.timeIntervalSinceNow))
                message += " · " + String(localized: "resets in \(remaining)")
            }
            return (DS.C.green, message, false)
        case .unverified(let sentAt, _):
            return (
                DS.C.yellow,
                String(localized: "Command sent at \(shortClock(sentAt)), but live quota did not confirm that the window opened."),
                true
            )
        case .failed(_, let reason):
            return (DS.C.red, String(localized: "Warm-up failed: \(reason)"), true)
        }
    }

    private func shortClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct HistoryRow: View {
    let event: HistoryEvent

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Text(time(event.timestamp))
                .font(DS.mono(10))
                .foregroundStyle(DS.C.textMuted)
                .frame(width: 45, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                Text(event.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.C.textMuted)
                    .lineLimit(2)
            }
        }
    }

    private var title: String {
        if let tool = event.tool {
            return "\(tool.shortName): \(event.title)"
        }
        return event.title
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
