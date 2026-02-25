import Foundation
import OpenAPIRuntime
import OpenAPIURLSession
import HTTPTypes

// MARK: - X-Registry-Auth Middleware

/// Authentication credentials for communicating with a Docker registry.
public struct RegistryAuth: Sendable {
    public let username: String
    public let password: String
    public let serverAddress: String

    public init(username: String, password: String, serverAddress: String) {
        self.username = username
        self.password = password
        self.serverAddress = serverAddress
    }

    /// Base64url-encoded JSON representation required by the Docker API's
    /// `X-Registry-Auth` header (RFC 4648 §5, no padding).
    public func encodedValue() throws -> String {
        let payload: [String: String] = [
            "username": username,
            "password": password,
            "serveraddress": serverAddress,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        // Docker expects base64url encoding (no padding)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// An identity-token based auth credential (obtained from `/auth`).
public struct RegistryIdentityToken: Sendable {
    public let identityToken: String

    public init(identityToken: String) {
        self.identityToken = identityToken
    }

    /// Base64url-encoded JSON representation required by the Docker API's
    /// `X-Registry-Auth` header.
    public func encodedValue() throws -> String {
        let payload: [String: String] = ["identitytoken": identityToken]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension HTTPField.Name {
    /// The `X-Registry-Auth` header used by Docker registry operations.
    public static var xRegistryAuth: Self { .init("X-Registry-Auth")! }
}

/// A middleware that injects the `X-Registry-Auth` header into requests that
/// require registry authentication (e.g. image push/pull from private registries).
///
/// Attach this when building a `Client` if you need to interact with private
/// registries. Requests that don't use the header will simply carry an
/// extra (ignored) header.
public struct RegistryAuthMiddleware: ClientMiddleware, Sendable {

    private let encodedAuth: String

    /// Create a middleware from username/password credentials.
    public init(auth: RegistryAuth) throws {
        self.encodedAuth = try auth.encodedValue()
    }

    /// Create a middleware from a pre-obtained identity token.
    public init(token: RegistryIdentityToken) throws {
        self.encodedAuth = try token.encodedValue()
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.xRegistryAuth] = encodedAuth
        return try await next(request, body, baseURL)
    }
}

// MARK: - Docker Host resolution

/// The resolved connection target derived from a `DOCKER_HOST`-style URI or
/// an explicit caller-supplied value.
///
/// Docker host strings use URI schemes to encode the transport:
///
/// | Scheme          | Transport              | Example                              |
/// |-----------------|------------------------|--------------------------------------|
/// | `unix://`       | Unix-domain socket     | `unix:///var/run/docker.sock`        |
/// | `tcp://`        | Plain TCP (no TLS)     | `tcp://192.168.1.10:2375`            |
/// | `http://`       | Plain HTTP over TCP    | `http://192.168.1.10:2375`           |
/// | `https://`      | HTTPS over TCP         | `https://192.168.1.10:2376`          |
enum DockerHostTarget {
    /// Connect via a Unix-domain socket at the given path.
    case unixSocket(path: String)
    /// Connect via plain HTTP/HTTPS to the given base URL.
    case tcp(url: URL)
}

extension DockerHostTarget {
    /// Parses a Docker host string (as found in `DOCKER_HOST`) into a
    /// strongly-typed connection target.
    ///
    /// - Parameter raw: A Docker host string, e.g.
    ///   `"unix:///var/run/docker.sock"` or `"tcp://192.168.1.10:2375"`.
    /// - Throws: `DockerError.invalidBasePath` if the string is not a
    ///   recognised Docker host URI.
    static func parse(_ raw: String) throws -> DockerHostTarget {
        guard let url = URL(string: raw) else {
            throw DockerError.invalidBasePath("Invalid DOCKER_HOST value: \(raw)")
        }
        switch url.scheme?.lowercased() {
        case "unix":
            // unix:///path/to/docker.sock — the path is in url.path
            let path = url.path
            guard !path.isEmpty else {
                throw DockerError.invalidBasePath(
                    "DOCKER_HOST unix:// URI has no socket path: \(raw)")
            }
            return .unixSocket(path: path)
        case "tcp":
            // Normalise tcp:// → http:// for URLSession
            let httpRaw = "http" + raw.dropFirst("tcp".count)
            guard let httpURL = URL(string: httpRaw) else {
                throw DockerError.invalidBasePath("Invalid DOCKER_HOST value: \(raw)")
            }
            return .tcp(url: httpURL)
        case "http", "https":
            return .tcp(url: url)
        default:
            throw DockerError.invalidBasePath(
                "Unsupported DOCKER_HOST scheme '\(url.scheme ?? "")' in: \(raw)")
        }
    }
}

// MARK: - Docker Client

/// A client for the Docker Engine API.
///
/// ### Automatic configuration via `DOCKER_HOST`
///
/// With no arguments, `Docker()` reads the `DOCKER_HOST` environment variable
/// and configures the correct transport automatically:
///
/// ```swift
/// // Honour whatever DOCKER_HOST is set to, or fall back to the default
/// // Unix socket at /var/run/docker.sock
/// let docker = try Docker()
/// ```
///
/// Supported `DOCKER_HOST` formats:
/// - `unix:///var/run/docker.sock` — Unix-domain socket (default on Linux)
/// - `unix:///Users/me/.docker/run/docker.sock` — Docker Desktop on macOS
/// - `tcp://192.168.1.10:2375` — remote daemon over plain TCP
/// - `http://192.168.1.10:2375` — remote daemon over HTTP
/// - `https://192.168.1.10:2376` — remote daemon over HTTPS
///
/// ### Explicit Unix socket
///
/// ```swift
/// let docker = try Docker(socketPath: "/Users/me/.docker/run/docker.sock")
/// ```
///
/// ### Explicit TCP host
///
/// ```swift
/// let docker = try Docker(host: "http://192.168.1.10:2375")
/// ```
///
/// ### Registry authentication
///
/// Supply `registryAuth` when you need to push/pull images from a private
/// registry. The credentials are injected as the `X-Registry-Auth` header:
///
/// ```swift
/// let auth = RegistryAuth(username: "user", password: "pass",
///                         serverAddress: "registry.example.com")
/// let docker = try Docker(registryAuth: auth)
/// ```
public struct Docker: Sendable {
    public let client: Client

    /// The server base URL the client sends requests to.
    public let serverURL: URL

    // MARK: - Exec helpers

    /// Polls `execInspect` until the exec instance has finished running, then
    /// returns its exit code.
    ///
    /// When you start an exec instance with `detach: true` the API returns
    /// immediately — there is no blocking call to wait on. Use this method
    /// afterwards to find out when the command finished and whether it succeeded:
    ///
    /// ```swift
    /// let execID = try await docker.client.containerExec(.init(
    ///     path: .init(id: containerID),
    ///     body: .json(.init(attachStdout: true, cmd: ["ls", "/"]))
    /// )).created.body.json.id
    ///
    /// _ = try await docker.client.execStart(.init(
    ///     path: .init(id: execID),
    ///     body: .json(.init(detach: true))
    /// )).ok
    ///
    /// let exitCode = try await docker.waitForExec(id: execID)
    /// // exitCode == 0  →  success
    /// ```
    ///
    /// - Parameters:
    ///   - execID: The exec instance ID returned by `containerExec`.
    ///   - pollInterval: How often to re-query `execInspect` while the
    ///     process is still running. Defaults to 50 ms.
    /// - Returns: The process exit code (`0` = success). Returns `-1` if
    ///   the daemon does not report an exit code.
    /// - Throws: Any error from the underlying `execInspect` call.
    public func waitForExec(
        id execID: String,
        pollInterval: Duration = .milliseconds(50)
    ) async throws -> Int {
        while true {
            let info = try await client.execInspect(.init(
                path: .init(id: execID)
            )).ok.body.json
            if info.running == false {
                return info.exitCode ?? -1
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    // MARK: - Environment-aware default init

    /// Creates a Docker client by reading `DOCKER_HOST` from the environment,
    /// falling back to the standard Unix socket if the variable is not set.
    ///
    /// This mirrors the behaviour of the official Docker CLI and most Docker
    /// SDKs: set `DOCKER_HOST` in the environment and every tool that uses
    /// this library will automatically point at the right daemon.
    ///
    /// **Fallback order:**
    /// 1. `DOCKER_HOST` environment variable (if set and non-empty)
    /// 2. `/var/run/docker.sock` (Linux default)
    ///
    /// - Parameters:
    ///   - apiVersion: The API version path component. Defaults to `"v1.53"`.
    ///   - registryAuth: Optional registry credentials for private image
    ///     operations.
    ///   - requestTimeout: Per-request timeout in seconds. Defaults to `300`.
    ///   - additionalMiddlewares: Extra middlewares appended after the
    ///     registry-auth middleware.
    public init(
        apiVersion: String = "v1.53",
        registryAuth: RegistryAuth? = nil,
        requestTimeout: TimeInterval = 300,
        additionalMiddlewares: [any ClientMiddleware] = []
    ) throws {
        let dockerHost = ProcessInfo.processInfo.environment["DOCKER_HOST"]
        let target: DockerHostTarget
        if let raw = dockerHost, !raw.isEmpty {
            target = try DockerHostTarget.parse(raw)
        } else {
            // Standard Linux fallback — Docker Desktop on macOS sets
            // DOCKER_HOST automatically when the daemon is running.
            target = .unixSocket(path: "/var/run/docker.sock")
        }
        try self.init(
            target: target,
            apiVersion: apiVersion,
            registryAuth: registryAuth,
            requestTimeout: requestTimeout,
            additionalMiddlewares: additionalMiddlewares
        )
    }

    // MARK: - Explicit Unix socket init

    /// Creates a Docker client that communicates with the daemon via a
    /// Unix-domain socket.
    ///
    /// - Parameters:
    ///   - socketPath: Absolute path to the Docker daemon socket.
    ///     Common values:
    ///     - macOS Docker Desktop: `"/Users/<name>/.docker/run/docker.sock"`
    ///     - Linux / Docker Engine: `"/var/run/docker.sock"`
    ///   - apiVersion: The API version path component. Defaults to `"v1.53"`.
    ///   - registryAuth: Optional registry credentials for private image
    ///     operations.
    ///   - requestTimeout: Per-request timeout in seconds. Defaults to `300`.
    ///   - additionalMiddlewares: Extra middlewares appended after the
    ///     registry-auth middleware.
    public init(
        socketPath: String,
        apiVersion: String = "v1.53",
        registryAuth: RegistryAuth? = nil,
        requestTimeout: TimeInterval = 300,
        additionalMiddlewares: [any ClientMiddleware] = []
    ) throws {
        try self.init(
            target: .unixSocket(path: socketPath),
            apiVersion: apiVersion,
            registryAuth: registryAuth,
            requestTimeout: requestTimeout,
            additionalMiddlewares: additionalMiddlewares
        )
    }

    // MARK: - Explicit TCP / custom transport init

    /// Creates a Docker client that communicates with the daemon over TCP or
    /// using a fully custom transport.
    ///
    /// - Parameters:
    ///   - host: The base URL of the Docker daemon, e.g.
    ///     `"http://192.168.1.10:2375"`. When `nil`, falls back to
    ///     `DOCKER_HOST` then `/var/run/docker.sock` — prefer the no-argument
    ///     `init()` for that case.
    ///   - registryAuth: Optional registry credentials for private image
    ///     operations.
    ///   - transport: The OpenAPI transport to use. Defaults to
    ///     `URLSessionTransport()`.
    ///   - additionalMiddlewares: Extra middlewares appended after the
    ///     registry-auth middleware.
    ///   - client: A fully pre-built `Client`. When supplied, all other
    ///     parameters are ignored.
    public init(
        host: String,
        registryAuth: RegistryAuth? = nil,
        transport: (any ClientTransport)? = nil,
        additionalMiddlewares: [any ClientMiddleware] = [],
        client: Client? = nil
    ) throws {
        guard let url = URL(string: host) else {
            throw DockerError.invalidBasePath("Invalid Docker host URL: \(host)")
        }
        self.serverURL = url

        if let client {
            self.client = client
            return
        }

        var middlewares: [any ClientMiddleware] = []
        if let auth = registryAuth {
            middlewares.append(try RegistryAuthMiddleware(auth: auth))
        }
        middlewares.append(contentsOf: additionalMiddlewares)

        self.client = Client(
            serverURL: url,
            transport: transport ?? URLSessionTransport(),
            middlewares: middlewares
        )
    }

    // MARK: - Internal target-based init

    /// Shared implementation that builds the client from a resolved
    /// ``DockerHostTarget``.
    private init(
        target: DockerHostTarget,
        apiVersion: String,
        registryAuth: RegistryAuth?,
        requestTimeout: TimeInterval,
        additionalMiddlewares: [any ClientMiddleware]
    ) throws {
        var middlewares: [any ClientMiddleware] = []
        if let auth = registryAuth {
            middlewares.append(try RegistryAuthMiddleware(auth: auth))
        }
        middlewares.append(contentsOf: additionalMiddlewares)

        switch target {
        case .unixSocket(let path):
            guard let url = URL(string: "http://localhost/\(apiVersion)") else {
                throw DockerError.invalidBasePath(
                    "Could not build server URL for API version \(apiVersion).")
            }
            self.serverURL = url
            self.client = Client(
                serverURL: url,
                transport: UnixSocketTransport.make(
                    socketPath: path,
                    requestTimeout: requestTimeout
                ),
                middlewares: middlewares
            )

        case .tcp(let baseURL):
            // Append the API version path to the TCP base URL.
            let versionedURL = baseURL.appendingPathComponent(apiVersion)
            self.serverURL = versionedURL
            self.client = Client(
                serverURL: versionedURL,
                transport: URLSessionTransport(),
                middlewares: middlewares
            )
        }
    }
}
