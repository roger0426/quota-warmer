import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ServiceManagement

struct SettingsTabView: View {
    @EnvironmentObject var appState: AppState
    /// Which page of the standalone Settings window this view renders.
    var pane: SettingsPane = .general

    @AppStorage("refreshInterval")   private var refreshInterval: Int    = 300
    @AppStorage("notifyWarning")     private var notifyWarning: Bool     = true
    @AppStorage("notifyActivated")   private var notifyActivated: Bool   = true
    @AppStorage(QuotaAlertSettings.sessionEnabledKey) private var alertSession: Bool = true
    @AppStorage(QuotaAlertSettings.sessionFirstKey)   private var alertSessionFirst: Int = QuotaAlertSettings.defaultSessionThresholds[0]
    @AppStorage(QuotaAlertSettings.sessionSecondKey)  private var alertSessionSecond: Int = QuotaAlertSettings.defaultSessionThresholds[1]
    @AppStorage(QuotaAlertSettings.weeklyEnabledKey)  private var alertWeekly: Bool = true
    @AppStorage(QuotaAlertSettings.weeklyFirstKey)    private var alertWeeklyFirst: Int = QuotaAlertSettings.defaultWeeklyThresholds[0]
    @AppStorage(QuotaAlertSettings.weeklySecondKey)   private var alertWeeklySecond: Int = QuotaAlertSettings.defaultWeeklyThresholds[1]
    @AppStorage(QuotaAlertSettings.paceEnabledKey)    private var alertPace: Bool = true
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var historyExpanded = true
    @State private var historyFilter = EventFilter()
    @State private var historyVisible = 25
    @AppStorage("rateLimitGuard")    private var rateLimitGuard: Bool    = true

    @AppStorage("morningPrewarmHour")         private var morningHour: Int         = 6
    @AppStorage("morningPrewarmMinute")       private var morningMinute: Int       = 0
    @AppStorage("morningPrewarmWeekdaysOnly") private var morningWeekdaysOnly: Bool = true
    @AppStorage(QuotaDisplay.colorfulBarsKey) private var colorfulBars: Bool = true
    @AppStorage(QuotaUsageLevel.warningPercentKey) private var warningPercent: Int = QuotaUsageLevel.defaultWarningPercent
    @AppStorage(QuotaDisplay.menuBarStyleKey) private var menuBarStyleRaw = QuotaDisplay.MenuBarStyle.gauge.rawValue
    @State private var language = AppLanguage.stored()
    @AppStorage(AppearanceMode.defaultsKey) private var appearanceRaw = AppearanceMode.system.rawValue

    private let refreshOptions: [(label: String, value: Int)] = [
        (String(localized: "5m"), 300), (String(localized: "10m"), 600),
        (String(localized: "15m"), 900), (String(localized: "30m"), 1800)
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                group("CHECKS", in: .general) {
                    row(icon: "clock.arrow.2.circlepath", title: "Quota Refresh Interval",
                        subtitle: "Default 5 minutes") {
                        segmentedPicker(
                            options: refreshOptions,
                            selected: $refreshInterval
                        ) { appState.applyRefreshInterval() }
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "shield.lefthalf.filled", title: "Rate-limit Guard",
                        subtitle: "Back off after failures") {
                        Toggle(isOn: $rateLimitGuard) { Text("Rate-limit Guard") }.labelsHidden()
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "arrow.clockwise", title: "Manual Refresh",
                        subtitle: "Monitored tools only") {
                        Button(action: { appState.refreshAllActivity() }) {
                            Text("Refresh")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 13)
                                .frame(height: 26)
                                .background(DS.C.surfaceHigh, in: Capsule())
                                .foregroundStyle(DS.C.textSub)
                                .overlay(Capsule().stroke(DS.C.border, lineWidth: 1))
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }

                group("ACCOUNTS", in: .accounts) {
                    AccountsSection()
                }

                group("DISPLAY", in: .general) {
                    row(icon: "circle.lefthalf.filled", title: "Theme",
                        subtitle: "System follows macOS") {
                        themePicker
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "globe", title: "Language",
                        subtitle: language == AppLanguage.atLaunch ? "System follows macOS" : "Restart to apply") {
                        HStack(spacing: 6) {
                            languagePicker
                            if language != AppLanguage.atLaunch {
                                Button(action: relaunch) {
                                    Text("Restart")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .lineLimit(1)
                                        .fixedSize()
                                        .padding(.horizontal, 9)
                                        .frame(height: 22)
                                        .background(DS.C.ink, in: Capsule())
                                        .foregroundStyle(DS.C.onInk)
                                }
                                .buttonStyle(PressableButtonStyle())
                                .help("Restart QuotaWarmer in the chosen language")
                            }
                        }
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "menubar.rectangle", title: "Menu Bar",
                        subtitle: menuBarStyleRaw == QuotaDisplay.MenuBarStyle.text.rawValue
                            ? "Percent and time to reset"
                            : "5-hour and weekly bars, red from the warning level") {
                        menuBarStylePicker
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "paintpalette", title: "Colorful Quota Bars",
                        subtitle: colorfulBars ? "Blue, then red from the warning level" : "Single-color bars") {
                        Toggle(isOn: $colorfulBars) { Text("Colorful Quota Bars") }.labelsHidden()
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "exclamationmark.triangle", title: "Warning At",
                        subtitle: "Usage at or above this shows red, in the panel and the widget") {
                        HStack(spacing: DS.Space.sm) {
                            Slider(
                                value: Binding(
                                    get: { Double(QuotaUsageLevel.clampedWarningPercent(warningPercent)) },
                                    set: { warningPercent = QuotaUsageLevel.clampedWarningPercent(Int($0.rounded())) }
                                ),
                                in: Double(QuotaUsageLevel.warningPercentRange.lowerBound)...Double(QuotaUsageLevel.warningPercentRange.upperBound),
                                step: Double(QuotaUsageLevel.warningPercentStep)
                            ) { Text("Warning At") }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 120)
                            Text(verbatim: "\(QuotaUsageLevel.clampedWarningPercent(warningPercent))%")
                                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(DS.C.text)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                    // The widget reads the threshold from status.json.
                    .onChange(of: warningPercent) { appState.quota.exportStatus() }
                }

                group("SHORTCUTS", in: .shortcuts) {
                    HotKeySettingsSection()
                }

                group("MORNING PRE-WARM", in: .morning) {
                    row(icon: "sunrise", title: "Wake & Warm Each Morning",
                        subtitle: "Wakes a sleeping Mac to start your window") {
                        Toggle(isOn: Binding(
                            get: { appState.morningPrewarmEnabled },
                            set: { appState.setMorningPrewarm($0) }
                        )) { Text("Wake & Warm Each Morning") }
                        .labelsHidden()
                        .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "clock", title: "Wake Time",
                        subtitle: "Start the window before you sit down") {
                        // Typed by hand (HH:mm). A DS-styled text field instead of
                        // the AppKit stepper DatePicker, which renders as a
                        // clipped dark box in this scaled borderless panel.
                        WakeTimeField(hour: $morningHour, minute: $morningMinute) {
                            appState.morningTimeChanged()
                        }
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "calendar", title: "Weekdays Only",
                        subtitle: "Skip Saturday and Sunday") {
                        Toggle(isOn: $morningWeekdaysOnly) { Text("Weekdays Only") }.labelsHidden()
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                            .onChange(of: morningWeekdaysOnly) { _, _ in appState.morningTimeChanged() }
                    }

                    if let status = appState.morningStatus {
                        Divider().background(DS.C.border).padding(.leading, 36)
                        HStack(alignment: .top, spacing: DS.Space.sm) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12)).foregroundStyle(DS.C.textSub).frame(width: 20)
                            Text(status)
                                .font(.system(size: 9.5)).foregroundStyle(DS.C.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, DS.Space.md)
                        .padding(.vertical, DS.Space.sm + 2)
                    }
                }

                group("ALERTS", in: .alerts) {
                    row(icon: "bell.badge", title: "Window Expiring Soon",
                        subtitle: "30 min before reset") {
                        Toggle(isOn: $notifyWarning) { Text("Window Expiring Soon") }.labelsHidden()
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "checkmark.circle", title: "Window Activated",
                        subtitle: "After warmup succeeds") {
                        Toggle(isOn: $notifyActivated) { Text("Window Activated") }.labelsHidden()
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "gauge.with.dots.needle.67percent", title: "5h Usage",
                        subtitle: "Alert at % used") {
                        thresholdPill($alertSessionFirst, enabled: alertSession)
                        thresholdPill($alertSessionSecond, enabled: alertSession)
                        Toggle(isOn: $alertSession) { Text("5h Usage") }.labelsHidden()
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "calendar.badge.exclamationmark", title: "Weekly Usage",
                        subtitle: "Alert at % used") {
                        thresholdPill($alertWeeklyFirst, enabled: alertWeekly)
                        thresholdPill($alertWeeklySecond, enabled: alertWeekly)
                        Toggle(isOn: $alertWeekly) { Text("Weekly Usage") }.labelsHidden()
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                    }

                    Divider().background(DS.C.border).padding(.leading, 36)

                    row(icon: "speedometer", title: "Pace Warning",
                        subtitle: "5h quota runs out before reset") {
                        Toggle(isOn: $alertPace) { Text("Pace Warning") }.labelsHidden()
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                    }
                }

                group("SYSTEM", in: .general) {
                    row(icon: "power", title: "Launch at Login",
                        subtitle: "Start with macOS") {
                        Toggle(isOn: $launchAtLogin) { Text("Launch at Login") }.labelsHidden()
                            .toggleStyle(.switch).scaleEffect(0.75).tint(DS.C.green)
                            .onChange(of: launchAtLogin) { _, v in
                                updateLaunchAtLogin(v)
                            }
                    }
                    if let launchAtLoginError {
                        Divider().background(DS.C.border).padding(.leading, 36)
                        Text(launchAtLoginError)
                            .font(.system(size: 9.5))
                            .foregroundStyle(DS.C.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, DS.Space.md)
                            .padding(.vertical, DS.Space.sm)
                    }
                }

                group("WELCOME", in: .general) {
                    row(icon: "hand.wave", title: "Welcome Guide",
                        subtitle: "Modes, CLI check and permissions") {
                        Button("Show Welcome Guide") {
                            appState.openWelcomeGuide()
                            appState.onShowPanel?()
                        }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(DS.C.blue)
                    }
                }

                group("HISTORY", in: .history) {
                    historyContent
                }

                group("HOW IT WORKS", in: .privacy) {
                    transparencyRow(
                        "What QuotaWarmer does",
                        "It watches your own Claude Code and Codex quota windows. Only for tools you switch to Auto-warm, it sends a single minimal \"hi\" through the CLI you're already logged into, the moment a fresh window opens."
                    )
                    Divider().background(DS.C.border).padding(.leading, 36)
                    transparencyRow(
                        "What it never does",
                        "It never bypasses or raises your limits, never shares or uploads your credentials, and never sends anything for tools left on Monitor or Off."
                    )
                    Divider().background(DS.C.border).padding(.leading, 36)
                    transparencyRow(
                        "Is this allowed?",
                        "You're using capacity you already pay for, through the official CLI you already use. Providers may change their APIs at any time; if automated warm-up is ever disallowed, switch any tool to Monitor and QuotaWarmer keeps tracking your quota."
                    )
                }

                group("PRIVACY", in: .privacy) {
                    infoRow(
                        title: "Credential access",
                        detail: "Monitored accounts only. Claude reads Keychain Claude Code-credentials, env CLAUDE_CODE_OAUTH_TOKEN, or ~/.claude/.credentials.json. Codex reads auth.json or Keychain Codex Auth. An added account reads only its own folder's Keychain item or credentials file."
                    )
                    Divider().background(DS.C.border).padding(.leading, 36)
                    infoRow(
                        title: "Logs",
                        detail: "History is kept in ~/Library/Application Support/io.github.roger0426.quotawarmer/events.jsonl and mirrored to ~/Library/Logs/io.github.roger0426.quotawarmer/diagnostics.log. Tokens and authorization headers are redacted and are never written to history or warmup logs."
                    )
                }

                group("ABOUT", in: .about) {
                    HStack(spacing: DS.Space.md) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(DS.C.accent(.claude))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("QuotaWarmer")
                                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.C.text)
                            Text("Version \(appVersion)  ·  macOS 14+")
                                .font(.system(size: 10)).foregroundStyle(DS.C.textMuted)
                        }
                        Spacer()
                        if appState.updateInfo != nil {
                            Text("update available")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(DS.C.accent(.claude))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(DS.C.accent(.claude).opacity(0.10), in: Capsule())
                                .overlay(Capsule().stroke(DS.C.accent(.claude).opacity(0.20)))
                        }
                    }
                    .padding(.horizontal, DS.Space.md)
                    .padding(.vertical, DS.Space.md)

                    Divider().background(DS.C.border).padding(.leading, DS.Space.md)

                    if let update = appState.updateInfo {
                        Button(action: { NSWorkspace.shared.open(update.htmlURL) }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill").font(.system(size: 11))
                                Text("Download v\(update.version)").font(.system(size: 11))
                            }
                            .foregroundStyle(DS.C.accent(.claude))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DS.Space.md)
                            .padding(.vertical, DS.Space.md)
                        }
                        .buttonStyle(.plain)
                        Divider().background(DS.C.border).padding(.leading, DS.Space.md)
                    } else if UpdateChecker.isEnabled {
                        row(icon: "arrow.clockwise.circle", title: "Check for Updates",
                            subtitle: "Check GitHub for the latest release") {
                            Button(action: { Task { await appState.checkForAppUpdate() } }) {
                                Text("Check")
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 13)
                                    .frame(height: 26)
                                    .background(DS.C.surfaceHigh, in: Capsule())
                                    .foregroundStyle(DS.C.textSub)
                                    .overlay(Capsule().stroke(DS.C.border, lineWidth: 1))
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                        Divider().background(DS.C.border).padding(.leading, 36)
                    }

                    Button(action: { NSApplication.shared.terminate(nil) }) {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle").font(.system(size: 11))
                            Text("Quit QuotaWarmer").font(.system(size: 11))
                        }
                        .foregroundStyle(DS.C.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Space.md)
                        .padding(.vertical, DS.Space.md)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, DS.Page.bottom)
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        if let build = info?["CFBundleVersion"] as? String, build != version {
            return "\(version) (\(build))"
        }
        return version
    }

    // MARK: - History

    /// Collapsible list of the latest events (moved here from the overview so
    /// the main panel stays focused on the live quota windows).
    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { historyExpanded.toggle() }) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DS.C.textSub)
                        .frame(width: 20)
                    Text("Recent Events")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(DS.C.text)
                    Spacer()
                    Text("\(appState.history.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.C.textMuted)
                    Image(systemName: historyExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.C.textMuted)
                }
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.sm + 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text(historyExpanded ? "Collapse history" : "Expand history"))
            .accessibilityAddTraits(.isButton)

            if historyExpanded {
                Divider().background(DS.C.border).padding(.leading, 36)
                historyFilterBar
                let filtered = appState.history.filter { historyFilter.matches($0) }
                if filtered.isEmpty {
                    Text(appState.history.isEmpty ? "No events yet" : "No events match this filter")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.C.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Space.lg)
                } else {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(filtered.prefix(historyVisible)) { event in
                            HistoryRow(event: event)
                        }
                        if filtered.count > historyVisible {
                            Button("Show more (\(filtered.count - historyVisible) more)") { historyVisible += 25 }
                                .buttonStyle(.link)
                                .font(.system(size: 10))
                        }
                    }
                    .padding(.horizontal, DS.Space.md)
                    .padding(.vertical, DS.Space.sm + 2)
                }
                HStack(spacing: DS.Space.md) {
                    Button("Export Diagnostics…") { exportDiagnostics() }
                    Button("Report an Issue") {
                        if let url = DiagnosticsExport.issueURL() { NSWorkspace.shared.open(url) }
                    }
                    Spacer()
                }
                .buttonStyle(.link)
                .font(.system(size: 10))
                .padding(.horizontal, DS.Space.md)
                .padding(.bottom, DS.Space.sm + 2)
            }
        }
    }

    private var historyFilterBar: some View {
        HStack(spacing: DS.Space.sm) {
            Picker("Provider", selection: Binding(
                get: { historyFilter.providerKey ?? "" },
                set: { historyFilter.providerKey = $0.isEmpty ? nil : $0; historyVisible = 25 }
            )) {
                Text("All providers").tag("")
                ForEach(appState.providers, id: \.storageKey) { Text($0.displayName).tag($0.storageKey) }
            }
            Picker("Kind", selection: Binding(
                get: { historyFilter.group },
                set: { historyFilter.group = $0; historyVisible = 25 }
            )) {
                ForEach(EventFilter.Group.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
        .labelsHidden()
        .font(.system(size: 10))
        .padding(.horizontal, DS.Space.md)
        .padding(.top, DS.Space.sm)
    }

    private func exportDiagnostics() {
        let providers = appState.providers.map { provider -> (String, String) in
            let state = appState.state(for: provider)
            return (provider.storageKey, "\(state.mode.rawValue), pinned=\(state.menuBarVisible)")
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        Task { @MainActor in
            let events = await EventLogStore.shared.recent(limit: 500)
            let text = DiagnosticsExport.report(events: events, providers: providers)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "quotawarmer-diagnostics-\(stamp).txt"
            panel.allowedContentTypes = [.plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Layout helpers

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = String(localized: "Launch at Login could not be changed: \(error.localizedDescription)")
        }

        let actual = SMAppService.mainApp.status == .enabled
        UserDefaults.standard.set(actual, forKey: "launchAtLogin")
        if launchAtLogin != actual {
            launchAtLogin = actual
        }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: LocalizedStringKey, in groupPane: SettingsPane, @ViewBuilder content: () -> Content) -> some View {
        if groupPane == pane {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .dsSectionLabel()
                    .padding(.horizontal, DS.Page.side + 2)
                    .padding(.top, DS.Space.md)
                    .padding(.bottom, DS.Space.xs + 2)

                VStack(spacing: 0) {
                    content()
                }
                .dsCard()
                .padding(.horizontal, DS.Page.side)
            }
        }
    }

    private func row<Control: View>(
        icon: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.C.textSub)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.C.text)
                    .lineLimit(1)
                    .fixedSize()
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.C.textMuted)
            }
            Spacer()
            control()
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm - 1)
    }

    private func privacyLine(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.C.text)
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(DS.C.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Full-width, always-visible explanatory row for the HOW IT WORKS group.
    private func transparencyRow(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        privacyLine(title, detail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm + 2)
    }

    private func infoRow(title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(DS.C.textSub)
                .frame(width: 20)
                .help(detail)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.C.text)
            Spacer()
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm + 2)
    }

    /// Click-to-cycle used% threshold (50 → … → 95 → 50), matching the
    /// app's other cycle controls instead of a popup menu in the scaled panel.
    private func thresholdPill(_ value: Binding<Int>, enabled: Bool) -> some View {
        Button(action: { value.wrappedValue = QuotaAlertSettings.nextThreshold(after: value.wrappedValue) }) {
            Text("\(value.wrappedValue)%")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(DS.C.surfaceHigh, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(enabled ? DS.C.text : DS.C.textMuted)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled)
        .help("Click to change the threshold")
        .accessibilityLabel(Text("Alert at \(value.wrappedValue) percent used. Activate to change."))
    }

    /// System / Light / Dark. Applied immediately, app-wide.
    private var themePicker: some View {
        segmentedPicker(
            options: AppearanceMode.allCases.enumerated().map { (label: $1.label, value: $0) },
            selected: Binding(
                get: { AppearanceMode.allCases.firstIndex { $0.rawValue == appearanceRaw } ?? 0 },
                set: { appearanceRaw = AppearanceMode.allCases[$0].rawValue }
            )
        ) { AppearanceMode.stored().apply() }
        .accessibilityLabel(Text("Theme"))
    }

    private var menuBarStylePicker: some View {
        let styles = QuotaDisplay.MenuBarStyle.allCases
        return segmentedPicker(
            options: styles.enumerated().map { (label: $1.label, value: $0) },
            selected: Binding(
                get: { styles.firstIndex { $0.rawValue == menuBarStyleRaw } ?? 0 },
                set: { menuBarStyleRaw = styles[$0].rawValue }
            )
        )
        .accessibilityLabel(Text("Menu Bar"))
    }

    private var languagePicker: some View {
        segmentedPicker(
            options: AppLanguage.allCases.enumerated().map { (label: $1.label, value: $0) },
            selected: Binding(
                get: { AppLanguage.allCases.firstIndex(of: language) ?? 0 },
                set: { language = AppLanguage.allCases[$0] }
            )
        ) { language.store() }
        .accessibilityLabel(Text("Language"))
    }

    /// Starts a fresh copy once this one has quit (the language is read only
    /// at launch), then quits.
    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Fixed script; the pid and bundle path are passed as arguments, not
        // written into the shell source.
        task.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
            "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath
        ]
        do {
            try task.run()
            NSApplication.shared.terminate(nil)
        } catch {
            NSSound.beep()
        }
    }

    private func segmentedPicker(
        options: [(label: String, value: Int)],
        selected: Binding<Int>,
        onChange: @escaping () -> Void = {}
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { opt in
                let isSelected = selected.wrappedValue == opt.value
                Button(action: { selected.wrappedValue = opt.value; onChange() }) {
                    Text(opt.label)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(
                            isSelected ? DS.C.surface : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(isSelected ? DS.C.border : Color.clear, lineWidth: 1)
                        )
                        .foregroundStyle(isSelected ? DS.C.text : DS.C.textMuted)
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(2)
        .background(DS.C.surfaceHigh, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Hand-typed HH:mm field drawn with DS tokens so it matches both themes.
/// Commits on Return or when focus leaves; input is parsed by `TimeInput`
/// (`6`, `630`, `6:30`, `06.30` …). Invalid text is rejected and the field
/// snaps back to the last valid time, so a typo can never schedule a bogus wake.
struct WakeTimeField: View {
    @Binding var hour: Int
    @Binding var minute: Int
    let onChange: () -> Void

    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("HH:mm", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .foregroundStyle(DS.C.text)
            .focused($focused)
            .frame(width: 52, height: 26)
            .background(DS.C.surfaceHigh, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(invalid ? DS.C.red : (focused ? DS.C.blue.opacity(0.6) : DS.C.border), lineWidth: 1)
            )
            .onAppear { draft = TimeInput.text(hour: hour, minute: minute) }
            .onChange(of: hour) { _, _ in if !focused { resetDraft() } }
            .onChange(of: minute) { _, _ in if !focused { resetDraft() } }
            // Keep the red "rejected" border until the user types something new
            // (the snap-back to the valid time must not clear it).
            .onChange(of: draft) { _, text in
                if text != TimeInput.text(hour: hour, minute: minute) { invalid = false }
            }
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .help("Type a time, e.g. 06:00, 6:30 or 0715, then press Return.")
            .accessibilityLabel(Text("Wake time"))
    }

    private func commit() {
        guard let parsed = TimeInput.parse(draft) else {
            invalid = true
            resetDraft()
            return
        }
        let changed = parsed.hour != hour || parsed.minute != minute
        invalid = false
        hour = parsed.hour
        minute = parsed.minute
        resetDraft()
        if changed { onChange() }
    }

    private func resetDraft() {
        let text = TimeInput.text(hour: hour, minute: minute)
        if draft != text { draft = text }
    }
}
