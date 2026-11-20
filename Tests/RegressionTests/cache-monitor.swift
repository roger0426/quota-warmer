import Foundation
import Testing
@testable import QuotaWarmerCore

extension RegressionTests {
    @Test func cacheMonitorTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subdir = root.appendingPathComponent("session/subagents")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let iso = ISO8601DateFormatter()
        func stamp(_ offset: Double) -> String { iso.string(from: now.addingTimeInterval(offset)) }
        func user(_ n: Double) -> String {
            #"{"type":"user","timestamp":"\#(stamp(n))","message":{"content":[{"type":"tool_result"}]}}"#
        }
        func response(_ n: Double, _ id: String, model: String = "opus-5-5", ttl: String = "1h", read: Int = 0, write: Int = 0) -> String {
            let detail = ttl == "1h" ? "ephemeral_1h_input_tokens" : "ephemeral_5m_input_tokens"
            return #"{"timestamp":"\#(stamp(n))","sessionId":"session","type":"assistant","requestId":"\#(id)","promptCacheRequested":"\#(ttl)","message":{"content":[{"type":"tool_use"}],"model":"\#(model)","usage":{"cache_read_input_tokens":\#(read),"cache_creation":{"\#(detail)":\#(write)}}}}"#
        }
        let main = root.appendingPathComponent("session.jsonl")
        let rows = [user(-900), response(-880, "a", write: 1000), response(-875, "a", write: 1000),
                    user(-300), response(-280, "b", read: 1000), user(-200), response(-190, "c", model: "sonnet-5", write: 1000)]
        try (rows.joined(separator: "\n") + "\n").write(to: main, atomically: true, encoding: .utf8)
        let sub = [user(-600), response(-590, "a", ttl: "5m", write: 1000),
                   user(-180), response(-160, "b", ttl: "", read: 0, write: 1000)]
        try (sub.joined(separator: "\n") + "\n").write(to: subdir.appendingPathComponent("agent-1.jsonl"), atomically: true, encoding: .utf8)
        let catalog = QuotaExtractorRegression.repoCatalog(.claude)
        let store = QuotaExtractorRegression.isolatedCatalogStore(.claude, catalog)
        let provider = LocalUsageProvider(claudeCatalog: store)
        var files: [URL: LocalUsageProvider.CacheFile] = [:]
        let lines = provider.cacheRequests(roots: [root], files: &files, now: now)
        let mainLine = try #require(lines.first { $0.first?.agent == nil })
        let agent = try #require(lines.first { $0.first?.agent != nil })
        #expect(mainLine.count == 3)
        #expect(mainLine[0].expiry == iso.date(from: stamp(2700)))
        #expect(agent.last?.ttl == 300)
        #expect(agent.last?.toolPending == true)
        let rollup = provider.cacheRollup(lines)
        let from = now.addingTimeInterval(-86_400), to = now.addingTimeInterval(3600)
        let short = rollup.total(from: from, to: to, side: .main)
        #expect(short.requests == 3)
        #expect(short.hits == 1 && short.modelChanges == 1)
        #expect(abs(short.alternativeDelta - (-0.003 + 0.0048 - 0.0015)) < 0.000001)
        let long = rollup.total(from: from, to: to, side: .subagent)
        #expect(long.expired == 1)
        #expect(abs(long.alternativeDelta - (0.006 - 0.0078)) < 0.000001)
        // Day and hour cells sum the same requests in a different order (the
        // fixture straddles an hour boundary whenever the test runs just after
        // the hour), so costs match only to rounding; counts must match exactly.
        let dayTotal = rollup.days.values.reduce(CacheCell()) { $0 + $1.main }
        var costless = dayTotal, shortCostless = short
        for keyPath in [\CacheCell.writeCost, \.inputSideCost, \.rewriteCost, \.alternativeDelta] {
            #expect(abs(dayTotal[keyPath: keyPath] - short[keyPath: keyPath]) < 0.000001)
            costless[keyPath: keyPath] = 0
            shortCostless[keyPath: keyPath] = 0
        }
        #expect(costless == shortCostless)
        // The checkpoint round-trips every request field.
        let encoded = try JSONEncoder().encode(files)
        let decoded = try JSONDecoder().decode([URL: LocalUsageProvider.CacheFile].self, from: encoded)
        #expect(provider.cacheRollup(lines) == rollup)
        #expect(decoded.mapValues(\.requests.count) == files.mapValues(\.requests.count))
        let handle = try FileHandle(forWritingTo: main)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((user(-100) + "\n").utf8))
        try handle.close()
        let refreshed = provider.cacheRequests(roots: [root], files: &files, now: now)
        #expect(refreshed.first { $0.first?.agent == nil }?.last?.toolPending == false)
    }

    @Test func cacheRollupMergeNeverShrinks() throws {
        var cell = CacheCell()
        cell.requests = 10
        cell.gaps = [5, 3, 1]
        var bigger = cell
        bigger.requests = 12
        var smaller = cell
        smaller.requests = 4
        var stored = CacheRollup()
        stored.days["2026-11-01"] = CacheSides(main: cell, subagent: cell)
        var fresh = CacheRollup()
        fresh.days["2026-11-01"] = CacheSides(main: bigger, subagent: smaller)
        fresh.days["2026-11-02"] = CacheSides(main: smaller, subagent: CacheCell())
        stored.merge(fresh)
        #expect(stored.days["2026-11-01"]?.main == bigger)
        #expect(stored.days["2026-11-01"]?.subagent == cell)
        #expect(stored.days["2026-11-02"]?.main == smaller)
        let data = try JSONEncoder().encode(stored)
        #expect(try JSONDecoder().decode(CacheRollup.self, from: data) == stored)
    }

    @Test func cacheVerdictUsesTotalData() {
        let calendar = Calendar(identifier: .gregorian)
        var rollup = CacheRollup()
        let keys = (1...10).map { String(format: "2026-11-%02d", $0) }
        for key in keys {
            var main = CacheCell()
            main.requests = 30
            main.inputSideCost = 1
            main.alternativeDelta = 0.2
            rollup.days[key] = CacheSides(main: main, subagent: CacheCell())
        }
        let main = rollup.verdict(dayKeys: keys, side: .main, calendar: calendar)
        #expect(main.outcome == .keep)
        #expect(main.spanDays == 10)
        #expect(abs(main.weeklyDelta - 1.4) < 0.000001)
        // No subagent requests: still a verdict for the range, not "not enough data".
        #expect(rollup.verdict(dayKeys: keys, side: .subagent, calendar: calendar).outcome == .noRequests)
        #expect(rollup.verdict(dayKeys: Array(keys.prefix(3)), side: .main, calendar: calendar).outcome == .notEnoughData)
        var same = rollup
        for key in keys { same.days[key]?.main.alternativeDelta = 0.01 }
        #expect(same.verdict(dayKeys: keys, side: .main, calendar: calendar).outcome == .aboutTheSame)
        for key in keys { same.days[key]?.main.alternativeDelta = -0.5 }
        #expect(same.verdict(dayKeys: keys, side: .main, calendar: calendar).outcome == .switchTTL)
    }

    @Test func rangeWindowCalendarAndRolling() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-11-19T15:00:00Z")!
        let week = RangeWindow.calendar(days: 7, offset: 0, now: now, calendar: calendar)
        #expect(week.dayKeys(calendar: calendar) == (13...19).map { String(format: "2026-11-%02d", $0) })
        let previous = RangeWindow.calendar(days: 7, offset: 1, now: now, calendar: calendar)
        #expect(previous.dayKeys(calendar: calendar).first == "2026-11-06")
        #expect(previous.end == week.start)
        let oldest = CostRollup.date(fromDayKey: "2026-11-09", calendar: calendar)
        #expect(previous.isPartial(oldest: oldest))
        #expect(!previous.canGoBack(oldest: oldest))
        #expect(week.canGoBack(oldest: oldest))
        let today = RangeWindow.calendar(days: 1, offset: 0, now: now, calendar: calendar)
        #expect(today.dayKeys(calendar: calendar) == ["2026-11-19"])
        let rolling = RangeWindow.rolling(hours: 24, offset: 1, now: now, calendar: calendar)
        #expect(rolling.end == now.addingTimeInterval(-86_400))
        #expect(rolling.start == now.addingTimeInterval(-2 * 86_400))
    }

    @Test func cacheScannerRestoresFromCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("p"), withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: storeDir)
        }
        let now = Date()
        let iso = ISO8601DateFormatter()
        func line(_ n: Double, _ id: String, read: Int, write: Int) -> String {
            #"{"timestamp":"\#(iso.string(from: now.addingTimeInterval(n)))","sessionId":"s","type":"assistant","requestId":"\#(id)","promptCacheRequested":"1h","message":{"content":[{"type":"text"}],"model":"opus-5-5","usage":{"cache_read_input_tokens":\#(read),"cache_creation":{"ephemeral_1h_input_tokens":\#(write)}}}}"#
        }
        let file = root.appendingPathComponent("p/s.jsonl")
        func user(_ n: Double) -> String {
            #"{"type":"user","timestamp":"\#(iso.string(from: now.addingTimeInterval(n)))","message":{"content":[{"type":"text"}]}}"#
        }
        try ([user(-610), line(-600, "a", read: 0, write: 2000), user(-70), line(-60, "b", read: 2000, write: 10)].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let catalog = QuotaExtractorRegression.repoCatalog(.claude)
        let provider = LocalUsageProvider(claudeCatalog: QuotaExtractorRegression.isolatedCatalogStore(.claude, catalog))
        let first = try #require(await CacheScanner(provider: provider, store: CacheRollupStore(directory: storeDir)).scan(roots: [root], now: now))
        #expect(first.rollup.days.values.reduce(0) { $0 + $1.main.requests } == 2)
        #expect(first.rows.count == 1)
        // A fresh launch reads the checkpoint and the stored rollup: same numbers, same live row.
        let second = try #require(await CacheScanner(provider: provider, store: CacheRollupStore(directory: storeDir)).scan(roots: [root], now: now))
        #expect(second.rollup == first.rollup)
        #expect(second.rows.map(\.id) == first.rows.map(\.id))
    }
}
