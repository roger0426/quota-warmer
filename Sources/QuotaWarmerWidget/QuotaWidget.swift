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
        // The app asks WidgetKit to reload when a reading changes; this is the
        // fallback cadence, and it also lets a reading that stopped updating
        // turn dim.
        let now = Date()
        let entry = QuotaEntry(date: now, providers: WidgetStatusReader.read())
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(15 * 60))))
    }

    static let sample: [WidgetProvider] = [
        WidgetProvider(
            id: "claude", tool: "claude", name: "Claude", mode: "monitor", displayMode: "remaining",
            fetchedAt: Date(),
            session: WidgetWindow(usedPercent: 35, remainingPercent: 65, resetAt: nil, settling: false),
            weekly: WidgetWindow(usedPercent: 20, remainingPercent: 80, resetAt: nil, settling: false)
        ),
        WidgetProvider(
            id: "codex", tool: "codex", name: "Codex", mode: "monitor", displayMode: "remaining",
            fetchedAt: Date(),
            session: WidgetWindow(usedPercent: 10, remainingPercent: 90, resetAt: nil, settling: false),
            weekly: WidgetWindow(usedPercent: 5, remainingPercent: 95, resetAt: nil, settling: false)
        )
    ]
}

// MARK: - Views

/// What one ring shows for one quota window.
struct RingValue {
    /// Percent drawn and printed: left or used, as the account is set in the app.
    let percent: Int?
    let usedPercent: Int?
    /// The reading is older than 30 minutes (the app's "expired" threshold).
    let stale: Bool

    init(window: WidgetWindow?, provider: WidgetProvider, now: Date) {
        if let window, !window.settling {
            percent = provider.displayMode == "used" ? window.usedPercent : window.remainingPercent
            usedPercent = window.usedPercent
        } else {
            percent = nil
            usedPercent = nil
        }
        stale = provider.fetchedAt.map { now.timeIntervalSince($0) > 30 * 60 } ?? true
    }

    /// Same bands as the app's bars: 50% used turns orange, 80% red.
    var color: Color {
        guard let usedPercent else { return .secondary }
        if usedPercent >= 80 { return .red }
        if usedPercent >= 50 { return .orange }
        return .green
    }
}

/// Battery-style ring: a track, a rounded arc for the percent, the provider
/// glyph in the middle.
struct QuotaRing: View {
    let value: RingValue
    let glyph: String?
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            if let percent = value.percent {
                Circle()
                    .trim(from: 0, to: max(0.001, CGFloat(percent) / 100))
                    .stroke(value.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let glyph {
                Image(glyph)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .padding(lineWidth * 2.4)
                    .foregroundStyle(.primary)
            }
        }
        .padding(lineWidth / 2)
        .opacity(value.stale ? 0.45 : 1)
    }
}

private func glyphName(for provider: WidgetProvider) -> String {
    provider.tool == "claude" ? "ClaudeCode" : "Codex"
}

private func percentText(_ value: RingValue) -> String {
    value.percent.map { "\($0)%" } ?? "–"
}

/// Small: one ring per account (session window), up to four, like the
/// Batteries widget.
struct SmallQuotaView: View {
    let entry: QuotaEntry

    var body: some View {
        let shown = Array(entry.providers.prefix(4))
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(shown) { provider in
                let value = RingValue(window: provider.session, provider: provider, now: entry.date)
                VStack(spacing: 2) {
                    QuotaRing(value: value, glyph: glyphName(for: provider))
                        .frame(maxWidth: shown.count > 2 ? 44 : 56, maxHeight: shown.count > 2 ? 44 : 56)
                    Text(percentText(value))
                        .font(.system(size: shown.count > 2 ? 11 : 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(value.stale ? .secondary : .primary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(provider.name) session \(percentText(value))"))
            }
        }
    }
}

/// Medium: per account, a session ring and a weekly ring side by side.
struct MediumQuotaView: View {
    let entry: QuotaEntry

    var body: some View {
        let shown = Array(entry.providers.prefix(3))
        HStack(spacing: 14) {
            ForEach(shown) { provider in
                VStack(spacing: 5) {
                    Text(provider.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        ring(provider.session, provider: provider, label: "5h", glyph: glyphName(for: provider))
                        ring(provider.weekly, provider: provider, label: "7d", glyph: nil)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func ring(_ window: WidgetWindow?, provider: WidgetProvider, label: String, glyph: String?) -> some View {
        let value = RingValue(window: window, provider: provider, now: entry.date)
        return VStack(spacing: 2) {
            QuotaRing(value: value, glyph: glyph)
                .frame(maxWidth: 52, maxHeight: 52)
                .overlay {
                    if glyph == nil {
                        Text(label)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            Text(percentText(value))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value.stale ? .secondary : .primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(provider.name) \(label) \(percentText(value))"))
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
                MediumQuotaView(entry: entry)
            } else {
                SmallQuotaView(entry: entry)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Widget

@main
struct QuotaWarmerWidget: Widget {
    /// Also used by the app to ask for a reload (`QuotaWidgetReload`).
    static let kind = "com.quotawarmer.app.widget.quota"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuotaTimelineProvider()) { entry in
            QuotaWidgetView(entry: entry)
        }
        .configurationDisplayName("Quota")
        .description("Session and weekly quota for each account.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
