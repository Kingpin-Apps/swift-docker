# Connecting to Docker

Choose the right transport for your environment — local Unix socket, remote TCP, or a custom transport.

## Overview

``Docker`` supports three connection modes. Pick the one that matches your deployment:

| Mode | When to use |
|------|-------------|
| Automatic (`Docker()`) | Development — honours `DOCKER_HOST` just like the CLI |
| Explicit socket path | CI, Docker Desktop on macOS, or a non-standard socket location |
| TCP / HTTP(S) | Remote daemons, Docker-in-Docker, or test servers |

## Automatic connection (recommended)

With no arguments, ``Docker`` reads `DOCKER_HOST` and falls back to `/var/run/docker.sock`:

```swift
let docker = try Docker()
```

Supported `DOCKER_HOST` formats:

| Value | Transport |
|-------|-----------|
| `unix:///var/run/docker.sock` | Unix socket — Linux default |
| `unix:///Users/me/.docker/run/docker.sock` | Unix socket — Docker Desktop on macOS |
| `tcp://192.168.1.10:2375` | Plain TCP (normalised to HTTP) |
| `http://192.168.1.10:2375` | HTTP over TCP |
| `https://192.168.1.10:2376` | HTTPS over TCP |

If `DOCKER_HOST` is not set the library falls back to `/var/run/docker.sock`.

## Explicit Unix socket

Use ``Docker/init(socketPath:apiVersion:registryAuth:requestTimeout:additionalMiddlewares:)`` when you know the exact path and do not want to rely on the environment:

```swift
// Docker Desktop on macOS
let docker = try Docker(
    socketPath: "/Users/alice/.docker/run/docker.sock"
)

// Standard Linux path
let docker = try Docker(
    socketPath: "/var/run/docker.sock"
)
```

Internally this creates a ``UnixSocketTransport`` backed by a custom `URLProtocol` that opens a raw POSIX socket. No external library is required.

## TCP / HTTP(S) host

Use ``Docker/init(host:registryAuth:transport:additionalMiddlewares:client:)`` to connect to a remote daemon or one exposed over TCP:

```swift
// Plain HTTP (no TLS)
let docker = try Docker(host: "http://192.168.1.10:2375")

// HTTPS
let docker = try Docker(host: "https://192.168.1.10:2376")
```

> Note: The API version path component (`/v1.53`) is appended automatically only for Unix-socket and `DOCKER_HOST`-parsed connections. When you supply a `host:` string directly, include the full base URL you want to use.

## Custom API version

The default API version is `v1.53`. Override it at init time if you need to target an older daemon:

```swift
let docker = try Docker(apiVersion: "v1.47")
```

## Custom transport

Pass any type that conforms to `ClientTransport` to use your own HTTP stack:

```swift
import OpenAPIAsyncHTTPClient

let transport = AsyncHTTPClientTransport()
let docker = try Docker(
    host: "http://192.168.1.10:2375",
    transport: transport
)
```

## Bringing your own pre-built client

If you need full control — for testing or advanced middleware chains — pass a fully constructed `Client` directly:

```swift
let myClient = Client(
    serverURL: URL(string: "http://localhost/v1.53")!,
    transport: myTransport,
    middlewares: [myLoggingMiddleware, myAuthMiddleware]
)
let docker = try Docker(host: "http://localhost/v1.53", client: myClient)
```

When a `client:` is supplied all other parameters are ignored.

## Request timeout

Long-polling endpoints such as `/containers/{id}/wait` can block for minutes. The default timeout is 300 seconds. Adjust it per-client:

```swift
let docker = try Docker(requestTimeout: 600)  // 10 minutes
```

## Error handling

``Docker`` throws ``DockerError/invalidBasePath(_:)`` when the host string or socket path cannot be resolved:

```swift
do {
    let docker = try Docker(host: "not a url")
} catch let err as DockerError {
    print(err)  // "Invalid Docker host URL: not a url"
}
```
