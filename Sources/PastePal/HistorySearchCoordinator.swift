import Foundation
import ClipboardCore

final class HistorySearchCoordinator {
    private struct Request {
        let query: String
        let groupID: String?
        let cancellation: HistoryQueryCancellation
        let completion: (Result<HistoryQueryResults, Error>) -> Void
    }
    private let load: (String, String?, HistoryQueryCancellation) throws -> HistoryQueryResults
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "local.pastepal.search", qos: .userInitiated)
    private var pending: Request?
    private var active: HistoryQueryCancellation?
    private var running = false

    init(directory: URL, load: ((String, String?, HistoryQueryCancellation) throws -> HistoryQueryResults)? = nil) {
        self.load = load ?? { query, groupID, cancellation in
            try HistoryQueryResults(directory: directory, query: query, groupID: groupID, cancellation: cancellation)
        }
    }
    deinit { active?.cancel() }
    func submit(query: String, groupID: String?, completion: @escaping (Result<HistoryQueryResults, Error>) -> Void) {
        let shouldStart = lock.withLock { () -> Bool in
            active?.cancel(); pending?.cancellation.cancel()
            pending = Request(query: query, groupID: groupID, cancellation: HistoryQueryCancellation(), completion: completion)
            guard !running else { return false }
            running = true
            return true
        }
        if shouldStart { worker.async { [weak self] in self?.drain() } }
    }
    func cancel() {
        lock.withLock { active?.cancel(); pending?.cancellation.cancel(); pending = nil }
    }
    private func drain() {
        while let request = lock.withLock({ () -> Request? in
            guard let request = pending else { running = false; active = nil; return nil }
            pending = nil; active = request.cancellation
            return request
        }) {
            let result = Result {
                let results = try load(request.query, request.groupID, request.cancellation)
                _ = try results.entry(at: 0)
                return results
            }
            lock.withLock { if active === request.cancellation { active = nil } }
            DispatchQueue.main.async {
                guard !request.cancellation.isCancelled else { return }
                request.completion(result)
            }
        }
    }
}
