import Foundation

/// The token kinds the Cost tab splits API-equivalent value into, in display
/// order (largest share first for a typical cached CLI session).
enum CostComponent: String, CaseIterable, Identifiable {
    case cacheRead, cacheWrite, output, input

    var id: String { rawValue }
}

/// One value per token kind: token counts (`TokenSplit`) or USD (`CostSplit`).
/// Codex has no cache writes; its cached input is `cacheRead` and `input` is
/// the uncached rest.
struct ComponentSplit<Value: Codable & Equatable & AdditiveArithmetic>: Codable, Equatable {
    var input: Value = .zero
    var output: Value = .zero
    var cacheWrite: Value = .zero
    var cacheRead: Value = .zero

    private enum CodingKeys: String, CodingKey {
        case input = "i", output = "o", cacheWrite = "w", cacheRead = "r"
    }

    subscript(_ component: CostComponent) -> Value {
        get {
            switch component {
            case .input: return input
            case .output: return output
            case .cacheWrite: return cacheWrite
            case .cacheRead: return cacheRead
            }
        }
        set {
            switch component {
            case .input: input = newValue
            case .output: output = newValue
            case .cacheWrite: cacheWrite = newValue
            case .cacheRead: cacheRead = newValue
            }
        }
    }

    var total: Value { input + output + cacheWrite + cacheRead }

    static func + (lhs: Self, rhs: Self) -> Self {
        var sum = lhs
        sum += rhs
        return sum
    }

    static func += (lhs: inout Self, rhs: Self) {
        for component in CostComponent.allCases { lhs[component] += rhs[component] }
    }
}

typealias TokenSplit = ComponentSplit<Int>
typealias CostSplit = ComponentSplit<Double>

extension CostSplit {
    /// `self` scaled so its total is `total`.
    func scaled(to total: Double) -> CostSplit {
        let current = self.total
        guard current > 0 else { return self }
        var result = CostSplit()
        for component in CostComponent.allCases { result[component] = self[component] * total / current }
        return result
    }

    /// `total` divided across the kinds in proportion to `tokens` — for a
    /// record that carries its own cost but no per-kind price.
    static func distributing(_ total: Double, by tokens: TokenSplit) -> CostSplit {
        var result = CostSplit()
        let count = tokens.total
        guard count > 0 else { return result }
        for component in CostComponent.allCases {
            result[component] = total * Double(tokens[component]) / Double(count)
        }
        return result
    }
}

/// Tokens and API-equivalent cost of one model on one day, or of one hour.
struct CostCell: Codable, Equatable {
    var tokens = TokenSplit()
    /// Cost of the priced tokens only.
    var cost = CostSplit()
    /// Tokens of models the catalog could not price; not in `cost`.
    var unpricedTokens = 0

    private enum CodingKeys: String, CodingKey {
        case tokens = "t", cost = "c", unpricedTokens = "u"
    }

    static func + (lhs: CostCell, rhs: CostCell) -> CostCell {
        CostCell(tokens: lhs.tokens + rhs.tokens, cost: lhs.cost + rhs.cost, unpricedTokens: lhs.unpricedTokens + rhs.unpricedTokens)
    }
}

/// An account's API-equivalent cost per local day (and model) and per hour.
/// The CLIs delete their logs (Claude Code after 30 days by default), so the
/// app keeps this rollup itself (`CostRollupStore`): each scan merges into it,
/// and a day whose logs are gone keeps its stored value.
struct CostRollup: Codable, Equatable {
    /// Hour cells feed only the weekly-quota card (the last few weeks).
    static let hourRetention: TimeInterval = 70 * 24 * 3600
    static let unlabeledModel = "unlabeled"

    /// Local day `yyyy-MM-dd` → model → cell.
    var days: [String: [String: CostCell]] = [:]
    /// Start of the hour (seconds since 1970, as a string) → cell.
    var hours: [String: CostCell] = [:]
    /// When every log still on disk was read into this rollup (seconds since
    /// 1970); nil until that one-time backfill ran. Regular scans read 30 days.
    var backfilledAt: Double?

    var isEmpty: Bool { days.isEmpty && hours.isEmpty }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func hourKey(_ hourStart: Date) -> String { String(Int(hourStart.timeIntervalSince1970)) }

    /// Adds one usage record. `cost` nil = the model has no price.
    mutating func add(dayKey: String, hourStart: Date, model: String?, tokens: TokenSplit, cost: CostSplit?) {
        var cell = CostCell(tokens: tokens)
        if let cost { cell.cost = cost } else { cell.unpricedTokens = tokens.total }
        let modelKey = (model?.isEmpty == false ? model : nil) ?? Self.unlabeledModel
        days[dayKey, default: [:]][modelKey, default: CostCell()] = (days[dayKey]?[modelKey] ?? CostCell()) + cell
        let hour = Self.hourKey(hourStart)
        hours[hour] = (hours[hour] ?? CostCell()) + cell
    }

    /// Merges a fresh scan into the stored rollup. A cell the scan also has is
    /// replaced unless the scan saw fewer tokens there (its window starts in
    /// the middle of the oldest day, or a log file was deleted); cells the
    /// scan no longer covers are kept.
    mutating func merge(_ fresh: CostRollup, now: Date = Date()) {
        for (day, models) in fresh.days {
            for (model, cell) in models {
                if let stored = days[day]?[model], stored.tokens.total > cell.tokens.total { continue }
                days[day, default: [:]][model] = cell
            }
        }
        for (hour, cell) in fresh.hours {
            if let stored = hours[hour], stored.tokens.total > cell.tokens.total { continue }
            hours[hour] = cell
        }
        let cutoff = now.addingTimeInterval(-Self.hourRetention).timeIntervalSince1970
        hours = hours.filter { (Double($0.key) ?? 0) >= cutoff }
    }

    /// Several accounts' rollups summed (the "All" view).
    static func combined(_ rollups: [CostRollup]) -> CostRollup {
        var result = CostRollup()
        for rollup in rollups {
            for (day, models) in rollup.days {
                for (model, cell) in models {
                    result.days[day, default: [:]][model] = (result.days[day]?[model] ?? CostCell()) + cell
                }
            }
            for (hour, cell) in rollup.hours {
                result.hours[hour] = (result.hours[hour] ?? CostCell()) + cell
            }
        }
        return result
    }

    // MARK: - Queries

    /// The day keys of the `count` local days ending with `now`'s, oldest first.
    static func dayKeys(endingAt now: Date, count: Int, calendar: Calendar) -> [String] {
        let today = calendar.startOfDay(for: now)
        return (0..<max(count, 1)).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { dayKey($0, calendar: calendar) }
        }
    }

    /// Every stored day key, oldest first.
    var sortedDayKeys: [String] { days.keys.sorted() }

    func summary(dayKeys keys: [String]) -> CostPeriodSummary {
        var summary = CostPeriodSummary()
        var byModel: [String: CostCell] = [:]
        for key in keys {
            for (model, cell) in days[key] ?? [:] {
                summary.add(cell)
                byModel[model] = (byModel[model] ?? CostCell()) + cell
            }
        }
        summary.models = byModel
            .map { ModelCostRow(model: $0.key, costUSD: $0.value.cost.total, tokens: $0.value.tokens.total, unpricedTokens: $0.value.unpricedTokens) }
            .filter { $0.tokens > 0 }
            .sorted { ($0.costUSD, $0.tokens) > ($1.costUSD, $1.tokens) }
        return summary
    }

    /// Cost per kind for each day key (missing days are zero).
    func dailyCosts(dayKeys keys: [String]) -> [CostSplit] {
        keys.map { key in
            (days[key] ?? [:]).values.reduce(into: CostSplit()) { $0 += $1.cost }
        }
    }

    /// Cost per kind for each hour starting in `[start, end)`; hours without
    /// usage are omitted.
    func hourlyCosts(from start: Date, to end: Date) -> [(hour: Date, cost: CostSplit)] {
        hours.compactMap { key, cell -> (hour: Date, cost: CostSplit)? in
            guard let seconds = Double(key) else { return nil }
            let hour = Date(timeIntervalSince1970: seconds)
            guard hour >= start, hour < end else { return nil }
            return (hour, cell.cost)
        }
        .sorted { $0.hour < $1.hour }
    }

    /// Priced cost of the hours starting in `[start, end)`.
    func cost(from start: Date, to end: Date) -> Double {
        hourlyCosts(from: start, to: end).reduce(0) { $0 + $1.cost.total }
    }

    /// The oldest hour with usage, if any.
    var firstHour: Date? {
        hours.keys.compactMap(Double.init).min().map { Date(timeIntervalSince1970: $0) }
    }
}

/// One model's row in the "By model" card.
struct ModelCostRow: Identifiable, Equatable {
    let model: String
    let costUSD: Double
    let tokens: Int
    let unpricedTokens: Int

    var id: String { model }
    var isUnpriced: Bool { unpricedTokens > 0 && costUSD == 0 }
}

/// Totals for one Cost-tab range.
struct CostPeriodSummary: Equatable {
    var tokens = TokenSplit()
    var cost = CostSplit()
    var unpricedTokens = 0
    var models: [ModelCostRow] = []

    mutating func add(_ cell: CostCell) {
        tokens += cell.tokens
        cost += cell.cost
        unpricedTokens += cell.unpricedTokens
    }

    var totalTokens: Int { tokens.total }

    /// Share of prompt tokens served from the cache.
    var cacheHitRate: Double? {
        let prompt = tokens.input + tokens.cacheWrite + tokens.cacheRead
        guard prompt > 0 else { return nil }
        return Double(tokens.cacheRead) / Double(prompt)
    }

    var unpricedModels: [ModelCostRow] { models.filter { $0.unpricedTokens > 0 } }
}

/// The API-equivalent value of one weekly quota period.
struct WeeklyQuotaValue: Identifiable, Equatable {
    let start: Date
    let end: Date
    let costUSD: Double
    /// Highest weekly used fraction seen in the period; nil without readings.
    let usedFraction: Double?
    let isCurrent: Bool

    var id: Date { end }

    /// The current period plus up to `count - 1` earlier ones, oldest first.
    /// Periods step back by `duration` from `resetAt` (the current period's
    /// end). Periods that end before the rollup's first hour are left out.
    static func periods(
        rollup: CostRollup,
        resetAt: Date,
        duration: TimeInterval,
        samples: [QuotaSample],
        currentUsed: Double?,
        count: Int = 4
    ) -> [WeeklyQuotaValue] {
        guard let first = rollup.firstHour else { return [] }
        // Readings right after a reset can still carry the old week's value.
        let settle: TimeInterval = 15 * 60
        var result: [WeeklyQuotaValue] = []
        for index in 0..<count {
            let end = resetAt.addingTimeInterval(-Double(index) * duration)
            let start = end.addingTimeInterval(-duration)
            guard end > first else { break }
            let isCurrent = index == 0
            let observed = samples
                .filter { $0.t >= start.addingTimeInterval(settle) && $0.t < end }
                .compactMap(\.w)
                .max()
            let used = isCurrent ? (currentUsed ?? observed) : observed
            result.append(WeeklyQuotaValue(
                start: start, end: end,
                costUSD: rollup.cost(from: start, to: end),
                usedFraction: used,
                isCurrent: isCurrent
            ))
        }
        return result.reversed()
    }
}

/// Persists each account's `CostRollup` as JSON under
/// `~/Library/Application Support/<app>/cost/<storageKey>.json`. Only token
/// counts, costs and model names are stored — no prompts or file paths.
final class CostRollupStore: @unchecked Sendable {
    static let shared = CostRollupStore()

    private let queue = DispatchQueue(label: "com.quotawarmer.cost-rollup")
    private let directory: URL
    private var cache: [String: CostRollup] = [:]

    init(directory: URL? = nil) {
        self.directory = directory ?? AppIdentity.supportDirectory.appendingPathComponent("cost", isDirectory: true)
    }

    /// Merges a fresh scan into the stored rollup, saves it, and returns the
    /// result. `backfill` marks a scan of every log on disk (`backfilledAt`).
    /// Blocks; call off the main actor.
    func merge(_ fresh: CostRollup, storageKey: String, backfill: Bool = false, now: Date = Date()) -> CostRollup {
        queue.sync {
            var rollup = loadLocked(storageKey)
            let before = rollup
            rollup.merge(fresh, now: now)
            if backfill { rollup.backfilledAt = now.timeIntervalSince1970 }
            cache[storageKey] = rollup
            if rollup != before { saveLocked(rollup, storageKey: storageKey) }
            return rollup
        }
    }

    func rollup(storageKey: String) -> CostRollup {
        queue.sync { loadLocked(storageKey) }
    }

    /// Moves files kept under older keys (one per account, before rollups
    /// were kept per log folder) into `storageKey`. Accounts that shared a
    /// folder hold the same cells, and `merge` keeps the larger cell, so
    /// nothing is counted twice. A legacy file that cannot be read stays.
    func adoptLegacy(_ legacyKeys: [String], into storageKey: String) {
        queue.sync {
            var rollup = loadLocked(storageKey)
            let before = rollup
            var adopted: [URL] = []
            for key in legacyKeys where key != storageKey {
                let url = fileURL(key)
                guard let data = try? Data(contentsOf: url),
                      let legacy = try? JSONDecoder().decode(CostRollup.self, from: data) else { continue }
                rollup.merge(legacy)
                adopted.append(url)
                cache[key] = nil
            }
            cache[storageKey] = rollup
            // Delete only once the merged rollup is on disk.
            let saved = rollup == before || saveLocked(rollup, storageKey: storageKey)
            if saved {
                for url in adopted { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    func removeAll(storageKey: String) {
        queue.async {
            self.cache[storageKey] = nil
            try? FileManager.default.removeItem(at: self.fileURL(storageKey))
        }
    }

    // MARK: - Queue-confined

    private func fileURL(_ storageKey: String) -> URL {
        directory.appendingPathComponent("\(storageKey).json")
    }

    private func loadLocked(_ storageKey: String) -> CostRollup {
        if let cached = cache[storageKey] { return cached }
        let url = fileURL(storageKey)
        var loaded = CostRollup()
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode(CostRollup.self, from: data) {
                loaded = decoded
            } else {
                // Keep an unreadable file aside rather than overwrite the only
                // copy of days whose logs are already gone.
                let aside = url.appendingPathExtension("unreadable")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: url, to: aside)
                DiagnosticLogger.append("cost_rollup_unreadable key=\(storageKey)")
            }
        }
        cache[storageKey] = loaded
        return loaded
    }

    @discardableResult
    private func saveLocked(_ rollup: CostRollup, storageKey: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(rollup).write(to: fileURL(storageKey), options: .atomic)
            return true
        } catch {
            DiagnosticLogger.append("cost_rollup_save_failed key=\(storageKey)")
            return false
        }
    }
}
