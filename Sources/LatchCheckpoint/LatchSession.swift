import Darwin
import Foundation

/// A single-threaded checkpoint session. All workload threads and devices must be idle between permits.
public final class LatchSession {
    private let descriptor: Int32
    private var iteration = 0
    private var running = false
    private var failed = false

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    private struct Message: Codable {
        var version = 1
        var kind: String
        var iteration: Int
    }

    private init(descriptor: Int32) { self.descriptor = descriptor }

    public static func connect() throws -> LatchSession {
        guard let text = ProcessInfo.processInfo.environment["LATCH_CHECKPOINT_FD"], let descriptor = Int32(text),
            descriptor > 2,
            fcntl(descriptor, F_GETFD) >= 0
        else { throw Failure(description: "Latch checkpoint channel unavailable") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        return LatchSession(descriptor: descriptor)
    }

    deinit { close(descriptor) }

    public func awaitPermit(iteration: Int) throws {
        guard !running, iteration == self.iteration else { throw Failure(description: "Unexpected iteration") }
        try exchange("ready", expecting: "permit", iteration: iteration)
        running = true
    }

    public func finishIteration(iteration: Int) throws {
        guard running, iteration == self.iteration else { throw Failure(description: "Iteration is not running") }
        try exchange("finished", expecting: "finished", iteration: iteration)
        running = false
        self.iteration += 1
    }

    private func exchange(_ kind: String, expecting: String, iteration: Int) throws {
        guard !failed else { throw Failure(description: "Checkpoint session failed; do not replay work") }
        do {
            var data = try JSONEncoder().encode(Message(kind: kind, iteration: iteration))
            data.append(10)
            var offset = 0
            while offset < data.count {
                let count = data.withUnsafeBytes {
                    write(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset)
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure(description: "Checkpoint supervisor disconnected") }
                offset += count
            }
            var response = Data()
            while response.count <= 1024 {
                var byte: UInt8 = 0
                let count = read(descriptor, &byte, 1)
                if count < 0, errno == EINTR { continue }
                guard count == 1 else { throw Failure(description: "Checkpoint supervisor disconnected") }
                if byte == 10 {
                    let message = try JSONDecoder().decode(Message.self, from: response)
                    guard message.version == 1, message.kind == expecting, message.iteration == iteration else {
                        throw Failure(description: "Invalid checkpoint response")
                    }
                    return
                }
                response.append(byte)
            }
            throw Failure(description: "Checkpoint response exceeds limit")
        } catch {
            failed = true
            throw error
        }
    }
}
