import Darwin
import Foundation
import Testing

@testable import Latch

final class OperatorFixture {
    let fixture: Fixture
    let scheduler: Scheduler
    let store: DurableJobs
    let service: FileLatch
    var queue: OperatorQueue { OperatorQueue(scheduler: scheduler) }

    init(fixture: Fixture? = nil) throws {
        self.fixture = try fixture ?? Fixture()
        scheduler = try Scheduler(path: self.fixture.lockPath)
        store = try DurableJobs(scheduler: scheduler)
        service = try FileLatch(path: scheduler.directory.appendingPathComponent("service.lock").path)
        try service.acquire(shared: false, timeout: 0)
        let status = SchedulerService.Status(
            running: true, pid: getpid(), path: self.fixture.lockPath,
            serviceRevision: BuildIdentity.serviceRevision)
        try JSONEncoder().encode(status).write(to: scheduler.directory.appendingPathComponent("service.json"))
    }

    func submit(_ name: String = "operator-test", measurement: Bool = false) throws -> DurableJobRecord {
        try store.submit(
            MCPSubmission([
                "requestKey": .string(UUID().uuidString), "name": .string(name),
                "executable": "/usr/bin/true", "workingDirectory": .string(fixture.directory.path),
                "measurement": .bool(measurement),
            ]))
    }

    func publishSensors() throws {
        try scheduler.transaction { state in
            state.record(
                SensorSnapshot(
                    sampledAt: Date(), uptime: ProcessInfo.processInfo.systemUptime,
                    cpuCores: 8, cpuActive: 0, busiestCore: 0, gpuActive: 0, aneWatts: 0,
                    memoryAvailableMiB: 24000, memoryTotalMiB: 32000, memoryPressure: "normal",
                    thermalState: "nominal",
                    diskBytesPerSecond: 0, unavailable: [], cpuTemperature: 30, gpuTemperature: 30))
        }
    }

    func finish(_ child: Child) throws -> Int32 {
        try fixture.finish(child, timeout: .seconds(10), onWait: publishSensors)
    }
}

@Test func `operator commands have distinct strict contracts from command execution`() throws {
    let id = UUID().uuidString
    #expect(try Options(arguments: ["list"]).command == .list)
    #expect(try Options(arguments: ["clear"]).command == .clear)
    #expect(try Options(arguments: ["stop"]).command == .stop)
    let options = try Options(arguments: ["prioritize", id.lowercased(), "--file", "/queue"])
    #expect(options.command == .prioritize)
    #expect(options.jobID == id)
    #expect(options.file == "/queue")
    #expect(try Options(arguments: ["run", "--", "/usr/bin/true"]).command == .run)
    for arguments in [
        ["prioritize"], ["prioritize", "not-an-id"], ["prioritize", id, id], ["list", "clear"],
        ["clear", "prioritize", id], ["prioritize", id, "--standalone"], ["prioritize", id, "--", "/usr/bin/true"],
        ["clear", "--timeout", "30"], ["list", "--shared"], ["stop", "clear"],
        ["stop", "--timeout", "30"], ["stop", "--standalone"], ["stop", "--", "/usr/bin/true"],
    ] { #expect(throws: LatchError.self) { try Options(arguments: arguments) } }
}

@Test func `operator priority changes only queued order and preserves evidence and retry identity`() throws {
    let f = try OperatorFixture()
    let running = try f.submit("running")
    let first = try f.submit("first")
    let second = try f.submit("second", measurement: true)
    let third = try f.submit("third")
    try f.scheduler.transaction { state in
        state.tasks[0].state = .running
        state.tasks[0].startedAt = Date()
        state.tasks[2].coolSince = 123
    }
    let before = try f.scheduler.snapshot()
    try f.queue.prioritize(second.id)
    let after = try f.scheduler.snapshot()
    #expect(after.tasks.map(\.id) == [running.id, second.id, first.id, third.id])
    #expect(after.tasks.first(where: { $0.id == second.id }) == before.tasks[2])
    #expect(after.jobs == before.jobs)
    #expect(try f.store.submit(second.submission).id == second.id)
    #expect(SchedulingPolicy.reason(for: after.tasks[1], in: after, now: 123) == "isolated task is running")
    try f.scheduler.transaction { state in state.tasks[0].state = .parked }
    let blocked = try f.scheduler.snapshot()
    #expect(SchedulingPolicy.reason(for: blocked.tasks[1], in: blocked, now: 123) == "waiting for fresh sensors")
    try f.queue.prioritize(second.id)
    #expect(try f.scheduler.snapshot().tasks.map(\.id) == after.tasks.map(\.id))
    #expect(throws: LatchError.self) { try f.queue.prioritize(running.id) }
    #expect(throws: LatchError.self) { try f.queue.prioritize(UUID().uuidString) }
    try f.store.cancel(first.id)
    #expect(throws: LatchError.self) { try f.queue.prioritize(first.id) }
}

@Test func `operator clear preserves started checkpoints running work and retained results`() throws {
    let f = try OperatorFixture()
    let running = try f.submit("running")
    let queued = try f.submit("queued")
    let waiting = try f.submit("waiting")
    let parked = try f.submit("parked")
    let completed = try f.submit("completed")
    try f.store.publish(completed.id, result: ["complete": true, "state": "completed", "succeeded": true])
    try f.scheduler.transaction { state in
        state.tasks[0].state = .running
        state.tasks[0].startedAt = Date()
        state.tasks[2].residentMemoryMiB = 100
        state.tasks[3].state = .parked
        state.tasks[3].residentMemoryMiB = 100
    }
    let before = try f.scheduler.snapshot()
    #expect(try f.queue.clear() == [queued.id])
    let after = try f.scheduler.snapshot()
    #expect(after.tasks.first(where: { $0.id == queued.id })?.state == .cancelling)
    for id in [running.id, waiting.id, parked.id] {
        #expect(after.tasks.first(where: { $0.id == id }) == before.tasks.first(where: { $0.id == id }))
        #expect(!FileManager.default.fileExists(atPath: f.store.file(id, "cancel").path))
    }
    #expect(FileManager.default.fileExists(atPath: f.store.file(queued.id, "cancel").path))
    #expect(try f.store.submit(queued.submission).id == queued.id)
    #expect(after.jobs == before.jobs)
    #expect(try f.queue.clear().isEmpty)
    #expect(SchedulingPolicy.reason(for: after.tasks[1], in: after, now: 0) == "queued task cancelled by operator")
    #expect(throws: LatchError.self) { try f.queue.prioritize(queued.id) }
}

@Test func `operator stop cancels all outstanding work and retains completed results`() throws {
    let f = try OperatorFixture()
    let running = try f.submit("running")
    let queued = try f.submit("queued")
    let parked = try f.submit("parked")
    let completed = try f.submit("completed")
    try f.store.publish(completed.id, result: ["complete": true, "state": "completed", "succeeded": true])
    try f.scheduler.transaction { state in
        state.tasks[0].state = .running
        state.tasks[0].startedAt = Date()
        state.tasks[2].state = .parked
        state.tasks[2].residentMemoryMiB = 100
    }
    let stop = try f.fixture.launch(["stop"])
    #expect(try f.fixture.finish(stop) == 0)
    #expect(stop.output.contains("3 outstanding job(s)"))
    for id in [running.id, queued.id, parked.id] {
        #expect(FileManager.default.fileExists(atPath: f.store.file(id, "cancel").path))
    }
    #expect(!FileManager.default.fileExists(atPath: f.store.file(completed.id, "cancel").path))
    #expect(try f.store.records().first { $0.id == completed.id }?.complete == true)
    #expect(try SchedulerService.status(in: f.scheduler.directory).running)
    let next = try f.submit("after-stop")
    #expect(!FileManager.default.fileExists(atPath: f.store.file(next.id, "cancel").path))
}

@Test(arguments: ["descendant", "orphan", "run-descendant", "run-orphan"], [false, true])
func `operator stop terminates scheduled CLI process groups including TERM resistant descendants`(
    mode: String, stopped: Bool
) throws {
    let f = try OperatorFixture()
    try withExtendedLifetime(f.service) {
        let marker = f.fixture.directory.appendingPathComponent("descendant-pid")
        let workload = f.fixture.executable.deletingLastPathComponent().appendingPathComponent("LatchTestWorkload")
        let isRun = mode.hasPrefix("run-")
        let workloadMode = isRun ? String(mode.dropFirst(4)) : mode
        let options = isRun ? ["run", "--shared"] : ["schedule", "--mode", "batch", "--cooldown", "0"]
        let child = try f.fixture.launch(options + ["--", workload.path, workloadMode, marker.path])
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !FileManager.default.fileExists(atPath: marker.path), ProcessInfo.processInfo.systemUptime < deadline {
            try f.publishSensors()
            Thread.sleep(forTimeInterval: 0.01)
        }
        let descendant = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        defer { _ = kill(descendant, SIGKILL) }
        if stopped {
            let supervisor = child.process.processIdentifier
            #expect(kill(supervisor, SIGSTOP) == 0)
            var info = proc_bsdinfo()
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while ProcessInfo.processInfo.systemUptime < deadline {
                _ = proc_pidinfo(supervisor, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
                if info.pbi_status == SSTOP { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(info.pbi_status == SSTOP)
        }
        let stop = try f.fixture.launch(["stop"])
        #expect(try f.fixture.finish(stop) == 0)
        #expect(
            try f.fixture.finish(child, timeout: .seconds(10)) == (workloadMode == "descendant" ? SIGKILL : SIGTERM))
        var info = proc_bsdinfo()
        #expect(
            proc_pidinfo(descendant, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == 0
                || info.pbi_status == SZOMB)
        #expect(try f.scheduler.snapshot().tasks.isEmpty)
        #expect(try SchedulerService.status(in: f.scheduler.directory).running)
    }
}

@Test func `scheduled CLI supervision preserves literal arguments streams cwd and exit status`() throws {
    let f = try OperatorFixture()
    try withExtendedLifetime(f.service) {
        let input = Pipe()
        let workload = f.fixture.executable.deletingLastPathComponent().appendingPathComponent("LatchTestWorkload")
        let arguments = ["a b", "", "--help", "$(must remain literal)"]
        let child = try f.fixture.launch(
            ["schedule", "--mode", "batch", "--cooldown", "0", "--", workload.path, "report"] + arguments,
            input: input)
        try input.fileHandleForWriting.write(contentsOf: Data("piped input".utf8))
        try input.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while child.process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            try f.publishSensors()
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(try f.fixture.finish(child) == 1)
        let report = try JSONDecoder().decode([String: [String]].self, from: Data(child.output.utf8))
        #expect(report["arguments"] == arguments)
        #expect(report["workingDirectory"] == [FileManager.default.currentDirectoryPath])
        #expect(child.errors == "separate stderr")
        #expect(try f.scheduler.snapshot().tasks.isEmpty)
    }
}

@Test(arguments: ["run", "schedule"], ["descendant", "orphan"])
func `operator stop reaches CLI workloads after their foreground supervisor is killed`(
    command: String, mode: String
) throws {
    let f = try OperatorFixture()
    defer { _ = try? f.queue.stop() }
    let marker = f.fixture.directory.appendingPathComponent("surviving-child")
    let workload = f.fixture.executable.deletingLastPathComponent().appendingPathComponent("LatchTestWorkload")
    let options = command == "run" ? ["run", "--shared"] : ["schedule", "--mode", "batch", "--cooldown", "0"]
    let child = try f.fixture.launch(options + ["--", workload.path, mode, marker.path])
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !FileManager.default.fileExists(atPath: marker.path), ProcessInfo.processInfo.systemUptime < deadline {
        try f.publishSensors()
        Thread.sleep(forTimeInterval: 0.01)
    }
    let descendant = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
    defer { _ = kill(descendant, SIGKILL) }
    #expect(kill(child.process.processIdentifier, SIGKILL) == 0)
    #expect(try f.fixture.finish(child) == SIGKILL)
    #expect(try f.scheduler.snapshot().tasks.count == 1)
    let gate = try FileLatch(path: f.fixture.lockPath)
    #expect(throws: LatchError.self) { try gate.acquire(shared: false, timeout: 0) }
    #expect(try f.queue.stop().count == 1)
    let releasedBy = ProcessInfo.processInfo.systemUptime + 6
    while try !f.scheduler.snapshot().tasks.isEmpty, ProcessInfo.processInfo.systemUptime < releasedBy {
        Thread.sleep(forTimeInterval: 0.01)
    }
    var info = proc_bsdinfo()
    #expect(
        proc_pidinfo(descendant, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == 0
            || info.pbi_status == SZOMB)
    #expect(try f.scheduler.snapshot().tasks.isEmpty)
    try gate.acquire(shared: false, timeout: 0)
    #expect(try SchedulerService.status(in: f.scheduler.directory).running)
}

@Test func `operator list excludes completed results and escapes job names`() throws {
    let f = try OperatorFixture()
    #expect(try f.queue.list() == "No outstanding jobs.")
    let a = try f.submit("build\n\u{1B}[31m")
    let b = try f.submit("benchmark")
    let done = try f.submit("done")
    try f.store.publish(done.id, result: ["complete": true, "state": "completed"])
    let listing = try f.fixture.launch(["list"])
    #expect(try f.fixture.finish(listing) == 0)
    let text = listing.output
    #expect(text.contains(a.id))
    #expect(text.contains(b.id))
    #expect(text.contains("queued"))
    #expect(text.contains("\\n\\u{1b}[31m"))
    #expect(!text.contains(done.id))
    #expect(!text.contains("\u{1B}"))
    #expect(text.split(separator: "\n").count == 3)
    let run = try f.fixture.launch(["prioritize", b.id])
    #expect(try f.fixture.finish(run) == 0)
    #expect(try f.scheduler.snapshot().tasks.first?.id == b.id)
    let clear = try f.fixture.launch(["clear"])
    #expect(try f.fixture.finish(clear) == 0)
    #expect(clear.output.contains("2 queued job(s)"))
}

@Test func `CLI work completes and releases its reservation after the foreground supervisor dies`() throws {
    let f = try OperatorFixture()
    let input = Pipe()
    defer {
        try? input.fileHandleForWriting.close()
        _ = try? f.queue.stop()
    }
    let marker = f.fixture.directory.appendingPathComponent("foreground-output")
    let child = try f.fixture.launch(["run", "--shared", "--", "/usr/bin/tee", marker.path], input: input)
    try input.fileHandleForWriting.write(contentsOf: Data("started".utf8))
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while (try? String(contentsOf: marker, encoding: .utf8)) != "started",
        ProcessInfo.processInfo.systemUptime < deadline
    {
        try f.publishSensors()
        Thread.sleep(forTimeInterval: 0.01)
    }
    try #require(try String(contentsOf: marker, encoding: .utf8) == "started")
    #expect(kill(child.process.processIdentifier, SIGKILL) == 0)
    #expect(try f.fixture.finish(child) == SIGKILL)
    #expect(try f.scheduler.snapshot().tasks.count == 1)
    try input.fileHandleForWriting.close()
    let releasedBy = ProcessInfo.processInfo.systemUptime + 5
    while try !f.scheduler.snapshot().tasks.isEmpty, ProcessInfo.processInfo.systemUptime < releasedBy {
        Thread.sleep(forTimeInterval: 0.01)
    }
    #expect(try f.scheduler.snapshot().tasks.isEmpty)
    let gate = try FileLatch(path: f.fixture.lockPath)
    try gate.acquire(shared: false, timeout: 0)
}

@Test(arguments: [false, true], ["clear", "stop"])
func `operator cancellation wakes queued CLI clients without starting their commands`(
    standalone: Bool, operation: String
) throws {
    let f = try OperatorFixture()
    let gate = try FileLatch(path: f.fixture.lockPath)
    try gate.acquire(shared: false, timeout: 0)
    try withExtendedLifetime((f.service, gate)) {
        let marker = f.fixture.directory.appendingPathComponent("must-not-run")
        let child = try f.fixture.launch(
            ["schedule"] + (standalone ? ["--standalone"] : []) + ["--", "/usr/bin/touch", marker.path])
        let run = try f.fixture.launch(["run", "--", "/usr/bin/touch", marker.path])
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while try f.scheduler.snapshot().tasks.count < 2, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let cancel = try f.fixture.launch([operation])
        #expect(try f.fixture.finish(cancel) == 0)
        #expect(try f.fixture.finish(child) == 75)
        #expect(try f.fixture.finish(run) == 75)
        #expect(child.errors.contains("cancelled by operator"))
        #expect(run.errors.contains("cancelled by operator"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try f.scheduler.snapshot().tasks.isEmpty)
    }
}

@Test func `operator mutations reject malformed running service metadata`() throws {
    let f = try OperatorFixture()
    let record = try f.submit()
    try JSONEncoder().encode(
        SchedulerService.Status(running: true, pid: getpid(), path: f.fixture.lockPath, serviceRevision: 0)
    ).write(
        to: f.scheduler.directory.appendingPathComponent("service.json"))
    try withExtendedLifetime(f.service) {
        #expect(throws: LatchError.self) { try f.queue.prioritize(record.id) }
        #expect(throws: LatchError.self) { try f.queue.clear() }
        #expect(throws: LatchError.self) { try f.queue.stop() }
        let state = try f.scheduler.snapshot()
        #expect(state.tasks.first?.state == .queued)
    }
}

@Test func `operator mutations require a running service while listing works offline`() throws {
    let f = try OperatorFixture()
    let record = try f.submit()
    f.service.release()
    #expect(throws: LatchError.self) { try f.queue.prioritize(record.id) }
    #expect(throws: LatchError.self) { try f.queue.clear() }
    #expect(throws: LatchError.self) { try f.queue.stop() }
    #expect(try f.queue.list().contains(record.id))
    #expect(try f.scheduler.snapshot().tasks.first?.state == .queued)
}

@Test func `clear persists cancellation of tickets whose supervisors have not launched`() throws {
    let f = try OperatorFixture()
    let record = try f.submit()
    #expect(try f.queue.clear() == [record.id])
    try f.store.launch(record.id, executable: f.fixture.executable)
    let job = MCPJob(record: record, store: f.store)
    let deadline = ProcessInfo.processInfo.systemUptime + 4
    while !job.complete, ProcessInfo.processInfo.systemUptime < deadline {
        try job.update(now: ProcessInfo.processInfo.systemUptime)
        Thread.sleep(forTimeInterval: 0.01)
    }
    let result = try job.result(includeOutput: true)
    #expect(result["complete"] == true)
    #expect(result["state"] == "cancelled")
    #expect(result["phase"] == "admission")
    #expect(try f.scheduler.snapshot().tasks.isEmpty)
    #expect(try f.store.submit(record.submission).id == record.id)
}
