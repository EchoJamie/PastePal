import PastePalLocalization
import Foundation

public enum HistoryRetentionMode: String, Codable, Sendable { case count, time }

public struct HistoryRetentionPolicy: Equatable, Sendable {
    public var mode: HistoryRetentionMode
    public var count: Int
    public var days: Int

    public init(mode: HistoryRetentionMode = .count, count: Int = 1000, days: Int = 30) {
        self.mode = mode; self.count = count; self.days = days
    }
    public func validate() throws {
        guard count > 0, days > 0 else { throw ValidationError.nonPositive }
    }
    public func cutoff(now: Date) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }
    public func removalIDs(entries: [HistoryEntry], groupedIDs: Set<String>, now: Date) -> Set<String> {
        let ungrouped = entries.filter { !groupedIDs.contains($0.id) }
        switch mode {
        case .count: return Set(ungrouped.sorted { $0.activity > $1.activity }.dropFirst(max(0, count)).map(\.id))
        case .time: return Set(ungrouped.filter { max($0.copiedAt, $0.usedAt ?? $0.copiedAt) < cutoff(now: now) }.map(\.id))
        }
    }
    public enum ValidationError: LocalizedError {
        case nonPositive
        public var errorDescription: String? { L("保留条数和天数必须是正整数。") }
    }
}
