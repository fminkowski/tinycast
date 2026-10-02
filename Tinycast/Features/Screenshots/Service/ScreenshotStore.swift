import CoreGraphics
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class ScreenshotStore {
    enum State { case disabled, loading, ready, failed }
    private(set) var items: [ScreenshotItem] = []
    private(set) var state: State = .disabled
    private(set) var folder: URL
    private(set) var version = 0
    @ObservationIgnored var onResultsChanged: (([ScreenshotItem], [ScreenshotItem]) -> Void)?
    @ObservationIgnored var onFailure: (() -> Void)?
    @ObservationIgnored private var cache: ScreenshotTextCache?
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let scan: @Sendable (URL) async throws -> [ScreenshotItem]
    @ObservationIgnored private let extract: @Sendable (URL) async throws -> String
    @ObservationIgnored private let canRun: () -> Bool
    @ObservationIgnored private let retryDelay: TimeInterval
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var recognitionTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var searchGeneration = UUID()
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var reportedCacheFailure = false
    @ObservationIgnored private var lastQuery = ""
    @ObservationIgnored private var lastResults: [ScreenshotItem]?
    @ObservationIgnored private var recognized: [String: Set<String>] = [:]
    @ObservationIgnored private var recognizedRevisions: [String: String] = [:]
    private static let logger = Logger(subsystem: "com.tinycast", category: "Screenshots")

    init(
        folder: URL, cacheURL: URL, retryDelay: TimeInterval = 30,
        canRun: @escaping () -> Bool = {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null) >= 2
        },
        scan: @escaping @Sendable (URL) async throws -> [ScreenshotItem] = ScreenshotStore.scanFolder,
        extract: @escaping @Sendable (URL) async throws -> String = { try await TextRecognitionWorker.extract(at: $0) }
    ) {
        self.folder = folder
        self.cacheURL = cacheURL
        self.retryDelay = retryDelay
        self.canRun = canRun
        self.scan = scan
        self.extract = extract
    }

    isolated deinit {
        scanTask?.cancel()
        recognitionTask?.cancel()
        searchTask?.cancel()
    }

    func start(folder: URL) {
        stop()
        self.folder = folder
        enabled = true
        state = .loading
        refresh()
    }

    func stop() {
        enabled = false
        generation = UUID()
        searchGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        searchTask?.cancel()
        recognitionTask?.cancel()
        cache = nil
        items = []
        lastResults = nil
        recognized = [:]
        recognizedRevisions = [:]
        refreshRequested = false
        reportedCacheFailure = false
        state = .disabled
        version += 1
    }

    func refresh() {
        guard enabled else { return }
        guard scanTask == nil else {
            refreshRequested = true
            return
        }
        let generation = generation
        let folder = folder
        let cacheURL = cacheURL
        let cache = cache
        let scan = scan
        scanTask = Task { [weak self] in
            defer {
                if let self, self.generation == generation {
                    self.scanTask = nil
                    if self.refreshRequested {
                        self.refreshRequested = false
                        self.refresh()
                    }
                }
            }
            do {
                let scanned = try await scan(folder)
                try Task.checkCancellation()
                guard let self, self.enabled, self.generation == generation else { return }
                let changed = self.items != scanned
                do {
                    let worker = Task.detached(priority: .utility) {
                        let cache = try cache ?? ScreenshotTextCache(url: cacheURL)
                        try cache.reconcile(scanned)
                        return cache
                    }
                    let ready = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    guard self.generation == generation else { return }
                    self.cache = ready
                    self.reportedCacheFailure = false
                } catch is CancellationError {
                    return
                } catch {
                    guard self.generation == generation else { return }
                    self.cache = nil
                    if !self.reportedCacheFailure { self.onFailure?() }
                    self.reportedCacheFailure = true
                }
                self.items = scanned
                self.state = .ready
                if changed { self.publish() } else { self.scheduleSearch() }
                self.scheduleRecognition()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.items = []
                self.state = .failed
                self.publish()
                Self.logger.error("Screenshot folder unavailable: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func search(_ query: String) -> [ScreenshotItem] {
        _ = version
        if lastQuery == query, let lastResults { return lastResults }
        if lastQuery != query {
            recognized = [:]
            recognizedRevisions = [:]
        }
        lastQuery = query
        lastResults = filteredResults()
        scheduleSearch()
        return lastResults ?? []
    }

    private func filteredResults() -> [ScreenshotItem] {
        let terms = lastQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        let recognized = recognized
        let revisions = recognizedRevisions
        return Array(items.lazy.filter { item in
            terms.allSatisfy { term in
                item.matchesMetadata(term)
                    || (revisions[item.id] == item.revision && recognized[term]?.contains(item.id) == true)
            }
        }.prefix(1000))
    }

    private func publish() {
        let previous = lastResults ?? []
        lastResults = filteredResults()
        version += 1
        onResultsChanged?(previous, lastResults ?? [])
        scheduleSearch()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchGeneration = UUID()
        let terms = lastQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        guard enabled, !terms.isEmpty, let cache else { return }
        let generation = generation
        let request = searchGeneration
        let revisions = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.revision) })
        searchTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try cache.matchingTerms(terms) }
            do {
                let matches = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.enabled, self.generation == generation, self.searchGeneration == request else { return }
                self.recognized = matches
                self.recognizedRevisions = revisions
                let previous = self.lastResults ?? []
                self.lastResults = self.filteredResults()
                self.version += 1
                self.onResultsChanged?(previous, self.lastResults ?? [])
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Screenshot text search failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func scheduleRecognition() {
        guard enabled, cache != nil, recognitionTask == nil else { return }
        let generation = generation
        let extract = extract
        recognitionTask = Task(priority: .background) { [weak self] in
            defer {
                self?.recognitionTask = nil
                if self?.enabled == true, self?.generation != generation { self?.scheduleRecognition() }
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.enabled, self.generation == generation, let cache = self.cache else { return }
                guard self.canRun() else { continue }
                let items = self.items
                let worker = Task.detached(priority: .background) {
                    (try cache.nextPending(in: items, at: Date()), try cache.nextRetry())
                }
                let pending = try? await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, self.generation == generation else { return }
                guard let item = pending?.0 else {
                    guard let retry = pending?.1 else { return }
                    do { try await Task.sleep(for: .seconds(max(0.25, retry.timeIntervalSinceNow))) } catch { return }
                    continue
                }
                do {
                    let text = try await extract(item.url)
                    try Task.checkCancellation()
                    guard self.enabled, self.generation == generation,
                        self.items.contains(where: { $0.id == item.id && $0.revision == item.revision })
                    else { continue }
                    let writer = Task.detached(priority: .background) { try cache.store(text, for: item) }
                    try await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
                    try Task.checkCancellation()
                    guard self.generation == generation else { return }
                    self.publish()
                } catch is CancellationError {
                    return
                } catch {
                    guard self.generation == generation, !Task.isCancelled else { return }
                    let retryAt = Date().addingTimeInterval(self.retryDelay)
                    let writer = Task.detached(priority: .background) { try cache.recordFailure(for: item, retryAt: retryAt) }
                    _ = try? await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
                    Self.logger.error("Screenshot recognition failed: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    nonisolated private static func scanFolder(_ folder: URL) async throws -> [ScreenshotItem] {
        let worker = Task.detached(priority: .utility) { try ScreenshotRepository.scan(folder) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
