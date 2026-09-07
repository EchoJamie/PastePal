import PastePalLocalization
import Foundation
import CSQLite
import CryptoKit

public final class HistoryStore: @unchecked Sendable {
    public enum Checkpoint { case beforeFileWrite, beforeCommit, beforeMarkUsed, beforeCleanup }
    public let directory: URL
    public let imageDirectory: URL
    private let queue = DispatchQueue(label: "local.pastepal.history")
    private var db: OpaquePointer?
    private let fault: ((Checkpoint) throws -> Void)?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var maintenanceWarning: String?
    public var cleanupWarning: String? { queue.sync { maintenanceWarning } }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directory: URL, fault: ((Checkpoint) throws -> Void)? = nil) throws {
        self.directory = directory; self.fault = fault
        imageDirectory = directory.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let code = sqlite3_open_v2(directory.appendingPathComponent("history.sqlite").path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else { if let db { sqlite3_close(db) }; db = nil; throw ClipboardError.database(L("无法打开数据库")) }
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA busy_timeout=3000")
            try execute("PRAGMA foreign_keys=ON")
            try execute("CREATE TABLE IF NOT EXISTS history (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL UNIQUE, activity INTEGER NOT NULL, payload BLOB NOT NULL)")
            let historyColumns = try tableColumns("history")
            if !historyColumns.contains("summary") { try execute("ALTER TABLE history ADD COLUMN summary BLOB") }
            if !historyColumns.contains("search_text") { try execute("ALTER TABLE history ADD COLUMN search_text TEXT") }
            try execute("CREATE INDEX IF NOT EXISTS history_activity ON history(activity DESC)")
            try execute("CREATE TABLE IF NOT EXISTS counters (id INTEGER PRIMARY KEY CHECK(id=1), value INTEGER NOT NULL)")
            try execute("INSERT OR IGNORE INTO counters VALUES (1,0)")
            try execute("CREATE TABLE IF NOT EXISTS clip_groups (id TEXT PRIMARY KEY, name TEXT NOT NULL COLLATE NOCASE UNIQUE, position INTEGER NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS clip_groups_position ON clip_groups(position ASC)")
            try execute("CREATE TABLE IF NOT EXISTS group_memberships (group_id TEXT NOT NULL REFERENCES clip_groups(id) ON DELETE CASCADE, entry_id TEXT NOT NULL REFERENCES history(id) ON DELETE CASCADE, created_at REAL NOT NULL, PRIMARY KEY(group_id,entry_id))")
            try execute("CREATE INDEX IF NOT EXISTS group_memberships_entry ON group_memberships(entry_id)")
            try execute("CREATE TABLE IF NOT EXISTS history_assets (entry_id TEXT NOT NULL REFERENCES history(id) ON DELETE CASCADE, file TEXT NOT NULL, PRIMARY KEY(entry_id,file))")
            try execute("CREATE INDEX IF NOT EXISTS history_assets_file ON history_assets(file)")
            try execute("CREATE TABLE IF NOT EXISTS schema_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try rebuildDerivedDataIfNeeded()
            try migrateActivityTimeIfNeeded()
            attemptCleanupUnlocked()
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }

    public func entries(query: String = "", filter: HistoryFilter = .all) throws -> [HistoryEntry] {
        try queue.sync { try entriesUnlocked().filter { $0.matches(query: query, filter: filter) } }
    }
    public func snapshot() throws -> HistorySnapshot {
        try queue.sync {
            HistorySnapshot(entries: try summariesUnlocked(), groups: try groupsUnlocked(), groupEntryIDs: try groupEntryIDsUnlocked())
        }
    }
    public func summaries(query: String = "", filter: HistoryFilter = .all) throws -> [HistoryEntry] {
        try queue.sync { try summariesUnlocked(query: query).filter { $0.matches(query: "", filter: filter) } }
    }
    public func groups() throws -> [ClipGroup] { try queue.sync { try groupsUnlocked() } }
    public func groupIDs(for entryID: String) throws -> Set<String> {
        try queue.sync { try stringSet("SELECT group_id FROM group_memberships WHERE entry_id=?", value: entryID) }
    }
    public func entryIDs(in groupID: String) throws -> Set<String> {
        try queue.sync { try stringSet("SELECT entry_id FROM group_memberships WHERE group_id=?", value: groupID) }
    }
    public func contains(id: String) throws -> Bool {
        try queue.sync { try scalarInt64("SELECT COUNT(*) FROM history WHERE id=?", strings: [id]) > 0 }
    }
    public func overview(maximumEntries: Int = 128) throws -> HistoryOverview {
        try queue.sync {
            HistoryOverview(entries: try summariesUnlocked(maximumEntries: max(0, maximumEntries)),
                            groups: try groupsUnlocked(), count: Int(try scalarInt64("SELECT COUNT(*) FROM history")))
        }
    }
    public func retentionRemovalCount(for policy: HistoryRetentionPolicy, now: Date) throws -> Int {
        try queue.sync {
            try policy.validate()
            let base = "SELECT COUNT(*) FROM history h WHERE NOT EXISTS (SELECT 1 FROM group_memberships gm WHERE gm.entry_id=h.id)"
            if policy.mode == .count { return max(0, Int(try scalarInt64(base)) - policy.count) }
            let stmt = try prepare(base + " AND activity_at < ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, policy.cutoff(now: now).timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }
    private func stringSet(_ sql: String, value: String) throws -> Set<String> {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, value, -1, transient)
        var values: Set<String> = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { throw failure() }
            values.insert(String(cString: text))
        }
    }
    public func ungroupedEntryCount() throws -> Int {
        try queue.sync {
            Int(try scalarInt64("SELECT COUNT(*) FROM history h WHERE NOT EXISTS (SELECT 1 FROM group_memberships gm WHERE gm.entry_id=h.id)"))
        }
    }
    public func content(id: String) throws -> ClipboardContent {
        try queue.sync {
            let entry = try entryUnlocked(id: id)
            let values = try entry.representations.map { value -> Representation in
                if let data = value.inline { return Representation(type: value.type, data: data, itemIndex: value.itemIndex) }
                guard let name = value.file, let data = try? Data(contentsOf: imageDirectory.appendingPathComponent(name)) else { throw ClipboardError.missingImage }
                return Representation(type: value.type, data: data, itemIndex: value.itemIndex)
            }
            guard ClipboardContent.digest(values) == entry.fingerprint else { throw ClipboardError.missingImage }
            return ClipboardContent(kind: entry.kind, text: entry.text, representations: values, width: entry.width, height: entry.height, frameCount: entry.frameCount)
        }
    }
    public func thumbnailURL(for entry: HistoryEntry) -> URL? { entry.thumbnailFile.map { imageDirectory.appendingPathComponent($0) } }
    public func sourceIconURL(for entry: HistoryEntry) -> URL? { entry.source?.iconFile.map { imageDirectory.appendingPathComponent($0) } }
    public func linkIconURL(for entry: HistoryEntry) -> URL? { entry.linkMetadata?.iconFile.map { imageDirectory.appendingPathComponent($0) } }
    public func linkPreviewURL(for entry: HistoryEntry) -> URL? { entry.linkMetadata?.previewFile.map { imageDirectory.appendingPathComponent($0) } }

    @discardableResult
    public func record(_ content: ClipboardContent, source: SourceApplication? = nil, sourceIcon: Data? = nil, limit: Int, now: Date = Date()) throws -> HistoryEntry {
        try record(content, source: source, sourceIcon: sourceIcon, policy: HistoryRetentionPolicy(count: limit), now: now)
    }
    @discardableResult
    public func record(_ content: ClipboardContent, source: SourceApplication? = nil, sourceIcon: Data? = nil, policy: HistoryRetentionPolicy, now: Date = Date(), retentionNow: Date? = nil) throws -> HistoryEntry {
        try queue.sync {
            try policy.validate()
            guard !content.representations.isEmpty else { throw ClipboardError.invalidContent }
            defer { attemptCleanupUnlocked() }
            let existing = try entriesUnlocked(whereClause: "WHERE fingerprint=?", bindings: [content.fingerprint]).first
            let storedSource = try storedSource(source, iconData: sourceIcon, previous: existing?.source)
            var entry: HistoryEntry
            if let existing {
                entry = existing
                entry.copiedAt = now; entry.source = storedSource
            } else {
                let id = UUID().uuidString
                var refs: [StoredRepresentation] = []
                for (index, value) in content.representations.enumerated() {
                    if content.kind == .image {
                        let name = "\(id)-\(index).data"
                        try fault?(.beforeFileWrite)
                        try value.data.write(to: imageDirectory.appendingPathComponent(name), options: .atomic)
                        refs.append(StoredRepresentation(type: value.type, inline: nil, file: name, itemIndex: value.itemIndex))
                    } else { refs.append(StoredRepresentation(type: value.type, inline: value.data, file: nil, itemIndex: value.itemIndex)) }
                }
                var thumbnail: String?
                if let data = content.thumbnail {
                    thumbnail = "\(id)-thumb.png"
                    try fault?(.beforeFileWrite)
                    try data.write(to: imageDirectory.appendingPathComponent(thumbnail!), options: .atomic)
                }
                entry = HistoryEntry(id: id, fingerprint: content.fingerprint, kind: content.kind, text: content.text, source: storedSource, createdAt: now, copiedAt: now, usedAt: nil, activity: 0, representations: refs, thumbnailFile: thumbnail, width: content.width, height: content.height, frameCount: content.frameCount, linkMetadata: nil, textLength: content.text?.count)
            }
            try transaction {
                entry.activity = try nextActivity()
                try save(entry)
                try prune(policy: policy, now: retentionNow ?? now)
            }
            return entry
        }
    }
    @discardableResult
    public func updateLinkMetadata(id: String, expectedFingerprint: String, payload: LinkMetadataPayload, now: Date = Date()) throws -> Bool {
        try queue.sync {
            guard var entry = try entriesUnlocked(whereClause: "WHERE id=?", bindings: [id]).first,
                  entry.fingerprint == expectedFingerprint, entry.linkURL != nil, entry.linkMetadata == nil else { return false }
            do {
                let icon = try writeAsset(payload.iconPNG, name: "\(id)-link-icon.png", maximumBytes: 1_000_000)
                let preview = try writeAsset(payload.previewPNG, name: "\(id)-link-preview.png", maximumBytes: 2_000_000)
                entry.linkMetadata = LinkMetadata(status: payload.status, title: payload.title, siteName: payload.siteName, iconFile: icon, previewFile: preview, fetchedAt: now)
                try transaction { try save(entry) }
                attemptCleanupUnlocked()
                return true
            } catch {
                attemptCleanupUnlocked()
                throw error
            }
        }
    }
    @discardableResult
    public func reuseLinkMetadata(id: String, expectedFingerprint: String, url: URL) throws -> Bool {
        try queue.sync {
            guard var target = try entriesUnlocked(whereClause: "WHERE id=?", bindings: [id]).first,
                  target.fingerprint == expectedFingerprint, target.linkMetadata == nil, target.linkURL == url else { return false }
            let statement = try prepare("SELECT summary FROM history WHERE id<>? ORDER BY activity DESC")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, id, -1, transient)
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return false }
                guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
                let summary = try decoder.decode(HistoryEntry.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
                if summary.linkURL == url, let metadata = summary.linkMetadata { target.linkMetadata = metadata; break }
            }
            try transaction { try save(target) }
            return true
        }
    }
    public func markUsed(id: String, policy: HistoryRetentionPolicy? = nil, now: Date = Date()) throws {
        try queue.sync {
            try policy?.validate()
            defer { attemptCleanupUnlocked() }
            try fault?(.beforeMarkUsed)
            var entry = try entryUnlocked(id: id)
            try transaction {
                entry.usedAt = now; entry.activity = try nextActivity()
                try save(entry)
                if let policy { try prune(policy: policy, now: now) }
            }
        }
    }
    public func setLimit(_ limit: Int) throws {
        try applyRetention(HistoryRetentionPolicy(count: limit))
    }
    public func applyRetention(_ policy: HistoryRetentionPolicy, now: Date = Date()) throws {
        try queue.sync {
            try policy.validate()
            try transaction { try prune(policy: policy, now: now) }
            attemptCleanupUnlocked()
        }
    }
    @discardableResult
    public func createGroup(name: String) throws -> ClipGroup {
        try queue.sync {
            let name = try normalizedGroupName(name)
            guard try !groupNameExists(name) else { throw ClipboardError.duplicateGroupName }
            let group = ClipGroup(id: UUID().uuidString, name: name, position: (try groupsUnlocked().last?.position ?? -1) + 1)
            try transaction { try insertGroup(group) }
            return group
        }
    }
    public func renameGroup(id: String, name: String) throws {
        try queue.sync {
            let name = try normalizedGroupName(name)
            guard try groupUnlocked(id: id) != nil else { throw ClipboardError.missingGroup }
            guard try !groupNameExists(name, excluding: id) else { throw ClipboardError.duplicateGroupName }
            try transaction { try execute("UPDATE clip_groups SET name=? WHERE id=?", strings: [name, id]) }
        }
    }
    public func moveGroup(id: String, offset: Int) throws {
        try queue.sync {
            guard offset != 0 else { return }
            let groups = try groupsUnlocked()
            guard let index = groups.firstIndex(where: { $0.id == id }) else { throw ClipboardError.missingGroup }
            let target = min(max(index + offset, 0), groups.count - 1)
            guard target != index else { return }
            var reordered = groups
            reordered.insert(reordered.remove(at: index), at: target)
            try transaction {
                for position in min(index, target)...max(index, target) {
                    try updateGroupPosition(id: reordered[position].id, position: groups[position].position)
                }
            }
        }
    }
    public func deleteGroup(id: String, limit: Int) throws {
        try deleteGroup(id: id, policy: HistoryRetentionPolicy(count: limit))
    }
    public func deleteGroup(id: String, policy: HistoryRetentionPolicy, now: Date = Date()) throws {
        try queue.sync {
            try policy.validate()
            guard try groupUnlocked(id: id) != nil else { throw ClipboardError.missingGroup }
            try transaction {
                try execute("DELETE FROM clip_groups WHERE id=?", strings: [id])
                try prune(policy: policy, now: now)
            }
            attemptCleanupUnlocked()
        }
    }
    public func add(entryID: String, toGroup groupID: String, now: Date = Date()) throws {
        try queue.sync {
            _ = try entryUnlocked(id: entryID)
            guard try groupUnlocked(id: groupID) != nil else { throw ClipboardError.missingGroup }
            try transaction {
                let statement = try prepare("INSERT OR IGNORE INTO group_memberships(group_id,entry_id,created_at) VALUES(?,?,?)")
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_text(statement, 1, groupID, -1, transient)
                sqlite3_bind_text(statement, 2, entryID, -1, transient)
                sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            }
        }
    }
    public func remove(entryID: String, fromGroup groupID: String, limit: Int) throws {
        try remove(entryID: entryID, fromGroup: groupID, policy: HistoryRetentionPolicy(count: limit))
    }
    public func remove(entryID: String, fromGroup groupID: String, policy: HistoryRetentionPolicy, now: Date = Date()) throws {
        try queue.sync {
            try policy.validate()
            try transaction {
                try execute("DELETE FROM group_memberships WHERE group_id=? AND entry_id=?", strings: [groupID, entryID])
                try prune(policy: policy, now: now)
            }
            attemptCleanupUnlocked()
        }
    }
    public func delete(id: String) throws {
        try queue.sync {
            try transaction { try execute("DELETE FROM history WHERE id=?", strings: [id]) }
            attemptCleanupUnlocked()
        }
    }
    public func clear() throws {
        try queue.sync {
            try transaction { try execute("DELETE FROM history") }
            attemptCleanupUnlocked()
        }
    }
    public func clearUngrouped() throws {
        try queue.sync {
            try transaction {
                try execute("DELETE FROM history WHERE NOT EXISTS (SELECT 1 FROM group_memberships gm WHERE gm.entry_id=history.id)")
            }
            attemptCleanupUnlocked()
        }
    }
    public func cleanup() throws { try queue.sync { try cleanupUnlocked(); maintenanceWarning = nil } }

    private func entriesUnlocked(whereClause: String = "", bindings: [String] = []) throws -> [HistoryEntry] {
        let statement = try prepare("SELECT payload FROM history \(whereClause) ORDER BY activity DESC")
        for (index, value) in bindings.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
        defer { sqlite3_finalize(statement) }
        var entries: [HistoryEntry] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return entries }
            guard result == SQLITE_ROW else { throw failure() }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw ClipboardError.database(L("记录数据为空")) }
            entries.append(try decoder.decode(HistoryEntry.self, from: Data(bytes: bytes, count: count)))
        }
    }
    private func summariesUnlocked(query: String = "", maximumEntries: Int? = nil) throws -> [HistoryEntry] {
        let sql = query.isEmpty
            ? "SELECT summary FROM history ORDER BY activity DESC"
            : "SELECT summary FROM history WHERE instr(search_text, ?) > 0 ORDER BY activity DESC"
        let statement = try prepare(sql + (maximumEntries.map { " LIMIT \($0)" } ?? ""))
        if !query.isEmpty { sqlite3_bind_text(statement, 1, query.lowercased(), -1, transient) }
        defer { sqlite3_finalize(statement) }
        var entries: [HistoryEntry] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return entries }
            guard result == SQLITE_ROW else { throw failure() }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw ClipboardError.database(L("记录摘要为空")) }
            entries.append(try decoder.decode(HistoryEntry.self, from: Data(bytes: bytes, count: count)))
        }
    }
    private func entryUnlocked(id: String) throws -> HistoryEntry {
        guard let entry = try entriesUnlocked(whereClause: "WHERE id=?", bindings: [id]).first else { throw ClipboardError.missingEntry }
        return entry
    }
    private func groupsUnlocked() throws -> [ClipGroup] {
        let statement = try prepare("SELECT id,name,position FROM clip_groups ORDER BY position ASC,id ASC")
        defer { sqlite3_finalize(statement) }
        var groups: [ClipGroup] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return groups }
            guard result == SQLITE_ROW, let id = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) else { throw failure() }
            groups.append(ClipGroup(id: String(cString: id), name: String(cString: name), position: Int(sqlite3_column_int64(statement, 2))))
        }
    }
    private func groupEntryIDsUnlocked() throws -> [String: Set<String>] {
        let statement = try prepare("SELECT group_id,entry_id FROM group_memberships")
        defer { sqlite3_finalize(statement) }
        var values: [String: Set<String>] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW, let groupID = sqlite3_column_text(statement, 0), let entryID = sqlite3_column_text(statement, 1) else { throw failure() }
            values[String(cString: groupID), default: []].insert(String(cString: entryID))
        }
    }
    private func groupUnlocked(id: String) throws -> ClipGroup? { try groupsUnlocked().first { $0.id == id } }
    private func normalizedGroupName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw ClipboardError.invalidGroupName }
        return name
    }
    private func groupNameExists(_ name: String, excluding id: String? = nil) throws -> Bool {
        let sql = id == nil
            ? "SELECT COUNT(*) FROM clip_groups WHERE name=? COLLATE NOCASE"
            : "SELECT COUNT(*) FROM clip_groups WHERE name=? COLLATE NOCASE AND id<>?"
        return try scalarInt64(sql, strings: [name] + [id].compactMap { $0 }) > 0
    }
    private func insertGroup(_ group: ClipGroup) throws {
        let statement = try prepare("INSERT INTO clip_groups(id,name,position) VALUES(?,?,?)")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, group.id, -1, transient)
        sqlite3_bind_text(statement, 2, group.name, -1, transient)
        sqlite3_bind_int64(statement, 3, Int64(group.position))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func updateGroupPosition(id: String, position: Int) throws {
        let statement = try prepare("UPDATE clip_groups SET position=? WHERE id=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(position))
        sqlite3_bind_text(statement, 2, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func save(_ entry: HistoryEntry) throws {
        let stmt = try prepare("INSERT INTO history(id,fingerprint,activity,payload,summary,search_text) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET activity=excluded.activity,payload=excluded.payload,summary=excluded.summary,search_text=excluded.search_text")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, entry.id, -1, transient)
        sqlite3_bind_text(stmt, 2, entry.fingerprint, -1, transient)
        sqlite3_bind_int64(stmt, 3, entry.activity)
        let data = try encoder.encode(entry)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32($0.count), transient) }
        let summary = try encoder.encode(entry.summary())
        _ = summary.withUnsafeBytes { sqlite3_bind_blob(stmt, 5, $0.baseAddress, Int32($0.count), transient) }
        sqlite3_bind_text(stmt, 6, entry.searchText, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        try updateActivityTime(entry)
        try replaceAssets(for: entry)
    }
    private func replaceAssets(for entry: HistoryEntry) throws {
        try execute("DELETE FROM history_assets WHERE entry_id=?", strings: [entry.id])
        guard !entry.files.isEmpty else { return }
        let statement = try prepare("INSERT INTO history_assets(entry_id,file) VALUES(?,?)")
        defer { sqlite3_finalize(statement) }
        for file in Set(entry.files) {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, entry.id, -1, transient)
            sqlite3_bind_text(statement, 2, file, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        }
    }
    private func rebuildDerivedDataIfNeeded() throws {
        guard try scalarInt64("SELECT COUNT(*) FROM schema_metadata WHERE key='history_summary_assets_v1'") == 0 else { return }
        let statement = try prepare("SELECT id FROM history ORDER BY activity DESC")
        defer { sqlite3_finalize(statement) }
        var ids: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let id = sqlite3_column_text(statement, 0) else { throw failure() }
            ids.append(String(cString: id))
        }
        try transaction(checkFault: false) {
            try execute("DELETE FROM history_assets")
            for id in ids {
                try autoreleasepool {
                    let entry = try entryUnlocked(id: id)
                    let summary = try encoder.encode(entry.summary())
                    let update = try prepare("UPDATE history SET summary=?,search_text=? WHERE id=?")
                    defer { sqlite3_finalize(update) }
                    _ = summary.withUnsafeBytes { sqlite3_bind_blob(update, 1, $0.baseAddress, Int32($0.count), transient) }
                    sqlite3_bind_text(update, 2, entry.searchText, -1, transient)
                    sqlite3_bind_text(update, 3, entry.id, -1, transient)
                    guard sqlite3_step(update) == SQLITE_DONE else { throw failure() }
                    try replaceAssets(for: entry)
                }
            }
            try execute("INSERT INTO schema_metadata(key,value) VALUES('history_summary_assets_v1','1')")
        }
    }
    private func storedSource(_ source: SourceApplication?, iconData: Data?, previous: SourceApplication?) throws -> SourceApplication? {
        guard let source else { return nil }
        let previousIcon = previous?.bundleID == source.bundleID ? previous?.iconFile : nil
        guard let iconData, !iconData.isEmpty, iconData.count <= 1_000_000 else {
            return SourceApplication(bundleID: source.bundleID, name: source.name, iconFile: previousIcon, attribution: source.attribution)
        }
        let digest = SHA256.hash(data: Data(source.bundleID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let name = "source-\(digest).png"
        let url = imageDirectory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try fault?(.beforeFileWrite)
            try iconData.write(to: url, options: .atomic)
        }
        return SourceApplication(bundleID: source.bundleID, name: source.name, iconFile: name, attribution: source.attribution)
    }
    private func writeAsset(_ data: Data?, name: String, maximumBytes: Int) throws -> String? {
        guard let data, !data.isEmpty, data.count <= maximumBytes else { return nil }
        try fault?(.beforeFileWrite)
        try data.write(to: imageDirectory.appendingPathComponent(name), options: .atomic)
        return name
    }
    private func nextActivity() throws -> Int64 {
        try execute("UPDATE counters SET value=value+1 WHERE id=1")
        let stmt = try prepare("SELECT value FROM counters WHERE id=1")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(stmt, 0)
    }
    private func migrateActivityTimeIfNeeded() throws {
        guard try !tableColumns("history").contains("activity_at") else { return }
        try transaction(checkFault: false) {
            try execute("ALTER TABLE history ADD COLUMN activity_at REAL NOT NULL DEFAULT 0")
            for entry in try summariesUnlocked() { try updateActivityTime(entry) }
            try execute("CREATE INDEX history_activity_at ON history(activity_at)")
        }
    }
    private func updateActivityTime(_ entry: HistoryEntry) throws {
        let stmt = try prepare("UPDATE history SET activity_at=? WHERE id=?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, max(entry.copiedAt, entry.usedAt ?? entry.copiedAt).timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, entry.id, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    private func prune(policy: HistoryRetentionPolicy, now: Date) throws {
        let sql: String
        switch policy.mode {
        case .count:
            sql = "DELETE FROM history WHERE id IN (SELECT h.id FROM history h WHERE NOT EXISTS (SELECT 1 FROM group_memberships gm WHERE gm.entry_id=h.id) ORDER BY h.activity DESC LIMIT -1 OFFSET ?)"
        case .time:
            sql = "DELETE FROM history WHERE activity_at < ? AND NOT EXISTS (SELECT 1 FROM group_memberships gm WHERE gm.entry_id=history.id)"
        }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        switch policy.mode {
        case .count: sqlite3_bind_int64(stmt, 1, Int64(policy.count))
        case .time: sqlite3_bind_double(stmt, 1, policy.cutoff(now: now).timeIntervalSince1970)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    private func attemptCleanupUnlocked() {
        do { try cleanupUnlocked(); maintenanceWarning = nil }
        catch { maintenanceWarning = L("历史已保存，但无引用图片清理失败，将在后续操作或启动时重试。") }
    }
    private func cleanupUnlocked() throws {
        try fault?(.beforeCleanup)
        let files = try FileManager.default.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil)
        guard !files.isEmpty else { return }
        let statement = try prepare("SELECT file FROM history_assets")
        defer { sqlite3_finalize(statement) }
        var referenced: Set<String> = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let file = sqlite3_column_text(statement, 0) else { throw failure() }
            referenced.insert(String(cString: file))
        }
        for file in files where !referenced.contains(file.lastPathComponent) { try FileManager.default.removeItem(at: file) }
    }
    private func transaction(checkFault: Bool = true, _ action: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try action()
            if checkFault { try fault?(.beforeCommit) }
            try execute("COMMIT")
        }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func tableColumns(_ table: String) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return columns }
            guard result == SQLITE_ROW, let name = sqlite3_column_text(statement, 1) else { throw failure() }
            columns.insert(String(cString: name))
        }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        return stmt
    }
    private func execute(_ sql: String, strings: [String] = []) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (index, value) in strings.enumerated() { sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient) }
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure() }
    }
    private func scalarInt64(_ sql: String, strings: [String] = []) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in strings.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(statement, 0)
    }
    private func failure() -> ClipboardError { .database(String(cString: sqlite3_errmsg(db))) }
}
