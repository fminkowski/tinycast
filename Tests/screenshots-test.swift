import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

@main
@MainActor
struct ScreenshotTests {
    static var failures = 0
    static var passes = 0

    static func main() async throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "tinycast-screenshots-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try namingAndFolders(scratch)
        try geometryAndScanning(scratch)
        try cacheInvalidation(scratch)
        try orientedImageCopy(scratch)
        try await libraryLifecycle(scratch)
        try await staleScan(scratch)
        try await changedFileBarrier(scratch)
        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    static func namingAndFolders(_ scratch: URL) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let date = Date(timeIntervalSince1970: 1_759_392_000)
        let first = ScreenshotNaming.filename(at: date, calendar: calendar, identifier: UUID())
        let second = ScreenshotNaming.filename(at: date, calendar: calendar, identifier: UUID())
        expect(first.hasPrefix("Screenshot ") && first.hasSuffix(".png"), "timestamped PNG filename")
        expect(first != second && !first.contains("/"), "same-second captures receive unique safe filenames")
        let stable = ScreenshotRepository.folder(chosen: nil, home: scratch, bundleID: "com.tinycast.app")
        let dev = ScreenshotRepository.folder(chosen: nil, home: scratch, bundleID: "com.tinycast.app.dev")
        let beta = ScreenshotRepository.folder(chosen: nil, home: scratch, bundleID: "com.tinycast.app.beta")
        expect(Set([stable, dev, beta]).count == 3, "default folder isolates every channel")
        expect(!FileManager.default.fileExists(atPath: stable.path), "resolving a default creates no folder")
        let chosen = ScreenshotRepository.folder(chosen: "~/Shots", home: scratch, bundleID: "com.tinycast.app")
        expect(chosen.path == scratch.appending(path: "Shots").path, "tilde folder uses the injected home")
        let png = try fixturePNG()
        let id = UUID()
        let saved = try ScreenshotRepository.save(png, in: stable, at: date, identifier: id)
        expect(try Data(contentsOf: saved) == png, "first capture creates its folder and saves the original PNG")
        do {
            _ = try ScreenshotRepository.save(png, in: stable, at: date, identifier: id)
            expect(false, "existing screenshot cannot be overwritten")
        } catch { expect(true, "existing screenshot cannot be overwritten") }
        expect(try Data(contentsOf: saved) == png, "collision preserves the existing screenshot")
    }

    static func geometryAndScanning(_ scratch: URL) throws {
        let rect = ScreenshotGeometry.rectangle(from: CGPoint(x: 100, y: 200), to: CGPoint(x: -50, y: 30))
        expect(rect == CGRect(x: -50, y: 30, width: 150, height: 170), "area selection normalizes reverse drags")
        let converted = ScreenshotGeometry.captureRectangle(rect, primaryTop: 900)
        expect(converted == CGRect(x: -50, y: 700, width: 150, height: 170), "capture geometry handles negative display origins")
        expect(ScreenshotGeometry.captureRectangle(converted, primaryTop: 900) == rect, "coordinate conversion round trips")
        let folder = scratch.appending(path: "scan")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = try fixturePNG()
        try png.write(to: folder.appending(path: "Invoice.png"))
        try png.write(to: folder.appending(path: ".hidden.png"))
        try Data("ordinary text".utf8).write(to: folder.appending(path: "notes.txt"))
        let nested = folder.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try png.write(to: nested.appending(path: "deep.png"))
        let items = try ScreenshotRepository.scan(folder)
        expect(items.count == 1 && items[0].name == "Invoice.png",
               "only top-level visible supported images are listed")
        expect(items[0].pixelWidth == 8 && items[0].pixelHeight == 6,
               "image metadata is read without full-size preview decoding")
        expect(items[0].matchesMetadata("invoice") && items[0].matchesMetadata(items[0].dateLabel),
               "filename and date are searchable")
        try FileManager.default.moveItem(at: items[0].url, to: folder.appending(path: "Renamed.png"))
        let renamed = try ScreenshotRepository.scan(folder)
        expect(renamed[0].fileIdentity == items[0].fileIdentity, "file identity survives a rename")
        expect(try ScreenshotRepository.png(at: renamed[0].url) == png, "existing PNG copies without decoding")
        expect(try ScreenshotRepository.scan(scratch.appending(path: "absent")).isEmpty, "missing default folder starts empty")
        let wrong = folder.appending(path: "notes.txt")
        do {
            _ = try ScreenshotRepository.png(at: wrong)
            expect(false, "unreadable image is refused")
        } catch { expect(true, "unreadable image is refused") }
    }

    static func cacheInvalidation(_ scratch: URL) throws {
        let url = scratch.appending(path: "cache.sqlite3")
        var cache = try ScreenshotTextCache(url: url)
        let old = item(scratch.appending(path: "cache.png"), revision: "old")
        try cache.reconcile([old])
        try cache.store("Alpine invoice 7391", for: old)
        expect(try cache.matches("invoice") == [old.id], "FTS finds recognized text")
        expect(try cache.matches("ALPINE") == [old.id], "OCR search is case insensitive")
        expect(try cache.matches("73") == [old.id], "short OCR queries are supported")
        expect(try cache.matches("\" OR *").isEmpty, "FTS punctuation is safely quoted")
        cache = try ScreenshotTextCache(url: url)
        expect(try cache.matches("invoice") == [old.id], "recognized text survives reopening")
        let changed = item(old.url, revision: "new")
        try cache.reconcile([changed])
        expect(try cache.matches("invoice").isEmpty, "changed files lose stale OCR")
        try cache.store("stale result", for: old)
        expect(try cache.matches("stale").isEmpty, "late old-revision output is rejected")
        let now = Date(timeIntervalSince1970: 100)
        expect(try cache.nextPending(in: [old], at: now) == nil, "queued recognition rejects an old file snapshot")
        try cache.recordFailure(for: changed, retryAt: now.addingTimeInterval(30))
        expect(try cache.nextPending(in: [changed], at: now) == nil, "failed recognition backs off")
        expect(try cache.nextPending(in: [changed], at: now.addingTimeInterval(31)) == changed,
               "failed recognition retries later")
        try cache.store("fresh result", for: changed)
        expect(try cache.nextPending(in: [changed], at: now.addingTimeInterval(31)) == nil,
               "successful recognition is not repeated")
        try cache.reconcile([])
        expect(try cache.matches("fresh").isEmpty, "deleted files lose derived text")
        let corrupt = scratch.appending(path: "corrupt.sqlite3")
        try Data("broken SQLite cache".utf8).write(to: corrupt)
        let rebuilt = try ScreenshotTextCache(url: corrupt)
        try rebuilt.reconcile([old])
        expect(try rebuilt.nextPending(in: [old], at: now) == old, "corrupt derived cache rebuilds for recognition")
    }

    static func orientedImageCopy(_ scratch: URL) throws {
        let original = try fixturePNG()
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw CocoaError(.fileReadCorruptFile) }
        let jpeg = scratch.appending(path: "rotated.jpg")
        guard let destination = CGImageDestinationCreateWithURL(jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        let copied = try ScreenshotRepository.png(at: jpeg)
        let converted = CGImageSourceCreateWithData(copied as CFData, nil)
        let decoded = converted.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        expect(decoded?.width == 6 && decoded?.height == 8, "copy rotates JPEG pixels at full resolution")
        let metadata = try ScreenshotRepository.scan(scratch).first { $0.name == jpeg.lastPathComponent }
        expect(metadata?.pixelWidth == 6 && metadata?.pixelHeight == 8, "metadata respects displayed image orientation")
        let later = item(scratch.appending(path: "later.png"), revision: "one")
        let earlier = ScreenshotItem(
            url: scratch.appending(path: "earlier.png"), fileIdentity: "earlier", revision: "two",
            createdAt: Date(timeIntervalSince1970: 50), dateLabel: "Jan 1", byteCount: 1, pixelWidth: 1, pixelHeight: 1)
        expect([earlier, later].sorted(by: ScreenshotItem.newestFirst) == [later, earlier], "newest image sorts first")
    }

    static func libraryLifecycle(_ scratch: URL) async throws {
        let first = scratch.appending(path: "first")
        let second = scratch.appending(path: "second")
        for folder in [first, second] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let png = try fixturePNG()
        try png.write(to: first.appending(path: "one.png"))
        try png.write(to: second.appending(path: "two.png"))
        let probe = ExtractionProbe()
        let store = ScreenshotStore(
            folder: first, cacheURL: scratch.appending(path: "lifecycle.sqlite3"), retryDelay: 0.01,
            canRun: { true }, extract: { url in try await probe.extract(url) })
        expect(store.state == .disabled && store.items.isEmpty, "disabled library performs no scan or OCR")
        store.start(folder: first)
        await wait { probe.pending != nil }
        expect(store.search("one").count == 1, "metadata appears before OCR finishes")
        store.start(folder: second)
        await wait { store.items.first?.name == "two.png" }
        probe.release("oldsecret")
        await wait { probe.pending != nil }
        expect(store.search("oldsecret").isEmpty, "switching folders cannot publish stale OCR")
        probe.release("Invoice alpine 7391")
        await wait { store.search("alpine").count == 1 }
        await wait { store.search("two alpine").count == 1 }
        expect(store.search("two alpine").count == 1, "each term can match filename or OCR")
        expect(probe.maximumActive == 1, "recognition stays serialized across folder changes")
        expect(FileManager.default.fileExists(atPath: first.appending(path: "one.png").path),
               "switching folders never moves files")
        probe.failNext = true
        try png.write(to: second.appending(path: "retry.png"))
        store.refresh()
        await wait { probe.failures == 1 }
        await wait { probe.pending != nil }
        probe.release("Retry success")
        await wait { store.search("success").count == 1 }
        expect(store.search("success").first?.name == "retry.png", "recognition failure retries without hiding the image")
        store.stop()
        expect(store.items.isEmpty && store.search("Invoice").isEmpty && store.state == .disabled,
               "disable clears resident library and search")
        probe.release("late disabled result")
    }

    static func staleScan(_ scratch: URL) async throws {
        let first = scratch.appending(path: "old-scan")
        let second = scratch.appending(path: "new-scan")
        let probe = ScanProbe()
        let store = ScreenshotStore(
            folder: first, cacheURL: scratch.appending(path: "stale-scan.sqlite3"), canRun: { false },
            scan: { url in await probe.scan(url) })
        store.start(folder: first)
        await wait { probe.waiters[first.path] != nil }
        store.start(folder: second)
        await wait { probe.waiters[second.path] != nil }
        probe.release(second, items: [item(second.appending(path: "new.png"), revision: "new")])
        await wait { store.items.count == 1 }
        probe.release(first, items: [item(first.appending(path: "old.png"), revision: "old")])
        try await Task.sleep(for: .milliseconds(50))
        expect(store.items.first?.name == "new.png", "cancelled old scan cannot replace the new folder")
        store.stop()
    }

    static func changedFileBarrier(_ scratch: URL) async throws {
        let folder = scratch.appending(path: "changed-file")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "existing.png")
        try fixturePNG().write(to: url)
        let old = try ScreenshotRepository.scan(folder)[0]
        let cacheURL = scratch.appending(path: "changed-file.sqlite3")
        let cache = try ScreenshotTextCache(url: cacheURL)
        try cache.reconcile([old])
        try cache.store("old recognized secret", for: old)
        let store = ScreenshotStore(folder: folder, cacheURL: cacheURL, canRun: { false })
        store.start(folder: folder)
        await wait { store.state == .ready }
        await wait { store.search("secret").count == 1 }
        var database: OpaquePointer?
        guard sqlite3_open(cacheURL.path, &database) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(database) }
        sqlite3_exec(database, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        store.refresh()
        try await Task.sleep(for: .milliseconds(100))
        expect(store.items.first?.revision == old.revision, "refresh publishes changed files after OCR invalidation")
        sqlite3_exec(database, "COMMIT", nil, nil, nil)
        await wait { store.items.first?.revision != old.revision }
        expect(store.search("secret").isEmpty, "changed image cannot inherit cached old text")
        _ = store.search("secret")
        _ = store.search("existing")
        try await Task.sleep(for: .milliseconds(50))
        expect(store.search("existing").count == 1, "superseded OCR query cannot replace current metadata results")
        store.stop()
        let gate = ScanProbe()
        let cancelled = Task.detached {
            _ = await gate.scan(folder)
            return try cache.matches("secret")
        }
        await wait { gate.waiters[folder.path] != nil }
        cancelled.cancel()
        gate.release(folder, items: [])
        do {
            _ = try await cancelled.value
            expect(false, "cancelled cache query throws")
        } catch is CancellationError { expect(true, "cancelled cache query throws") }
    }

    static func fixturePNG() throws -> Data {
        guard let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return try ScreenshotRepository.png(image)
    }

    static func item(_ url: URL, revision: String) -> ScreenshotItem {
        ScreenshotItem(url: url, fileIdentity: url.path, revision: revision, createdAt: Date(timeIntervalSince1970: 100),
                       dateLabel: "Jan 1, 1970", byteCount: 20, pixelWidth: 8, pixelHeight: 6)
    }

    static func wait(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        expect(false, "asynchronous operation completed within five seconds")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if condition { passes += 1 } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }
}

@MainActor
private final class ExtractionProbe {
    var pending: CheckedContinuation<String, Never>?
    var failNext = false
    var failures = 0
    var active = 0
    var maximumActive = 0

    func extract(_ url: URL) async throws -> String {
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if failNext {
            failNext = false
            failures += 1
            throw CocoaError(.fileReadUnknown)
        }
        return await withCheckedContinuation { pending = $0 }
    }

    func release(_ text: String) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: text)
    }
}

@MainActor
private final class ScanProbe {
    var waiters: [String: CheckedContinuation<[ScreenshotItem], Never>] = [:]

    func scan(_ folder: URL) async -> [ScreenshotItem] {
        await withCheckedContinuation { waiters[folder.path] = $0 }
    }

    func release(_ folder: URL, items: [ScreenshotItem]) {
        waiters.removeValue(forKey: folder.path)?.resume(returning: items)
    }
}
