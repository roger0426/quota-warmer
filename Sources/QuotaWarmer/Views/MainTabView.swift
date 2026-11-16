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
                providerList
                    .zIndex(2)   // a card's hover bubble draws over the header above it
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
                shortcut: "r",
                hint: appState.providers.map { tool in
                    "\(tool.displayName): \(ToolStatusCopy.refreshHint(for: appState.state(for: tool)))"
                }.joined(separator: "\n"),
                hintBeside: true
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
            ForEach(Array(appState.providers.enumerated()), id: \.element) { index, tool in
                providerRow(tool)
                    .dsCard()
                    // iStat-style detail window beside the panel on hover.
                    .hoverDetail(id: "provider-\(tool.storageKey)", delay: 0) {
                        ProviderDetailView(tool: tool, state: appState.state(for: tool))
                    }
                    // Hover bubbles open upward, so later cards stack above
                    // earlier ones and a bubble isn't hidden by the card above.
                    .zIndex(Double(index))
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
                    // Same plain glyph colour for every provider (white in dark).
                    tint: DS.C.text,
                    size: 22,
                    isDisabled: state.isWarming,
                    hint: ToolStatusCopy.warmHint(for: state)
                ) { appState.activate(tool) }
                .opacity(state.isWarming ? 0.4 : 1)
                IconButton(
                    systemName: state.isFetchingQuota ? "hourglass" : state.quotaBackoffActive ? "clock.arrow.circlepath" : "arrow.clockwise",
                    help: "Refresh \(tool.shortName) quota now",
                    size: 22,
                    // Only an in-flight fetch disables Refresh. Disabling it
                    // during a rate-limit backoff made the control dead for the
                    // whole retry window — which is exactly when the user wants
                    // to retry. `refreshQuotaManually` forces through it.
                    isDisabled: state.isFetchingQuota,
                    hint: ToolStatusCopy.refreshHint(for: state)
                ) { Task { await appState.refreshQuotaManually(for: tool) } }
            }
            .zIndex(1)   // hover bubbles draw over this card's rows

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
            inline: true,
            // Only the weekly window lasts long enough for "days left".
            unusedSoon: windowDuration >= 86400 && !settlingActive
                && UnusedQuotaRule.load().applies(remainingFraction: metric?.remainingFraction, resetAt: effectiveReset)
        )
    }

    private func fallbackResetText(_ state: ToolState, metric: QuotaMetric?) -> String {
        ToolStatusCopy.resetFallback(for: state, metric: metric)
    }

    private func providerIssue(_ state: ToolState) -> String? {
        ToolStatusCopy.providerIssue(for: state)
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
