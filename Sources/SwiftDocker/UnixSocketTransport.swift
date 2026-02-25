import Foundation
import OpenAPIURLSession

// MARK: - Unix socket URLProtocol

/// A `URLProtocol` subclass that fulfils every `URLSession` request over a
/// Unix-domain socket instead of TCP.
///
/// `URLSession` has no native Unix socket support, so we intercept requests,
/// open a raw POSIX socket to the configured path, hand-write an HTTP/1.1
/// request, read the full response, decode chunked transfer-encoding, and hand
/// the result back to the URL loading system.
///
/// This class is used internally by ``UnixSocketTransport`` and is not meant
/// to be used directly.
public final class UnixSocketURLProtocol: URLProtocol, @unchecked Sendable {

    // Thread-safe storage for the socket path, set once before the URLSession
    // is created and never mutated again during a session's lifetime.
    nonisolated(unsafe) static var socketPath: String = ""

    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        Task { await self.perform() }
    }

    public override func stopLoading() {}

    private func perform() async {
        do {
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            // Build the request-target path + query string.
            let method = request.httpMethod ?? "GET"
            var target = url.path.isEmpty ? "/" : url.path
            if let query = url.query { target += "?\(query)" }

            // Assemble request headers.
            var rawRequest = "\(method) \(target) HTTP/1.1\r\n"
            rawRequest += "Host: \(host)\r\n"
            rawRequest += "Connection: close\r\n"

            if let headers = request.allHTTPHeaderFields {
                for (key, value) in headers
                where key.lowercased() != "host" && key.lowercased() != "connection" {
                    rawRequest += "\(key): \(value)\r\n"
                }
            }

            // Drain the request body (URLSessionTransport may supply it as a
            // stream when the bidirectional streaming mode is active).
            let bodyData: Data
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buf.deallocate(); stream.close() }
                while stream.hasBytesAvailable {
                    let n = stream.read(buf, maxLength: 4096)
                    if n > 0 { data.append(buf, count: n) }
                }
                bodyData = data
            } else {
                bodyData = request.httpBody ?? Data()
            }

            if !bodyData.isEmpty {
                rawRequest += "Content-Length: \(bodyData.count)\r\n"
            }
            rawRequest += "\r\n"

            // Open the Unix-domain socket.
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
            defer { close(fd) }

            let path = UnixSocketURLProtocol.socketPath
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
                path.withCString { cstr in
                    _ = memcpy(ptr.baseAddress!, cstr, min(path.utf8.count + 1, ptr.count))
                }
            }
            let connectResult = withUnsafeBytes(of: &addr) { ptr in
                connect(fd,
                        ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                        socklen_t(MemoryLayout<sockaddr_un>.size))
            }
            guard connectResult == 0 else { throw URLError(.cannotConnectToHost) }

            // Send headers then body.
            let headerBytes = Data(rawRequest.utf8)
            try headerBytes.withUnsafeBytes { ptr in
                guard send(fd, ptr.baseAddress!, ptr.count, 0) >= 0 else {
                    throw URLError(.networkConnectionLost)
                }
            }
            if !bodyData.isEmpty {
                try bodyData.withUnsafeBytes { ptr in
                    guard send(fd, ptr.baseAddress!, ptr.count, 0) >= 0 else {
                        throw URLError(.networkConnectionLost)
                    }
                }
            }

            // Read until the server closes the connection.
            var responseData = Data()
            let recvBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { recvBuf.deallocate() }
            while true {
                let n = recv(fd, recvBuf, 4096, 0)
                if n <= 0 { break }
                responseData.append(recvBuf, count: n)
            }

            // Split at the blank line between headers and body.
            guard let headerEnd = responseData.range(of: Data("\r\n\r\n".utf8)) else {
                throw URLError(.badServerResponse)
            }
            let headerSection = String(
                data: responseData[responseData.startIndex..<headerEnd.lowerBound],
                encoding: .utf8) ?? ""
            let rawBody = responseData[headerEnd.upperBound...]

            // Parse the status line.
            var lines = headerSection.components(separatedBy: "\r\n")
            let statusLine = lines.removeFirst()
            let statusParts = statusLine.components(separatedBy: " ")
            guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
                throw URLError(.badServerResponse)
            }

            // Parse response headers into a dictionary.
            var httpHeaders: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = String(line[line.startIndex..<colon])
                    .trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                httpHeaders[name] = value
            }

            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: httpHeaders
            )!

            // Decode chunked transfer-encoding before handing the body back
            // to URLSession — Docker always uses chunked responses.
            let isChunked = httpHeaders["Transfer-Encoding"]?
                .lowercased().contains("chunked") == true
            let decodedBody = isChunked ? Self.decodeChunked(Data(rawBody)) : Data(rawBody)

            client?.urlProtocol(self, didReceive: httpResponse,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: decodedBody)
            client?.urlProtocolDidFinishLoading(self)

        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    // MARK: Chunked decoding

    /// Decodes an HTTP/1.1 chunked-encoded body into its raw payload bytes.
    ///
    /// Format per RFC 9112 §7.1:
    /// ```
    /// chunk-size CRLF chunk-data CRLF  (repeated)
    /// 0 CRLF [trailers] CRLF
    /// ```
    static func decodeChunked(_ data: Data) -> Data {
        var result = Data()
        guard let text = String(data: data, encoding: .utf8) else { return data }
        var remaining = text[...]
        while !remaining.isEmpty {
            guard let crlf = remaining.range(of: "\r\n") else { break }
            // The chunk-size line may carry extensions after a semicolon.
            let sizeLine = String(remaining[remaining.startIndex..<crlf.lowerBound])
                .components(separatedBy: ";").first ?? ""
            guard let chunkSize = Int(sizeLine.trimmingCharacters(in: .whitespaces),
                                      radix: 16) else { break }
            if chunkSize == 0 { break }
            remaining = remaining[crlf.upperBound...]
            let chunkStart = remaining.startIndex
            guard let chunkEnd = remaining.index(
                chunkStart, offsetBy: chunkSize, limitedBy: remaining.endIndex
            ) else { break }
            if let chunkData = String(remaining[chunkStart..<chunkEnd]).data(using: .utf8) {
                result.append(chunkData)
            }
            remaining = remaining[chunkEnd...]
            // Skip the trailing CRLF after the chunk payload.
            if remaining.hasPrefix("\r\n") {
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 2)...]
            }
        }
        return result.isEmpty ? data : result
    }
}

// MARK: - Unix socket transport factory

/// Convenience factory that creates a `URLSessionTransport` backed by a
/// Unix-domain socket.
///
/// ```swift
/// let transport = UnixSocketTransport.make(socketPath: "/var/run/docker.sock")
/// let docker = try Docker(host: "http://localhost/v1.53", transport: transport)
/// ```
public enum UnixSocketTransport {

    /// Returns a `URLSessionTransport` whose underlying `URLSession` routes all
    /// requests through the Unix-domain socket at `socketPath`.
    ///
    /// - Parameters:
    ///   - socketPath: Absolute path to the Docker daemon socket, e.g.
    ///     `"/var/run/docker.sock"` or `"/Users/me/.docker/run/docker.sock"`.
    ///   - requestTimeout: Per-request timeout in seconds. Default is `300`
    ///     seconds to accommodate long-polling endpoints such as
    ///     `/containers/{id}/wait`.
    public static func make(
        socketPath: String,
        requestTimeout: TimeInterval = 300
    ) -> URLSessionTransport {
        UnixSocketURLProtocol.socketPath = socketPath
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnixSocketURLProtocol.self]
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout
        let session = URLSession(configuration: config)
        return URLSessionTransport(configuration: .init(session: session))
    }
}
