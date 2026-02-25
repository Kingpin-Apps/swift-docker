# SwiftDocker

A Swift client library for the [Docker Engine API](https://docs.docker.com/engine/api/), built on top of [Swift OpenAPI Generator](https://github.com/apple/swift-openapi-generator). Communicates with the Docker daemon over a Unix socket or TCP, with full async/await support.

## Requirements

- Swift 6.2+
- macOS 13+ / Linux

## Installation

Add SwiftDocker to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/swift-docker", from: "1.0.0"),
],
targets: [
    .target(
        name: "MyTarget",
        dependencies: [
            .product(name: "SwiftDocker", package: "swift-docker"),
        ]
    ),
]
```

> **Important:** SwiftDocker uses the Swift OpenAPI Generator build plugin to generate its API client at compile time. You must build the project at least once after adding the dependency before the generated types are available in your code. In Xcode press **⌘B**, or on the command line run:
>
> ```bash
> swift build
> ```

## Connecting to Docker

### Automatic (recommended)

With no arguments, `Docker()` reads the `DOCKER_HOST` environment variable and falls back to `/var/run/docker.sock`:

```swift
let docker = try Docker()
```

Supported `DOCKER_HOST` formats:

| Format | Transport |
|--------|-----------|
| `unix:///var/run/docker.sock` | Unix socket (Linux default) |
| `unix:///Users/me/.docker/run/docker.sock` | Unix socket (Docker Desktop on macOS) |
| `tcp://192.168.1.10:2375` | Plain TCP |
| `http://192.168.1.10:2375` | HTTP over TCP |
| `https://192.168.1.10:2376` | HTTPS over TCP |

### Explicit Unix socket

```swift
let docker = try Docker(socketPath: "/Users/me/.docker/run/docker.sock")
```

### Explicit TCP host

```swift
let docker = try Docker(host: "http://192.168.1.10:2375")
```

### Private registry authentication

Supply `registryAuth` to authenticate with a private registry. The credentials are injected as the `X-Registry-Auth` header on every request:

```swift
let auth = RegistryAuth(
    username: "myuser",
    password: "mypassword",
    serverAddress: "registry.example.com"
)
let docker = try Docker(registryAuth: auth)
```

If you have a pre-obtained identity token (from `/auth`):

```swift
let token = RegistryIdentityToken(identityToken: "my-identity-token")
let docker = try Docker(registryAuth: nil) // then attach RegistryAuthMiddleware manually
```

## Examples

### Run a container and capture its output

Create an Alpine container, run a command, wait for it to finish, and read the logs:

```swift
let docker = try Docker(socketPath: "/Users/me/.docker/run/docker.sock")

// 1. Create the container
let createBody = try await docker.client.containerCreate(.init(
    body: .json(.init(
        value1: .init(
            cmd: ["echo", "hello world"],
            image: "alpine"
        ),
        value2: .init()
    ))
)).created.body.json

let containerID = createBody.id
print("Created container: \(containerID)")

// 2. Start the container
_ = try await docker.client.containerStart(.init(
    path: .init(id: containerID)
)).noContent

// 3. Wait for it to finish
let waitResult = try await docker.client.containerWait(.init(
    path: .init(id: containerID),
    query: .init(condition: .notRunning)
)).ok.body.json

print("Exited with status: \(waitResult.statusCode)")

// 4. Fetch stdout logs
let logsBody = try await docker.client.containerLogs(.init(
    path: .init(id: containerID),
    query: .init(stdout: true)
)).ok.body.applicationVnd_docker_multiplexedStream

let logsData = try await Data(collecting: logsBody, upTo: 1024 * 1024)
let logText = DockerMultiplexedStream.text(from: logsData)
print("Output: \(logText)") // "hello world\n"
```

### Exec a command inside a running container

Start a long-running container and exec commands into it:

```swift
let docker = try Docker(socketPath: "/Users/me/.docker/run/docker.sock")

// 1. Create and start a long-running container
let containerID = try await docker.client.containerCreate(.init(
    body: .json(.init(
        value1: .init(cmd: ["sleep", "30"], image: "alpine"),
        value2: .init()
    ))
)).created.body.json.id

_ = try await docker.client.containerStart(.init(
    path: .init(id: containerID)
)).noContent

// 2. Create an exec instance
let execID = try await docker.client.containerExec(.init(
    path: .init(id: containerID),
    body: .json(.init(
        attachStdout: true,
        attachStderr: true,
        cmd: ["ls", "/"]
    ))
)).created.body.json.id

// 3. Start it detached
_ = try await docker.client.execStart(.init(
    path: .init(id: execID),
    body: .json(.init(detach: true))
)).ok

// 4. Wait for the exec to finish and check its exit code
let exitCode = try await docker.waitForExec(id: execID)
print("Exit code: \(exitCode)") // 0 = success

// 5. Clean up
_ = try? await docker.client.containerStop(.init(
    path: .init(id: containerID)
))
```

### Decode multiplexed log output

Docker multiplexes stdout and stderr into a single stream when `Tty: false`. Use `DockerMultiplexedStream` to decode it:

```swift
// Collect raw multiplexed stream data
let logsBody = try await docker.client.containerLogs(.init(
    path: .init(id: containerID),
    query: .init(stdout: true, stderr: true)
)).ok.body.applicationVnd_docker_multiplexedStream

let rawData = try await Data(collecting: logsBody, upTo: 1024 * 1024)

// Decode into individual frames (each with a stream type and payload)
let frames = DockerMultiplexedStream.decode(rawData)
for frame in frames {
    switch frame.stream {
    case .stdout: print("[stdout] \(frame.text ?? "")")
    case .stderr: print("[stderr] \(frame.text ?? "")")
    case .stdin:  break
    }
}

// Or get stdout as a plain string (optionally include stderr)
let stdoutOnly = DockerMultiplexedStream.text(from: rawData)
let combined   = DockerMultiplexedStream.text(from: rawData, includeStderr: true)
```

### List running containers

```swift
let docker = try Docker()

let containers = try await docker.client.containerList(.init(
    query: .init(all: false) // only running containers
)).ok.body.json

for container in containers {
    print("\(container.id.prefix(12))  \(container.image)  \(container.state)")
}
```

### Pull an image

```swift
let docker = try Docker()

_ = try await docker.client.imageCreate(.init(
    query: .init(fromImage: "alpine", tag: "latest")
)).ok
```

## API version

The default API version is `v1.53`. You can override it at init time:

```swift
let docker = try Docker(apiVersion: "v1.47")
```

## Error handling

All errors thrown from the `Docker` initialiser conform to `DockerError`:

```swift
do {
    let docker = try Docker(host: "not-a-valid-url")
} catch let error as DockerError {
    print(error) // "Invalid Docker host URL: not-a-valid-url"
}
```

`DockerError` cases:

| Case | Description |
|------|-------------|
| `.invalidBasePath(String?)` | The supplied host/socket path could not be parsed |
| `.valueError(String?)` | A value supplied to the library was invalid |

## Architecture

- **`Docker`** — the main entry point. Wraps an OpenAPI-generated `Client` and provides convenience helpers like `waitForExec(id:pollInterval:)`.
- **`UnixSocketTransport`** — a `URLSessionTransport`-compatible transport that routes requests over a POSIX Unix-domain socket. Used automatically when connecting via a socket path.
- **`DockerMultiplexedStream`** — decoder for Docker's multiplexed log stream format (`application/vnd.docker.multiplexed-stream`).
- **`RegistryAuthMiddleware`** — an OpenAPI `ClientMiddleware` that injects the `X-Registry-Auth` header for private registry operations.
- **`Client`** — the raw OpenAPI-generated client, available as `docker.client`. Every Docker Engine API endpoint is accessible directly on this object.

## License

See [LICENSE](LICENSE).
