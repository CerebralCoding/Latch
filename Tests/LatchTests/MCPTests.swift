import Darwin
import Foundation
import Testing

@testable import Latch

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
        let response = try request(
            "initialize",
            params: [
                "protocolVersion": .string(version), "capabilities": [:],
                "clientInfo": ["name": "swift-tests", "version": "1"],
            ])
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
        try message(timeout: timeout) { $0["id"] == id }
    }

    func notification(_ method: String, token: MCPValue? = nil) throws -> MCPValue {
        try message { $0["method"] == .string(method) && (token == nil || $0["params"]?["progressToken"] == token) }
    }

    private func message(timeout: Double = 6, matching: (MCPValue) -> Bool) throws -> MCPValue {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let index = received.firstIndex(where: matching) {
                return received.remove(at: index)
            }
            while let newline = buffer.firstIndex(of: 10) {
                let data = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                try received.append(JSONDecoder().decode(MCPValue.self, from: data))
            }
            if received.contains(where: matching) {
                continue
            }
            var descriptor = pollfd(
                fd: child.stdout.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) > 0 {
                var bytes = [UInt8](repeating: 0, count: 16384)
                let count = read(descriptor.fd, &bytes, bytes.count)
                guard count > 0 else { throw LatchError("MCP server closed stdout unexpectedly") }
                buffer.append(contentsOf: bytes.prefix(count))
            }
        }
        throw LatchError("MCP message timed out")
    }
}

private func checkpointState(_ client: MCPClient, id: String, state: String, iteration: Int) throws -> MCPValue {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while ProcessInfo.processInfo.systemUptime < deadline {
        let result = try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": .number(0.02)])[
            "result"]?["structuredContent"]
        if result?["state"] == .string(state), result?["completedIterations"] == .number(Double(iteration)) {
            return result!
        }
        if result?["complete"] == true { throw LatchError("checkpoint ended early: \(String(describing: result))") }
    }
    throw LatchError("checkpoint did not reach \(state) iteration \(iteration)")
}

@Test func `checkpoints preserve process memory and rejoin FIFO with a fresh cooldown`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        var arguments = try #require(interactiveSubmission(fixture, mode: "checkpoints", input: "pipe").object)
        arguments["checkpoints"] = true
        let id = try jobID(client.tool("latch_submit", arguments: .object(arguments)))
        try admission(scheduler)
        _ = try checkpointState(client, id: id, state: "waiting", iteration: 0)
        let gate = try FileLatch(path: fixture.lockPath)
        try gate.acquire(shared: false, timeout: 0)
        gate.release()
        try admission(scheduler)
        _ = try outputUntil(client, job: id, contains: "iteration:0")
        let first = try checkpointState(client, id: id, state: "running", iteration: 0)
        let other = try jobID(client.tool("latch_submit", arguments: submission(fixture)))
        _ = try delivered(client, job: id, tool: "latch_input", arguments: ["text": "x"])
        _ = try checkpointState(client, id: id, state: "waiting", iteration: 1)
        let state = try scheduler.snapshot()
        #expect(state.tasks.map(\.id) == [other, id])
        #expect(state.tasks.last?.coolSince == nil)
        #expect((state.tasks.last?.residentMemoryMiB ?? 0) > 0)
        #expect(try SchedulerView(scheduler: scheduler).capacity.parkedResidentMemoryMiB > 0)
        try admission(scheduler)
        #expect(
            try client.tool("latch_wait", arguments: ["jobID": .string(other), "timeoutSeconds": 4])["result"]?[
                "structuredContent"]?["succeeded"] == true)
        service.release()
        try admission(scheduler)
        _ = try checkpointState(client, id: id, state: "waiting", iteration: 1)
        let restarted = try mcpService(scheduler)
        defer { withExtendedLifetime(restarted) {} }
        try admission(scheduler)
        _ = try outputUntil(client, job: id, contains: "iteration:1")
        let second = try checkpointState(client, id: id, state: "running", iteration: 1)
        #expect(first["pid"] == second["pid"])
        _ = try delivered(client, job: id, tool: "latch_input", arguments: ["text": "x"])
        let result = try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])["result"]?[
            "structuredContent"]
        #expect(result?["succeeded"] == true)
        #expect(result?["completedIterations"] == 2)
        #expect(try scheduler.snapshot().tasks.isEmpty)
    }
}

@Test(arguments: [true, false])
func `parked checkpoints survive reconnect and handle cancellation or supervisor loss`(loss: Bool) throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let store = try DurableJobs(scheduler: scheduler)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        var arguments = submission(fixture, mode: "checkpoints").object!
        arguments["checkpoints"] = true
        let id = try jobID(client.tool("latch_submit", arguments: .object(arguments)))
        try admission(scheduler)
        _ = try checkpointState(client, id: id, state: "waiting", iteration: 0)
        try admission(scheduler)
        _ = try checkpointState(client, id: id, state: "waiting", iteration: 1)
        try client.input.fileHandleForWriting.close()
        #expect(try fixture.finish(client.child) == 0)
        let other = try MCPClient(fixture: fixture)
        _ = try checkpointState(other, id: id, state: "waiting", iteration: 1)
        if loss {
            let record = try #require(store.records().first { $0.id == id })
            #expect(kill(try #require(record.supervisorPID), SIGKILL) == 0)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while ProcessInfo.processInfo.systemUptime < deadline {
                try store.recover(executable: fixture.executable)
                if try store.records().first(where: { $0.id == id })?.complete == true { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
        } else {
            _ = try other.tool("latch_cancel", arguments: ["jobID": .string(id)])
        }
        let result = try other.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])["result"]?[
            "structuredContent"]
        #expect(result?["complete"] == true)
        #expect(result?["succeeded"] == false)
        #expect(result?["completedIterations"] == 1)
        if loss {
            #expect(result?["terminationReason"] == "unknown")
        } else {
            #expect(result?["state"] == "cancelled")
            #expect(result?["phase"] == "command")
            #expect(result?["error"] == nil)
        }
    }
}

@Test func `checkpoint duplicates never advance twice and malformed messages fail closed`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let store = try DurableJobs(scheduler: scheduler)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let record = try store.submit(MCPSubmission(submission(fixture)))
        let checkpoint = try CheckpointCoordinator(id: record.id, scheduler: scheduler)
        checkpoint.pid = getpid()
        func send(_ message: CheckpointMessage) throws {
            var bytes = try JSONEncoder().encode(message)
            bytes.append(10)
            #expect(bytes.withUnsafeBytes { write(checkpoint.clientChannel, $0.baseAddress, $0.count) } == bytes.count)
            try checkpoint.receive()
        }
        try admission(scheduler)
        #expect(try checkpoint.admit())
        try send(CheckpointMessage(kind: "ready", iteration: 0))
        try send(CheckpointMessage(kind: "ready", iteration: 0))
        #expect(try scheduler.snapshot().tasks.count == 1)
        try admission(scheduler)
        try checkpoint.advance()
        try send(CheckpointMessage(kind: "finished", iteration: 0))
        try send(CheckpointMessage(kind: "finished", iteration: 0))
        #expect(checkpoint.completedIterations == 1)
        #expect(checkpoint.iteration == 1)
        #expect(try scheduler.snapshot().tasks.first?.state == .parked)
        #expect(throws: LatchError.self) { try send(CheckpointMessage(version: 2, kind: "ready", iteration: 1)) }
    }
}

@Test func `MCP execution returns once with progress and no model polling`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        try client.send([
            "jsonrpc": "2.0", "id": "execute", "method": "tools/call",
            "params": [
                "name": "latch_execute", "arguments": submission(fixture), "_meta": ["progressToken": 42],
            ],
        ])
        let queued = try client.notification("notifications/progress", token: 42)
        #expect(queued["params"]?["message"] == "queued")
        #expect(queued["params"]?["progress"] == 1)
        #expect(queued["params"]?["total"] == nil)
        #expect(try client.request("ping")["result"] == [:])
        try admission(scheduler)
        let result = try client.response(id: "execute")
        #expect(result["result"]?["structuredContent"]?["succeeded"] == true)
        #expect(result["result"]?["structuredContent"]?["stdout"] != nil)
        var previous = 1.0
        while true {
            let progress = try client.notification("notifications/progress", token: 42)
            guard case .number(let value) = progress["params"]?["progress"] else {
                Issue.record("missing progress")
                return
            }
            #expect(value > previous)
            previous = value
            if progress["params"]?["message"] == "completed" {
                break
            }
        }
    }
}

@Test(arguments: ["report", "fail75"])
func `MCP task result blocks until completion and retains the final result`(mode: String) throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let arguments = submission(fixture, mode: mode)
        let created = try client.request(
            "tools/call",
            params: [
                "name": "latch_execute", "arguments": arguments, "task": ["ttl": 60000],
                "_meta": ["progressToken": "task-progress"],
            ])
        let task = try #require(created["result"]?["task"])
        let id = try #require(task["taskId"]?.string)
        #expect(task["status"] == "working")
        #expect(task["ttl"] == .null)
        #expect(task["createdAt"]?.string != nil)
        #expect(task["lastUpdatedAt"]?.string != nil)
        #expect(
            try client.request("tools/call", params: ["name": "latch_execute", "arguments": arguments, "task": [:]])[
                "result"]?["task"]?["taskId"] == .string(id))
        #expect(try client.request("tasks/get", params: ["taskId": .string(id)])["result"]?["status"] == "working")
        guard case .array(let list) = try client.request("tasks/list")["result"]?["tasks"] else {
            Issue.record("missing tasks")
            return
        }
        #expect(list.count == 1)
        try client.send(["jsonrpc": "2.0", "id": "result", "method": "tasks/result", "params": ["taskId": .string(id)]])
        #expect(try client.request("ping")["result"] == [:])
        let progress = try client.notification("notifications/progress", token: "task-progress")
        #expect(progress["params"]?["_meta"] == MCPTask.metadata(id))
        try admission(scheduler)
        let result = try client.response(id: "result")
        #expect(result["result"]?["structuredContent"]?["complete"] == true)
        #expect(result["result"]?["isError"] == .bool(mode == "fail75"))
        #expect(result["result"]?["_meta"] == MCPTask.metadata(id))
        #expect(try client.request("tasks/result", params: ["taskId": .string(id)])["result"] == result["result"])
        let terminal: MCPValue = mode == "report" ? "completed" : "failed"
        #expect(try client.request("tasks/get", params: ["taskId": .string(id)])["result"]?["status"] == terminal)
        while true {
            let notification = try client.notification("notifications/tasks/status")
            #expect(notification["params"]?["taskId"] == .string(id))
            if notification["params"]?["status"] == terminal {
                break
            }
        }
        #expect(try client.request("tasks/cancel", params: ["taskId": .string(id)])["error"]?["code"] == -32602)
        _ = try client.tool("latch_forget", arguments: ["jobID": .string(id)])
        #expect(try client.request("tasks/get", params: ["taskId": .string(id)])["error"]?["code"] == -32602)
    }
}

@Test func `MCP task cancellation cleans up running work and status arrives without polling`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let other = try MCPClient(fixture: fixture)
        let marker = fixture.directory.appendingPathComponent("child-pid")
        let created = try client.request(
            "tools/call",
            params: [
                "name": "latch_execute", "arguments": submission(fixture, mode: "orphan", arguments: [marker.path]),
                "task": [:],
            ])
        let id = try #require(created["result"]?["task"]?["taskId"]?.string)
        #expect(try other.request("tasks/get", params: ["taskId": .string(id)])["result"]?["status"] == "working")
        try client.send([
            "jsonrpc": "2.0", "id": "cancelled-wait", "method": "tasks/result", "params": ["taskId": .string(id)],
        ])
        try client.send([
            "jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": "cancelled-wait"],
        ])
        try admission(scheduler)
        let running = try client.notification("notifications/tasks/status")
        #expect(running["params"]?["status"] == "working")
        #expect(running["params"]?["statusMessage"] == "running")
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !FileManager.default.fileExists(atPath: marker.path), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(FileManager.default.fileExists(atPath: marker.path))
        let cancelled = try other.request("tasks/cancel", params: ["taskId": .string(id)])
        #expect(cancelled["result"]?["status"] == "cancelled")
        let result = try client.request("tasks/result", params: ["taskId": .string(id)])
        #expect(result["result"]?["structuredContent"]?["state"] == "cancelled")
        #expect(result["result"]?["structuredContent"]?["complete"] == true)
        #expect(try other.request("tasks/result", params: ["taskId": .string(id)])["result"] == result["result"])
        #expect(try client.request("tasks/cancel", params: ["taskId": .string(id)])["error"]?["code"] == -32602)
    }
}

@Test func `MCP rejects malformed task metadata and keeps older clients compatible`() throws {
    let fixture = try Fixture()
    let client = try MCPClient(fixture: fixture)
    for task: MCPValue in [false, ["ttl": -1], ["ttl": .number(1.5)], ["surprise": true]] {
        #expect(
            try client.request(
                "tools/call", params: ["name": "latch_execute", "arguments": submission(fixture), "task": task])[
                    "error"]?["code"] == -32602)
    }
    #expect(try client.request("tools/call", params: ["name": "latch_view", "task": [:]])["error"]?["code"] == -32601)
    #expect(
        try client.request(
            "tools/call",
            params: ["name": "latch_execute", "arguments": submission(fixture), "_meta": ["progressToken": true]])[
                "error"]?["code"] == -32602)
    let older = try MCPClient(fixture: fixture, initialize: false)
    #expect(try older.handshake(version: "2025-06-18")["result"]?["capabilities"]?["tasks"] == nil)
    #expect(try older.request("tasks/list")["error"]?["code"] == -32601)
    // A peer without task support must ignore augmentation metadata and return the ordinary result.
    #expect(
        try older.request("tools/call", params: ["name": "latch_view", "task": [:]])["result"]?["structuredContent"]?[
            "scheduler"] != nil)
}

@Test func `MCP request cancellation only stops waiting and explicit cancellation stops the job`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let arguments = submission(fixture)
        try client.send([
            "jsonrpc": "2.0", "id": "execute", "method": "tools/call",
            "params": ["name": "latch_execute", "arguments": arguments],
        ])
        let id = try jobID(client.tool("latch_submit", arguments: arguments))
        try client.send([
            "jsonrpc": "2.0", "id": "waiting", "method": "tools/call",
            "params": [
                "name": "latch_wait", "arguments": ["jobID": .string(id)], "_meta": ["progressToken": "waiting"],
            ],
        ])
        #expect(try client.notification("notifications/progress", token: "waiting")["params"]?["message"] == "queued")
        #expect(
            try client.request(
                "tools/call",
                params: [
                    "name": "latch_wait", "arguments": ["jobID": .string(id)], "_meta": ["progressToken": "waiting"],
                ])["error"]?["code"] == -32602)
        try client.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": "waiting"]])
        let pending = try client.request(
            "tools/call",
            params: [
                "name": "latch_wait", "arguments": ["jobID": .string(id), "timeoutSeconds": .number(0.01)],
                "_meta": ["progressToken": "waiting"],
            ])
        #expect(pending["result"]?["structuredContent"]?["state"] == "queued")
        try client.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": "execute"]])
        #expect(
            try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 0])["result"]?[
                "structuredContent"]?["complete"] == false)
        _ = try client.tool("latch_cancel", arguments: ["jobID": .string(id)])
        let cancelled = try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])
        #expect(cancelled["result"]?["structuredContent"]?["state"] == "cancelled")
        #expect(try scheduler.snapshot().tasks.isEmpty)
    }
}

@Test func `MCP drain preserves accepted work and results but retires old endpoints`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let arguments = submission(fixture)
        let id = try jobID(client.tool("latch_submit", arguments: arguments))
        var drain: UpdateDrain? = try UpdateDrain(scheduler: scheduler)
        try withExtendedLifetime(drain) {
            #expect(
                try client.tool("latch_submit", arguments: submission(fixture))["result"]?["structuredContent"]?["code"]
                    == 75)
            #expect(try jobID(client.tool("latch_submit", arguments: arguments)) == id)
            #expect(throws: LatchError.self) { try drain!.wait(timeout: 0) }
            try admission(scheduler)
            #expect(
                try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])["result"]?[
                    "structuredContent"]?["succeeded"] == true)
            try drain!.wait(timeout: 1)
            try UpdateDrain.advance(in: scheduler.directory)
            #expect(
                try client.tool("latch_wait", arguments: ["jobID": .string(id)])["result"]?["structuredContent"]?[
                    "succeeded"] == true)
        }
        drain = nil
        #expect(
            try client.tool("latch_submit", arguments: submission(fixture))["result"]?["structuredContent"]?["code"]
                == 69)
        #expect(try jobID(client.tool("latch_submit", arguments: arguments)) == id)
        let fresh = try MCPClient(fixture: fixture)
        let next = try jobID(fresh.tool("latch_submit", arguments: submission(fixture)))
        try admission(scheduler)
        #expect(
            try fresh.tool("latch_wait", arguments: ["jobID": .string(next), "timeoutSeconds": 4])["result"]?[
                "structuredContent"]?["succeeded"] == true)
    }
}

private func mcpService(_ scheduler: Scheduler) throws -> FileLatch {
    let lock = try FileLatch(path: scheduler.directory.appendingPathComponent("service.lock").path)
    try lock.acquire(shared: false, timeout: 0)
    let status = SchedulerService.Status(
        running: true, pid: getpid(), path: scheduler.path, serviceRevision: BuildIdentity.serviceRevision)
    try JSONEncoder().encode(status).write(
        to: scheduler.directory.appendingPathComponent("service.json"), options: .atomic)
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
        for seconds in (0...10).reversed() {
            $0.record(
                SensorSnapshot(
                    sampledAt: Date(), uptime: now - Double(seconds),
                    cpuCores: ProcessInfo.processInfo.activeProcessorCount, cpuActive: 0, busiestCore: 0,
                    gpuActive: 0, aneWatts: 0,
                    memoryAvailableMiB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) * 8 / 10,
                    memoryTotalMiB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
                    memoryPressure: "normal", thermalState: "nominal", diskBytesPerSecond: 0,
                    unavailable: [], cpuTemperature: 30, gpuTemperature: 30))
        }
    }
}

private func submission(
    _ fixture: Fixture, key: String = UUID().uuidString, mode: String = "report", arguments: [String] = []
) -> MCPValue {
    [
        "requestKey": .string(key), "name": "mcp-test",
        "executable": .string(
            fixture.executable.deletingLastPathComponent().appendingPathComponent("LatchTestWorkload").path),
        "arguments": .array(([mode] + arguments).map(MCPValue.string)),
        "workingDirectory": .string(fixture.directory.path),
        "measurement": false,
    ]
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
    guard case .array(let tools) = listed["result"]?["tools"] else {
        Issue.record("missing tools")
        return
    }
    #expect(
        tools.compactMap { $0["name"]?.string } == [
            "latch_view", "latch_submit", "latch_wait", "latch_cancel", "latch_forget", "latch_execute", "latch_signal",
            "latch_input", "latch_resize", "latch_control", "latch_read",
        ])
    #expect(initialized["result"]?["capabilities"]?["tasks"]?["requests"]?["tools"]?["call"] == [:])
    #expect(tools[5]["execution"]?["taskSupport"] == "optional")
    #expect(tools[0]["annotations"]?["readOnlyHint"] == true)
    #expect(tools[1]["annotations"]?["readOnlyHint"] == false)
    #expect(tools[1]["annotations"]?["openWorldHint"] == true)
    let properties = try #require(tools[1]["inputSchema"]?["properties"]?.object)
    #expect(
        Set(properties.keys) == [
            "requestKey", "name", "executable", "arguments", "workingDirectory", "measurement", "input", "columns",
            "rows", "checkpoints",
        ])
    #expect(try client.request("unknown")["error"]?["code"] == -32601)
    #expect(try client.tool("service_install")["error"]?["code"] == -32602)
    #expect(try client.tool("latch_view", arguments: ["unexpected": true])["error"]?["code"] == -32602)
    #expect(try client.request("ping")["result"] == [:])
}

@Test func `Latch plans resources without asking the agent for budgets`() {
    let build = TaskPlanner.plan(
        executable: "/usr/bin/swift", arguments: ["build", "-c", "release"], measurement: false, cpuCount: 12,
        memoryMiB: 32768)
    #expect(build.arguments == ["build", "-c", "release", "--jobs", "4"])
    #expect(build.requirements.mode == .batch)
    #expect(build.requirements.cpuCores == 4)
    #expect(build.requirements.memoryMiB == 4096)
    #expect(build.requirements.temperatureGuard == TemperatureGuard())
    #expect(build.admissionTimeout == nil)
    let measurement = TaskPlanner.plan(
        executable: "/usr/bin/swift", arguments: ["build"], measurement: true, cpuCount: 12, memoryMiB: 32768)
    #expect(measurement.requirements.mode == .isolated)
    #expect(measurement.requirements.cpuCores == 12)
    #expect(measurement.arguments == ["build"])
    #expect(measurement.requirements.temperatureGuard == TemperatureGuard(maxCPU: 50, maxGPU: 50, cooldown: 10))
    for (executable, arguments) in [
        ("/usr/bin/swift", ["test"]), ("/usr/bin/swift", ["build", "-j", "8"]), ("/model", ["infer"]),
    ] {
        let plan = TaskPlanner.plan(
            executable: executable, arguments: arguments, measurement: false, cpuCount: 8, memoryMiB: 16384)
        #expect(plan.requirements.mode == .isolated)
        #expect(plan.arguments == arguments)
    }
    let small = TaskPlanner.plan(
        executable: "/usr/bin/swift", arguments: ["build"], measurement: false, cpuCount: 1, memoryMiB: 2048)
    #expect(small.requirements.cpuCores == 1)
    #expect(small.requirements.memoryMiB == 512)
}

@Test func `MCP rejects invalid submissions before spawning`() throws {
    let fixture = try Fixture()
    let client = try MCPClient(fixture: fixture)
    for (key, invalid) in [
        ("cpu", MCPValue.bool(true)), ("cpu", .number(1.5)), ("arguments", .string("echo hi")),
        ("executable", .string("relative")), ("arguments", .array([.string("nul\0byte")])),
        ("mode", .string("unsafe")), ("cooldownSeconds", .number(-1)),
        ("workingDirectory", .string("/missing/latch-test")),
    ] {
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
        #expect(
            try client.tool("latch_submit", arguments: submission(fixture, key: "same", mode: "fail75"))["error"]?[
                "code"] == -32602)
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
        #expect(
            try client.tool("latch_forget", arguments: ["jobID": .string(id)])["result"]?["structuredContent"]?[
                "forgotten"] == true)
        #expect(!FileManager.default.fileExists(atPath: scheduler.directory.appendingPathComponent(id + ".lease").path))
        #expect(
            try client.tool("latch_forget", arguments: ["jobID": .string(id)])["result"]?["structuredContent"]?[
                "forgotten"] == false)
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
        try client.send([
            "jsonrpc": "2.0", "id": "pending-wait", "method": "tools/call",
            "params": ["name": "latch_wait", "arguments": ["jobID": .string(id), "timeoutSeconds": 60]],
        ])
        #expect(try client.request("ping")["result"] == [:])
        #expect(try client.tool("latch_view")["result"]?["isError"] == false)
        try client.send([
            "jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": "pending-wait"],
        ])
        let pending = try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": .number(0.05)])
        #expect(pending["result"]?["structuredContent"]?["complete"] == false)
        #expect(pending["result"]?["structuredContent"]?["state"] == "queued")
        try admission(scheduler)
        #expect(
            try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])["result"]?[
                "structuredContent"]?["succeeded"] == true)
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

@Test func `another connection can cancel wait and forget a queued job`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let first = try MCPClient(fixture: fixture)
        let second = try MCPClient(fixture: fixture)
        let id = try jobID(first.tool("latch_submit", arguments: submission(fixture)))
        #expect(try first.tool("latch_forget", arguments: ["jobID": .string(id)])["error"]?["code"] == -32602)
        _ = try second.tool("latch_cancel", arguments: ["jobID": .string(id)])
        let result = try first.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])
        #expect(result["result"]?["structuredContent"]?["state"] == "cancelled")
        #expect(result["result"]?["isError"] == true)
        #expect(try scheduler.snapshot().tasks.isEmpty)
        #expect(
            try second.tool("latch_forget", arguments: ["jobID": .string(id)])["result"]?["structuredContent"]?[
                "forgotten"] == true)
        #expect(
            try first.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 0])["error"]?["code"]
                == -32602)
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
        let id = try jobID(
            client.tool("latch_submit", arguments: submission(fixture, mode: mode, arguments: [marker.path])))
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
        #expect(
            response["result"]?["structuredContent"]?["exitCode"]
                == (mode == "descendant" ? MCPValue.number(9) : .number(15)))
        let releasedBy = ProcessInfo.processInfo.systemUptime + 2
        while try !scheduler.snapshot().tasks.isEmpty, ProcessInfo.processInfo.systemUptime < releasedBy {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(try scheduler.snapshot().tasks.isEmpty)
        let gate = try FileLatch(path: fixture.lockPath)
        try gate.acquire(shared: false, timeout: 0)
    }
}

@Test func `MCP disconnect preserves tickets and results across reconnects`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let arguments = submission(fixture)
        let id = try jobID(client.tool("latch_submit", arguments: arguments))
        try client.input.fileHandleForWriting.close()
        #expect(try fixture.finish(client.child) == 0)
        #expect(try scheduler.snapshot().tasks.first?.id == id)
        let reconnected = try MCPClient(fixture: fixture)
        #expect(try jobID(reconnected.tool("latch_submit", arguments: arguments)) == id)
        try admission(scheduler)
        #expect(
            try reconnected.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])["result"]?[
                "structuredContent"]?["succeeded"] == true)
        #expect(try SchedulerService.requireRunning(in: scheduler.directory) == getpid())
    }
}

@Test func `MCP handles fragmented requests and the older supported version`() throws {
    let fixture = try Fixture()
    let client = try MCPClient(fixture: fixture, initialize: false)
    let message: MCPValue = [
        "jsonrpc": "2.0", "id": "fragment", "method": "initialize",
        "params": [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"],
        ],
    ]
    let data = try JSONEncoder().encode(message)
    try client.input.fileHandleForWriting.write(contentsOf: data.prefix(7))
    try client.input.fileHandleForWriting.write(contentsOf: data.dropFirst(7))
    try client.input.fileHandleForWriting.write(contentsOf: Data([13, 10]))
    #expect(try client.response(id: "fragment")["result"]?["protocolVersion"] == "2025-06-18")
    try client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    #expect(try client.tool("latch_view")["result"]?["structuredContent"]?["scheduler"] != nil)
}

@Test func `queued MCP tickets survive an abrupt endpoint crash`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let arguments = submission(fixture)
        let id = try jobID(client.tool("latch_submit", arguments: arguments))
        let queuedBy = ProcessInfo.processInfo.systemUptime + 3
        while try scheduler.snapshot().tasks.isEmpty, ProcessInfo.processInfo.systemUptime < queuedBy {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(try scheduler.snapshot().tasks.count == 1)
        #expect(kill(client.child.process.processIdentifier, SIGKILL) == 0)
        #expect(try fixture.finish(client.child) == SIGKILL)
        let reconnected = try MCPClient(fixture: fixture)
        #expect(try jobID(reconnected.tool("latch_submit", arguments: arguments)) == id)
        #expect(try scheduler.snapshot().tasks.first?.id == id)
        try admission(scheduler)
        #expect(
            try reconnected.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])["result"]?[
                "structuredContent"]?["succeeded"] == true)
    }
}

@Test func `connections share retry keys and queue more than two jobs in FIFO order`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let first = try MCPClient(fixture: fixture)
        let second = try MCPClient(fixture: fixture)
        let arguments = submission(fixture, key: "first")
        let firstID = try jobID(first.tool("latch_submit", arguments: arguments))
        #expect(try jobID(second.tool("latch_submit", arguments: arguments)) == firstID)
        let secondID = try jobID(second.tool("latch_submit", arguments: submission(fixture, key: "second")))
        let thirdID = try jobID(first.tool("latch_submit", arguments: submission(fixture, key: "third")))
        let fourthID = try jobID(second.tool("latch_submit", arguments: submission(fixture, key: "fourth")))
        let fifthID = try jobID(first.tool("latch_submit", arguments: submission(fixture, key: "fifth")))
        let allIDs = [firstID, secondID, thirdID, fourthID, fifthID]
        #expect(try scheduler.snapshot().tasks.map(\.id) == allIDs)
        #expect(
            try second.tool("latch_submit", arguments: submission(fixture, key: "first", mode: "fail75"))["error"]?[
                "code"] == -32602)
        let view = try second.tool("latch_view")["result"]?["structuredContent"]
        #expect(view?["owner"] == nil)
        #expect(view?["globalOutstandingLimit"] == 64)
        #expect(view?["globalRetainedLimit"] == 256)
        guard case .array(let jobs) = view?["jobs"] else {
            Issue.record("missing shared jobs")
            return
        }
        #expect(Set(jobs.compactMap { $0["jobID"]?.string }) == Set(allIDs))
        _ = try second.tool("latch_cancel", arguments: ["jobID": .string(firstID)])
        #expect(
            try first.tool("latch_wait", arguments: ["jobID": .string(firstID), "timeoutSeconds": 4])["result"]?[
                "structuredContent"]?["complete"] == true)
        #expect(try scheduler.snapshot().tasks.map(\.id) == Array(allIDs.dropFirst()))
    }
}

@Test func `durable queue enforces only global outstanding and retention bounds`() throws {
    let fixture = try Fixture()
    let store = try DurableJobs(scheduler: Scheduler(path: fixture.lockPath))
    for _ in 0..<DurableJobs.globalOutstandingLimit {
        _ = try store.submit(MCPSubmission(submission(fixture)))
    }
    #expect(throws: LatchError.self) { try store.submit(MCPSubmission(submission(fixture))) }
    #expect(try store.scheduler.snapshot().tasks.count == DurableJobs.globalOutstandingLimit)
    for record in try store.records() {
        try store.publish(record.id, result: ["state": "completed", "complete": true, "succeeded": true])
    }
    for index in DurableJobs.globalOutstandingLimit..<DurableJobs.globalRetainedLimit {
        let record = try store.submit(MCPSubmission(submission(fixture, key: "result-\(index)")))
        try store.publish(record.id, result: ["state": "completed", "complete": true, "succeeded": true])
    }
    #expect(try store.records().count == DurableJobs.globalRetainedLimit)
    #expect(throws: LatchError.self) { try store.submit(MCPSubmission(submission(fixture))) }
    let completed = try #require(store.records().first)
    #expect(try store.submit(completed.submission).id == completed.id)
    try store.forget(completed.id)
    #expect(try store.submit(completed.submission).id != completed.id)
}

@Test func `unlaunched durable tickets recover in their original FIFO position`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let store = try DurableJobs(scheduler: scheduler)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let older = try store.submit(MCPSubmission(submission(fixture)))
        let newer = try store.submit(MCPSubmission(submission(fixture)))
        try store.launch(newer.id, executable: fixture.executable)
        #expect(try scheduler.snapshot().tasks.map(\.id) == [older.id, newer.id])
        try store.recover(executable: fixture.executable)
        try admission(scheduler, expectedTasks: 2)
        let first = try MCPClient(fixture: fixture)
        #expect(
            try first.tool("latch_wait", arguments: ["jobID": .string(older.id), "timeoutSeconds": 4])["result"]?[
                "structuredContent"]?["succeeded"] == true)
        #expect(try store.records().first(where: { $0.id == newer.id })?.complete == false)
        try admission(scheduler)
        let second = try MCPClient(fixture: fixture)
        #expect(
            try second.tool("latch_wait", arguments: ["jobID": .string(newer.id), "timeoutSeconds": 4])["result"]?[
                "structuredContent"]?["succeeded"] == true)
    }
}

@Test func `recovery never replays a potentially executed command`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let store = try DurableJobs(scheduler: scheduler)
    let record = try store.submit(MCPSubmission(submission(fixture)))
    try scheduler.transaction { $0.tasks[0].state = .running }
    try store.recover(executable: fixture.executable)
    let job = MCPJob(record: record, store: store)
    try job.update(now: ProcessInfo.processInfo.systemUptime)
    let result = try job.result(includeOutput: true)
    #expect(result["complete"] == true)
    #expect(result["succeeded"] == false)
    #expect(result["terminationReason"] == "unknown")
    #expect(try scheduler.snapshot().tasks.isEmpty)
}

@Test func `protocol tasks and completed output survive reconnecting`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let handle = try client.request(
            "tools/call", params: ["name": "latch_execute", "arguments": submission(fixture), "task": [:]])
        let id = try #require(handle["result"]?["task"]?["taskId"]?.string)
        try admission(scheduler)
        let original = try client.request("tasks/result", params: ["taskId": .string(id)])
        try client.input.fileHandleForWriting.close()
        #expect(try fixture.finish(client.child) == 0)
        let reconnected = try MCPClient(fixture: fixture)
        #expect(
            try reconnected.request("tasks/result", params: ["taskId": .string(id)])["result"] == original["result"])
        #expect(
            try reconnected.request("tasks/get", params: ["taskId": .string(id)])["result"]?["status"] == "completed")
    }
}

@Test func `queued durable jobs retain their tickets while the service is unavailable`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    let client = try MCPClient(fixture: fixture)
    let id = try jobID(client.tool("latch_submit", arguments: submission(fixture)))
    service.release()
    let result = try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": .number(0.2)])
    #expect(result["result"]?["structuredContent"]?["complete"] == false)
    #expect(try scheduler.snapshot().tasks.first?.id == id)
    let restarted = try mcpService(scheduler)
    try withExtendedLifetime(restarted) {
        try admission(scheduler)
        #expect(
            try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])["result"]?[
                "structuredContent"]?["succeeded"] == true)
    }
}

@Test func `recovery commits an already written final result without replay`() throws {
    let fixture = try Fixture()
    let store = try DurableJobs(scheduler: Scheduler(path: fixture.lockPath))
    let record = try store.submit(MCPSubmission(submission(fixture)))
    let final: MCPValue = ["state": "completed", "complete": true, "succeeded": true, "stdout": "saved output"]
    try JSONEncoder().encode(final).write(to: store.file(record.id, "result.json"), options: .atomic)
    try store.recover(executable: fixture.executable)
    let recovered = try #require(store.records().first)
    #expect(recovered.complete)
    #expect(recovered.environment.isEmpty)
    #expect(try store.scheduler.snapshot().tasks.isEmpty)
    #expect(
        try JSONDecoder().decode(MCPValue.self, from: Data(contentsOf: store.file(record.id, "result.json"))) == final)
}

@Test func `MCP has no owner configuration or submission property`() throws {
    #expect(try Options(arguments: ["mcp"]).command == .mcp)
    #expect(throws: LatchError.self) { try Options(arguments: ["mcp", "--owner", "agent"]) }
    #expect(throws: LatchError.self) { try Options(arguments: ["view", "--owner", "agent"]) }
    let fixture = try Fixture()
    var arguments = try #require(submission(fixture).object)
    arguments["owner"] = "another"
    #expect(throws: MCPFailure.self) { try MCPSubmission(.object(arguments)) }
}

private func interactiveSubmission(_ fixture: Fixture, mode: String, input: String) throws -> MCPValue {
    var arguments = try #require(submission(fixture, mode: mode).object)
    arguments["input"] = .string(input)
    return .object(arguments)
}

private func delivered(_ client: MCPClient, job: String, tool: String, arguments: MCPValue) throws -> MCPValue {
    var values = try #require(arguments.object)
    values["jobID"] = .string(job)
    values["requestKey"] = values["requestKey"] ?? .string(UUID().uuidString)
    let receipt = try client.tool(tool, arguments: .object(values))
    let id = try #require(receipt["result"]?["structuredContent"]?["controlID"]?.string)
    let result = try client.tool(
        "latch_control", arguments: ["jobID": .string(job), "controlID": .string(id), "timeoutSeconds": 4])
    let content = try #require(result["result"]?["structuredContent"])
    #expect(content["state"] == "delivered", "Control result: \(String(describing: content))")
    return content
}

private func outputUntil(_ client: MCPClient, job: String, contains text: String) throws -> String {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    var output = ""
    var offset: MCPValue = 0
    while !output.contains(text), ProcessInfo.processInfo.systemUptime < deadline {
        let response = try client.tool(
            "latch_read", arguments: ["jobID": .string(job), "stdoutOffset": offset, "timeoutSeconds": 1])
        let value = try #require(response["result"]?["structuredContent"])
        output += value["stdout"]?["text"]?.string ?? ""
        offset = value["stdout"]?["nextOffset"] ?? offset
        if value["complete"] == true {
            break
        }
    }
    try #require(output.contains(text))
    return output
}

@Test func `pipe input is literal durable and deduplicated and EOF closes stdin`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let id = try jobID(
            client.tool("latch_submit", arguments: interactiveSubmission(fixture, mode: "pipe-input", input: "pipe")))
        try admission(scheduler)
        _ = try outputUntil(client, job: id, contains: "ready")
        let bytes = Data([0, 3, 4, 255, 10, 65])
        let values: MCPValue = [
            "jobID": .string(id), "requestKey": "bytes", "base64": .string(bytes.base64EncodedString()),
        ]
        let receipt = try delivered(client, job: id, tool: "latch_input", arguments: values)
        try client.input.fileHandleForWriting.close()
        #expect(try fixture.finish(client.child) == 0)
        let reconnected = try MCPClient(fixture: fixture)
        let retry = try reconnected.tool("latch_input", arguments: values)
        #expect(retry["result"]?["structuredContent"]?["controlID"] == receipt["controlID"])
        #expect(
            try reconnected.tool(
                "latch_input", arguments: ["jobID": .string(id), "requestKey": "bytes", "text": "different"])["error"]?[
                    "code"] == -32602)
        _ = try delivered(reconnected, job: id, tool: "latch_input", arguments: ["eof": true])
        let result = try reconnected.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])
        #expect(result["result"]?["structuredContent"]?["stdout"] == .string("ready\n" + bytes.base64EncodedString()))
        #expect(result["result"]?["structuredContent"]?["succeeded"] == true)
    }
}

@Test func `interrupt is relayed without escalation or automatic cancellation`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let id = try jobID(
            client.tool(
                "latch_submit", arguments: interactiveSubmission(fixture, mode: "ignore-interrupt", input: "pipe")))
        try admission(scheduler)
        _ = try outputUntil(client, job: id, contains: "ready")
        _ = try delivered(client, job: id, tool: "latch_signal", arguments: ["signal": "interrupt"])
        let pending = try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": .number(2.1)])
        #expect(pending["result"]?["structuredContent"]?["state"] == "running")
        _ = try delivered(client, job: id, tool: "latch_input", arguments: ["eof": true])
        #expect(
            try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])["result"]?[
                "structuredContent"]?["succeeded"] == true)
    }
}

@Test(arguments: ["interrupt", "key", "eof", "raw"])
func `terminal attaches streams and forwards signals and control characters`(mode: String) throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let id = try jobID(
            client.tool(
                "latch_submit",
                arguments: interactiveSubmission(
                    fixture, mode: mode == "raw" ? "raw-terminal" : "terminal", input: "terminal")))
        try admission(scheduler)
        _ = try outputUntil(client, job: id, contains: "ready")
        if mode == "interrupt" {
            let other = try MCPClient(fixture: fixture)
            _ = try delivered(other, job: id, tool: "latch_signal", arguments: ["signal": "interrupt"])
        } else {
            let bytes = mode == "key" ? "\u{3}" : (mode == "eof" ? "\u{4}" : "\u{3}\u{4}\u{0}")
            _ = try delivered(client, job: id, tool: "latch_input", arguments: ["text": .string(bytes)])
        }
        let result = try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])["result"]?[
            "structuredContent"]
        #expect(result?["complete"] == true)
        #expect(result?["stderr"] == "")
        if mode == "interrupt" || mode == "key" {
            #expect(result?["exitCode"] == 2)
            #expect(result?["terminationReason"] == "signal")
            #expect(result?["state"] == "completed")
        } else {
            #expect(result?["succeeded"] == true)
            if mode == "raw" {
                #expect(result?["stdout"]?.string?.contains("AwQA") == true)
            }
        }
    }
}

@Test func `terminal resize input and receipts are shared across connections`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let id = try jobID(
            client.tool("latch_submit", arguments: interactiveSubmission(fixture, mode: "terminal", input: "terminal")))
        try admission(scheduler)
        _ = try outputUntil(client, job: id, contains: "terminal-stderr")
        try client.input.fileHandleForWriting.close()
        #expect(try fixture.finish(client.child) == 0)
        let other = try MCPClient(fixture: fixture)
        let receipt = try delivered(other, job: id, tool: "latch_resize", arguments: ["columns": 120, "rows": 45])
        let resumed = try MCPClient(fixture: fixture)
        let controlID = try #require(receipt["controlID"])
        #expect(
            try resumed.tool("latch_control", arguments: ["jobID": .string(id), "controlID": controlID])["result"]?[
                "structuredContent"] == receipt)
        _ = try delivered(resumed, job: id, tool: "latch_input", arguments: ["text": "size\n"])
        _ = try outputUntil(resumed, job: id, contains: "size: 120x45")
        _ = try delivered(resumed, job: id, tool: "latch_input", arguments: ["text": "exit\n"])
        #expect(
            try resumed.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])["result"]?[
                "structuredContent"]?["succeeded"] == true)
    }
}

@Test func `stopped work retains its reservation and explicit cancellation still terminates it`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let id = try jobID(
            client.tool("latch_submit", arguments: interactiveSubmission(fixture, mode: "pipe-input", input: "pipe")))
        try admission(scheduler)
        _ = try outputUntil(client, job: id, contains: "ready")
        _ = try delivered(client, job: id, tool: "latch_signal", arguments: ["signal": "stop"])
        #expect(try scheduler.snapshot().tasks.first?.state == .running)
        _ = try client.tool("latch_cancel", arguments: ["jobID": .string(id)])
        #expect(
            try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])["result"]?[
                "structuredContent"]?["state"] == "cancelled")
    }
}

@Test func `live output retains a bounded tail with byte offsets and explicit gaps`() throws {
    var output = MCPLiveOutput()
    output.append(Data(repeating: 65, count: 40000), output: true)
    let first = try output.value(stdoutOffset: 0, stderrOffset: 0, complete: false)
    #expect(first["stdout"]?["startOffset"] == 7232)
    #expect(first["stdout"]?["nextOffset"] == 40000)
    #expect(first["stdout"]?["truncated"] == true)
    output.append(Data([0, 255, 3]), output: true)
    #expect(try output.value(stdoutOffset: 40000, stderrOffset: 0, complete: false)["stdout"]?["base64"] == "AP8D")
    #expect(throws: MCPFailure.self) { try output.value(stdoutOffset: 50000, stderrOffset: 0, complete: false) }
}

@Test func `backpressured input cannot block signal delivery`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let id = try jobID(
            client.tool("latch_submit", arguments: interactiveSubmission(fixture, mode: "blocked-input", input: "pipe"))
        )
        try admission(scheduler)
        _ = try outputUntil(client, job: id, contains: "ready")
        var receipts: [String] = []
        for index in 0..<12 {
            let response = try client.tool(
                "latch_input",
                arguments: [
                    "jobID": .string(id), "requestKey": .string("chunk-\(index)"),
                    "text": .string(String(repeating: "a", count: 16384)),
                ])
            try receipts.append(#require(response["result"]?["structuredContent"]?["controlID"]?.string))
        }
        let last = try #require(receipts.last)
        #expect(
            try client.tool(
                "latch_control", arguments: ["jobID": .string(id), "controlID": .string(last), "timeoutSeconds": 0])[
                    "result"]?["structuredContent"]?["complete"] == false)
        _ = try delivered(client, job: id, tool: "latch_signal", arguments: ["signal": "interrupt"])
        #expect(
            try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])["result"]?[
                "structuredContent"]?["exitCode"] == 2)
        for receipt in receipts {
            #expect(
                try client.tool(
                    "latch_control",
                    arguments: ["jobID": .string(id), "controlID": .string(receipt), "timeoutSeconds": 0])["result"]?[
                        "structuredContent"]?["complete"] == true)
        }
    }
}

@Test func `signals reach the entire workload process group`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let marker = fixture.directory.appendingPathComponent("signal-child")
        let id = try jobID(
            client.tool("latch_submit", arguments: submission(fixture, mode: "descendant", arguments: [marker.path])))
        try admission(scheduler)
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !FileManager.default.fileExists(atPath: marker.path), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(FileManager.default.fileExists(atPath: marker.path))
        _ = try delivered(client, job: id, tool: "latch_signal", arguments: ["signal": "interrupt"])
        #expect(
            try client.tool("latch_wait", arguments: ["jobID": .string(id), "timeoutSeconds": 4])["result"]?[
                "structuredContent"]?["exitCode"] == 2)
        let gate = try FileLatch(path: fixture.lockPath)
        try gate.acquire(shared: false, timeout: 0)
    }
}

@Test func `control validation rejects invalid and queued operations and lost receipts are never replayed`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try mcpService(scheduler)
    try withExtendedLifetime(service) {
        let client = try MCPClient(fixture: fixture)
        let id = try jobID(client.tool("latch_submit", arguments: submission(fixture)))
        #expect(
            try client.tool(
                "latch_signal", arguments: ["jobID": .string(id), "requestKey": "queued", "signal": "interrupt"])[
                    "error"]?["code"] == -32602)
        for extra: MCPValue in [["input": "bad"], ["input": "pipe", "columns": 80], ["input": "terminal", "rows": 0]] {
            var arguments = try #require(submission(fixture).object)
            arguments.merge(extra.object!) { _, new in new }
            #expect(throws: MCPFailure.self) { try MCPSubmission(.object(arguments)) }
        }
        for values: MCPValue in [
            ["requestKey": "bad", "base64": "!"], ["requestKey": "bad", "text": "a", "base64": "YQ=="],
            ["requestKey": "bad", "text": .string(String(repeating: "a", count: 16385))],
        ] {
            #expect(throws: MCPFailure.self) {
                try MCPControl(
                    operation: "latch_input",
                    arguments: MCPArguments(values, allowed: ["requestKey", "base64", "text"]))
            }
        }
    }
    let separate = try Fixture()
    let store = try DurableJobs(scheduler: Scheduler(path: separate.lockPath))
    let job = try store.submit(MCPSubmission(submission(separate)))
    try store.scheduler.transaction {
        $0.jobs?[0].state = "running"
        $0.tasks[0].state = .running
    }
    let input = try MCPArguments(
        ["requestKey": "interrupt", "signal": "interrupt"], allowed: ["requestKey", "signal"])
    let control = try store.enqueueControl(MCPControl(operation: "latch_signal", arguments: input), id: job.id)
    _ = try store.claimControls(job.id)
    try store.recover(executable: separate.executable)
    #expect(try store.controls(job.id).first?.state == "unknown")
    #expect(
        try store.enqueueControl(MCPControl(operation: "latch_signal", arguments: input), id: job.id).id == control.id)
    try store.forgetControl(control.id, id: job.id)
    #expect(try store.controls(job.id).isEmpty)
}

@Test func `a full input queue reserves space for interrupt delivery`() throws {
    let fixture = try Fixture()
    let store = try DurableJobs(scheduler: Scheduler(path: fixture.lockPath))
    let job = try store.submit(MCPSubmission(interactiveSubmission(fixture, mode: "blocked-input", input: "pipe")))
    try store.scheduler.transaction { $0.jobs?[0].state = "running" }
    for index in 0..<12 {
        let input = try MCPArguments(
            ["requestKey": .string("input-\(index)"), "text": "bytes"], allowed: ["requestKey", "text"])
        _ = try store.enqueueControl(MCPControl(operation: "latch_input", arguments: input), id: job.id)
    }
    let extra = try MCPArguments(["requestKey": "extra", "text": "bytes"], allowed: ["requestKey", "text"])
    #expect(throws: LatchError.self) {
        try store.enqueueControl(MCPControl(operation: "latch_input", arguments: extra), id: job.id)
    }
    let interrupt = try MCPArguments(
        ["requestKey": "interrupt", "signal": "interrupt"], allowed: ["requestKey", "signal"])
    #expect(
        try store.enqueueControl(MCPControl(operation: "latch_signal", arguments: interrupt), id: job.id).state
            == "queued")
}
