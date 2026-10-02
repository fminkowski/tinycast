import Foundation
import SQLite3

nonisolated final class ScreenshotTextCache: Sendable {
    enum Failure: Error { case database(Int32) }
    let url: URL

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try Self.createSchema(at: url)
        } catch Failure.database(let code) where code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(filePath: url.path + suffix)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            try Self.createSchema(at: url)
        }
    }

    func reconcile(_ items: [ScreenshotItem]) throws {
        let database = try Connection(url: url)
        let revisions = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.revision) })
        try database.transaction {
            var current: [String: String] = [:]
            try database.query("SELECT path, revision FROM recognition") { statement in
                current[Self.string(statement, 0)] = Self.string(statement, 1)
            }
            for (path, revision) in current where revisions[path] != revision {
                try Task.checkCancellation()
                try database.execute("DELETE FROM ocr WHERE path = ?", strings: [path])
                try database.execute("DELETE FROM recognition WHERE path = ?", strings: [path])
            }
            for item in items where current[item.id] != item.revision {
                try Task.checkCancellation()
                try database.execute("INSERT INTO recognition(path, revision) VALUES (?, ?)", strings: [item.id, item.revision])
            }
        }
    }

    func nextPending(in items: [ScreenshotItem], at now: Date) throws -> ScreenshotItem? {
        let database = try Connection(url: url)
        var pending: [String: String] = [:]
        try database.query("SELECT path, revision FROM recognition WHERE complete = 0 AND retry_at <= ?",
                           doubles: [now.timeIntervalSince1970]) { statement in
            pending[Self.string(statement, 0)] = Self.string(statement, 1)
        }
        return items.first { pending[$0.id] == $0.revision }
    }

    func nextRetry() throws -> Date? {
        let database = try Connection(url: url)
        var retry: Date?
        try database.query("SELECT min(retry_at) FROM recognition WHERE complete = 0") { statement in
            if sqlite3_column_type(statement, 0) != SQLITE_NULL {
                retry = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            }
        }
        return retry
    }

    func store(_ text: String, for item: ScreenshotItem) throws {
        let database = try Connection(url: url)
        try database.transaction {
            var current = false
            try database.query("SELECT revision FROM recognition WHERE path = ?", strings: [item.id]) {
                current = Self.string($0, 0) == item.revision
            }
            guard current else { return }
            try database.execute("DELETE FROM ocr WHERE path = ?", strings: [item.id])
            try database.execute("INSERT INTO ocr(path, text) VALUES (?, ?)", strings: [item.id, text])
            try database.execute("UPDATE recognition SET complete = 1 WHERE path = ? AND revision = ?",
                                 strings: [item.id, item.revision])
        }
    }

    func recordFailure(for item: ScreenshotItem, retryAt: Date) throws {
        let database = try Connection(url: url)
        try database.execute("UPDATE recognition SET retry_at = ? WHERE path = ? AND revision = ?",
                             strings: [item.id, item.revision], doubles: [retryAt.timeIntervalSince1970])
    }

    func matches(_ term: String) throws -> Set<String> {
        try matchingTerms([term])[term] ?? []
    }

    func matchingTerms(_ terms: [String]) throws -> [String: Set<String>] {
        let database = try Connection(url: url)
        var matches: [String: Set<String>] = [:]
        for term in terms {
            var paths: Set<String> = []
            if term.count >= 3 {
                let quoted = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                try database.query("SELECT path FROM ocr WHERE ocr MATCH ?", strings: [quoted]) {
                    paths.insert(Self.string($0, 0))
                }
            } else {
                try database.query("SELECT path FROM ocr WHERE instr(lower(text), lower(?)) > 0", strings: [term]) {
                    paths.insert(Self.string($0, 0))
                }
            }
            matches[term] = paths
        }
        return matches
    }

    private static func createSchema(at url: URL) throws {
        let database = try Connection(url: url, create: true)
        try database.execute("PRAGMA journal_mode=WAL")
        try database.execute("""
            CREATE TABLE IF NOT EXISTS recognition (
                path TEXT PRIMARY KEY, revision TEXT NOT NULL, complete INTEGER NOT NULL DEFAULT 0,
                retry_at REAL NOT NULL DEFAULT 0
            )
            """)
        try database.execute("CREATE VIRTUAL TABLE IF NOT EXISTS ocr USING fts5(path UNINDEXED, text, tokenize='trigram')")
    }

    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let text = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: text)
    }

    private final class Connection {
        private var handle: OpaquePointer?
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        init(url: URL, create: Bool = false) throws {
            let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
            let code = sqlite3_open_v2(url.path, &handle, flags, nil)
            guard code == SQLITE_OK else {
                sqlite3_close(handle)
                handle = nil
                throw Failure.database(code)
            }
            sqlite3_busy_timeout(handle, 500)
            sqlite3_exec(handle, "PRAGMA cache_size=-2048", nil, nil, nil)
            sqlite3_progress_handler(handle, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        }

        deinit { sqlite3_close(handle) }

        func transaction(_ operation: () throws -> Void) throws {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try operation()
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }

        func execute(_ sql: String, strings: [String] = [], doubles: [Double] = []) throws {
            try query(sql, strings: strings, doubles: doubles) { _ in }
        }

        func query(
            _ sql: String, strings: [String] = [], doubles: [Double] = [], row: (OpaquePointer) -> Void
        ) throws {
            try Task.checkCancellation()
            var prepared: OpaquePointer?
            let code = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
            guard code == SQLITE_OK, let prepared else { throw Failure.database(code) }
            defer { sqlite3_finalize(prepared) }
            for (index, value) in doubles.enumerated() {
                sqlite3_bind_double(prepared, Int32(index + 1), value)
            }
            for (index, value) in strings.enumerated() {
                sqlite3_bind_text(prepared, Int32(doubles.count + index + 1), value, -1, Self.transient)
            }
            var status = sqlite3_step(prepared)
            while status == SQLITE_ROW {
                try Task.checkCancellation()
                row(prepared)
                status = sqlite3_step(prepared)
            }
            if status == SQLITE_INTERRUPT, Task.isCancelled { throw CancellationError() }
            guard status == SQLITE_DONE else { throw Failure.database(status) }
        }
    }
}
