import PastePalLocalization
import Foundation
import CSQLite

public final class HistoryQueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() { lock.withLock { cancelled = true } }
}

// 独立只读事务固定结果顺序，分页不占用写入连接。
public final class HistoryQueryResults: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellation: HistoryQueryCancellation
    private var db: OpaquePointer?
    private let predicate: String
    private let bindings: [String]
    private let pageSize: Int
    private let maximumCachedBytes: Int
    private var pages: [Int: (entries: [HistoryEntry], cost: Int)] = [:]
    private var pageOrder: [Int] = []
    private var cachedBytes = 0
    private var lastLocated: (id: String, index: Int)?
    public private(set) var count = 0
    public var cachedEntryCount: Int { lock.withLock { pages.values.reduce(0) { $0 + $1.entries.count } } }
    public var isEmpty: Bool { count == 0 }
    public var indices: Range<Int> { 0..<count }

    public init(directory: URL, query: String = "", groupID: String? = nil,
                cancellation: HistoryQueryCancellation = HistoryQueryCancellation(), pageSize: Int = 64,
                maximumCachedBytes: Int = 4 * 1_024 * 1_024) throws {
        self.cancellation = cancellation
        self.pageSize = max(1, pageSize); self.maximumCachedBytes = max(0, maximumCachedBytes)
        var clauses = [String](), values = [String]()
        if !query.isEmpty { clauses.append("instr(h.search_text, ?) > 0"); values.append(query.lowercased()) }
        if let groupID {
            clauses.append("EXISTS (SELECT 1 FROM group_memberships gm WHERE gm.entry_id=h.id AND gm.group_id=?)")
            values.append(groupID)
        }
        predicate = clauses.isEmpty ? "1" : clauses.joined(separator: " AND ")
        bindings = values
        guard sqlite3_open_v2(directory.appendingPathComponent("history.sqlite").path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw ClipboardError.database(L("无法打开历史查询"))
        }
        sqlite3_busy_timeout(db, 1000)
        sqlite3_progress_handler(db, 1000, { context in
            guard let context else { return 0 }
            return Unmanaged<HistoryQueryCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
        }, Unmanaged.passUnretained(cancellation).toOpaque())
        do {
            try checkCancellation()
            guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw failure() }
            count = try scalar("SELECT COUNT(*) FROM history h WHERE \(predicate)", values: bindings)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }

    public func entry(at index: Int) throws -> HistoryEntry? {
        try lock.withLock {
            try checkCancellation()
            guard indices.contains(index) else { return nil }
            let page = index / pageSize
            if let cached = pages[page] {
                pageOrder.removeAll { $0 == page }; pageOrder.append(page)
                return cached.entries[index % pageSize]
            }
            let statement = try prepare("SELECT summary FROM history h WHERE \(predicate) ORDER BY activity DESC LIMIT \(pageSize) OFFSET \(page * pageSize)", values: bindings)
            defer { sqlite3_finalize(statement) }
            var entries = [HistoryEntry](), cost = 0
            while true {
                try checkCancellation()
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
                let size = Int(sqlite3_column_bytes(statement, 0))
                entries.append(try JSONDecoder().decode(HistoryEntry.self, from: Data(bytes: bytes, count: size)))
                cost += size
            }
            if cost <= maximumCachedBytes {
                while pageOrder.count >= 4 || cachedBytes + cost > maximumCachedBytes {
                    guard !pageOrder.isEmpty else { break }
                    if let removed = pages.removeValue(forKey: pageOrder.removeFirst()) { cachedBytes -= removed.cost }
                }
                pages[page] = (entries, cost); pageOrder.append(page); cachedBytes += cost
            }
            return entries.indices.contains(index % pageSize) ? entries[index % pageSize] : nil
        }
    }
    public func index(of id: String) throws -> Int? {
        try lock.withLock {
            try checkCancellation()
            if let lastLocated, lastLocated.id == id { return lastLocated.index }
            for (page, cached) in pages {
                if let offset = cached.entries.firstIndex(where: { $0.id == id }) {
                    let index = page * pageSize + offset
                    lastLocated = (id, index)
                    return index
                }
            }
            guard try scalar("SELECT COUNT(*) FROM history h WHERE \(predicate) AND h.id=?", values: bindings + [id]) > 0 else { return nil }
            let index = try scalar("SELECT COUNT(*) FROM history h WHERE \(predicate) AND h.activity > (SELECT activity FROM history WHERE id=?)", values: bindings + [id])
            lastLocated = (id, index)
            return index
        }
    }
    public func allIDs() throws -> [String] {
        try lock.withLock {
            let statement = try prepare("SELECT id FROM history h WHERE \(predicate) ORDER BY activity DESC", values: bindings)
            defer { sqlite3_finalize(statement) }
            var ids = [String]()
            while true {
                try checkCancellation()
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return ids }
                guard result == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw failure() }
                ids.append(String(cString: text))
            }
        }
    }
    private func scalar(_ sql: String, values: [String]) throws -> Int {
        let statement = try prepare(sql, values: values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }
    private func prepare(_ sql: String, values: [String]) throws -> OpaquePointer {
        try checkCancellation()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
        return statement
    }
    private func checkCancellation() throws { if cancellation.isCancelled { throw CancellationError() } }
    private func failure() -> Error {
        cancellation.isCancelled ? CancellationError() : ClipboardError.database(String(cString: sqlite3_errmsg(db)))
    }
}
