import Foundation

/// Prompt-cache behavior of one side (main conversation or subagents) during
/// one local day or one hour. Every field adds up across cells, so a range is
/// the sum of its days. Numbers only: no prompts, paths or session names.
struct CacheCell: Codable, Equatable {
    /// Requests that read or wrote the cache.
    var requests = 0
    /// Gaps between consecutive requests of one conversation line, binned
    /// `<5m`, `5–60m`, `>60m`.
    var gaps = [0, 0, 0]
    /// Cached prefix tokens standing before each of those gaps.
    var prefixes = [0, 0, 0]
    /// What the request after a gap did with the cache.
    var hits = 0, expired = 0, modelChanges = 0, prefixChanges = 0, unknown = 0
    var reads = 0, writes = 0, inputs = 0
    /// API-equivalent USD of priced requests.
    var writeCost = 0.0, inputSideCost = 0.0
    /// Write cost of requests that rebuilt a prefix the previous request had cached.
    var rewriteCost = 0.0
    /// Input-side cost change had this side used the other TTL
    /// (main conversation → 5m, subagents → 1h).
    var alternativeDelta = 0.0
    /// Requests whose model has no price; left out of the costs.
    var unpriced = 0

    private enum CodingKeys: String, CodingKey {
        case requests = "n", gaps = "g", prefixes = "p"
        case hits = "h", expired = "e", modelChanges = "m", prefixChanges = "c", unknown = "u"
        case reads = "r", writes = "w", inputs = "i"
        case writeCost = "wc", inputSideCost = "ic", rewriteCost = "rc", alternativeDelta = "ad", unpriced = "x"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) -> Int { (try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0 }
        func double(_ key: CodingKeys) -> Double { (try? c.decodeIfPresent(Double.self, forKey: key)) ?? 0 }
        func bins(_ key: CodingKeys) -> [Int] {
            let value = (try? c.decodeIfPresent([Int].self, forKey: key)) ?? []
            return value.count == 3 ? value : [0, 0, 0]
        }
        requests = int(.requests)
        gaps = bins(.gaps)
        prefixes = bins(.prefixes)
        hits = int(.hits); expired = int(.expired); modelChanges = int(.modelChanges)
        prefixChanges = int(.prefixChanges); unknown = int(.unknown)
        reads = int(.reads); writes = int(.writes); inputs = int(.inputs)
        writeCost = double(.writeCost); inputSideCost = double(.inputSideCost)
        rewriteCost = double(.rewriteCost); alternativeDelta = double(.alternativeDelta)
        unpriced = int(.unpriced)
    }

    var isEmpty: Bool { requests == 0 }
    var gapCount: Int { gaps.reduce(0, +) }

    /// Cache-read share of all input-side tokens.
    var tokenHitRate: Double? {
        let total = inputs + reads + writes
        return total > 0 ? Double(reads) / Double(total) : nil
    }

    /// Cache-write share of input-side cost.
    var writeShare: Double? {
        inputSideCost > 0 ? writeCost / inputSideCost : nil
    }

    static func + (lhs: CacheCell, rhs: CacheCell) -> CacheCell {
        var sum = lhs
        sum += rhs
        return sum
    }

    static func += (lhs: inout CacheCell, rhs: CacheCell) {
        lhs.requests += rhs.requests
        for i in 0..<3 {
            lhs.gaps[i] += rhs.gaps[i]
            lhs.prefixes[i] += rhs.prefixes[i]
        }
        lhs.hits += rhs.hits
        lhs.expired += rhs.expired
        lhs.modelChanges += rhs.modelChanges
        lhs.prefixChanges += rhs.prefixChanges
        lhs.unknown += rhs.unknown
        lhs.reads += rhs.reads
        lhs.writes += rhs.writes
        lhs.inputs += rhs.inputs
        lhs.writeCost += rhs.writeCost
        lhs.inputSideCost += rhs.inputSideCost
        lhs.rewriteCost += rhs.rewriteCost
        lhs.alternativeDelta += rhs.alternativeDelta
        lhs.unpriced += rhs.unpriced
    }

    /// Whether a fresh scan's cell should replace this stored one: a scan
    /// that saw fewer requests (logs deleted, or a checkpoint that no longer
    /// holds the day's early requests) never shrinks what is stored.
    func isCovered(by fresh: CacheCell) -> Bool {
        (fresh.requests, fresh.gapCount) >= (requests, gapCount)
    }
}

/// The two sides the monitor compares.
enum CacheSide: String, CaseIterable, Identifiable, Codable {
    case main, subagent
    var id: String { rawValue }
    /// The TTL Claude Code uses on a subscription.
    var defaultTTL: Double { self == .main ? 3600 : 300 }
    /// The TTL `alternativeDelta` prices.
    var alternativeTTL: Double { self == .main ? 300 : 3600 }
}

struct CacheSides: Codable, Equatable {
    var main = CacheCell()
    var subagent = CacheCell()

    private enum CodingKeys: String, CodingKey { case main = "m", subagent = "s" }

    subscript(_ side: CacheSide) -> CacheCell {
        get { side == .main ? main : subagent }
        set { if side == .main { main = newValue } else { subagent = newValue } }
    }

    var requests: Int { main.requests + subagent.requests }
}

/// One log folder's prompt-cache statistics per local day and per hour.
/// Claude Code deletes transcripts after 30 days, so the app keeps this
/// itself (`CacheRollupStore`): each scan merges into it, and a day whose
/// transcripts are gone keeps its stored cells.
struct CacheRollup: Codable, Equatable {
    static let hourRetention: TimeInterval = 70 * 24 * 3600

    /// Local day `yyyy-MM-dd` → cells.
    var days: [String: CacheSides] = [:]
    /// Start of the hour (seconds since 1970, as a string) → cells.
    var hours: [String: CacheSides] = [:]

    var isEmpty: Bool { days.isEmpty && hours.isEmpty }

    mutating func add(_ cell: CacheCell, side: CacheSide, at date: Date, calendar: Calendar) {
        let day = CostRollup.dayKey(date, calendar: calendar)
        days[day, default: CacheSides()][side] += cell
        let hourStart = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        hours[CostRollup.hourKey(hourStart), default: CacheSides()][side] += cell
    }

    /// Merges a fresh scan: each of its cells replaces the stored one unless
    /// the stored one saw more (see `CacheCell.isCovered(by:)`). Cells the
    /// scan no longer covers are kept.
    mutating func merge(_ fresh: CacheRollup, now: Date = Date()) {
        func merged(_ stored: CacheSides?, _ incoming: CacheSides) -> CacheSides {
            guard var result = stored else { return incoming }
            for side in CacheSide.allCases where result[side].isCovered(by: incoming[side]) {
                result[side] = incoming[side]
            }
            return result
        }
        for (day, cells) in fresh.days { days[day] = merged(days[day], cells) }
        for (hour, cells) in fresh.hours { hours[hour] = merged(hours[hour], cells) }
        let cutoff = now.addingTimeInterval(-Self.hourRetention).timeIntervalSince1970
        hours = hours.filter { (Double($0.key) ?? 0) >= cutoff }
    }

    /// Several log folders summed.
    static func combined(_ rollups: [CacheRollup]) -> CacheRollup {
        var result = CacheRollup()
        for rollup in rollups {
            for (day, cells) in rollup.days {
                for side in CacheSide.allCases { result.days[day, default: CacheSides()][side] += cells[side] }
            }
            for (hour, cells) in rollup.hours {
                for side in CacheSide.allCases { result.hours[hour, default: CacheSides()][side] += cells[side] }
            }
        }
        return result
    }

    // MARK: - Queries

    var sortedDayKeys: [String] { days.keys.filter { days[$0]?.requests ?? 0 > 0 }.sorted() }

    func total(dayKeys keys: [String], side: CacheSide) -> CacheCell {
        keys.reduce(into: CacheCell()) { $0 += days[$1]?[side] ?? CacheCell() }
    }

    func total(from start: Date, to end: Date, side: CacheSide) -> CacheCell {
        hourly(from: start, to: end, side: side).reduce(into: CacheCell()) { $0 += $1.cell }
    }

    /// Cells of the hours starting in `[start, end)`, oldest first; empty hours omitted.
    func hourly(from start: Date, to end: Date, side: CacheSide) -> [(hour: Date, cell: CacheCell)] {
        hours.compactMap { key, cells -> (hour: Date, cell: CacheCell)? in
            guard let seconds = Double(key) else { return nil }
            let hour = Date(timeIntervalSince1970: seconds)
            guard hour >= start, hour < end, !cells[side].isEmpty else { return nil }
            return (hour, cells[side])
        }
        .sorted { $0.hour < $1.hour }
    }

    /// The TTL verdict for `side` over `dayKeys` (see `CacheVerdict`). Whether
    /// there is enough data is judged on both sides together.
    func verdict(dayKeys keys: [String], side: CacheSide, calendar: Calendar) -> CacheVerdict {
        let active = keys.filter { (days[$0]?.requests ?? 0) > 0 }.sorted()
        var span = 0
        if let first = active.first.flatMap({ CostRollup.date(fromDayKey: $0, calendar: calendar) }),
           let last = active.last.flatMap({ CostRollup.date(fromDayKey: $0, calendar: calendar) }) {
            span = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        }
        let requests = keys.reduce(0) { $0 + (days[$1]?.requests ?? 0) }
        return CacheVerdict(cell: total(dayKeys: keys, side: side), side: side, spanDays: span, totalRequests: requests)
    }
}

/// Whether the side's current TTL is the cheaper one, from the
/// API-equivalent input-side cost had it used the other TTL. Given once the
/// range (both sides together) spans a week and holds enough requests; a
/// change under 5% reads as "about the same".
struct CacheVerdict: Equatable {
    static let minimumDays = 7
    static let minimumRequests = 200
    static let sameThreshold = 0.05

    enum Outcome: Equatable { case keep, switchTTL, aboutTheSame, noRequests, notEnoughData }

    let side: CacheSide
    let spanDays: Int
    /// Requests of both sides in the range.
    let totalRequests: Int
    /// This side's requests.
    let requests: Int
    /// USD per week had the side used `side.alternativeTTL`; positive = costlier.
    let weeklyDelta: Double
    /// Change relative to the input-side cost; nil when nothing was priced.
    let relativeDelta: Double?

    init(cell: CacheCell, side: CacheSide, spanDays: Int, totalRequests: Int) {
        self.side = side
        self.spanDays = spanDays
        self.totalRequests = totalRequests
        requests = cell.requests
        weeklyDelta = spanDays > 0 ? cell.alternativeDelta * 7 / Double(spanDays) : 0
        relativeDelta = cell.inputSideCost > 0 ? cell.alternativeDelta / cell.inputSideCost : nil
    }

    var outcome: Outcome {
        guard spanDays >= Self.minimumDays, totalRequests >= Self.minimumRequests else { return .notEnoughData }
        guard let relative = relativeDelta else { return .noRequests }
        if abs(relative) < Self.sameThreshold { return .aboutTheSame }
        return relative > 0 ? .keep : .switchTTL
    }
}

/// Where the scanner left each transcript file, so a relaunch reads only the
/// bytes appended since. Holds only recent requests (`CacheRollupStore`
/// prunes the rest; their days are already in the rollup).
struct CacheCheckpoint: Codable {
    var savedAt = Date.distantPast
    /// File path → state.
    var files: [String: LocalUsageProvider.CacheFile] = [:]
}

/// Persists each log folder's `CacheRollup` and `CacheCheckpoint` under
/// `~/Library/Application Support/<app>/cache/`. The rollup holds numbers
/// only; the checkpoint also names transcript files and the project folder
/// and session slug of recent requests (for the live list after a relaunch).
final class CacheRollupStore: @unchecked Sendable {
    static let shared = CacheRollupStore()

    private let queue = DispatchQueue(label: "com.quotawarmer.cache-rollup")
    private let directory: URL
    private var cache: [String: CacheRollup] = [:]

    init(directory: URL? = nil) {
        self.directory = directory ?? AppIdentity.supportDirectory.appendingPathComponent("cache", isDirectory: true)
    }

    /// A file-name-safe, stable key for a log folder (FNV-1a of its path).
    static func key(for root: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in root.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// Merges a fresh scan into the stored rollup, saves it when it changed,
    /// and returns the result. Blocks; call off the main actor.
    func merge(_ fresh: CacheRollup, key: String, now: Date = Date()) -> CacheRollup {
        queue.sync {
            var rollup = loadLocked(key)
            let before = rollup
            rollup.merge(fresh, now: now)
            cache[key] = rollup
            if rollup != before { saveLocked(rollup, to: fileURL(key)) }
            return rollup
        }
    }

    func rollup(key: String) -> CacheRollup {
        queue.sync { loadLocked(key) }
    }

    func checkpoint(key: String) -> CacheCheckpoint? {
        queue.sync {
            guard let data = try? Data(contentsOf: checkpointURL(key)) else { return nil }
            // A checkpoint is only a speed-up: an unreadable one means a full rescan.
            return try? JSONDecoder().decode(CacheCheckpoint.self, from: data)
        }
    }

    func saveCheckpoint(_ checkpoint: CacheCheckpoint, key: String) {
        queue.sync { _ = saveLocked(checkpoint, to: checkpointURL(key)) }
    }

    // MARK: - Queue-confined

    private func fileURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).json") }
    private func checkpointURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).checkpoint.json") }

    private func loadLocked(_ key: String) -> CacheRollup {
        if let cached = cache[key] { return cached }
        let url = fileURL(key)
        var loaded = CacheRollup()
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode(CacheRollup.self, from: data) {
                loaded = decoded
            } else {
                // Keep an unreadable file aside rather than overwrite the only
                // copy of days whose transcripts are already gone.
                let aside = url.appendingPathExtension("unreadable")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: url, to: aside)
                DiagnosticLogger.append("cache_rollup_unreadable key=\(key)")
            }
        }
        cache[key] = loaded
        return loaded
    }

    @discardableResult
    private func saveLocked<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
            return true
        } catch {
            DiagnosticLogger.append("cache_rollup_save_failed file=\(url.lastPathComponent)")
            return false
        }
    }
}
