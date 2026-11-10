import Foundation

/// Sends one provider request and yields the response body in chunks.
///
/// The production transport shares one connection pool for a run. Tests supply
/// canned responses, so no test opens a socket.
protocol ProviderTransport: Sendable {
    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>)
}

extension ProviderTransport {
    /// Collects a whole body, failing once it passes `maximumBytes`.
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let (response, chunks) = try await open(request)
        if response.expectedContentLength > Int64(maximumBytes) {
            throw ProviderPipelineError.responseTooLarge
        }
        var body = Data()
        for try await chunk in chunks {
            guard chunk.count <= maximumBytes - body.count else { throw ProviderPipelineError.responseTooLarge }
            body.append(chunk)
        }
        return (body, response)
    }

    /// Reads a line-delimited body, calling `onLine` for each line until it returns false.
    func readLines(
        _ request: URLRequest,
        maximumBytes: Int,
        onResponse: (HTTPURLResponse) throws -> Bool,
        onLine: (String) throws -> Bool
    ) async throws -> (HTTPURLResponse, Data) {
        let (response, chunks) = try await open(request)
        guard try onResponse(response) else {
            // The caller wants the raw body (an error response), capped.
            var body = Data()
            for try await chunk in chunks {
                guard chunk.count <= maximumBytes - body.count else { throw ProviderPipelineError.responseTooLarge }
                body.append(chunk)
            }
            return (response, body)
        }
        var splitter = LineSplitter()
        var total = 0
        for try await chunk in chunks {
            total += chunk.count
            guard total <= maximumBytes else { throw ProviderPipelineError.responseTooLarge }
            for line in splitter.append(chunk) {
                guard try onLine(line) else { return (response, Data()) }
            }
        }
        if let last = splitter.finish() {
            _ = try onLine(last)
        }
        return (response, Data())
    }
}

/// Splits a byte stream into lines across arbitrary chunk boundaries. Accepts LF and CRLF.
struct LineSplitter {
    static let maximumLineBytes = 256 * 1_024
    private var pending = Data()

    mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var lineData = pending[pending.startIndex..<newline]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        if pending.count > Self.maximumLineBytes {
            // A line this long is not a decision event. Drop it so memory stays bounded.
            pending.removeAll(keepingCapacity: false)
        }
        return lines
    }

    mutating func finish() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll(keepingCapacity: false) }
        var lineData = pending[...]
        if lineData.last == 0x0D { lineData = lineData.dropLast() }
        return String(decoding: lineData, as: UTF8.self)
    }
}

/// URLSession transport for provider and sign-in requests.
///
/// One ephemeral session per run: no cookies, cache, credential storage, or
/// system proxy, and a redirect ends the request instead of being followed.
final class URLSessionProviderTransport: NSObject, ProviderTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let session: URLSession

    init(maximumConnections: Int = 1, requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 120) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.httpMaximumConnectionsPerHost = min(max(1, maximumConnections), 16)
        session = URLSession(configuration: configuration)
        super.init()
    }

    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let (bytes, response) = try await session.bytes(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderPipelineError.requestFailed(nil)
        }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    buffer.reserveCapacity(4_096)
                    for try await byte in bytes {
                        buffer.append(byte)
                        // Flush on newline so streamed events are delivered as they arrive.
                        if byte == 0x0A || buffer.count >= 4_096 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, stream)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
