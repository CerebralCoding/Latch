import Foundation
import Testing

@testable import Latch

@Test(arguments: [false, true])
func `process exit watches can be retried after registration failure or delivery`(watchBeforeExit: Bool) throws {
    let fixture = try Fixture()
    let watcher = try QueueWatcher(directory: fixture.directory.path)
    let process = Process()
    let input = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/cat")
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    let pid = process.processIdentifier
    if watchBeforeExit { watcher.wait(seconds: 0, pids: [pid]) }
    try input.fileHandleForWriting.close()
    if watchBeforeExit { watcher.wait(seconds: 2, pids: [pid]) }
    process.waitUntilExit()
    if !watchBeforeExit { watcher.wait(seconds: 0, pids: [pid]) }
    let start = ContinuousClock.now
    watcher.wait(seconds: 2, pids: [pid])
    #expect(start.duration(to: .now) < .seconds(1))
}
