import Combine
import Foundation

/// A conversation line whose prompt cache is still warm.
struct LiveCacheRow: Identifiable, Equatable {
    let id: String
    let project: String
    let slug: String
    let side: CacheSide
    let ttl: Double
    let inferredTTL: Bool
    let toolPending: Bool
    let expiry: Date
    let prefixTokens: Int
    /// API-equivalent cost of writing the prefix again once it expires.
    let rewriteCost: Double?
}

struct CacheScan {
    var rows: [LiveCacheRow] = []
    var rollup = CacheRollup()
    var scannedAt = Date.distantPast
}

/// Reads Claude transcripts incrementally and keeps each log folder's
/// rollup and read checkpoint in `CacheRollupStore`.
actor CacheScanner {
    static let checkpointInterval: TimeInterval = 300

    private let provider: LocalUsageProvider
    private let store: CacheRollupStore
    private let calendar: Calendar
    private var files: [String: [URL: LocalUsageProvider.CacheFile]] = [:]
    private var loaded: Set<String> = []
    private var checkpointSaved: [String: (at: Date, signature: Int)] = [:]

    init(provider: LocalUsageProvider = LocalUsageProvider(), store: CacheRollupStore = .shared,
         calendar: Calendar = .current) {
        self.provider = provider
        self.store = store
        self.calendar = calendar
    }

    /// What is already on disk, for showing something before the first scan ends.
    func stored(roots: [URL]) -> CacheRollup {
        CacheRollup.combined(roots.map { store.rollup(key: CacheRollupStore.key(for: $0)) })
    }

    /// Scans every root, merges into the stored rollups and returns the
    /// combined result. nil when cancelled.
    func scan(roots: [URL], now: Date = Date()) -> CacheScan? {
        var rows: [LiveCacheRow] = []
        var rollups: [CacheRollup] = []
        // Requests before yesterday leave memory and the checkpoint; their
        // days are complete in the stored rollup, which a smaller scan never shrinks.
        let cutoff = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        for root in Set(roots).sorted(by: { $0.path < $1.path }) {
            let key = CacheRollupStore.key(for: root)
            restoreIfNeeded(key: key)
            var state = files[key] ?? [:]
            let lines = provider.cacheRequests(roots: [root], files: &state, now: now)
            guard !Task.isCancelled else { return nil }
            rollups.append(store.merge(provider.cacheRollup(lines, calendar: calendar), key: key, now: now))
            state = state.mapValues { $0.pruned(before: cutoff) }
            files[key] = state
            saveCheckpointIfNeeded(state, key: key, now: now)
            for line in lines {
                guard let last = line.last, last.prefix > 0, last.expiry > now else { continue }
                rows.append(LiveCacheRow(
                    id: "\(key)/\(last.session)/\(last.agent ?? "")",
                    project: last.project, slug: last.slug,
                    side: last.agent == nil ? .main : .subagent,
                    ttl: last.ttl, inferredTTL: last.inferred, toolPending: last.toolPending,
                    expiry: last.expiry, prefixTokens: last.prefix,
                    rewriteCost: provider.rewriteCost(last)))
            }
        }
        return CacheScan(rows: rows.sorted { $0.expiry < $1.expiry },
                         rollup: CacheRollup.combined(rollups), scannedAt: now)
    }

    private func restoreIfNeeded(key: String) {
        guard !loaded.contains(key) else { return }
        loaded.insert(key)
        // A checkpoint without its rollup would skip days nothing holds any more.
        guard !store.rollup(key: key).isEmpty, let checkpoint = store.checkpoint(key: key) else { return }
        files[key] = Dictionary(uniqueKeysWithValues: checkpoint.files.map { (URL(fileURLWithPath: $0.key), $0.value) })
        checkpointSaved[key] = (checkpoint.savedAt, Self.signature(files[key] ?? [:]))
    }

    private func saveCheckpointIfNeeded(_ state: [URL: LocalUsageProvider.CacheFile], key: String, now: Date) {
        let signature = Self.signature(state)
        if let saved = checkpointSaved[key],
           saved.signature == signature || now.timeIntervalSince(saved.at) < Self.checkpointInterval { return }
        var checkpoint = CacheCheckpoint(savedAt: now)
        for (url, file) in state { checkpoint.files[url.path] = file }
        store.saveCheckpoint(checkpoint, key: key)
        checkpointSaved[key] = (now, signature)
    }

    private static func signature(_ state: [URL: LocalUsageProvider.CacheFile]) -> Int {
        var hasher = Hasher()
        for (url, file) in state.sorted(by: { $0.key.path < $1.key.path }) {
            hasher.combine(url.path)
            hasher.combine(file.offset)
            hasher.combine(file.requests.count)
        }
        return hasher.finalize()
    }
}

/// Keeps scanning in the background, whether or not the panel is open:
/// every 25 s while the Cache tab is shown, every 2 min otherwise.
@MainActor
final class CacheMonitor: ObservableObject {
    static let focusedInterval: TimeInterval = 25
    static let backgroundInterval: TimeInterval = 120

    @Published private(set) var rows: [LiveCacheRow] = []
    @Published private(set) var rollup = CacheRollup()
    @Published private(set) var updatedAt: Date?
    /// True until the first scan of this launch finishes.
    @Published private(set) var isLoading = true

    private let scanner = CacheScanner()
    private var roots: @MainActor () -> [URL] = { [] }
    private var loop: Task<Void, Never>?
    private var isFocused = false
    private var isScanning = false

    func start(roots: @escaping @MainActor () -> [URL]) {
        self.roots = roots
        restart()
    }

    /// The Cache tab is shown (true) or left (false).
    func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        // A scan in progress keeps going (a cold one takes seconds); the loop
        // then waits the shorter interval.
        if focused && !isScanning { restart() }
    }

    private func restart() {
        loop?.cancel()
        loop = Task { [weak self] in
            guard let self else { return }
            let roots = self.roots()
            if self.rollup.isEmpty {
                let stored = await self.scanner.stored(roots: roots)
                if self.rollup.isEmpty { self.rollup = stored }
            }
            while !Task.isCancelled {
                let roots = self.roots()
                self.isScanning = true
                let result = await self.scanner.scan(roots: roots)
                self.isScanning = false
                if let scan = result, !Task.isCancelled {
                    self.rows = scan.rows
                    self.rollup = scan.rollup
                    self.updatedAt = scan.scannedAt
                    self.isLoading = false
                }
                let interval = self.isFocused ? Self.focusedInterval : Self.backgroundInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
}
