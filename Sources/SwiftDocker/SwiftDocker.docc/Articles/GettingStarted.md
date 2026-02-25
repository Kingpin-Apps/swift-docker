# Getting Started with SwiftDocker

Install the package, connect to Docker, and run your first container in minutes.

## Overview

SwiftDocker is a Swift Package Manager library. Once added as a dependency you create a ``Docker`` instance, call methods on ``Docker/client``, and use standard Swift async/await throughout.

## Installation

Add the package to your `Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/your-org/swift-docker", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "MyApp",
            dependencies: [
                .product(name: "SwiftDocker", package: "swift-docker"),
            ]
        ),
    ]
)
```

Then fetch dependencies:

```bash
swift package resolve
```

> Important: SwiftDocker uses the Swift OpenAPI Generator build plugin to generate its API client at compile time. **You must build the project at least once** after adding the dependency before you can use any types from `SwiftDocker`. In Xcode, press **⌘B** (Product → Build). On the command line run `swift build`. Until the first build completes, the generated `Client` type and all API types will appear to be missing.

## Connecting to the daemon

The simplest way to connect is to call ``Docker/init(apiVersion:registryAuth:requestTimeout:additionalMiddlewares:)`` with no arguments. It reads the `DOCKER_HOST` environment variable — or falls back to `/var/run/docker.sock` — exactly the same way the Docker CLI does:

```swift
import SwiftDocker

let docker = try Docker()
```

On macOS with Docker Desktop running, `DOCKER_HOST` is typically set to the user-scoped socket path automatically. On Linux the standard `/var/run/docker.sock` is used.

> Tip: See <doc:ConnectingToDocker> for all connection options including explicit socket paths, TCP hosts, and custom transports.

## Listing running containers

```swift
let docker = try Docker()

// containerList returns only running containers by default (all: false)
let containers = try await docker.client.containerList(.init(
    query: .init(all: false)
)).ok.body.json

for container in containers {
    print("\(container.id.prefix(12))  \(container.image)  \(container.state)")
}
```

## Running a one-shot container

The snippet below creates an Alpine container, starts it, waits for it to exit, then reads its stdout:

```swift
import SwiftDocker
import Foundation

let docker = try Docker()

// 1. Create
let containerID = try await docker.client.containerCreate(.init(
    body: .json(.init(
        value1: .init(cmd: ["echo", "hello world"], image: "alpine"),
        value2: .init()
    ))
)).created.body.json.id

// 2. Start
_ = try await docker.client.containerStart(.init(
    path: .init(id: containerID)
)).noContent

// 3. Wait for exit
let status = try await docker.client.containerWait(.init(
    path: .init(id: containerID),
    query: .init(condition: .notRunning)
)).ok.body.json.statusCode

print("Exited: \(status)")  // 0

// 4. Read logs
let rawLogs = try await docker.client.containerLogs(.init(
    path: .init(id: containerID),
    query: .init(stdout: true)
)).ok.body.applicationVnd_docker_multiplexedStream

let data = try await Data(collecting: rawLogs, upTo: 1024 * 1024)
print(DockerMultiplexedStream.text(from: data))  // "hello world\n"
```

## Next steps

- <doc:ConnectingToDocker> — all connection options
- <doc:WorkingWithContainers> — full container lifecycle
- <doc:ExecAndLogs> — exec commands and stream logs
- <doc:RegistryAuthentication> — private registry credentials
