import Darwin
import Foundation
import Testing

@testable import Latch

@Test func `parses command without changing arguments`() throws {
    let options = try Options(arguments: ["run", "--shared", "--timeout", "0.25", "--", "printf", "a b", "", "--help"])
    #expect(options.shared)
    #expect(options.timeout == 0.25)
    #expect(options.childArguments == ["printf", "a b", "", "--help"])
    #expect(try Options(arguments: ["run", "--help"]).command == .help)
}

@Test(arguments: [
    [], ["unknown"], ["run"], ["run", "--"], ["run", "--", ""],
    ["run", "echo"], ["wait", "--shared"], ["status", "--timeout", "1"],
    ["wait", "--timeout", "nan"], ["wait", "--timeout", "inf"],
    ["wait", "--timeout", "-1"], ["wait", "--timeout", "1e100"],
    ["wait", "--timeout"], ["wait", "--file", ""], ["wait", "--", "echo"],
    ["wait", "--no-wait", "--timeout", "1"],
])
func `rejects invalid arguments`(arguments: [String]) {
    #expect(throws: LatchError.self) { try Options(arguments: arguments) }
}

@Test func `explicit path overrides environment`() throws {
    #expect(
        try Options(arguments: ["wait", "--file", "explicit.lock"])
            .resolvedPath(environment: ["LATCH_FILE": "environment.lock"]) == "explicit.lock")
    #expect(
        try Options(arguments: ["wait"])
            .resolvedPath(environment: ["LATCH_FILE": "environment.lock"]) == "environment.lock")
    #expect(throws: LatchError.self) {
        try Options(arguments: ["wait"]).resolvedPath(environment: ["LATCH_FILE": ""])
    }
}

@Test func `shared holders exclude exclusive work`() throws {
    let fixture = try Fixture()
    let first = try FileLatch(path: fixture.lockPath)
    let second = try FileLatch(path: fixture.lockPath)
    let exclusive = try FileLatch(path: fixture.lockPath)
    try withExtendedLifetime((first, second)) {
        try first.acquire(shared: true, timeout: 0)
        try second.acquire(shared: true, timeout: 0)
        #expect(throws: LatchError.self) { try exclusive.acquire(shared: false, timeout: 0) }
    }
}

@Test func `rejects symlinks and nonregular files`() throws {
    let fixture = try Fixture()
    let target = fixture.directory.appendingPathComponent("target")
    try Data("unchanged".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(atPath: fixture.lockPath, withDestinationPath: target.path)
    #expect(throws: LatchError.self) { try FileLatch(path: fixture.lockPath) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "unchanged")
    #expect(throws: LatchError.self) { try FileLatch(path: fixture.directory.path) }
    let fifo = fixture.directory.appendingPathComponent("fifo").path
    #expect(mkfifo(fifo, 0o600) == 0)
    #expect(throws: LatchError.self) { try FileLatch(path: fifo) }
}

@Test func `run preserves arguments streams and exit status`() throws {
    let service = try OperatorFixture()
    defer { withExtendedLifetime(service) {} }
    let fixture = service.fixture
    try service.publishSensors()
    let output = try fixture.launch(["run", "--", "/usr/bin/printf", "%s\\n", "a b", "", "--help"])
    #expect(try service.finish(output) == 0)
    #expect(output.output == "a b\n\n--help\n")

    let input = Pipe()
    let cat = try fixture.launch(["run", "--", "/bin/cat"], input: input)
    input.fileHandleForWriting.write(Data("piped input\n".utf8))
    try input.fileHandleForWriting.close()
    #expect(try service.finish(cat) == 0)
    #expect(cat.output == "piped input\n")

    let failure = try fixture.launch(["run", "--", "/usr/bin/false"])
    #expect(try service.finish(failure) == 1)
    let missing = try fixture.launch(["run", "--", "latch-test-command-that-does-not-exist"])
    #expect(try service.finish(missing) == 127)
    #expect(missing.errors.contains("cannot execute"))
    let denied = try fixture.launch(["run", "--", fixture.lockPath])
    #expect(try service.finish(denied) == 126)
    let free = try fixture.launch(["status"])
    #expect(try fixture.finish(free) == 0)
    #expect(free.output == "free\n")
}

@Test func `busy and timeout do not run the command`() throws {
    let service = try OperatorFixture()
    defer { withExtendedLifetime(service) {} }
    let fixture = service.fixture
    try service.publishSensors()
    let holder = try FileLatch(path: fixture.lockPath)
    try withExtendedLifetime(holder) {
        try holder.acquire(shared: false, timeout: 0)
        let marker = fixture.directory.appendingPathComponent("should-not-exist").path
        let immediate = try fixture.launch(["run", "--no-wait", "--", "/usr/bin/touch", marker])
        #expect(try service.finish(immediate) == 75)
        let clock = ContinuousClock()
        let start = clock.now
        let timed = try fixture.launch(["run", "--timeout", "0.1", "--", "/usr/bin/touch", marker])
        #expect(try service.finish(timed) == 75)
        #expect(start.duration(to: clock.now) >= .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: marker))
        let status = try fixture.launch(["status"])
        #expect(try fixture.finish(status) == 75)
        #expect(status.output == "held\n")
    }
}

@Test func `parked agents wake after release`() throws {
    let fixture = try Fixture()
    var holder: FileLatch? = try FileLatch(path: fixture.lockPath)
    try holder?.acquire(shared: false, timeout: 0)
    let waiters = try (0..<4).map { _ in try fixture.launch(["wait"]) }
    Thread.sleep(forTimeInterval: 0.1)
    let allParked = waiters.allSatisfy(\.process.isRunning)
    #expect(allParked)
    withExtendedLifetime(holder) {}
    holder = nil
    for waiter in waiters {
        #expect(try fixture.finish(waiter) == 0)
        #expect(waiter.output.isEmpty)
    }
}

@Test func `queued commands run one at A time and release on termination`() throws {
    let service = try OperatorFixture()
    defer { withExtendedLifetime(service) {} }
    let fixture = service.fixture
    try service.publishSensors()
    let first = try fixture.launch(["run", "--", "/bin/sleep", "30"])
    try fixture.waitUntilHeld(onWait: service.publishSensors)
    let second = try fixture.launch([
        "run", "--", "/usr/bin/touch", fixture.directory.appendingPathComponent("ran").path,
    ])
    Thread.sleep(forTimeInterval: 0.1)
    #expect(second.process.isRunning)
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("ran").path))
    #expect(kill(first.process.processIdentifier, SIGTERM) == 0)
    #expect(try service.finish(first) == SIGTERM)
    #expect(first.process.terminationReason == .uncaughtSignal)
    #expect(try service.finish(second) == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("ran").path))
    let free = try fixture.launch(["status"])
    #expect(try fixture.finish(free) == 0)
}

@Test func `shared processes overlap and wait is A checkpoint`() throws {
    let service = try OperatorFixture()
    defer { withExtendedLifetime(service) {} }
    let fixture = service.fixture
    try service.publishSensors()
    let first = try fixture.launch(["run", "--shared", "--", "/bin/sleep", "30"])
    try fixture.waitUntilHeld(onWait: service.publishSensors)
    let second = try fixture.launch(["run", "--shared", "--no-wait", "--", "/usr/bin/true"])
    #expect(try service.finish(second) == 0)
    let checkpoint = try fixture.launch(["wait", "--no-wait"])
    #expect(try fixture.finish(checkpoint) == 0)
    let exclusive = try fixture.launch(["run", "--no-wait", "--", "/usr/bin/true"])
    #expect(try fixture.finish(exclusive) == 75)
    #expect(first.process.isRunning)
    #expect(kill(first.process.processIdentifier, SIGTERM) == 0)
    #expect(try service.finish(first) == SIGTERM)
    let free = try fixture.launch(["status"])
    #expect(try fixture.finish(free) == 0)
}

final class Child {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    var output: String {
        String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    var errors: String {
        String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

final class Fixture {
    let directory: URL
    let executable: URL
    var children: [Child] = []
    var lockPath: String {
        directory.appendingPathComponent("test.lock").path
    }

    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        directory = root.appendingPathComponent(".build/latch-tests/\(UUID().uuidString)")
        var candidate = Bundle(for: Fixture.self).bundleURL
        var found: URL?
        for _ in 0..<6 {
            let binary = candidate.appendingPathComponent("latch")
            if FileManager.default.isExecutableFile(atPath: binary.path) {
                found = binary
                break
            }
            candidate.deleteLastPathComponent()
        }
        executable = try #require(found, "latch executable must be built alongside the tests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: lockPath + ".queue/state.json")),
            let state = try? JSONDecoder().decode(SchedulerState.self, from: data)
        {
            for task in state.tasks where state.jobs.contains(where: { $0.id == task.id }) && task.pid > 1 {
                if let lease = try? FileLatch(path: lockPath + ".queue/" + task.id + ".lease") {
                    do { try lease.acquire(shared: false, timeout: 0) } catch let error as LatchError
                        where error.exitCode == 75
                    { _ = kill(-task.pid, SIGKILL) } catch {}
                }
            }
            for job in state.jobs where !job.complete {
                if let pid = job.supervisorPID, pid > 1,
                    let lease = try? FileLatch(path: lockPath + ".queue/jobs/" + job.id + ".supervisor.lock")
                {
                    do { try lease.acquire(shared: false, timeout: 0) } catch let error as LatchError
                        where error.exitCode == 75
                    { _ = kill(-pid, SIGKILL) } catch {}
                }
            }
        }
        for child in children where child.process.isRunning {
            kill(child.process.processIdentifier, SIGKILL)
            child.process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func launch(_ arguments: [String], input: Pipe? = nil, includeFile: Bool = true) throws -> Child {
        let child = Child()
        child.process.executableURL = executable
        child.process.arguments = includeFile ? [arguments[0], "--file", lockPath] + arguments.dropFirst() : arguments
        child.process.standardOutput = child.stdout
        child.process.standardError = child.stderr
        child.process.standardInput = input ?? Pipe()
        try child.process.run()
        children.append(child)
        return child
    }

    func finish(_ child: Child, timeout: Duration = .seconds(5), onWait: (() throws -> Void)? = nil) throws -> Int32 {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while child.process.isRunning, ContinuousClock.now < deadline {
            try onWait?()
            Thread.sleep(forTimeInterval: 0.005)
        }
        try #require(!child.process.isRunning, "child did not exit within \(timeout)")
        child.process.waitUntilExit()
        return child.process.terminationStatus
    }

    func waitUntilHeld(onWait: (() throws -> Void)? = nil) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            try onWait?()
            let probe = try FileLatch(path: lockPath)
            do {
                try probe.acquire(shared: false, timeout: 0)
                probe.release()
            } catch let error as LatchError where error.exitCode == 75 {
                return
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        let tasks = try Scheduler(path: lockPath).snapshot().tasks
        Issue.record(
            "child did not acquire latch within five seconds; tasks: \(tasks)"
        )
        throw LatchError("test timed out")
    }
}
