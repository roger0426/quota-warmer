import AppIntents
import SwiftUI
import WidgetKit

// The widget is a separate, sandboxed process. It shows what the app last
// wrote to `~/Library/Application Support/io.github.roger0426.quotawarmer/status.json` (see
// `QuotaStatusFile` in the app) and does nothing else: no network, no
// credentials, no CLI. Its only entitlement beyond the sandbox is read-only
// access to that folder.

// MARK: - Status file (the fields the widget shows)

struct WidgetStatusFile: Decodable {
    /// Settings → Warning At; absent in files from older app versions.
    var warningPercent: Int? = nil
    let providers: [WidgetProvider]
}

/// What the widget draws from one read of the status file.
struct WidgetStatus {
    var providers: [WidgetProvider] = []
    var warningPercent: Int = RingValue.defaultWarningPercent
}

struct WidgetProvider: Decodable, Identifiable {
    let id: String
    let tool: String
    /// `default` for the CLI's built-in account.
    let account: String
    let name: String
    let mode: String
    let displayMode: String
    let fetchedAt: Date?
    let session: WidgetWindow?
    let weekly: WidgetWindow?
}

struct WidgetWindow: Decodable {
    let usedPercent: Int
    let remainingPercent: Int
    let resetAt: Date?
    /// Not started yet: there is no running window to place a time marker in.
    let idle: Bool
    let settling: Bool
}

enum WidgetStatusReader {
    /// The user's real home directory. Inside the sandbox `NSHomeDirectory()`
    /// is the widget's container, so the path comes from the password database.
    static var statusURL: URL {
        let home: String
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/io.github.roger0426.quotawarmer/status.json")
    }

    static func read() -> WidgetStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: statusURL),
              let file = try? decoder.decode(WidgetStatusFile.self, from: data) else { return WidgetStatus() }
        return WidgetStatus(
            providers: file.providers.filter { $0.mode != "off" },
            warningPercent: file.warningPercent ?? RingValue.defaultWarningPercent
        )
    }
}

// MARK: - Configuration (Edit Widget)

/// Number under each ring (medium widget only).
enum WidgetNumber: String, AppEnum {
    case used, remaining, off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Number"
    static let caseDisplayRepresentations: [WidgetNumber: DisplayRepresentation] = [
        .used: "Used",
        .remaining: "Remaining",
        .off: "Off",
    ]
}

/// Which quota window the thick outer ring shows; the other goes inside.
enum WidgetOuterRing: String, AppEnum {
    case session, weekly

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Outer Ring"
    static let caseDisplayRepresentations: [WidgetOuterRing: DisplayRepresentation] = [
        .session: "5-hour",
        .weekly: "Weekly",
    ]
}

struct QuotaWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Quota"
    static let description = IntentDescription("Choose the number, which window is the outer ring, and the time marker.")

    @Parameter(title: "Number", default: .used)
    var number: WidgetNumber

    @Parameter(title: "Outer Ring", default: .session)
    var outerRing: WidgetOuterRing

    @Parameter(title: "Time Marker", default: true)
    var timeMarker: Bool

    init() {}
}

// MARK: - Timeline

struct QuotaEntry: TimelineEntry {
    let date: Date
    let providers: [WidgetProvider]
    let warningPercent: Int
    let configuration: QuotaWidgetIntent
}

struct QuotaTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(date: Date(), providers: Self.sample, warningPercent: RingValue.defaultWarningPercent,
                   configuration: QuotaWidgetIntent())
    }

    func snapshot(for configuration: QuotaWidgetIntent, in context: Context) async -> QuotaEntry {
        let file = WidgetStatusReader.read()
        let providers = file.providers.isEmpty && context.isPreview ? Self.sample : file.providers
        return QuotaEntry(date: Date(), providers: providers, warningPercent: file.warningPercent,
                          configuration: configuration)
    }

    func timeline(for configuration: QuotaWidgetIntent, in context: Context) async -> Timeline<QuotaEntry> {
        // The app asks WidgetKit to reload when a reading changes. Between
        // reloads the same reading is re-drawn every 10 minutes so the time
        // marker keeps moving and a reading that stopped updating turns dim.
        let now = Date()
        let file = WidgetStatusReader.read()
        let entries = (0..<12).map { step in
            QuotaEntry(date: now.addingTimeInterval(Double(step) * 600), providers: file.providers,
                       warningPercent: file.warningPercent, configuration: configuration)
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(12 * 600)))
    }

    static let sample: [WidgetProvider] = [
        WidgetProvider(
            id: "claude", tool: "claude", account: "default", name: "Claude", mode: "monitor", displayMode: "used",
            fetchedAt: Date(),
            session: WidgetWindow(usedPercent: 35, remainingPercent: 65, resetAt: Date().addingTimeInterval(3 * 3600), idle: false, settling: false),
            weekly: WidgetWindow(usedPercent: 20, remainingPercent: 80, resetAt: Date().addingTimeInterval(4 * 86400), idle: false, settling: false)
        ),
        WidgetProvider(
            id: "codex", tool: "codex", account: "default", name: "Codex", mode: "monitor", displayMode: "used",
            fetchedAt: Date(),
            session: WidgetWindow(usedPercent: 85, remainingPercent: 15, resetAt: Date().addingTimeInterval(3600), idle: false, settling: false),
            weekly: WidgetWindow(usedPercent: 40, remainingPercent: 60, resetAt: Date().addingTimeInterval(2 * 86400), idle: false, settling: false)
        )
    ]
}

// MARK: - Ring values

/// One ring: how much of a quota window is used, and how far through the
/// window the clock is.
struct RingValue {
    /// Used percent; nil when there is no usable reading.
    let used: Int?
    /// 0…1 of the window's time that has passed; nil when it is not running.
    let elapsed: Double?
    /// Fill with what is left (like a battery) instead of what is used.
    let showsRemaining: Bool
    /// Used percent at which the ring turns red (Settings → Warning At).
    let warningPercent: Int

    /// Matches the app's default warning level.
    static let defaultWarningPercent = 80

    init(window: WidgetWindow?, duration: TimeInterval, now: Date, showsRemaining: Bool, warningPercent: Int) {
        self.showsRemaining = showsRemaining
        self.warningPercent = warningPercent
        guard let window, !window.settling else {
            used = nil
            elapsed = nil
            return
        }
        used = min(max(window.usedPercent, 0), 100)
        if !window.idle, let resetAt = window.resetAt, resetAt > now {
            elapsed = min(max(1 - resetAt.timeIntervalSince(now) / duration, 0), 1)
        } else {
            elapsed = nil
        }
    }

    /// The percent the widget shows: used, or what is left.
    var shown: Int? { used.map { showsRemaining ? 100 - $0 : $0 } }

    /// Ring fill, 0…1.
    var fraction: Double { Double(shown ?? 0) / 100 }

    /// Two levels, like the app's bars: blue below the warning level, red at
    /// or above it.
    var color: Color {
        guard let used else { return .secondary }
        return used >= warningPercent ? .red : .blue
    }
}

private let sessionDuration: TimeInterval = 5 * 3600
private let weeklyDuration: TimeInterval = 7 * 86400

// MARK: - Views

/// Sizes for a ring drawn in a `size` × `size` square.
struct RingMetrics {
    let line: CGFloat
    let innerLine: CGFloat
    let diameter: CGFloat
    let innerDiameter: CGFloat
    let glyph: CGFloat

    init(size: CGFloat) {
        // Batteries widget: the ring is about a tenth of its diameter.
        line = max(3, size * 0.105)
        diameter = size - line
        innerLine = max(2, line * 0.45)
        innerDiameter = diameter - line - innerLine * 1.6
        glyph = max(10, (innerDiameter - innerLine) * 0.46)
    }
}

/// Batteries-style gauge for one account: a thick outer ring and a thin
/// inner ring (5-hour and weekly, in the configured order) around the
/// provider glyph. A white dot on the outer ring marks how far through that
/// window the clock is.
struct QuotaRing: View {
    let provider: WidgetProvider
    let outer: RingValue
    let inner: RingValue
    let showsMarker: Bool
    let now: Date

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let m = RingMetrics(size: min(geo.size.width, geo.size.height))
            ZStack {
                ring(outer, line: m.line, diameter: m.diameter)
                if showsMarker, let elapsed = outer.elapsed {
                    let angle = (elapsed * 360 - 90) * .pi / 180
                    let dot = m.line * 0.64
                    // White dot; on a light widget a darker outline and a
                    // soft shadow keep it visible over the pale track.
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(Color.black.opacity(colorScheme == .light ? 0.5 : 0.35),
                                                       lineWidth: colorScheme == .light ? 1 : 0.75))
                        .shadow(color: .black.opacity(colorScheme == .light ? 0.35 : 0.25), radius: 1, y: 0.5)
                        .frame(width: dot, height: dot)
                        .offset(x: m.diameter / 2 * cos(angle), y: m.diameter / 2 * sin(angle))
                }
                ring(inner, line: m.innerLine, diameter: m.innerDiameter)
                glyph(size: m.glyph)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func ring(_ value: RingValue, line: CGFloat, diameter: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: line)
            if value.fraction > 0 {
                Circle()
                    .trim(from: 0, to: value.fraction)
                    .stroke(value.color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // In tinted / clear widgets the fill takes the accent tint.
                    .widgetAccentable()
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// The provider glyph with a status badge in its corner: the status
    /// colour, with an added account's initial in it (a smaller plain dot for
    /// the default account). Same proportions as the menu bar: the badge
    /// shares one centre either way, and a transparent gap is cut into the
    /// logo around it instead of an outline.
    private func glyph(size: CGFloat) -> some View {
        let status = provider.statusColor(at: now)
        let badge = provider.badge
        let diameter = size * (badge == nil ? 0.37 : 0.53)
        let gap = max(1, size * 0.067)
        let center = CGPoint(x: size * 0.87, y: size * 0.83)
        return ZStack(alignment: .topLeading) {
            Image(provider.tool == "claude" ? "ClaudeCode" : "Codex")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .mask {
                    Rectangle()
                        .overlay {
                            Circle()
                                .frame(width: diameter + 2 * gap, height: diameter + 2 * gap)
                                .position(center)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
            Circle()
                .fill(status)
                .frame(width: diameter, height: diameter)
                .position(center)
            if let badge {
                Text(verbatim: badge)
                    .font(.system(size: diameter * 0.75, weight: .bold, design: .rounded))
                    .foregroundStyle(status == .yellow ? Color.black : Color.white)
                    .position(center)
            }
        }
        .frame(width: size, height: size)
    }
}

extension WidgetProvider {
    /// Initial of an added account ("Claude · Work" → "W"); nil for the default.
    var badge: String? {
        guard account != "default" else { return nil }
        let label = name.components(separatedBy: " · ").last ?? name
        return label.first.map { String($0).uppercased() }
    }

    /// Badge colour: blue monitoring, green auto-warm while the reading is
    /// fresh; yellow once it is stale. (The status file carries no sign-in
    /// health, so the widget has no red.)
    func statusColor(at now: Date) -> Color {
        if isStale(at: now) { return .yellow }
        return mode == "autoWarm" ? .green : .blue
    }

    /// Reading older than 30 minutes (the app's "expired" threshold).
    func isStale(at now: Date) -> Bool {
        fetchedAt.map { now.timeIntervalSince($0) > 30 * 60 } ?? true
    }
}

/// Number under a ring, like the Batteries widget: semibold value, smaller
/// "%". Plain text colour; only the ring carries blue / red.
private func percentLabel(_ value: String, unit: Bool = true) -> some View {
    (Text(verbatim: value).font(.system(size: 15, weight: .semibold, design: .rounded))
        + Text(verbatim: unit ? "%" : "").font(.system(size: 11, weight: .semibold, design: .rounded)))
        .monospacedDigit()
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
}

/// One account: two rings, plus the outer ring's number when shown.
struct QuotaCell: View {
    let provider: WidgetProvider
    let now: Date
    let warningPercent: Int
    let configuration: QuotaWidgetIntent
    let showsNumber: Bool

    var body: some View {
        let remaining = configuration.number == .remaining
        let session = RingValue(window: provider.session, duration: sessionDuration, now: now,
                                showsRemaining: remaining, warningPercent: warningPercent)
        let weekly = RingValue(window: provider.weekly, duration: weeklyDuration, now: now,
                               showsRemaining: remaining, warningPercent: warningPercent)
        let weeklyOuter = configuration.outerRing == .weekly
        let outer = weeklyOuter ? weekly : session
        let verb = remaining ? "left" : "used"
        let sessionText = session.shown.map { "\($0)%" } ?? "–"
        let weeklyText = weekly.shown.map { "\($0)%" } ?? "–"
        VStack(spacing: 4) {
            QuotaRing(provider: provider, outer: outer, inner: weeklyOuter ? session : weekly,
                      showsMarker: configuration.timeMarker, now: now)
            if showsNumber {
                percentLabel(outer.shown.map(String.init) ?? "–", unit: outer.shown != nil)
            }
        }
        .opacity(provider.isStale(at: now) ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(provider.name): session \(sessionText) \(verb), week \(weeklyText) \(verb)"))
    }
}

/// Empty slot: a grey ring only, as the Batteries widget draws an unused one.
struct EmptyGauge: View {
    let showsNumber: Bool

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let m = RingMetrics(size: min(geo.size.width, geo.size.height))
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: m.line)
                    .frame(width: m.diameter, height: m.diameter)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .aspectRatio(1, contentMode: .fit)
            // Keeps the ring the same size as a filled slot's.
            if showsNumber { percentLabel("–").hidden() }
        }
        .accessibilityHidden(true)
    }
}

struct QuotaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    /// Small widget: rings only, like Batteries. Medium: numbers unless Off.
    private var showsNumber: Bool {
        family == .systemMedium && entry.configuration.number != .off
    }

    var body: some View {
        Group {
            if entry.providers.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 20))
                    Text("Open QuotaWarmer")
                        .font(.system(size: 11, weight: .medium))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            } else if family == .systemMedium {
                // One row of four slots.
                HStack(spacing: 16) {
                    ForEach(0..<4, id: \.self) { index in slot(index) }
                }
            } else {
                // 2 × 2 rings filling the tile.
                VStack(spacing: 10) {
                    HStack(spacing: 10) { slot(0); slot(1) }
                    HStack(spacing: 10) { slot(2); slot(3) }
                }
            }
        }
        // The system's widget background: on macOS 26 it renders as the
        // translucent glass the Batteries widget uses.
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private func slot(_ index: Int) -> some View {
        if index < entry.providers.count {
            QuotaCell(provider: entry.providers[index], now: entry.date, warningPercent: entry.warningPercent,
                      configuration: entry.configuration, showsNumber: showsNumber)
        } else {
            EmptyGauge(showsNumber: showsNumber)
        }
    }
}

// MARK: - Widget

@main
struct QuotaWarmerWidget: Widget {
    static let kind = "io.github.roger0426.quotawarmer.widget.quota"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: QuotaWidgetIntent.self, provider: QuotaTimelineProvider()) { entry in
            QuotaWidgetView(entry: entry)
        }
        .configurationDisplayName("Quota")
        .description("Quota per account: a thick outer ring and a thin inner ring for the 5-hour and weekly windows. Blue turns red at the warning level; the white dot is the time elapsed in the outer window.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
