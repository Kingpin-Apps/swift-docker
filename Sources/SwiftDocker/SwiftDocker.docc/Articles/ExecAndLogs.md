# Exec Commands and Reading Logs

Run commands inside running containers and decode Docker's multiplexed log stream.

## Overview

Docker provides two mechanisms for getting output from a container:

- **Logs** — retrieve the buffered stdout/stderr of a container's main process via `containerLogs`.
- **Exec** — create and start a new process inside a running container via `containerExec` + `execStart`.

Both return output in Docker's multiplexed stream format, which ``DockerMultiplexedStream`` can decode into clean text or individual ``DockerLogFrame`` values.

## Reading container logs

`containerLogs` returns the accumulated output of the container's main process. The response body is a `application/vnd.docker.multiplexed-stream` — an async byte sequence you collect into `Data` and then decode:

```swift
import Foundation
import SwiftDocker

let docker = try Docker()

let logsBody = try await docker.client.containerLogs(.init(
    path: .init(id: containerID),
    query: .init(stdout: true, stderr: true)
)).ok.body.applicationVnd_docker_multiplexedStream

// Collect up to 1 MB
let data = try await Data(collecting: logsBody, upTo: 1024 * 1024)

// Decode to plain text (stdout only by default)
let text = DockerMultiplexedStream.text(from: data)
print(text)

// Include stderr interleaved with stdout
let combined = DockerMultiplexedStream.text(from: data, includeStderr: true)
```

### Log query options

| Option | Type | Description |
|--------|------|-------------|
| `stdout` | `Bool?` | Include stdout frames |
| `stderr` | `Bool?` | Include stderr frames |
| `since` | `Int?` | Only logs since this Unix timestamp |
| `tail` | `String?` | Number of lines from end, or `"all"` |
| `timestamps` | `Bool?` | Prepend RFC3339 timestamps |

```swift
// Last 50 lines with timestamps
let logsBody = try await docker.client.containerLogs(.init(
    path: .init(id: containerID),
    query: .init(stdout: true, stderr: true, timestamps: true, tail: "50")
)).ok.body.applicationVnd_docker_multiplexedStream
```

## Understanding the multiplexed stream

When a container runs without a TTY (`Tty: false`), Docker multiplexes stdout and stderr into a single byte stream using 8-byte frame headers:

```
┌──────────┬────────────────┬──────────────────────────────────────┐
│ stream   │ padding (3 B)  │ payload size (4 B, big-endian)       │
│ (1 byte) │                │                                      │
├──────────┴────────────────┴──────────────────────────────────────┤
│ payload  (size bytes)                                            │
└──────────────────────────────────────────────────────────────────┘
```

Stream byte values: `0` = stdin, `1` = stdout, `2` = stderr.

### Decoding individual frames

Use ``DockerMultiplexedStream/decode(_:)`` when you need to handle stdout and stderr separately:

```swift
let frames = DockerMultiplexedStream.decode(data)

for frame in frames {
    switch frame.stream {
    case .stdout:
        print("[OUT] \(frame.text ?? "<binary>")")
    case .stderr:
        print("[ERR] \(frame.text ?? "<binary>")")
    case .stdin:
        break
    }
}
```

Each ``DockerLogFrame`` exposes:
- ``DockerLogFrame/stream`` — the ``DockerStreamType`` (`stdin`, `stdout`, or `stderr`)
- ``DockerLogFrame/payload`` — raw `Data`
- ``DockerLogFrame/text`` — payload decoded as UTF-8, or `nil` for binary frames

## Running exec commands

Exec lets you run an additional process inside an already-running container. The typical flow is:

1. **Create** the exec instance with `containerExec`.
2. **Start** it with `execStart`.
3. **Wait** for it to finish with ``Docker/waitForExec(id:pollInterval:)``.

### Detached exec (fire-and-forget)

```swift
let docker = try Docker()

// Create the exec instance
let execID = try await docker.client.containerExec(.init(
    path: .init(id: containerID),
    body: .json(.init(
        attachStdout: true,
        attachStderr: true,
        cmd: ["ls", "/"]
    ))
)).created.body.json.id

// Start it detached
_ = try await docker.client.execStart(.init(
    path: .init(id: execID),
    body: .json(.init(detach: true))
)).ok

// Poll until the process finishes, then get the exit code
let exitCode = try await docker.waitForExec(id: execID)
print("Exit code: \(exitCode)")  // 0 = success
```

### Multiple exec commands on the same container

You can run as many exec instances as you like sequentially or concurrently on a single container:

```swift
let docker = try Docker(socketPath: "/Users/me/.docker/run/docker.sock")

// Start a long-lived container
let containerID = try await docker.client.containerCreate(.init(
    body: .json(.init(
        value1: .init(cmd: ["sleep", "60"], image: "alpine"),
        value2: .init()
    ))
)).created.body.json.id

_ = try await docker.client.containerStart(.init(
    path: .init(id: containerID)
)).noContent

// Exec 1: list root directory
let lsID = try await docker.client.containerExec(.init(
    path: .init(id: containerID),
    body: .json(.init(attachStdout: true, cmd: ["ls", "/"]))
)).created.body.json.id

_ = try await docker.client.execStart(.init(
    path: .init(id: lsID),
    body: .json(.init(detach: true))
)).ok

let lsExit = try await docker.waitForExec(id: lsID)
assert(lsExit == 0)

// Exec 2: echo a message
let echoID = try await docker.client.containerExec(.init(
    path: .init(id: containerID),
    body: .json(.init(attachStdout: true, cmd: ["echo", "hello from exec"]))
)).created.body.json.id

_ = try await docker.client.execStart(.init(
    path: .init(id: echoID),
    body: .json(.init(detach: true))
)).ok

let echoExit = try await docker.waitForExec(id: echoID)
assert(echoExit == 0)

// Stop the container when done
_ = try? await docker.client.containerStop(.init(
    path: .init(id: containerID)
))
```

### Inspecting an exec instance

``Docker/waitForExec(id:pollInterval:)`` uses `execInspect` internally. You can also call it directly:

```swift
let info = try await docker.client.execInspect(.init(
    path: .init(id: execID)
)).ok.body.json

print("Running:   \(info.running ?? false)")
print("Exit code: \(info.exitCode ?? -1)")
print("PID:       \(info.pid ?? 0)")
```

## Poll interval

``Docker/waitForExec(id:pollInterval:)`` defaults to polling every 50 milliseconds. Adjust it for long-running commands:

```swift
let exitCode = try await docker.waitForExec(
    id: execID,
    pollInterval: .milliseconds(200)
)
```
