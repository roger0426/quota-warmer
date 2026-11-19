import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}

extension Color {
    /// Hex literal initializer, e.g. `Color(hex: 0xF8FAFC)`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }

    /// Appearance-aware color: resolved against the view's effective
    /// appearance at draw time, so it follows the app theme (System / Light /
    /// Dark, see `AppearanceMode`) and live system switches with no re-layout.
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

/// Design tokens. Tuned to the iStat Menus dropdown language: the panel is a
/// vibrant translucent material (see `VibrancyBackground`), surfaces are faint
/// tints over it rather than opaque cards, borders are hairlines, and text
/// uses system-like label / secondary / tertiary greys. Every token has a dark
/// twin so both themes read the same.
enum DS {
    enum C {
        // Surfaces — tints laid over the vibrant panel material.
        static let bg          = Color(light: 0xF5F5F7, dark: 0x1E1F23, lightAlpha: 0.55, darkAlpha: 0.55)   // content base
        static let sidebar     = Color(light: 0x000000, dark: 0x000000, lightAlpha: 0.035, darkAlpha: 0.22)  // narrow left rail
        static let surface     = Color(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.66, darkAlpha: 0.075)  // grouped sections (iStat-style cards)
        static let surfaceHigh = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.055, darkAlpha: 0.09)  // quiet button / segmented fill
        static let track       = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.11)   // gauge track (no data)
        static let ink         = Color(light: 0x0F172A, dark: 0xF1F3F6)   // selected indicator
        /// Opaque text on an `ink` fill (selected chips, prominent buttons).
        static let onInk       = Color(light: 0xFFFFFF, dark: 0x1C1D21)
        /// Selected rail slot / segmented choice.
        static let selection   = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.13)
        /// Label on a filled accent/danger surface (Warm, prominent buttons).
        /// White reads only 2.9:1 on the muted dark accents, so dark text is used there.
        static let onAccent    = Color(light: 0xFFFFFF, dark: 0x101216)
        /// Pace knob: stays bright on any bar color in both themes.
        static let knob        = Color(light: 0xFFFFFF, dark: 0xE8EAEE)
        /// Outline that keeps the white knob / time-marker dot visible on a
        /// light background or a pale track (light theme), and separated from
        /// the fill in dark theme.
        /// Hover hint bubble: an opaque raised fill, a step off the panel
        /// tint so the hint never blends into the background.
        static let hintFill    = Color(light: 0xFFFFFF, dark: 0x3A3E47)
        static let hintBorder  = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.18, darkAlpha: 0.16)
        static let knobStroke  = Color(light: 0x0F172A, dark: 0x000000, lightAlpha: 0.55, darkAlpha: 0.45)

        // Borders
        static let border      = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.11, darkAlpha: 0.11)   // hairline section / divider border
        static let borderSoft  = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.06)   // very subtle inner divider
        static let borderFocus = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.22)

        // Text
        // iStat Menus–style: text is white (black in light) for contrast;
        // secondary information is set apart by a smaller size or lighter
        // weight, not by grey. Only `textMuted` keeps a slight dim, for
        // footnotes and placeholders.
        static let text        = Color(light: 0x0F172A, dark: 0xF5F6F8)   // titles and values
        static let textSub     = Color(light: 0x0F172A, dark: 0xF5F6F8)   // body: same ink as text
        static let textMuted   = Color(light: 0x2B3443, dark: 0xD6DAE0)   // meta: barely dimmed

        // Status — used as text and as dots. Every value is >= 4.5:1 on the
        // card surfaces in its theme (WCAG AA text); status is also conveyed by
        // a label or symbol, never by color alone.
        static let green  = Color(light: 0x11813A, dark: 0x53A96A)
        static let yellow = Color(light: 0xA95D05, dark: 0xCA8B3A)
        static let red    = Color(light: 0xD92525, dark: 0xD5817E)
        static let blue   = Color(light: 0x2563EB, dark: 0x709AD0)

        // Usage bars and rings, iStat Menus–style: blue below the warning
        // level, pink-red at or above it. Only the graphics carry colour;
        // numbers and labels stay plain text.
        // Each fill keeps >= 3:1 against its own track (WCAG 1.4.11).
        static let usageBlue   = Color(light: 0x2F7DEB, dark: 0x4A8CF0)   // iStat Menus–style blue
        static let usageRed    = Color(light: 0xD8365A, dark: 0xF0506E)   // iStat Menus–style pink-red
        /// "Use it or lose it": the unused part of a weekly bar that resets
        /// soon with much still left (see `UnusedQuotaRule`).
        static let unusedYellow = Color(light: 0xE0A100, dark: 0xF5C542)
        /// Warning text on cards (unpriced models): ≥ 4.5:1 on the card in
        /// both themes; always paired with a ⚠ so it is not color-only.
        static let costWarn = Color(light: 0xA95D05, dark: 0xF5C542)
        /// Colored track tint behind a usage bar (a touch lighter in dark).
        static let usageTrackOpacity: Double = 0.16
        /// Single-color bar used when Colorful Quota Bars is off: the original
        /// near-black in light, a soft gray (not glaring white) in dark.
        static let barPlain    = Color(light: 0x0F172A, dark: 0xA9AFBA)

        static func usage(_ level: QuotaUsageLevel) -> Color {
            switch level {
            case .normal:   return usageBlue
            case .critical: return usageRed
            }
        }

        /// Per-tool brand accent. Dark variants are muted like the status colors;
        /// Codex indigo is lifted so the pin stays legible on graphite.
        static func accent(_ tool: ProviderID) -> Color { accent(tool.kind) }

        static func accent(_ tool: ToolID) -> Color {
            tool == .claude ? claudeAccent : codexAccent
        }
        /// Busy hours used by both Claude and Codex: between the two accents.
        static let bothAccent = Color(light: 0xC2408A, dark: 0xC583AB)

        /// History tab: one fixed color per tool across every chart — Claude
        /// orange, Codex blue — so a series is recognisable at a glance and
        /// never reads as a usage level.
        static func history(_ tool: ToolID) -> Color {
            tool == .claude ? claudeAccent : historyCodex
        }
        /// History busy hours shared by both tools: between orange and blue.
        static let historyBoth = Color(light: 0x8B5CC7, dark: 0x8E72C4)
        private static let historyCodex = Color(light: 0x2C84DB, dark: 0x4A86CC)
        private static let claudeAccent = Color(light: 0xBA4F0B, dark: 0xD48554)   // Anthropic orange
        private static let codexAccent  = Color(light: 0x613DE6, dark: 0x9C8EDB)   // OpenAI indigo
    }

    // MARK: - Spacing
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    // MARK: - Radii
    enum R {
        static let sm: CGFloat = 5    // badges / small chips / graph wells
        static let md: CGFloat = 7    // buttons / inputs
        static let lg: CGFloat = 9    // grouped sections
        static let xl: CGFloat = 12   // outer panel
    }

    // MARK: - Layout
    // The panel is laid out at totalWidth × totalHeight then uniformly
    // scaled by panelScale, so this knob shrinks the whole UI proportionally
    // without any reflow. At 1.0 the type is drawn at its nominal size: body
    // text 11–12 pt and labels 10 pt, the range macOS uses for menu-bar panels
    // (system font 13 pt, small 11 pt). The earlier 0.81 drew 10 pt labels at 8 pt.
    static let panelScale: CGFloat = 1.0
    static let contentWidth: CGFloat = 372
    static let totalWidth:   CGFloat = contentWidth
    /// Tab bar along the top edge of the panel (Overview, History, Settings).
    static let tabBarHeight: CGFloat = 40
    // The panel height on every tab. History and Settings scroll inside it;
    // the overview and tool tabs do not scroll, so they report their content
    // height (see `PanelHeightKey`) and the panel grows only when that content
    // would not fit.
    static let totalHeight: CGFloat = 462

    // MARK: - Page layout
    // Shared by every tab so the title, cards and edges line up when switching.
    enum Page {
        static let top: CGFloat = 12          // content top inset
        static let side: CGFloat = 10         // content left/right inset
        static let bottom: CGFloat = 10       // content bottom inset
        static let spacing: CGFloat = 10      // gap between header / cards
        static let headerHeight: CGFloat = 28
        static let titleSize: CGFloat = 15
        static let cardPadding: CGFloat = 12  // inner padding of content cards
    }

    // MARK: - Typography
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - View modifiers

extension View {
    /// Grouped section: a faint tint over the panel material with a hairline border.
    func dsCard(radius: CGFloat = DS.R.lg) -> some View {
        self
            .background(DS.C.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(DS.C.border, lineWidth: 1))
    }

    /// Uppercase, letter-spaced section label (e.g. "WINDOW STATUS").
    func dsSectionLabel() -> some View {
        self.font(.system(size: 10, weight: .bold))
            .foregroundStyle(DS.C.textSub)
            .tracking(0.7)
            .textCase(.uppercase)
    }
}


/// Natural height of a tab's content, reported up so the panel can size to it —
/// no dead space with no banked resets, no clipping with several.
struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    func reportsPanelHeight() -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
        })
    }
}
