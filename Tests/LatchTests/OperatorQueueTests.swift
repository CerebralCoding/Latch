import Darwin
import Foundation
import Testing

@testable import Latch

private final class OperatorFixture {
    let fixture: Fixture
    let scheduler: Scheduler
    let store: DurableJobs
    let service: FileLatch
    var queue: OperatorQueue { OperatorQueue(scheduler: scheduler) }

    init() throws {
        fixture = try Fixture()
        scheduler = try Scheduler(path: fixture.lockPath)
        store = try DurableJobs(scheduler: scheduler)
        service = try FileLatch(path: scheduler.directory.appendingPathComponent("service.lock").path)
        try service.acquire(shared: false, timeout: 0)
        let status = SchedulerService.Status(
            running: true, pid: getpid(), path: fixture.lockPath,
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
}

@Test func `operator flags have distinct strict contracts from command execution`() throws {
    let id = UUID().uuidString
    #expect(try Options(arguments: ["--list"]).command == .list)
    #expect(try Options(arguments: ["--clear"]).command == .clear)
    let options = try Options(arguments: ["--run", id.lowercased(), "--file", "/queue"])
    #expect(options.command == .prioritize)
    #expect(options.jobID == id)
    #expect(options.file == "/queue")
    #expect(try Options(arguments: ["run", "--", "/usr/bin/true"]).command == .run)
    for arguments in [
        ["--run"], ["--run", "not-an-id"], ["--run", id, id], ["--list", "--clear"],
        ["--clear", "--run", id], ["--run", id, "--standalone"], ["--run", id, "--", "/usr/bin/true"],
        ["--clear", "--timeout", "30"], ["--list", "--shared"],
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

@Test func `operator list excludes completed results and escapes job names`() throws {
    let f = try OperatorFixture()
    #expect(try f.queue.list() == "No outstanding jobs.")
    let a = try f.submit("build\n\u{1B}[31m")
    let b = try f.submit("benchmark")
    let done = try f.submit("done")
    try f.store.publish(done.id, result: ["complete": true, "state": "completed"])
    let listing = try f.fixture.launch(["--list"])
    #expect(try f.fixture.finish(listing) == 0)
    let text = listing.output
    #expect(text.contains(a.id))
    #expect(text.contains(b.id))
    #expect(text.contains("queued"))
    #expect(text.contains("\\n\\u{1b}[31m"))
    #expect(!text.contains(done.id))
    #expect(!text.contains("\u{1B}"))
    #expect(text.split(separator: "\n").count == 3)
    let run = try f.fixture.launch(["--run", b.id])
    #expect(try f.fixture.finish(run) == 0)
    #expect(try f.scheduler.snapshot().tasks.first?.id == b.id)
    let clear = try f.fixture.launch(["--clear"])
    #expect(try f.fixture.finish(clear) == 0)
    #expect(clear.output.contains("2 queued job(s)"))
}

@Test(arguments: [false, true])
func `operator clear wakes queued CLI clients without starting their commands`(standalone: Bool) throws {
    let f = try OperatorFixture()
    let gate = try FileLatch(path: f.fixture.lockPath)
    try gate.acquire(shared: false, timeout: 0)
    try withExtendedLifetime((f.service, gate)) {
        let marker = f.fixture.directory.appendingPathComponent("must-not-run")
        let child = try f.fixture.launch(
            ["schedule"] + (standalone ? ["--standalone"] : []) + ["--", "/usr/bin/touch", marker.path])
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while try f.scheduler.snapshot().tasks.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(try f.queue.clear().count == 1)
        #expect(try f.fixture.finish(child) == 75)
        #expect(child.errors.contains("cancelled by operator"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try f.scheduler.snapshot().tasks.isEmpty)
    }
}

@Test func `operator mutations reject a service with an uncertain revision`() throws {
    let f = try OperatorFixture()
    let record = try f.submit()
    try JSONEncoder().encode(SchedulerService.Status(running: true, pid: getpid(), path: f.fixture.lockPath)).write(
        to: f.scheduler.directory.appendingPathComponent("service.json"))
    try withExtendedLifetime(f.service) {
        #expect(throws: LatchError.self) { try f.queue.prioritize(record.id) }
        #expect(throws: LatchError.self) { try f.queue.clear() }
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
