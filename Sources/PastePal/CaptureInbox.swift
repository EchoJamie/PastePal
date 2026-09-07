import Foundation
import ClipboardCore

// 正文先原样暂存，排队只保留序号；入库成功后再移除。
final class CaptureInbox {
    private struct Reference: Codable { let type: String; let itemIndex: Int; let file: String }
    private struct Manifest: Codable {
        let values: [Reference]
        let source: SourceApplication?
        let icon: Data?
        let capturedAt: Date
    }
    struct Capture {
        let sequence: UInt64
        let values: [Representation]
        let source: SourceApplication?
        let icon: Data?
        let capturedAt: Date
    }
    private let directory: URL
    private let lock = NSLock()
    private var first: UInt64 = 0
    private var next: UInt64 = 0
    var hasPending: Bool { lock.withLock { first < next } }
    var pendingUpperBound: UInt64 { lock.withLock { next } }

    init(directory: URL) throws {
        self.directory = directory.appendingPathComponent("CaptureInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let files = FileManager.default.enumerator(at: self.directory, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) {
            var minimum: UInt64?
            for case let url as URL in files {
                if let sequence = UInt64(url.lastPathComponent) {
                    minimum = min(minimum ?? sequence, sequence); next = max(next, sequence + 1)
                } else if url.lastPathComponent.hasPrefix("."), UUID(uuidString: String(url.lastPathComponent.dropFirst())) != nil {
                    try FileManager.default.removeItem(at: url)
                }
            }
            first = minimum ?? next
        }
    }
    func append(_ values: [Representation], source: SourceApplication?, icon: Data?, capturedAt: Date) throws {
        try lock.withLock {
            let staging = directory.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do {
                var references = [Reference]()
                for (index, value) in values.enumerated() {
                    let file = "\(index).data"
                    try value.data.write(to: staging.appendingPathComponent(file), options: .atomic)
                    references.append(Reference(type: value.type, itemIndex: value.itemIndex, file: file))
                }
                let manifest = Manifest(values: references, source: source, icon: icon, capturedAt: capturedAt)
                try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
                try FileManager.default.moveItem(at: staging, to: location(next))
                next += 1
            } catch { try? FileManager.default.removeItem(at: staging); throw error }
        }
    }
    func peek(before upperBound: UInt64 = UInt64.max) throws -> Capture? {
        let item = lock.withLock { () -> (UInt64, URL)? in
            while first < next, first < upperBound {
                let url = location(first)
                if FileManager.default.fileExists(atPath: url.path) { return (first, url) }
                first += 1
            }
            return nil
        }
        guard let (sequence, url) = item else { return nil }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url.appendingPathComponent("manifest.json")))
        let values = try manifest.values.map { reference in
            Representation(type: reference.type, data: try Data(contentsOf: url.appendingPathComponent(reference.file)), itemIndex: reference.itemIndex)
        }
        return Capture(sequence: sequence, values: values, source: manifest.source, icon: manifest.icon, capturedAt: manifest.capturedAt)
    }
    func acknowledge(_ sequence: UInt64) throws {
        try lock.withLock {
            try FileManager.default.removeItem(at: location(sequence))
            if first == sequence { first += 1 }
        }
    }
    private func location(_ sequence: UInt64) -> URL { directory.appendingPathComponent(String(sequence), isDirectory: true) }
}
