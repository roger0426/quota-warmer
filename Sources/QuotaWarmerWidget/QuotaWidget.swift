import SwiftUI
import WidgetKit

// The widget is a separate, sandboxed process. It shows what the app last
// wrote to `~/Library/Application Support/io.github.roger0426.quotawarmer/status.json` (see
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
            .appendingPathComponent("Library/Application Support/io.github.roger0426.quotawarmer/status.json")
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

/// Sizes for a gauge drawn in a `size` × `size` square.
struct GaugeMetrics {
    let line: CGFloat
    let diameter: CGFloat
    let glyph: CGFloat

    init(size: CGFloat) {
        line = max(3, size * 0.09)
        // Leave room for the time knob, which is slightly wider than the ring.
        diameter = size - line * 1.2
        glyph = max(10, diameter - line * 3.2)
    }
}

/// One arc of the split ring: the clockwise range `low…high` in screen angles
/// (degrees, clockwise from 3 o'clock), cut into `segments` equal pieces, and
/// filled from its left end, which is `low` or `high` depending on the arc.
struct RingArc {
    let low: Double
    let high: Double
    let segments: Int
    /// The fill starts at `low` and runs clockwise; otherwise it starts at
    /// `high` and runs anticlockwise.
    let fillsClockwise: Bool
    /// Angle between neighbouring segments.
    let segmentGap: Double

    var length: Double { high - low }

    /// Angle `fraction` (0…1) of the way along the arc from its left end.
    func angle(at fraction: Double) -> Double {
        fillsClockwise ? low + length * fraction : high - length * fraction
    }

    /// The segments as clockwise `(start, end)` ranges, clipped to `range`.
    func pieces(within range: ClosedRange<Double>? = nil) -> [(Double, Double)] {
        let count = max(segments, 1)
        let piece = (length - segmentGap * Double(count - 1)) / Double(count)
        return (0..<count).compactMap { index in
            let start = low + Double(index) * (piece + segmentGap)
            let end = start + piece
            let clippedStart = max(start, range?.lowerBound ?? start)
            let clippedEnd = min(end, range?.upperBound ?? end)
            return clippedEnd > clippedStart ? (clippedStart, clippedEnd) : nil
        }
    }

    /// The part of the arc a `fraction` (0…1) fill covers, as a clockwise range.
    func filledRange(_ fraction: Double) -> ClosedRange<Double> {
        let fill = length * fraction
        return fillsClockwise ? low...(low + fill) : (high - fill)...high
    }
}

/// Where the two arcs of the split ring sit. The weekly arc is centred on
/// 12 o'clock and spans `topSpan` in 7 segments, one per day; the session arc
/// takes the rest of the circle in 5 segments, one per hour. The segment count
/// is what tells the two apart, so it still reads when the system drains the
/// colour (tinted, clear or vibrant widgets). Both fill from their left end
/// towards the right: the weekly arc clockwise over the top, the session arc
/// anticlockwise round the bottom.
struct SplitRing {
    /// Degrees of the circle given to the weekly arc.
    static let defaultTopSpan: Double = 120

    let weekly: RingArc
    let session: RingArc

    init(topSpan: Double, line: CGFloat, diameter: CGFloat) {
        let radius = Double(diameter) / 2
        let degrees = { (length: Double) in length / radius * 180 / .pi }
        // Between the arcs: two cap radii plus a little air. Between the
        // segments of one arc: a bit less, so the arcs still read as two.
        let gap = degrees(Double(line) * 1.9)
        let segmentGap = degrees(Double(line) * 1.35)
        let leftSplit = 270 - topSpan / 2
        weekly = RingArc(
            low: leftSplit + gap / 2, high: leftSplit + topSpan - gap / 2,
            segments: 7, fillsClockwise: true, segmentGap: segmentGap
        )
        session = RingArc(
            low: leftSplit + topSpan + gap / 2, high: leftSplit + 360 - gap / 2,
            segments: 5, fillsClockwise: false, segmentGap: segmentGap
        )
    }
}

/// Clockwise pieces of a circle, stroked with round caps.
struct ArcPieces: View {
    let pieces: [(Double, Double)]
    let line: CGFloat

    var body: some View {
        ZStack {
            ForEach(pieces.indices, id: \.self) { index in
                let (start, end) = pieces[index]
                Circle()
                    .trim(from: 0, to: (end - start) / 360)
                    .stroke(style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(start))
            }
        }
    }
}

/// Gauge for one account: a single ring split in two. The short arc over the
/// top is the weekly window (7 day segments), the long arc round the bottom the
/// session (5h) window (5 hour segments), both as quota used and both filling
/// left to right. A white dot on each arc marks how far through the window the
/// clock is, so a fill that runs ahead of its dot means quota is being used
/// faster than time.
struct QuotaGauge: View {
    let provider: WidgetProvider
    let now: Date
    var topSpan: Double = SplitRing.defaultTopSpan
    @Environment(\.colorScheme) private var colorScheme

    private var session: RingValue { RingValue(window: provider.session, duration: sessionDuration, now: now) }
    private var weekly: RingValue { RingValue(window: provider.weekly, duration: weeklyDuration, now: now) }

    var body: some View {
        GeometryReader { geo in
            let metrics = GaugeMetrics(size: min(geo.size.width, geo.size.height))
            let split = SplitRing(topSpan: topSpan, line: metrics.line, diameter: metrics.diameter)
            ZStack {
                SplitRingTracks(split: split, line: metrics.line, opacity: 0.13)
                arc(weekly, on: split.weekly, metrics: metrics)
                arc(session, on: split.session, metrics: metrics)
                glyph
                    .frame(width: metrics.glyph, height: metrics.glyph)
            }
            .frame(width: metrics.diameter, height: metrics.diameter)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// The used fill and the time knob of one arc.
    private func arc(_ value: RingValue, on arc: RingArc, metrics: GaugeMetrics) -> some View {
        let radius = metrics.diameter / 2
        let line = metrics.line
        return ZStack {
            if let used = value.used, used > 0 {
                ArcPieces(pieces: arc.pieces(within: arc.filledRange(Double(used) / 100)), line: line)
                    .foregroundStyle(value.color)
                    // In tinted / clear widgets the fill takes the accent tint
                    // and the tracks stay in the primary group.
                    .widgetAccentable()
            }
            if let elapsed = value.elapsed {
                let angle = arc.angle(at: elapsed) * .pi / 180
                // A knob a little wider than the ring, with a dark rim so it
                // reads on the track and on a green or red fill alike. On a
                // light background the white knob needs a heavier rim.
                let light = colorScheme == .light
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(
                        Color.black.opacity(light ? 0.85 : 0.55),
                        lineWidth: light ? max(1.2, line * 0.26) : max(0.75, line * 0.14)
                    ))
                    .frame(width: line * 1.05, height: line * 1.05)
                    .offset(x: radius * cos(angle), y: radius * sin(angle))
            }
        }
        .frame(width: metrics.diameter, height: metrics.diameter)
    }

    /// The provider glyph, with the account's initial in its centre.
    private var glyph: some View {
        Image(provider.tool == "claude" ? "ClaudeCode" : "Codex")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(.primary)
            .overlay {
                if let badge = provider.badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(.background)
                        .frame(minWidth: 13, minHeight: 13)
                        .background(Color.primary, in: Circle())
                        .overlay(Circle().stroke(.background, lineWidth: 1.5))
                }
            }
    }
}

/// The empty, segmented tracks of a split ring.
struct SplitRingTracks: View {
    let split: SplitRing
    let line: CGFloat
    let opacity: Double

    var body: some View {
        ZStack {
            ArcPieces(pieces: split.weekly.pieces(), line: line)
            ArcPieces(pieces: split.session.pieces(), line: line)
        }
        .foregroundStyle(Color.primary.opacity(opacity))
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

/// One account's gauge. No text: like the Batteries widget's rings, the fill,
/// its colour and the glyph carry everything; VoiceOver gets the numbers.
struct QuotaCell: View {
    let provider: WidgetProvider
    let now: Date

    var body: some View {
        let session = RingValue(window: provider.session, duration: sessionDuration, now: now)
        let weekly = RingValue(window: provider.weekly, duration: weeklyDuration, now: now)
        let sessionText = session.used.map { "\($0)%" } ?? "–"
        let weeklyText = weekly.used.map { "\($0)%" } ?? "–"
        QuotaGauge(provider: provider, now: now)
            .opacity(provider.isStale(at: now) ? 0.45 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(provider.name): session \(sessionText) used, week \(weeklyText) used"))
    }
}

/// Empty slot: the two tracks only, as the Batteries widget draws an unused ring.
struct EmptyGauge: View {
    var topSpan: Double = SplitRing.defaultTopSpan

    var body: some View {
        GeometryReader { geo in
            let metrics = GaugeMetrics(size: min(geo.size.width, geo.size.height))
            SplitRingTracks(
                split: SplitRing(topSpan: topSpan, line: metrics.line, diameter: metrics.diameter),
                line: metrics.line,
                opacity: 0.08
            )
            .frame(width: metrics.diameter, height: metrics.diameter)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
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
                // One row of four slots.
                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { index in slot(index) }
                }
            } else {
                // 2 × 2 slots.
                VStack(spacing: 10) {
                    HStack(spacing: 10) { slot(0); slot(1) }
                    HStack(spacing: 10) { slot(2); slot(3) }
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private func slot(_ index: Int) -> some View {
        if index < entry.providers.count {
            QuotaCell(provider: entry.providers[index], now: entry.date)
        } else {
            EmptyGauge()
        }
    }
}

// MARK: - Widget

@main
struct QuotaWarmerWidget: Widget {
    static let kind = "io.github.roger0426.quotawarmer.widget.quota"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuotaTimelineProvider()) { entry in
            QuotaWidgetView(entry: entry)
        }
        .configurationDisplayName("Quota")
        .description("Quota used per account: week on the top arc (7 days), session on the bottom arc (5 hours), both filling left to right. The white dot is the time elapsed.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
