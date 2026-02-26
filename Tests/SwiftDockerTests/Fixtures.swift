import Foundation
import HTTPTypes
import OpenAPIRuntime
@testable import SwiftDocker

// MARK: - MockTransport

/// A `ClientTransport` that intercepts requests and returns pre-programmed
/// responses, letting unit tests run without a live Docker daemon.
///
/// ### Basic usage
///
/// Register a handler for one or more operation IDs, then build a `Docker`
/// client via the `host:transport:` initialiser:
///
/// ```swift
/// var transport = MockTransport()
/// transport.register(operationID: "containerCreate") { _, _ in
///     (.init(status: .created), try Fixtures.containerCreateBody(id: "abc123"))
/// }
///
/// let docker = try Docker(host: "http://localhost", transport: transport)
/// let response = try await docker.client.containerCreate(...)
/// ```
///
/// ### Catch-all handler
///
/// If no per-operation handler is registered the transport falls back to
/// ``MockTransport/defaultHandler``. This is useful when you need a single
/// closure to cover every request:
///
/// ```swift
/// transport.defaultHandler = { request, body in
///     throw MockTransportError.unexpectedRequest(request.path ?? "")
/// }
/// ```
actor MockTransport: ClientTransport {

    // MARK: Types

    typealias Handler = @Sendable (HTTPRequest, HTTPBody?) async throws -> (HTTPResponse, HTTPBody?)

    // MARK: State

    private var handlers: [String: Handler] = [:]

    /// Called when no handler is registered for a given `operationID`.
    /// Defaults to throwing ``MockTransportError.unhandledOperation``.
    var defaultHandler: Handler = { request, _ in
        throw MockTransportError.unhandledOperation(
            request.path ?? "<unknown path>"
        )
    }

    // MARK: Registration

    /// Registers a response handler for a specific OpenAPI `operationID`.
    ///
    /// - Parameters:
    ///   - operationID: The operation identifier as declared in the OpenAPI
    ///     document (e.g. `"containerCreate"`, `"containerStart"`).
    ///   - handler: An async closure that receives the raw `HTTPRequest` and
    ///     optional body, and returns the `HTTPResponse` and optional body to
    ///     hand back to the caller.
    func register(operationID: String, handler: @escaping Handler) {
        handlers[operationID] = handler
    }

    /// Removes a previously registered handler.
    func unregister(operationID: String) {
        handlers.removeValue(forKey: operationID)
    }

    // MARK: ClientTransport

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        if let handler = handlers[operationID] {
            return try await handler(request, body)
        }
        return try await defaultHandler(request, body)
    }
}

// MARK: - MockTransportError

enum MockTransportError: Error, CustomStringConvertible {
    /// No handler was registered for the given operation.
    case unhandledOperation(String)
    /// The test expected a different request path.
    case unexpectedRequest(String)

    var description: String {
        switch self {
        case .unhandledOperation(let path):
            return "MockTransport: no handler registered for request to '\(path)'"
        case .unexpectedRequest(let path):
            return "MockTransport: unexpected request to '\(path)'"
        }
    }
}

// MARK: - Fixtures

/// Pre-built JSON payloads that mirror real Docker Engine API responses.
///
/// Each helper returns an `HTTPBody` ready to pass back from a
/// ``MockTransport`` handler.  The payloads are minimal but structurally
/// valid — they contain every field that the generated `Client` decoder
/// will look for.
enum Fixtures {

    // MARK: Container

    /// A `POST /containers/create` 201-Created body.
    ///
    /// - Parameter id: The container ID to embed. Defaults to a short fake ID.
    /// - Parameter warnings: Optional warnings array. Defaults to empty.
    static func containerCreateBody(
        id: String = "deadbeef1234",
        warnings: [String] = []
    ) throws -> HTTPBody {
        let warningsJSON = warnings.map { "\"\($0)\"" }.joined(separator: ", ")
        let json = """
        {
          "Id": "\(id)",
          "Warnings": [\(warningsJSON)]
        }
        """
        return HTTPBody(Data(json.utf8))
    }

    /// A `POST /containers/{id}/wait` 200-OK body.
    ///
    /// - Parameter statusCode: The exit code reported by the container.
    static func containerWaitBody(statusCode: Int = 0) throws -> HTTPBody {
        let json = """
        {
          "StatusCode": \(statusCode),
          "Error": null
        }
        """
        return HTTPBody(Data(json.utf8))
    }

    /// A `GET /containers/{id}/logs` 200-OK body.
    ///
    /// Returns a Docker multiplexed-stream frame for a single stdout line.
    ///
    /// - Parameter message: The plain-text log line.
    static func containerLogsBody(message: String = "hello world\n") -> HTTPBody {
        HTTPBody(DockerMultiplexedStream.frame(stream: .stdout, text: message))
    }

    /// A `POST /containers/{id}/exec` 201-Created body.
    ///
    /// - Parameter id: The exec-instance ID. Defaults to a short fake ID.
    static func containerExecBody(id: String = "execfeedface") throws -> HTTPBody {
        let json = """
        { "Id": "\(id)" }
        """
        return HTTPBody(Data(json.utf8))
    }

    /// A `GET /exec/{id}/json` 200-OK body.
    ///
    /// - Parameters:
    ///   - running: Whether the exec instance is still running.
    ///   - exitCode: The exit code (only meaningful when `running` is `false`).
    static func execInspectBody(running: Bool = false, exitCode: Int = 0) throws -> HTTPBody {
        let json = """
        {
          "ID": "execfeedface",
          "Running": \(running),
          "ExitCode": \(exitCode),
          "ProcessConfig": {
            "tty": false,
            "entrypoint": "sh",
            "arguments": [],
            "privileged": false
          },
          "OpenStdin": false,
          "OpenStderr": true,
          "OpenStdout": true,
          "ContainerID": "deadbeef1234",
          "Pid": 42
        }
        """
        return HTTPBody(Data(json.utf8))
    }

    // MARK: Response helpers

    /// Returns a minimal JSON-content-type `HTTPResponse` with the given status.
    static func jsonResponse(status: HTTPResponse.Status) -> HTTPResponse {
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = "application/json"
        return response
    }

    /// Returns a 204 No Content `HTTPResponse` (e.g. containerStart).
    static func noContentResponse() -> HTTPResponse {
        HTTPResponse(status: .noContent)
    }

    /// Returns an `HTTPResponse` with `application/vnd.docker.multiplexed-stream`
    /// content type (e.g. containerLogs).
    static func multiplexedStreamResponse(status: HTTPResponse.Status) -> HTTPResponse {
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = "application/vnd.docker.multiplexed-stream"
        return response
    }
}

// MARK: - DockerMultiplexedStream + frame helper

extension DockerMultiplexedStream {

    /// The stream type carried in a Docker multiplexed-stream header.
    enum Stream: UInt8 { case stdin = 0, stdout = 1, stderr = 2 }

    /// Encodes `text` as a single Docker multiplexed-stream frame.
    ///
    /// Frame format (8-byte header + payload):
    /// ```
    /// byte 0   : stream type  (0=stdin, 1=stdout, 2=stderr)
    /// bytes 1-3: padding (0x00)
    /// bytes 4-7: payload size, big-endian uint32
    /// bytes 8+ : payload
    /// ```
    static func frame(stream: Stream, text: String) -> Data {
        let payload = Data(text.utf8)
        var header = Data(count: 8)
        header[0] = stream.rawValue
        // bytes 1-3 are already 0 (padding)
        let size = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: size) { header.replaceSubrange(4..<8, with: $0) }
        return header + payload
    }
}

// MARK: - Docker convenience init for tests

extension Docker {

    /// Creates a `Docker` client backed by `transport` instead of a real
    /// Unix socket.  Use this in unit tests together with ``MockTransport``.
    ///
    /// ```swift
    /// let transport = MockTransport()
    /// let docker = Docker.mock(transport: transport)
    /// ```
    static func mock(transport: some ClientTransport) throws -> Docker {
        try Docker(host: "http://localhost", transport: transport)
    }
}
