import Testing
import Foundation
@testable import SwiftDocker

// MARK: - Shared helpers

let dockerSocketPath = "/Users/hadderley/.docker/run/docker.sock"

// MARK: - Tests

/// Equivalent to:
///
///   curl --unix-socket $SOCK -d '{"Image":"alpine","Cmd":["echo","hello world"]}' \
///        -X POST http://localhost/v1.53/containers/create
///   curl --unix-socket $SOCK -X POST http://localhost/v1.53/containers/{id}/start
///   curl --unix-socket $SOCK -X POST http://localhost/v1.53/containers/{id}/wait
///   curl --unix-socket $SOCK "http://localhost/v1.53/containers/{id}/logs?stdout=1"
@Test func runAlpineEchoContainer() async throws {
    let docker = try Docker(socketPath: dockerSocketPath)

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
    print("Created container: \(containerID)")
    if !createBody.warnings.isEmpty {
        print("Warnings: \(createBody.warnings)")
    }

    // 2. Start the container.
    _ = try await docker.client.containerStart(.init(
        path: .init(id: containerID)
    )).noContent
    print("Container started.")

    // 3. Wait for the container to finish.
    // `not-running` resolves as soon as the container stops, which is correct
    // for a container that may already have exited by the time we call wait.
    let waitResult = try await docker.client.containerWait(.init(
        path: .init(id: containerID),
        query: .init(condition: .notRunning)
    )).ok.body.json
    print("Container exited with status: \(waitResult.statusCode)")
    #expect(waitResult.statusCode == 0)

    // 4. Fetch stdout logs.
    let logsBody = try await docker.client.containerLogs(.init(
        path: .init(id: containerID),
        query: .init(stdout: true)
    )).ok.body.applicationVnd_docker_multiplexedStream
    let logsData = try await Data(collecting: logsBody, upTo: 1024 * 1024)

    // Use the library's multiplexed-stream decoder to extract plain text.
    let logText = DockerMultiplexedStream.text(from: logsData)
    print("Container logs: \(logText)")
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
    let docker = try Docker(socketPath: dockerSocketPath)

    // 1. Create a container that stays alive long enough for us to exec into.
    let containerID = try await docker.client.containerCreate(.init(
        body: .json(.init(
            value1: .init(
                cmd: ["sleep", "30"],
                image: "alpine"
            ),
            value2: .init()
        ))
    )).created.body.json.id
    print("Created container: \(containerID)")

    // 2. Start it.
    _ = try await docker.client.containerStart(.init(
        path: .init(id: containerID)
    )).noContent
    print("Container started.")

    // -------------------------------------------------------------------------
    // Exec 1: `ls /`
    // -------------------------------------------------------------------------

    // 3a. Create the exec instance.
    let lsExecID = try await docker.client.containerExec(.init(
        path: .init(id: containerID),
        body: .json(.init(
            attachStdout: true,
            attachStderr: true,
            cmd: ["ls", "/"]
        ))
    )).created.body.json.id
    print("Created exec (ls /): \(lsExecID)")

    // 3b. Start detached — fire-and-forget; output goes to the exec's stream
    //     which we read back via execInspect once complete.
    _ = try await docker.client.execStart(.init(
        path: .init(id: lsExecID),
        body: .json(.init(detach: true))
    )).ok
    print("Exec (ls /) started.")

    // 3c. Wait for it to finish and verify the exit code.
    let lsExitCode = try await docker.waitForExec(id: lsExecID)
    print("Exec (ls /) exit code: \(lsExitCode)")
    #expect(lsExitCode == 0)

    // -------------------------------------------------------------------------
    // Exec 2: `echo hello from exec`
    // -------------------------------------------------------------------------

    // 4a. Create a second exec instance.
    let echoExecID = try await docker.client.containerExec(.init(
        path: .init(id: containerID),
        body: .json(.init(
            attachStdout: true,
            attachStderr: true,
            cmd: ["echo", "hello from exec"]
        ))
    )).created.body.json.id
    print("Created exec (echo): \(echoExecID)")

    // 4b. Start detached.
    _ = try await docker.client.execStart(.init(
        path: .init(id: echoExecID),
        body: .json(.init(detach: true))
    )).ok
    print("Exec (echo) started.")

    // 4c. Wait for it to finish and verify the exit code.
    let echoExitCode = try await docker.waitForExec(id: echoExecID)
    print("Exec (echo) exit code: \(echoExitCode)")
    #expect(echoExitCode == 0)

    // -------------------------------------------------------------------------
    // Cleanup: stop the container so it doesn't linger.
    // -------------------------------------------------------------------------

    // `containerWait` with `next-exit` will resolve once we kill it.
    // We fire the wait first (non-awaited), then stop, so the wait
    // doesn't race. Here we just stop and ignore the wait response.
    _ = try? await docker.client.containerStop(.init(
        path: .init(id: containerID)
    ))
    print("Container stopped.")
}
