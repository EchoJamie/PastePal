import Foundation

final class BoundedLinkDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum OverflowPolicy {
        case reject
        case keepPrefix
    }

    struct ResponseData {
        let data: Data
        let response: HTTPURLResponse
        let isTruncated: Bool
    }

    private struct Transfer {
        let maximumBytes: Int
        let overflowPolicy: OverflowPolicy
        let expectedPrefixes: [String]
        let completion: (ResponseData?) -> Void
        var response: HTTPURLResponse?
        var data = Data()
    }

    private let queue = DispatchQueue(label: "local.pastepal.bounded-link-download")
    private var session: URLSession!
    private var transfers: [Int: Transfer] = [:]
    private var cancelled = false

    init(configuration: URLSessionConfiguration) {
        super.init()
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    func load(_ request: URLRequest, maximumBytes: Int, expectedPrefixes: [String], overflowPolicy: OverflowPolicy = .reject, completion: @escaping (ResponseData?) -> Void) {
        queue.async {
            guard !self.cancelled, maximumBytes > 0 else { completion(nil); return }
            let task = self.session.dataTask(with: request)
            self.transfers[task.taskIdentifier] = Transfer(maximumBytes: maximumBytes, overflowPolicy: overflowPolicy, expectedPrefixes: expectedPrefixes, completion: completion)
            task.resume()
        }
    }

    func cancelAll() {
        queue.async {
            guard !self.cancelled else { return }
            self.cancelled = true
            let callbacks = self.transfers.values.map(\.completion)
            self.transfers.removeAll()
            self.session.invalidateAndCancel()
            callbacks.forEach { $0(nil) }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfers[dataTask.taskIdentifier],
              let response = response as? HTTPURLResponse,
              (200..<400).contains(response.statusCode),
              transfer.overflowPolicy == .keepPrefix || response.expectedContentLength <= 0 || response.expectedContentLength <= Int64(transfer.maximumBytes),
              response.mimeType.map({ mime in transfer.expectedPrefixes.contains(where: mime.lowercased().hasPrefix) }) ?? true else {
            completionHandler(.cancel)
            finish(dataTask, succeeded: false)
            return
        }
        transfers[dataTask.taskIdentifier]?.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = transfers[dataTask.taskIdentifier].map({ ($0.maximumBytes - $0.data.count, $0.overflowPolicy) }) else { return }
        let (remaining, policy) = state
        if policy == .keepPrefix, data.count >= remaining {
            // 只复制预算内的字节，不持有超限块的切片。
            data.withUnsafeBytes { bytes in
                if remaining > 0, let base = bytes.baseAddress {
                    transfers[dataTask.taskIdentifier]?.data.append(base.assumingMemoryBound(to: UInt8.self), count: remaining)
                }
            }
            dataTask.cancel()
            finish(dataTask, succeeded: true, isTruncated: true)
            return
        }
        guard data.count <= remaining else {
            dataTask.cancel()
            finish(dataTask, succeeded: false)
            return
        }
        transfers[dataTask.taskIdentifier]?.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(task, succeeded: error == nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let transfer = transfers[task.taskIdentifier], let url = request.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.absoluteString.utf8.count <= 4_096 else {
            completionHandler(nil)
            task.cancel()
            finish(task, succeeded: false)
            return
        }
        var redirected = request
        redirected.httpShouldHandleCookies = false
        redirected.setValue("bytes=0-\(transfer.maximumBytes - 1)", forHTTPHeaderField: "Range")
        completionHandler(redirected)
    }

    private func finish(_ task: URLSessionTask, succeeded: Bool, isTruncated: Bool = false) {
        guard var transfer = transfers.removeValue(forKey: task.taskIdentifier) else { return }
        let result: ResponseData?
        if succeeded, !transfer.data.isEmpty, let response = transfer.response {
            result = ResponseData(data: transfer.data, response: response, isTruncated: isTruncated)
        } else {
            result = nil
        }
        transfer.data = Data()
        let completion = transfer.completion
        // 先退出接收回调，避免解析阶段继续持有本次网络分块。
        queue.async { completion(result) }
    }
}
