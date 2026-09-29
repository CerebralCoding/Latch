import Darwin
import Foundation
@testable import Latch
import Testing

private final class MCPClient {
    let fixture: Fixture
    let child: Child
    let input = Pipe()
    private var buffer = Data()
    private var received: [MCPValue] = []
    private var sequence = 0

    init(fixture: Fixture, initialize: Bool = true) throws {
        self.fixture = fixture
        child = try fixture.launch(["mcp"], input: input)
        _ = fcntl(child.stdout.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
        if initialize {
            try handshake()
        }
    }

    deinit {
        try? input.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while child.process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if child.process.isRunning {
            kill(child.process.processIdentifier, SIGKILL)
        }
    }

    func send(_ value: MCPValue) throws {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    @discardableResult
    func handshake(version: String = "2025-11-25") throws -> MCPValue {
        let response = try request("initialize", params: ["protocolVersion": .string(version), "capabilities": [:], "clientInfo": ["name": "swift-tests", "version": "1"]])
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return response
    }

    func request(_ method: String, params: MCPValue = [:]) throws -> MCPValue {
        sequence += 1
        let id = MCPValue.number(Double(sequence))
        try send(["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params])
        return try response(id: id)
    }

    func tool(_ name: String, arguments: MCPValue = [:]) throws -> MCPValue {
        try request("tools/call", params: ["name": .string(name), "arguments": arguments])
    }

    func response(id: MCPValue, timeout: Double = 6) throws -> MCPValue {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let index = received.firstIndex(where: { $0["id"] == id }) {
                return received.remove(at: index)
            }
            while let newline = buffer.firstIndex(of: 10) {
                let data = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                try received.append(JSONDecoder().decode(MCPValue.self, from: data))
            }
            if received.contains(where: { $0["id"] == id }) {
                continue
            }
            var descriptor = pollfd(fd: child.stdout.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) > 0 {
                var bytes = [UInt8](repeating: 0, count: 16384)
                let count = read(descriptor.fd, &bytes, bytes.count)
                guard count > 0 else { throw LatchError("MCP server closed stdout unexpectedly") }
                buffer.append(contentsOf: bytes.prefix(count))
            }
        }
        throw LatchError("MCP response timed out for \(id)")
    }
}

private func mcpService(_ scheduler: Scheduler) throws -> FileLatch {
    let lock = try FileLatch(path: scheduler.directory.appendingPathComponent("service.lock").path)
    try lock.acquire(shared: false, timeout: 0)
    let status = SchedulerService.Status(running: true, pid: getpid(), path: scheduler.path)
    try JSONEncoder().encode(status).write(to: scheduler.directory.appendingPathComponent("service.json"), options: .atomic)
    return lock
}

private func admission(_ scheduler: Scheduler, expectedTasks: Int = 1) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 4
    while try scheduler.snapshot().tasks.count < expectedTasks, ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    try #require(try scheduler.snapshot().tasks.count >= expectedTasks)
    try scheduler.transaction {
        let now = ProcessInfo.processInfo.systemUptime
        for seconds in (0 ... 10).reversed() {
            $0.record(SensorSnapshot(sampledAt: Date(), uptime: now - Double(seconds),
                                     cpuCores: ProcessInfo.processInfo.activeProcessorCount, cpuActive: 0, busiestCore: 0,
                                     gpuActive: 0, aneWatts: 0, memoryAvailableMiB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) * 8 / 10, memoryTotalMiB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
                                     memoryPressure: "normal", thermalState: "nominal", diskBytesPerSecond: 0,
                                     unavailable: [], cpuTemperature: 30, gpuTemperature: 30))
        }
    }
}

private func submission(_ fixture: Fixture, key: String = UUID().uuidString, mode: String = "report", arguments: [String] = []) -> MCPValue {
    ["requestKey": .string(key), "name": "mcp-test", "executable": .string(fixture.executable.deletingLastPathComponent().appendingPathComponent("LatchTestWorkload").path),
     "arguments": .array(([mode] + arguments).map(MCPValue.string)), "workingDirectory": .string(fixture.directory.path),
     "measurement": false]
}

private func jobID(_ response: MCPValue) throws -> String {
    try #require(response["result"]?["structuredContent"]?["jobID"]?.string)
}

@Test func `MCP negotiates initialization discovers tools and validates protocol errors`() throws {
    let fixture = try Fixture()
    let client = try MCPClient(fixture: fixture, initialize: false)
    #expect(try client.request("tools/list")["error"]?["code"] == -32600)
    try client.input.fileHandleForWriting.write(contentsOf: Data("not json\n".utf8))
    #expect(try client.response(id: .null)["error"]?["code"] == -32700)
    let initialized = try client.handshake(version: "unsupported-version")
    #expect(initialized["result"]?["protocolVersion"] == "2025-11-25")
    #expect(initialized["result"]?["capabilities"]?["tools"] != nil)
    let listed = try client.request("tools/list")
    guard case let .array(tools) = listed["result"]?["tools"] else { Issue.record("missing tools"); return }
    #expect(tools.compactMap { $0["name"]?.string } == ["latch_view", "latch_submit", "latch_wait", "latch_cancel", "latch_forget"])
    #expect(tools[0]["annotations"]?["readOnlyHint"] == true)
    #expect(tools[1]["annotations"]?["readOnlyHint"] == false)
    #expect(tools[1]["annotations"]?["openWorldHint"] == true)
    let properties = try #require(tools[1]["inputSchema"]?["properties"]?.object)
    #expect(Set(properties.keys) == ["requestKey", "name", "executable", "arguments", "workingDirectory", "measurement"])
    #expect(try client.request("unknown")["error"]?["code"] == -32601)
    #expect(try client.tool("service_install")["error"]?["code"] == -32602)
    #expect(try client.tool("latch_view", arguments: ["unexpected": true])["error"]?["code"] == -32602)
    #expect(try client.request("ping")["result"] == [:])
}

@Test func `Latch plans resources without asking the agent for budgets`() {
    let build = TaskPlanner.plan(executable: "/usr/bin/swift", arguments: ["build", "-c", "release"], measurement: false, cpuCount: 12, memoryMiB: 32768)
    #expect(build.arguments == ["build", "-c", "release", "--jobs", "4"])
    #expect(build.requirements.mode == .batch)
    #expect(build.requirements.cpuCores == 4)
    #expect(build.requirements.memoryMiB == 4096)
    #expect(build.requirements.temperatureGuard == TemperatureGuard())
    let measurement = TaskPlanner.plan(executable: "/usr/bin/swift", arguments: ["build"], measurement: true, cpuCount: 12, memoryMiB: 32768)
    #expect(measurement.requirements.mode == .isolated)
    #expect(measurement.requirements.cpuCores == 12)
    #expect(measurement.arguments == ["build"])
    #expect(measurement.requirements.temperatureGuard == TemperatureGuard(maxCPU: 50, maxGPU: 50, cooldown: 10))
    for (executable, arguments) in [("/usr/bin/swift", ["test"]), ("/usr/bin/swift", ["build", "-j", "8"]), ("/model", ["infer"])] {
        let plan = TaskPlanner.plan(executable: executable, arguments: arguments, measurement: false, cpuCount: 8, memoryMiB: 16384)
        #expect(plan.requirements.mode == .isolated)
        #expect(plan.arguments == arguments)
    }
    let small = TaskPlanner.plan(executable: "/usr/bin/swift", arguments: ["build"], measurement: false, cpuCount: 1, memoryMiB: 2048)
    #expect(small.requirements.cpuCores == 1)
    #expect(small.requirements.memoryMiB == 512)
}

@Test func `MCP rejects invalid submissions before spawning`() throws {
    let fixture = try Fixture()
    let client = try MCPClient(fixture: fixture)
    for (key, invalid) in [("cpu", MCPValue.bool(true)), ("cpu", .number(1.5)), ("arguments", .string("echo hi")),
                           ("executable", .string("relative")), ("arguments", .array([.string("nul\0byte")])),
                           ("mode", .string("unsafe")), ("cooldownSeconds", .number(-1)), ("workingDirectory", .string("/missing/latch-test"))]
    {
        var arguments = try #require(submission(fixture).object)
        arguments[key] = invalid
        #expect(try client.tool("latch_submit", arguments: .object(arguments))["error"]?["code"] == -32602)
    }
    let missingService = try client.tool("latch_submit", arguments: submission(fixture))
    #expect(missingService["result"]?["isError"] == true)
    #expect(missingService["result"]?["structuredContent"]?["code"] == 69)
    #expect(try Scheduler(path: fixture.lockPath).snapshot().tasks.isEmpty)
}

@Test func `MCP schedules literal arguments preserves cwd and deduplicates submissions`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let arguments = submission(fixture, key: "same", arguments: ["a b", "$HOME", "", "; false"])
        let id = try jobID(client.tool("latch_submit", arguments: arguments))
        #expect(try jobID(client.tool("latch_submit", arguments: arguments)) == id)
        #expect(try client.tool("latch_submit", arguments: submission(fixture, key: "same", mode: "fail75"))["error"]?["code"] == -32602)
        try admission(scheduler)
        let response = try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])
        let result = try #require(response["result"]?["structuredContent"])
        #expect(result["complete"] == true)
        #expect(result["succeeded"] == true)
        #expect(result["phase"] == "command")
        #expect(result["stderr"] == "separate stderr")
        let stdout = try #require(result["stdout"]?.string)
        let report = try JSONDecoder().decode([String: [String]].self, from: Data(stdout.utf8))
        #expect(report["arguments"] == ["a b", "$HOME", "", "; false"])
        #expect(report["workingDirectory"] == [fixture.directory.path])
        #expect(try client.tool("latch_forget", arguments: ["jobID": .string(id)])["result"]?["structuredContent"]?["forgotten"] == true)
        #expect(try client.tool("latch_forget", arguments: ["jobID": .string(id)])["result"]?["structuredContent"]?["forgotten"] == false)
        #expect(try scheduler.snapshot().tasks.isEmpty)
    }
}

@Test func `MCP wait is nonblocking for other requests and cancellation only stops that wait`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let id = try jobID(client.tool("latch_submit", arguments: submission(fixture)))
        try client.send(["jsonrpc": "2.0", "id": "pending-wait", "method": "tools/call", "params": ["name": "latch_wait", "arguments": ["jobID": .string(id), "timeoutSeconds": 60]]])
        #expect(try client.request("ping")["result"] == [:])
        #expect(try client.tool("latch_view")["result"]?["isError"] == false)
        try client.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": "pending-wait"]])
        let pending = try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": .number(0.05)])
        #expect(pending["result"]?["structuredContent"]?["complete"] == false)
        #expect(pending["result"]?["structuredContent"]?["state"] == "queued")
        try admission(scheduler)
        #expect(try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])["result"]?["structuredContent"]?["succeeded"] == true)
    }
}

@Test func `MCP bounds output and distinguishes a command exit from admission failure`() throws {
    for mode in ["flood", "fail75"] {
        let fixture = try Fixture()
        let scheduler = try Scheduler(path: fixture.lockPath)
        let service = try mcpService(scheduler)
        try withExtendedLifetime(service) {
            let client = try MCPClient(fixture: fixture)
            let id = try jobID(client.tool("latch_submit", arguments: submission(fixture, mode: mode)))
            try admission(scheduler)
            let response = try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])
            let result = try #require(response["result"]?["structuredContent"])
            #expect(result["complete"] == true)
            #expect(result["phase"] == "command")
            if mode == "flood" {
                #expect(result["stdout"]?.string?.utf8.count == 32768)
                #expect(result["stderr"]?.string?.utf8.count == 32768)
                #expect(result["stdoutTruncated"] == true)
                #expect(result["stderrTruncated"] == true)
                #expect(response["result"]?["isError"] == false)
            } else {
                #expect(result["exitCode"] == 75)
                #expect(response["result"]?["isError"] == true)
            }
        }
    }
}

@Test func `MCP cancellation is connection scoped and reaps a queued worker`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let first = try MCPClient(fixture: fixture)
        let second = try MCPClient(fixture: fixture)
        let id = try jobID(first.tool("latch_submit", arguments: submission(fixture)))
        #expect(try second.tool("latch_cancel", arguments: ["jobID": .string(id)])["error"]?["code"] == -32602)
        #expect(try first.tool("latch_forget", arguments: ["jobID": .string(id)])["error"]?["code"] == -32602)
        _ = try first.tool("latch_cancel", arguments: ["jobID": .string(id)])
        let result = try first.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])
        #expect(result["result"]?["structuredContent"]?["state"] == "cancelled")
        #expect(result["result"]?["isError"] == true)
        #expect(try scheduler.snapshot().tasks.isEmpty)
    }
}

@Test(arguments: ["descendant", "orphan"])
func `MCP cancels the workload process group and escalates after TERM`(mode: String) throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let marker = fixture.directory.appendingPathComponent("child-pid")
        let id = try jobID(client.tool("latch_submit", arguments: submission(fixture, mode: mode, arguments: [marker.path])))
        try admission(scheduler)
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !FileManager.default.fileExists(atPath: marker.path), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(FileManager.default.fileExists(atPath: marker.path))
        let started = ProcessInfo.processInfo.systemUptime
        _ = try client.tool("latch_cancel", arguments: ["jobID": .string(id)])
        let response = try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])
        #expect(ProcessInfo.processInfo.systemUptime - started >= 2)
        #expect(response["result"]?["structuredContent"]?["complete"] == true)
        #expect(response["result"]?["structuredContent"]?["exitCode"] == (mode == "descendant" ? MCPValue.number(9) : .number(15)))
        let releasedBy = ProcessInfo.processInfo.systemUptime + 2
        while try !scheduler.snapshot().tasks.isEmpty, ProcessInfo.processInfo.systemUptime < releasedBy {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(try scheduler.snapshot().tasks.isEmpty)
        let gate = try FileLatch(path: fixture.lockPath)
        try gate.acquire(shared: false, timeout: 0)
    }
}

@Test func `MCP disconnect cancels queued jobs and leaves service ownership unchanged`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        _ = try client.tool("latch_submit", arguments: submission(fixture))
        try client.input.fileHandleForWriting.close()
        #expect(try fixture.finish(client.child) == 0)
        #expect(try scheduler.snapshot().tasks.isEmpty)
        #expect(try SchedulerService.requireRunning(in: scheduler.directory) == getpid())
    }
}

@Test func `MCP handles fragmented requests and the older supported version`() throws {
    let fixture = try Fixture()
    let client = try MCPClient(fixture: fixture, initialize: false)
    let message: MCPValue = ["jsonrpc": "2.0", "id": "fragment", "method": "initialize", "params": [
        "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"],
    ]]
    let data = try JSONEncoder().encode(message)
    try client.input.fileHandleForWriting.write(contentsOf: data.prefix(7))
    try client.input.fileHandleForWriting.write(contentsOf: data.dropFirst(7))
    try client.input.fileHandleForWriting.write(contentsOf: Data([13, 10]))
    #expect(try client.response(id: "fragment")["result"]?["protocolVersion"] == "2025-06-18")
    try client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    #expect(try client.tool("latch_view")["result"]?["structuredContent"]?["scheduler"] != nil)
}

@Test func `queued MCP workers withdraw after an abrupt owner crash`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        _ = try client.tool("latch_submit", arguments: submission(fixture))
        let queuedBy = ProcessInfo.processInfo.systemUptime + 3
        while try scheduler.snapshot().tasks.isEmpty, ProcessInfo.processInfo.systemUptime < queuedBy {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(try scheduler.snapshot().tasks.count == 1)
        #expect(kill(client.child.process.processIdentifier, SIGKILL) == 0)
        #expect(try fixture.finish(client.child) == SIGKILL)
        let releasedBy = ProcessInfo.processInfo.systemUptime + 3
        while try !scheduler.snapshot().tasks.isEmpty, ProcessInfo.processInfo.systemUptime < releasedBy {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(try scheduler.snapshot().tasks.isEmpty)
    }
}
