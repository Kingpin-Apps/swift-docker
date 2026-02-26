import Testing
import Foundation
import HTTPTypes
@testable import SwiftDocker

// MARK: - Tests

/// Equivalent to:
///
///   curl --unix-socket $SOCK -d '{"Image":"alpine","Cmd":["echo","hello world"]}' \
///        -X POST http://localhost/v1.53/containers/create
///   curl --unix-socket $SOCK -X POST http://localhost/v1.53/containers/{id}/start
///   curl --unix-socket $SOCK -X POST http://localhost/v1.53/containers/{id}/wait
///   curl --unix-socket $SOCK "http://localhost/v1.53/containers/{id}/logs?stdout=1"
@Test func runAlpineEchoContainer() async throws {
    let transport = MockTransport()

    await transport.register(operationID: "ContainerCreate") { _, _ in
        (Fixtures.jsonResponse(status: .created), try Fixtures.containerCreateBody(id: "abc123"))
    }
    await transport.register(operationID: "ContainerStart") { _, _ in
        (Fixtures.noContentResponse(), nil)
    }
    await transport.register(operationID: "ContainerWait") { _, _ in
        (Fixtures.jsonResponse(status: .ok), try Fixtures.containerWaitBody(statusCode: 0))
    }
    await transport.register(operationID: "ContainerLogs") { _, _ in
        (Fixtures.multiplexedStreamResponse(status: .ok), Fixtures.containerLogsBody(message: "hello world\n"))
    }

    let docker = try Docker.mock(transport: transport)

    // 1. Create the container.
    let createResponse = try await docker.client.containerCreate(.init(
        body: .json(.init(
            value1: .init(
                cmd: ["echo", "hello world"],
                image: "alpine"
            ),
            value2: .init()
        ))
    ))
    let createBody = try createResponse.created.body.json
    let containerID = createBody.id
    #expect(containerID == "abc123")
    #expect(createBody.warnings.isEmpty)

    // 2. Start the container.
    _ = try await docker.client.containerStart(.init(
        path: .init(id: containerID)
    )).noContent

    // 3. Wait for the container to finish.
    let waitResult = try await docker.client.containerWait(.init(
        path: .init(id: containerID),
        query: .init(condition: .notRunning)
    )).ok.body.json
    #expect(waitResult.statusCode == 0)

    // 4. Fetch stdout logs.
    let logsBody = try await docker.client.containerLogs(.init(
        path: .init(id: containerID),
        query: .init(stdout: true)
    )).ok.body.applicationVnd_docker_multiplexedStream
    let logsData = try await Data(collecting: logsBody, upTo: 1024 * 1024)

    let logText = DockerMultiplexedStream.text(from: logsData)
    #expect(logText.contains("hello world"))
}

/// Equivalent to:
///
///   # Create and start a long-running container
///   curl --unix-socket $SOCK -d '{"Image":"alpine","Cmd":["sleep","30"]}' \
///        -X POST http://localhost/v1.53/containers/create
///   curl --unix-socket $SOCK -X POST http://localhost/v1.53/containers/{id}/start
///
///   # Create an exec instance for `ls /`
///   curl --unix-socket $SOCK \
///        -d '{"Cmd":["ls","/"],"AttachStdout":true,"Detach":true}' \
///        -X POST http://localhost/v1.53/containers/{id}/exec
///
///   # Start it detached
///   curl --unix-socket $SOCK -d '{"Detach":true}' \
///        -X POST http://localhost/v1.53/exec/{execID}/start
///
///   # Inspect to get the exit code
///   curl --unix-socket $SOCK http://localhost/v1.53/exec/{execID}/json
///
///   # Repeat for `echo hello from exec`
///   ...
@Test func dockerExecOnRunningContainer() async throws {
    let transport = MockTransport()

    // containerCreate returns the same ID regardless of which container is
    // being created — tests only care that the ID flows through correctly.
    await transport.register(operationID: "ContainerCreate") { _, _ in
        (Fixtures.jsonResponse(status: .created), try Fixtures.containerCreateBody(id: "deadbeef1234"))
    }
    await transport.register(operationID: "ContainerStart") { _, _ in
        (Fixtures.noContentResponse(), nil)
    }
    // containerExec issues unique IDs for the two exec instances.
    let execIDs = ["execid-ls", "execid-echo"]
    let execIDCounter = Counter()
    await transport.register(operationID: "ContainerExec") { _, _ in
        let idx = await execIDCounter.next()
        let id = idx < execIDs.count ? execIDs[idx] : "execid-unknown"
        return (Fixtures.jsonResponse(status: .created), try Fixtures.containerExecBody(id: id))
    }
    await transport.register(operationID: "ExecStart") { _, _ in
        (HTTPResponse(status: .ok), nil)
    }
    // execInspect is polled by waitForExec — always reply "finished, exit 0".
    await transport.register(operationID: "ExecInspect") { _, _ in
        (Fixtures.jsonResponse(status: .ok), try Fixtures.execInspectBody(running: false, exitCode: 0))
    }
    await transport.register(operationID: "ContainerStop") { _, _ in
        (Fixtures.noContentResponse(), nil)
    }

    let docker = try Docker.mock(transport: transport)

    // 1. Create a container.
    let containerID = try await docker.client.containerCreate(.init(
        body: .json(.init(
            value1: .init(cmd: ["sleep", "30"], image: "alpine"),
            value2: .init()
        ))
    )).created.body.json.id
    #expect(containerID == "deadbeef1234")

    // 2. Start it.
    _ = try await docker.client.containerStart(.init(
        path: .init(id: containerID)
    )).noContent

    // -------------------------------------------------------------------------
    // Exec 1: `ls /`
    // -------------------------------------------------------------------------

    let lsExecID = try await docker.client.containerExec(.init(
        path: .init(id: containerID),
        body: .json(.init(attachStdout: true, attachStderr: true, cmd: ["ls", "/"]))
    )).created.body.json.id
    #expect(lsExecID == "execid-ls")

    _ = try await docker.client.execStart(.init(
        path: .init(id: lsExecID),
        body: .json(.init(detach: true))
    )).ok

    let lsExitCode = try await docker.waitForExec(id: lsExecID)
    #expect(lsExitCode == 0)

    // -------------------------------------------------------------------------
    // Exec 2: `echo hello from exec`
    // -------------------------------------------------------------------------

    let echoExecID = try await docker.client.containerExec(.init(
        path: .init(id: containerID),
        body: .json(.init(attachStdout: true, attachStderr: true, cmd: ["echo", "hello from exec"]))
    )).created.body.json.id
    #expect(echoExecID == "execid-echo")

    _ = try await docker.client.execStart(.init(
        path: .init(id: echoExecID),
        body: .json(.init(detach: true))
    )).ok

    let echoExitCode = try await docker.waitForExec(id: echoExecID)
    #expect(echoExitCode == 0)

    // -------------------------------------------------------------------------
    // Cleanup
    // -------------------------------------------------------------------------

    _ = try? await docker.client.containerStop(.init(
        path: .init(id: containerID)
    ))
}

// MARK: - Counter

/// A simple async-safe incrementing counter used to hand out unique IDs
/// across sequential calls to the same mock handler.
actor Counter {
    private var value = 0
    func next() -> Int {
        defer { value += 1 }
        return value
    }
}
