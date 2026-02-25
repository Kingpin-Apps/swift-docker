# Working with Containers

Create, start, inspect, stop, and remove containers using the Docker Engine API.

## Overview

The container lifecycle in Docker maps directly onto a small set of API calls. SwiftDocker exposes all of them through ``Docker/client``. This article walks through the most common operations in order.

## Creating a container

`containerCreate` corresponds to `docker create` / `docker run`. Supply the image name and any command override via the request body:

```swift
let docker = try Docker()

let response = try await docker.client.containerCreate(.init(
    body: .json(.init(
        value1: .init(
            cmd: ["echo", "hello world"],
            image: "alpine"
        ),
        value2: .init()
    ))
)).created.body.json

let containerID = response.id
print("Created: \(containerID)")

// Warnings (e.g. deprecated flags) are returned alongside the ID
if !response.warnings.isEmpty {
    print("Warnings: \(response.warnings)")
}
```

### Naming a container

```swift
let response = try await docker.client.containerCreate(.init(
    query: .init(name: "my-app"),
    body: .json(.init(
        value1: .init(image: "nginx"),
        value2: .init()
    ))
)).created.body.json
```

### Environment variables and port bindings

```swift
let response = try await docker.client.containerCreate(.init(
    body: .json(.init(
        value1: .init(
            env: ["PORT=8080", "DEBUG=true"],
            image: "my-server",
            exposedPorts: ["8080/tcp": .init()]
        ),
        value2: .init()
    ))
)).created.body.json
```

## Starting a container

`containerStart` corresponds to `docker start`:

```swift
_ = try await docker.client.containerStart(.init(
    path: .init(id: containerID)
)).noContent
```

## Waiting for a container to exit

`containerWait` blocks (on the server side) until the specified condition is met. Use `.notRunning` when you want to wait for a container that may already have stopped:

```swift
let result = try await docker.client.containerWait(.init(
    path: .init(id: containerID),
    query: .init(condition: .notRunning)
)).ok.body.json

print("Exit status: \(result.statusCode)")
if let err = result.error, let msg = err.message {
    print("Error: \(msg)")
}
```

Available wait conditions:

| Condition | Meaning |
|-----------|---------|
| `.notRunning` | Resolves as soon as the container is no longer running |
| `.nextExit` | Resolves on the next exit event |
| `.removed` | Resolves once the container is removed |

> Tip: The default request timeout is 300 seconds. Increase it via ``Docker/init(apiVersion:registryAuth:requestTimeout:additionalMiddlewares:)`` if your containers may run longer.

## Inspecting a container

`containerInspect` corresponds to `docker inspect`:

```swift
let info = try await docker.client.containerInspect(.init(
    path: .init(id: containerID)
)).ok.body.json

print("Status: \(info.state?.status ?? "unknown")")
print("Image:  \(info.image ?? "-")")
```

## Listing containers

List only running containers (`all: false` is the default):

```swift
let running = try await docker.client.containerList(.init(
    query: .init(all: false)
)).ok.body.json
```

Include stopped containers:

```swift
let all = try await docker.client.containerList(.init(
    query: .init(all: true)
)).ok.body.json

for c in all {
    print("\(c.id.prefix(12))  \(c.image)  \(c.state)")
}
```

## Stopping and removing a container

```swift
// Stop (sends SIGTERM, waits up to 10 s, then SIGKILL)
_ = try? await docker.client.containerStop(.init(
    path: .init(id: containerID)
))

// Remove
_ = try await docker.client.containerDelete(.init(
    path: .init(id: containerID),
    query: .init(v: false, force: false)
)).noContent
```

Force-remove a running container in one call:

```swift
_ = try await docker.client.containerDelete(.init(
    path: .init(id: containerID),
    query: .init(force: true)
)).noContent
```

## Pulling an image before creating a container

`containerCreate` returns a `404` if the image is not present locally. Pull it first with `imageCreate`:

```swift
_ = try await docker.client.imageCreate(.init(
    query: .init(fromImage: "alpine", tag: "latest")
)).ok

let containerID = try await docker.client.containerCreate(.init(
    body: .json(.init(
        value1: .init(image: "alpine:latest"),
        value2: .init()
    ))
)).created.body.json.id
```

## Complete example — run and capture output

```swift
import SwiftDocker
import Foundation

let docker = try Docker(socketPath: "/Users/me/.docker/run/docker.sock")

// Create
let containerID = try await docker.client.containerCreate(.init(
    body: .json(.init(
        value1: .init(cmd: ["sh", "-c", "echo stdout; echo stderr >&2"], image: "alpine"),
        value2: .init()
    ))
)).created.body.json.id

// Start
_ = try await docker.client.containerStart(.init(
    path: .init(id: containerID)
)).noContent

// Wait
let exit = try await docker.client.containerWait(.init(
    path: .init(id: containerID),
    query: .init(condition: .notRunning)
)).ok.body.json
assert(exit.statusCode == 0)

// Fetch stdout + stderr
let body = try await docker.client.containerLogs(.init(
    path: .init(id: containerID),
    query: .init(stdout: true, stderr: true)
)).ok.body.applicationVnd_docker_multiplexedStream

let data = try await Data(collecting: body, upTo: 1024 * 1024)
let text = DockerMultiplexedStream.text(from: data, includeStderr: true)
print(text)  // "stdout\nstderr\n"

// Clean up
_ = try? await docker.client.containerDelete(.init(
    path: .init(id: containerID)
)).noContent
```
