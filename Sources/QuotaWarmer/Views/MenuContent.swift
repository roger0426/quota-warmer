import SwiftUI
import AppKit

// Makes the hosting NSWindow transparent so our rounded corners don't bleed.
private struct WindowTransparencyConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension AppearanceMode {
    /// Applies the theme app-wide. `nil` hands control back to macOS, so the
    /// panel follows System Settings — including live light/dark switches.
    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum AppTab: Hashable {
    case main
    case history
    case settings
}

struct MenuContent: View {
    @EnvironmentObject var appState: AppState

    /// The overview fits its content; other tabs share `DS.totalHeight` as a
    /// floor and grow only when their content would not fit.
    private var panelHeight: CGFloat {
        let overview = appState.selectedTab == .main && !appState.showWelcomeGuide
        return AppState.panelHeight(forMeasured: appState.panelContentHeight, fitsContent: overview)
    }

    var body: some View {
        panel
            .frame(width: DS.totalWidth, height: panelHeight)
            .scaleEffect(DS.panelScale, anchor: .topLeading)
            .frame(
                width: DS.totalWidth * DS.panelScale,
                height: panelHeight * DS.panelScale,
                alignment: .topLeading
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.R.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.R.xl, style: .continuous)
                    .strokeBorder(DS.C.border, lineWidth: 0.5)
            )
            .padding(2)
            .background(WindowTransparencyConfigurator())
            .onPreferenceChange(PanelHeightKey.self) { appState.panelContentHeight = $0 }
    }

    private var panel: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(DS.C.border)
                .frame(width: 0.5)
            mainContent
        }
        // iStat Menus–style: the translucent menu material, lightly tinted.
        .background(DS.C.bg)
        .background(VibrancyBackground(material: .popover))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 6) {
            SidebarSlot(isSelected: appState.selectedTab == .main, help: "Overview", shortcut: "1") {
                appState.selectedTab = .main
            } icon: {
                Image(systemName: appState.selectedTab == .main ? "house.fill" : "house")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(appState.selectedTab == .main ? DS.C.ink : DS.C.textSub)
            }

            Spacer()

            SidebarSlot(isSelected: appState.selectedTab == .history, help: "History", shortcut: "2") {
                appState.selectedTab = .history
            } icon: {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(appState.selectedTab == .history ? DS.C.ink : DS.C.textSub)
            }

            SidebarSlot(isSelected: appState.selectedTab == .settings, help: "Settings", shortcut: "3") {
                appState.selectedTab = .settings
            } icon: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(appState.selectedTab == .settings ? DS.C.ink : DS.C.textSub)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(width: DS.sidebarWidth)
        .background(DS.C.sidebar)
        // Opening the panel puts keyboard focus on the first slot (Home); the
        // selected slot already has its own highlight, so the system's blue
        // focus ring is not drawn here. Tab and ⌘1–3 still work.
        .focusEffectDisabled()
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if appState.showWelcomeGuide {
            WelcomeGuideView()
                .frame(width: DS.contentWidth)
                .frame(maxHeight: .infinity)
        } else {
            tabContent
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch appState.selectedTab {
        case .main:
            MainTabView()
                .frame(width: DS.contentWidth)
                .frame(maxHeight: .infinity)
        case .history:
            HistoryTabView()
                .frame(width: DS.contentWidth)
                .frame(maxHeight: .infinity)
        case .settings:
            SettingsTabView()
                .frame(width: DS.contentWidth)
                .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Sidebar items

/// One icon slot in the narrow left rail. Selected state is a soft filled
/// rounded highlight, like the selected pane in iStat Menus; hover gives a
/// fainter one. Holds any icon (SF Symbol or template provider glyph).
struct SidebarSlot<Icon: View>: View {
    let isSelected: Bool
    let help: LocalizedStringKey
    /// Optional ⌘-number key that selects this slot while the panel is focused.
    var shortcut: KeyEquivalent? = nil
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            icon()
                .frame(width: 36, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: DS.R.md, style: .continuous)
                        .fill(highlight)
                )
                .frame(width: DS.sidebarWidth, height: 36)
        }
        .buttonStyle(PressableButtonStyle())
        .modifier(OptionalKeyboardShortcut(key: shortcut))
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }

    private var highlight: Color {
        if isSelected { return DS.C.selection }
        if hovering { return DS.C.surfaceHigh }
        return .clear
    }
}

/// Initial of an added account, shown on its provider glyph so two Claude (or
/// Codex) accounts can be told apart at a glance.
struct AccountBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .heavy, design: .rounded))
            .foregroundStyle(DS.C.onAccent)
            .frame(minWidth: 12, minHeight: 12)
            .background(color, in: Circle())
            .overlay(Circle().stroke(DS.C.sidebar, lineWidth: 1.5))
    }
}
