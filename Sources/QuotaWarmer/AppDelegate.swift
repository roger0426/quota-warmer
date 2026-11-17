import AppKit
import Combine
import Combine
import SwiftUI

/// Owns the menu-bar status item. We use an AppKit `NSStatusItem` (rather than a
/// SwiftUI `MenuBarExtra`) so the icon supports both a left-click panel and a
/// right-click menu. Left-click toggles a borderless panel hosting `MenuContent`;
/// right-click (or control-click) shows the actions menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState

    private var statusItem: NSStatusItem!
    private var panel: NSPanel?
    private lazy var settingsWindow = SettingsWindowController(appState: appState)
    private var heightObserver: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private var lastCloseAt: Date = .distantPast

    override init() {
        // Before AppState reads any setting: bring over upstream's settings and data once.
        LegacyDataMigration.runAtLaunch()
        appState = AppState()
        super.init()
        IntegrationBridge.appState = appState
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.requestPermission()
        AppearanceMode.stored().apply()
        _ = AppLanguage.atLaunch  // pin the launch language before Settings can change it

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.toolTip = String(localized: "QuotaWarmer — left-click for stats, right-click for menu")
        }
        statusItem = item
        refreshButtonImage()

        // AppState's 1 s UI timer + quota updates poke objectWillChange; mirror
        // that into the status-item image so the countdowns tick.
        appState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshButtonImage() }
            .store(in: &cancellables)
        appState.onUITick = { [weak self] in self?.refreshButtonImage() }
        appState.onOpenSettings = { [weak self] in self?.showSettingsWindow() }
        appState.onShowPanel = { [weak self] in self?.showPanelIfHidden() }

        GlobalHotKey.shared.onPress = { [weak self] in self?.togglePanelFromHotKey() }
        GlobalHotKey.shared.reload()
    }

    // MARK: - Integrations

    /// `quotawarmer://` links (see `IntegrationURLHandler`: read/open/refresh only).
    func application(_ application: NSApplication, open urls: [URL]) {
        IntegrationURLHandler.handle(urls, appState: appState) { [weak self] tab in
            if tab == .settings {
                self?.showSettingsWindow()
                return
            }
            if let tab { self?.appState.selectedTab = tab }
            self?.showPanelIfHidden()
        }
    }

    private func togglePanelFromHotKey() {
        if panel?.isVisible == true {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanelIfHidden() {
        if panel?.isVisible != true { showPanel() }
    }

    private var lastImageKey: String?
    /// ~12 fps redraw while a menu-bar bar fades (the 1 s tick is too coarse).
    private var glowTimer: Timer?

    /// Called every second and on every state change; rebuilds and reassigns the
    /// status-item image only when what it shows changed (about once a minute).
    private func refreshButtonImage() {
        updateGlowTimer()
        let key = MenuBarStatus.contentKey(for: appState)
        guard key != lastImageKey else { return }
        lastImageKey = key
        statusItem?.button?.image = MenuBarStatus.image(for: appState)
        statusItem?.button?.setAccessibilityLabel(MenuBarStatus.accessibilityLabel(for: appState))
    }

    private func updateGlowTimer() {
        let needed = MenuBarStatus.needsGlowAnimation(for: appState)
        if needed, glowTimer == nil {
            glowTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshButtonImage() }
            }
        } else if !needed, let timer = glowTimer {
            timer.invalidate()
            glowTimer = nil
        }
    }

    // MARK: - Click routing

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isRightClick {
            closePanel()
            showMenu()
        } else {
            togglePanel()
        }
    }

    // MARK: - Panel (left click)

    private func togglePanel() {
        if panel?.isVisible == true {
            closePanel()
        } else if Date().timeIntervalSince(lastCloseAt) >= 0.25 {
            // Guard against immediately reopening when the very click we're
            // handling just dismissed a key panel via windowDidResignKey.
            showPanel()
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let hosting = NSHostingView(rootView: MenuContent().environmentObject(appState))
        hosting.setFrameSize(hosting.fittingSize)
        let created = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.contentView = hosting
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.level = .popUpMenu
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.hidesOnDeactivate = false
        created.delegate = self
        // No system window animation: the panel opens with a short fade of
        // its own (see `showPanel`) and closes at once, like iStat Menus.
        created.animationBehavior = .none
        panel = created
        // Follow the content height (resets gained/used, tab switches) while open,
        // keeping the top edge pinned under the menu bar item.
        heightObserver = appState.$panelContentHeight
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.fitPanelToContent() }
        return created
    }

    private func fitPanelToContent() {
        guard let panel, panel.isVisible, let hosting = panel.contentView else { return }
        let newSize = hosting.fittingSize
        guard abs(newSize.height - panel.frame.height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - newSize.height
        frame.size = newSize
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func showPanel() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let panel = ensurePanel()
        if let hosting = panel.contentView { panel.setContentSize(hosting.fittingSize) }

        let size = panel.frame.size
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        // Left edges line up with the menu-bar item, like iStat Menus dropdowns.
        var origin = NSPoint(x: buttonRect.minX, y: buttonRect.minY - size.height - 2)
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - size.width - 6)
        }
        panel.setFrameOrigin(origin)
        appState.isPanelVisible = true
        // Countdowns were not ticking while hidden; refresh before showing.
        appState.objectWillChange.send()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.08
                panel.animator().alphaValue = 1
            }
        }
        // The native shadow is traced from the content's alpha; recompute it so
        // it follows the rounded panel instead of a stale rectangular outline.
        panel.invalidateShadow()
    }

    private func closePanel() {
        guard let panel, panel.isVisible else { return }
        HoverDetailPresenter.shared.hide()
        panel.orderOut(nil)
        appState.isPanelVisible = false
        lastCloseAt = Date()
    }

    // MARK: - Menu (right click)

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        menu.addItem(makeItem(String(localized: "Show Stats"), #selector(showStats)))
        menu.addItem(makeItem(String(localized: "Go to Settings"), #selector(goToSettings)))

        let debug = NSMenuItem(title: String(localized: "Debug Level"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for level in DebugLevel.allCases {
            let entry = makeItem(level.title, #selector(setDebugLevel(_:)))
            entry.state = (DebugLevel.current == level) ? .on : .off
            entry.representedObject = level.rawValue
            submenu.addItem(entry)
        }
        debug.submenu = submenu
        menu.addItem(debug)

        menu.addItem(.separator())
        menu.addItem(makeItem(String(localized: "About QuotaWarmer"), #selector(showAbout)))
        menu.addItem(makeItem(String(localized: "Quit"), #selector(quit), key: "q"))

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showStats() {
        appState.selectedTab = .main
        showPanel()
    }

    @objc private func goToSettings() {
        showSettingsWindow()
    }

    private func showSettingsWindow() {
        closePanel()
        settingsWindow.show()
    }

    @objc private func setDebugLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let level = DebugLevel(rawValue: raw) else { return }
        DebugLevel.current = level
        DiagnosticLogger.append("debug_level_changed level=\(level.title.lowercased())")
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        // Only the menu-bar panel uses this delegate; the Settings window
        // stays open when it loses focus.
        guard (notification.object as? NSWindow) === panel else { return }
        closePanel()
    }
}

/// Borderless panel that can still become key so the hosted SwiftUI controls
/// (buttons, steppers, fields) stay interactive.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
