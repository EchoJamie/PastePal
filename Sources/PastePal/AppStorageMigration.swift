import PastePalLocalization
import Foundation
import Darwin

enum StorageMigrationDisposition: Equatable {
    case sourceMissing
    case migrated
    case destinationPreserved

    var description: String {
        switch self {
        case .sourceMissing: L("没有旧数据")
        case .migrated: L("已迁移并保留旧备份")
        case .destinationPreserved: L("新位置已有内容，已保留")
        }
    }
}

struct AppStorageMigrationReport: Equatable {
    let data: StorageMigrationDisposition
    let preferences: StorageMigrationDisposition
}

enum AppStorageMigrationError: LocalizedError {
    case oldApplicationRunning
    case copiedDataDoesNotMatch
    case copiedPreferencesDoNotMatch

    var errorDescription: String? {
        switch self {
        case .oldApplicationRunning:
            L("旧版应用仍在运行。请退出旧版应用后重试。")
        case .copiedDataDoesNotMatch:
            L("复制后的数据校验失败，旧数据未被改动。")
        case .copiedPreferencesDoNotMatch:
            L("复制后的设置校验失败，旧设置未被改动。")
        }
    }
}

struct AppStorageMigration {
    static let oldPreferencesDomain = "local.jamie.MacClipboard"
    static let newPreferencesDomain = "local.jamie.PastePal"
    static var liveDataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PastePal", isDirectory: true)
    }

    private struct ManifestEntry: Equatable {
        let kind: String
        let size: Int
    }

    private let fileManager: FileManager
    private let applicationSupportDirectory: URL
    private let oldDataDirectoryName: String
    private let newDataDirectoryName: String
    private let oldPreferencesDomain: String
    private let newPreferencesDomain: String
    private let copyDirectory: (FileManager, URL, URL) throws -> Void

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL,
        oldDataDirectoryName: String = "MacClipboard",
        newDataDirectoryName: String = "PastePal",
        oldPreferencesDomain: String = Self.oldPreferencesDomain,
        newPreferencesDomain: String = Self.newPreferencesDomain,
        copyDirectory: @escaping (FileManager, URL, URL) throws -> Void = { manager, source, destination in
            try manager.copyItem(at: source, to: destination)
        }
    ) {
        self.fileManager = fileManager
        self.applicationSupportDirectory = applicationSupportDirectory
        self.oldDataDirectoryName = oldDataDirectoryName
        self.newDataDirectoryName = newDataDirectoryName
        self.oldPreferencesDomain = oldPreferencesDomain
        self.newPreferencesDomain = newPreferencesDomain
        self.copyDirectory = copyDirectory
    }

    static func live() -> Self {
        Self(
            applicationSupportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        )
    }

    func run() throws -> AppStorageMigrationReport {
        let data = try migrateData()
        let preferences = try migratePreferences()
        return AppStorageMigrationReport(data: data, preferences: preferences)
    }

    private func migrateData() throws -> StorageMigrationDisposition {
        let source = applicationSupportDirectory.appendingPathComponent(oldDataDirectoryName, isDirectory: true)
        let destination = applicationSupportDirectory.appendingPathComponent(newDataDirectoryName, isDirectory: true)
        let staging = applicationSupportDirectory.appendingPathComponent(".\(newDataDirectoryName).migration-staging", isDirectory: true)

        guard fileManager.fileExists(atPath: source.path) else { return .sourceMissing }
        if fileManager.fileExists(atPath: destination.path) {
            let isEmptyDirectory = (try? fileManager.contentsOfDirectory(atPath: destination.path).isEmpty) == true
            guard isEmptyDirectory else { return .destinationPreserved }
            try fileManager.removeItem(at: destination)
        }

        try fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        let lockPath = source.appendingPathComponent("instance.lock").path
        let oldLock = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard oldLock >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard flock(oldLock, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(oldLock)
            if lockError != EWOULDBLOCK {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(lockError))
            }
            throw AppStorageMigrationError.oldApplicationRunning
        }
        defer {
            flock(oldLock, LOCK_UN)
            close(oldLock)
        }

        if fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
        do {
            try copyDirectory(fileManager, source, staging)
            guard try manifest(of: source) == manifest(of: staging) else {
                throw AppStorageMigrationError.copiedDataDoesNotMatch
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: staging)
                return .destinationPreserved
            }
            try fileManager.moveItem(at: staging, to: destination)
            return .migrated
        } catch {
            if fileManager.fileExists(atPath: staging.path) { try? fileManager.removeItem(at: staging) }
            throw error
        }
    }

    private func manifest(of root: URL) throws -> [String: ManifestEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { return [:] }
        var result: [String: ManifestEntry] = [:]
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            let kind = values.isDirectory == true ? "directory" : values.isSymbolicLink == true ? "symlink" : "file"
            let path = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            result[path] = ManifestEntry(kind: kind, size: values.isRegularFile == true ? values.fileSize ?? 0 : 0)
        }
        if let enumerationError { throw enumerationError }
        return result
    }

    private func migratePreferences() throws -> StorageMigrationDisposition {
        let defaults = UserDefaults.standard
        guard let oldValues = defaults.persistentDomain(forName: oldPreferencesDomain), !oldValues.isEmpty else {
            return .sourceMissing
        }
        let existing = defaults.persistentDomain(forName: newPreferencesDomain) ?? [:]
        var merged = oldValues
        for (key, value) in existing { merged[key] = value }
        if NSDictionary(dictionary: existing).isEqual(to: merged) { return .destinationPreserved }

        defaults.setPersistentDomain(merged, forName: newPreferencesDomain)
        defaults.synchronize()
        guard let migrated = defaults.persistentDomain(forName: newPreferencesDomain),
              NSDictionary(dictionary: migrated).isEqual(to: merged) else {
            if existing.isEmpty {
                defaults.removePersistentDomain(forName: newPreferencesDomain)
            } else {
                defaults.setPersistentDomain(existing, forName: newPreferencesDomain)
            }
            throw AppStorageMigrationError.copiedPreferencesDoNotMatch
        }
        return .migrated
    }
}
