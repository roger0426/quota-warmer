import SwiftUI
import WidgetKit

// The widget is a separate, sandboxed process. It shows what the app last
// wrote to `~/Library/Application Support/QuotaWarmer/status.json` (see
// `QuotaStatusFile` in the app) and does nothing else: no network, no
// credentials, no CLI. Its only entitlement beyond the sandbox is read-only
// access to that folder.

// MARK: - Status file (the fields the widget shows)

struct WidgetStatusFile: Decodable {
    let providers: [WidgetProvider]
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
            .appendingPathComponent("Library/Application Support/QuotaWarmer/status.json")
    }

    static func read() -> [WidgetProvider] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: statusURL),
              let file = try? decoder.decode(WidgetStatusFile.self, from: data) else { return [] }
        return file.providers.filter { $0.mode != "off" }
    }
}

// MARK: - Timeline

struct QuotaEntry: TimelineEntry {
    let date: Date
    let providers: [WidgetProvider]
}

struct QuotaTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(date: Date(), providers: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        let providers = WidgetStatusReader.read()
        completion(QuotaEntry(date: Date(), providers: providers.isEmpty && context.isPreview ? Self.sample : providers))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        // The app asks WidgetKit to reload when a reading changes. Between
        // reloads the same reading is re-drawn every 10 minutes so the time
        // marker keeps moving and a reading that stopped updating turns dim.
        let now = Date()
        let providers = WidgetStatusReader.read()
        let entries = (0..<12).map { step in
            QuotaEntry(date: now.addingTimeInterval(Double(step) * 600), providers: providers)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(12 * 600))))
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

    /// Same threshold as the app's red bar: 80% used.
    static let criticalUsedPercent = 80

    init(window: WidgetWindow?, duration: TimeInterval, now: Date) {
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

    /// Green, like a battery ring; red once the quota is nearly gone.
    var color: Color {
        guard let used else { return .secondary }
        return used >= Self.criticalUsedPercent ? .red : .green
    }
}

private let sessionDuration: TimeInterval = 5 * 3600
private let weeklyDuration: TimeInterval = 7 * 86400

// MARK: - Views

/// Battery-style gauge for one account: the outer ring is the session (5h)
/// window, the inner ring the weekly window, both as quota used. A white dot
/// on each ring marks how far through the window the clock is, so a fill that
/// runs ahead of its dot means quota is being used faster than time.
struct QuotaGauge: View {
    let provider: WidgetProvider
    let now: Date

    private var session: RingValue { RingValue(window: provider.session, duration: sessionDuration, now: now) }
    private var weekly: RingValue { RingValue(window: provider.weekly, duration: weeklyDuration, now: now) }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let line = max(3, size * 0.095)
            let gap = line * 0.45
            let outer = size - line
            let inner = outer - 2 * (line + gap)
            ZStack {
                ring(session, diameter: outer, line: line)
                ring(weekly, diameter: inner, line: line)
                glyph
                    .frame(width: max(8, inner - line * 2.6), height: max(8, inner - line * 2.6))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func ring(_ value: RingValue, diameter: CGFloat, line: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.13), lineWidth: line)
            if let used = value.used, used > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(used) / 100)
                    .stroke(value.color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let elapsed = value.elapsed {
                Circle()
                    .fill(Color.white)
                    .frame(width: line * 0.62, height: line * 0.62)
                    .shadow(color: .black.opacity(0.35), radius: 0.6)
                    .offset(y: -diameter / 2)
                    .rotationEffect(.degrees(360 * elapsed))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// The provider glyph with the account's initial, as in the app's sidebar.
    private var glyph: some View {
        Image(provider.tool == "claude" ? "ClaudeCode" : "Codex")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(.primary)
            .overlay(alignment: .bottomTrailing) {
                if let badge = provider.badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundStyle(.background)
                        .frame(minWidth: 11, minHeight: 11)
                        .background(Color.primary, in: Circle())
                        .offset(x: 5, y: 4)
                }
            }
    }
}

extension WidgetProvider {
    /// Initial of an added account ("Claude · Work" → "W"); nil for the default.
    var badge: String? {
        guard account != "default" else { return nil }
        let label = name.components(separatedBy: " · ").last ?? name
        return label.first.map { String($0).uppercased() }
    }

    /// Reading older than 30 minutes (the app's "expired" threshold).
    func isStale(at now: Date) -> Bool {
        fetchedAt.map { now.timeIntervalSince($0) > 30 * 60 } ?? true
    }
}

/// A gauge with the session's used percent under it, as the Batteries widget
/// puts the charge under each ring.
struct QuotaCell: View {
    let provider: WidgetProvider
    let now: Date
    var percentSize: CGFloat = 13

    var body: some View {
        let session = RingValue(window: provider.session, duration: sessionDuration, now: now)
        let weekly = RingValue(window: provider.weekly, duration: weeklyDuration, now: now)
        let stale = provider.isStale(at: now)
        let sessionText = session.used.map { "\($0)%" } ?? "–"
        let weeklyText = weekly.used.map { "\($0)%" } ?? "–"
        let critical = (session.used ?? 0) >= RingValue.criticalUsedPercent
        VStack(spacing: 3) {
            QuotaGauge(provider: provider, now: now)
            Text(sessionText)
                .font(.system(size: percentSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(critical ? Color.red : Color.primary)
                .lineLimit(1)
        }
        .opacity(stale ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(provider.name): session \(sessionText) used, week \(weeklyText) used"))
    }
}

struct QuotaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

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
                // One row, up to four accounts.
                HStack(spacing: 12) {
                    ForEach(Array(entry.providers.prefix(4))) { provider in
                        QuotaCell(provider: provider, now: entry.date, percentSize: 14)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                // 2 × 2 grid, up to four accounts.
                let shown = Array(entry.providers.prefix(4))
                let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(shown) { provider in
                        QuotaCell(provider: provider, now: entry.date, percentSize: shown.count > 2 ? 11 : 13)
                    }
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Widget

@main
struct QuotaWarmerWidget: Widget {
    static let kind = "com.quotawarmer.app.widget.quota"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuotaTimelineProvider()) { entry in
            QuotaWidgetView(entry: entry)
        }
        .configurationDisplayName("Quota")
        .description("Session (outer ring) and weekly (inner ring) quota used for each account.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
