import Foundation

// MARK: - Docker stream types

/// Identifies which output stream a multiplexed log frame originated from.
public enum DockerStreamType: UInt8, Sendable {
    case stdin  = 0
    case stdout = 1
    case stderr = 2
}

/// A single decoded frame from a Docker multiplexed log stream.
public struct DockerLogFrame: Sendable {
    /// The stream the payload was written to (stdin / stdout / stderr).
    public let stream: DockerStreamType
    /// The raw payload bytes for this frame.
    public let payload: Data

    /// The payload decoded as a UTF-8 string, if possible.
    public var text: String? { String(data: payload, encoding: .utf8) }
}

// MARK: - Multiplexed stream decoding

/// Utilities for working with Docker's multiplexed log stream format.
///
/// When a container is started without a TTY (`Tty: false`), Docker
/// multiplexes stdout and stderr into a single byte stream using 8-byte
/// frame headers:
///
/// ```
/// ┌──────────┬──────────────┬───────────────────────────────────┐
/// │ stream   │  padding (3) │  payload size (4 bytes, big-endian)│
/// │ (1 byte) │              │                                    │
/// └──────────┴──────────────┴───────────────────────────────────┘
/// │              payload (size bytes)                            │
/// └──────────────────────────────────────────────────────────────┘
/// ```
///
/// Reference: https://docs.docker.com/engine/api/v1.53/#tag/Container/operation/ContainerAttach
public enum DockerMultiplexedStream {

    /// Decodes all frames from a multiplexed Docker log stream.
    ///
    /// - Parameter data: Raw bytes received from a Docker log or attach endpoint
    ///   that uses `application/vnd.docker.multiplexed-stream`.
    /// - Returns: An array of decoded ``DockerLogFrame`` values in order.
    public static func decode(_ data: Data) -> [DockerLogFrame] {
        var frames: [DockerLogFrame] = []
        var index = data.startIndex
        while data.distance(from: index, to: data.endIndex) >= 8 {
            let streamByte = data[index]
            let stream = DockerStreamType(rawValue: streamByte) ?? .stdout
            // Bytes 1-3 are padding; bytes 4-7 are the big-endian payload size.
            let sizeStart = data.index(index, offsetBy: 4)
            let sizeEnd   = data.index(index, offsetBy: 8)
            let size = data[sizeStart..<sizeEnd].reduce(0) { ($0 << 8) | Int($1) }
            guard size > 0 else {
                // Zero-length frame: advance past the header and continue.
                index = sizeEnd
                continue
            }
            let payloadStart = sizeEnd
            guard let payloadEnd = data.index(
                payloadStart, offsetBy: size, limitedBy: data.endIndex
            ) else { break }
            let payload = data[payloadStart..<payloadEnd]
            frames.append(DockerLogFrame(stream: stream, payload: Data(payload)))
            index = payloadEnd
        }
        return frames
    }

    /// Returns the concatenated text of all stdout (and optionally stderr)
    /// frames decoded from a multiplexed Docker log body.
    ///
    /// - Parameters:
    ///   - data: Raw multiplexed stream bytes.
    ///   - includeStderr: When `true`, stderr frames are included in the
    ///     result interleaved with stdout. Default is `false`.
    /// - Returns: The combined UTF-8 text of the selected frames.
    public static func text(from data: Data, includeStderr: Bool = false) -> String {
        decode(data)
            .filter { $0.stream == .stdout || (includeStderr && $0.stream == .stderr) }
            .compactMap(\.text)
            .joined()
    }
}
