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
        let short = provider.cacheStatistics([mainLine], target: 300)
        #expect(short.hits == 1 && short.modelChanges == 1)
        #expect(abs(short.alternativeDelta - (-0.003 + 0.0048 - 0.0015)) < 0.000001)
        let long = provider.cacheStatistics([agent], target: 3600)
        #expect(long.expired == 1 && !long.eligible)
        #expect(abs(long.alternativeDelta - (0.006 - 0.0078)) < 0.000001)
        let handle = try FileHandle(forWritingTo: main)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((user(-100) + "\n").utf8))
        try handle.close()
        let refreshed = provider.cacheRequests(roots: [root], files: &files, now: now)
        #expect(refreshed.first { $0.first?.agent == nil }?.last?.toolPending == false)
    }
}
