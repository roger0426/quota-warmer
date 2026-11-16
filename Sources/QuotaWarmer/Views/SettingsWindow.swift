import SwiftUI
import AppKit

/// Pages of the standalone Settings window. Each `SettingsTabView` group is
/// tagged with exactly one page.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, accounts, alerts, morning, shortcuts, history, privacy, about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general:   return "General"
        case .accounts:  return "Accounts"
        case .alerts:    return "Alerts"
        case .morning:   return "Morning Pre-warm"
        case .shortcuts: return "Shortcuts"
        case .history:   return "Event History"
        case .privacy:   return "Privacy"
        case .about:     return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general:   return "gearshape"
        case .accounts:  return "person.2"
        case .alerts:    return "bell.badge"
        case .morning:   return "sunrise"
        case .shortcuts: return "command"
        case .history:   return "clock.arrow.circlepath"
        case .privacy:   return "hand.raised"
        case .about:     return "info.circle"
        }
    }
}

/// Sidebar + page layout, like System Settings / iStat Menus preferences.
struct SettingsWindowView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage(AppSettings.Key.settingsWindowPane) private var paneRaw = SettingsPane.general.rawValue

    private var pane: SettingsPane { SettingsPane(rawValue: paneRaw) ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(pane.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.C.text)
                    .padding(.horizontal, DS.Page.side + 2)
                    .padding(.top, DS.Space.md)
                SettingsTabView(pane: pane)
                    // Reset per-page @State (e.g. history paging) on switch.
                    .id(pane)
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 620, minHeight: 460)
        .background(DS.C.bg)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { item in
                Button { paneRaw = item.rawValue } label: {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12.5, weight: .medium))
                            .frame(width: 20)
                            .foregroundStyle(item == pane ? DS.C.blue : DS.C.textSub)
                        Text(item.title)
                            .font(.system(size: 12, weight: item == pane ? .semibold : .regular))
                            .foregroundStyle(DS.C.text)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Space.sm)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: DS.R.md, style: .continuous)
                            .fill(item == pane ? DS.C.selection : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.top, 34)   // clear the transparent title bar's traffic lights
        .padding(.bottom, DS.Space.md)
        .frame(width: 184)
        .frame(maxHeight: .infinity)
        .background(DS.C.sidebar)
    }
}

/// Owns the one Settings window. A normal titled window: it does not close
/// when it loses focus (unlike the menu-bar panel).
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // An LSUIElement app has to activate itself, or the window opens
        // behind whatever app is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsWindowView().environmentObject(appState))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = String(localized: "QuotaWarmer Settings")
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 680, height: 560))
        window.setFrameAutosaveName("QuotaWarmerSettingsWindow")
        if window.frame.origin == .zero { window.center() }
        return window
    }
}
