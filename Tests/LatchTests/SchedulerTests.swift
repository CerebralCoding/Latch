import Darwin
import Foundation
@testable import Latch
import Testing

private func idleSensors(at uptime: Double = ProcessInfo.processInfo.systemUptime) -> SensorSnapshot {
    SensorSnapshot(
        sampledAt: Date(), uptime: uptime, cpuCores: 8, cpuActive: 0, busiestCore: 0,
        gpuActive: 0, aneWatts: 0, memoryAvailableMiB: 24000, memoryTotalMiB: 32000,
        memoryPressure: "normal", thermalState: "nominal", diskBytesPerSecond: 0, unavailable: [],
    )
}

private func task(_ mode: TaskRequirements.Mode = .batch, cores: Int = 1, gpu: Bool = false) -> ScheduledTask {
    ScheduledTask(id: UUID().uuidString, name: "test", pid: getpid(), arguments: ["true"],
                  requirements: TaskRequirements(mode: mode, cpuCores: cores, gpu: gpu))
}

@Test func `scheduler options preserve command and validate resources`() throws {
    let options = try Options(arguments: ["schedule", "--name", "inference", "--mode", "batch", "--gpu", "--bandwidth", "--cpu", "2", "--memory-mib", "4096", "--", "model", "--gpu"])
    #expect(options.taskName == "inference")
    #expect(options.requirements == TaskRequirements(mode: .batch, cpuCores: 2, memoryMiB: 4096, gpu: true, bandwidth: true, temperatureGuard: TemperatureGuard()))
    #expect(options.childArguments == ["model", "--gpu"])
    #expect(try Options(arguments: ["schedule", "--", "true"]).requirements.mode == .isolated)
}

@Test(arguments: [
    ["schedule", "--cpu", "0", "--", "true"],
    ["schedule", "--memory-mib", "-1", "--", "true"],
    ["schedule", "--mode", "anything", "--", "true"],
    ["schedule", "--gpu", "--gpu", "--", "true"],
    ["run", "--gpu", "--", "true"], ["tasks", "--timeout", "1"],
    ["sensors", "--file", "ignored"], ["schedule", "--name", "", "--", "true"],
])
func `rejects invalid scheduler options`(arguments: [String]) {
    #expect(throws: LatchError.self) { try Options(arguments: arguments) }
}

@Test func `compatible batch fits but reservations cannot overcommit`() {
    var first = task(cores: 4)
    first.state = .running
    var next = task(cores: 4)
    var state = SchedulerState(tasks: [first, next], sensors: idleSensors(at: 10))
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 10) == nil)
    next.requirements.cpuCores = 5
    state.tasks[1] = next
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 10) == "CPU reservation capacity")
    next.requirements.cpuCores = 1
    next.requirements.memoryMiB = 21000
    state.tasks[1] = next
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 10) == "insufficient memory headroom")
}

@Test func `oldest measurement prevents new batch work overtaking`() {
    var running = task()
    running.state = .running
    let measurement = task(.isolated)
    let newcomer = task()
    var state = SchedulerState(tasks: [running, measurement, newcomer], sensors: idleSensors(at: 10), quietSince: 7)
    #expect(SchedulingPolicy.reason(for: measurement, in: state, now: 10) == "waiting for running tasks to drain")
    #expect(SchedulingPolicy.reason(for: newcomer, in: state, now: 10) == "waiting for earlier queued tasks")
    state.tasks.removeFirst()
    #expect(SchedulingPolicy.reason(for: measurement, in: state, now: 10) == nil)
    state.tasks[0].state = .running
    #expect(SchedulingPolicy.reason(for: newcomer, in: state, now: 10) == "isolated task is running")
}

@Test func `gpu IO and bandwidth reservations conflict`() {
    for resource in [\TaskRequirements.gpu, \.io, \.bandwidth] {
        var running = task()
        running.state = .running
        running.requirements[keyPath: resource] = true
        var next = task()
        next.requirements[keyPath: resource] = true
        let state = SchedulerState(tasks: [running, next], sensors: idleSensors(at: 10))
        #expect(SchedulingPolicy.reason(for: next, in: state, now: 10) != nil)
    }
}

@Test func `sensors block busy hot pressured and stale admission`() {
    let next = task(cores: 4, gpu: true)
    let base = SchedulerState(tasks: [next], sensors: idleSensors(at: 10))
    #expect(SchedulingPolicy.reason(for: next, in: base, now: 10) == nil)
    var state = base
    state.sensors?.cpuActive = 0.7
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 10) == "insufficient CPU headroom")
    state = base
    state.sensors?.memoryPressure = "warning"
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 10) == "memory pressure is warning")
    state = base
    state.sensors?.thermalState = "serious"
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 10) == "thermal state is serious")
    state = base
    state.sensors?.gpuActive = nil
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 10) == "GPU is busy or unavailable")
    #expect(SchedulingPolicy.reason(for: next, in: base, now: 13) == "waiting for fresh sensors")
    #expect(SchedulingPolicy.reason(for: next, in: base, now: 9) == "waiting for fresh sensors")
}

@Test func `isolation requires continuous recent quiet samples`() {
    let measurement = task(.isolated)
    var state = SchedulerState(tasks: [measurement])
    state.record(idleSensors(at: 10))
    #expect(SchedulingPolicy.reason(for: measurement, in: state, now: 10) != nil)
    state.record(idleSensors(at: 11))
    state.record(idleSensors(at: 12))
    #expect(SchedulingPolicy.reason(for: measurement, in: state, now: 12) == nil)
    var busy = idleSensors(at: 13)
    busy.busiestCore = 0.9
    state.record(busy)
    #expect(state.quietSince == nil)
    state.record(idleSensors(at: 14))
    state.record(idleSensors(at: 18))
    #expect(state.quietSince == 18)
    var missing = idleSensors(at: 19)
    missing.aneWatts = nil
    missing.unavailable = ["ANE power"]
    state.record(missing)
    #expect(SchedulingPolicy.reason(for: measurement, in: state, now: 19) == "required sensors unavailable: ANE power")
}

@Test func `reservations remain visible until their leases close`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath, collect: { idleSensors() })
    var first: TaskReservation? = try scheduler.reserve(name: "cpu", arguments: ["true"], requirements: TaskRequirements(mode: .batch, cpuCores: 2), timeout: 0)
    let second = try scheduler.reserve(name: "gpu", arguments: ["true"], requirements: TaskRequirements(mode: .batch, gpu: true), timeout: 0)
    try withExtendedLifetime(second) {
        #expect(try scheduler.snapshot().tasks.count == 2)
        withExtendedLifetime(first) {}
        first = nil
        let state = try scheduler.snapshot()
        #expect(state.tasks.count == 1)
        #expect(state.tasks.first?.name == "gpu")
        #expect(throws: LatchError.self) {
            try scheduler.reserve(name: "another GPU", arguments: ["true"], requirements: TaskRequirements(mode: .batch, gpu: true), timeout: 0)
        }
        #expect(try scheduler.snapshot().tasks.count == 1)
    }
}

@Test func `scheduler does not sample behind an exclusive latch`() throws {
    let fixture = try Fixture()
    var collections = 0
    let scheduler = try Scheduler(path: fixture.lockPath) {
        collections += 1
        return idleSensors()
    }
    let holder = try FileLatch(path: fixture.lockPath)
    try holder.acquire(shared: false, timeout: 0)
    try withExtendedLifetime(holder) {
        let sampled = try scheduler.refreshSensors()
        #expect(!sampled)
        #expect(throws: LatchError.self) {
            try scheduler.reserve(name: "waiting", arguments: ["true"], requirements: TaskRequirements(), timeout: 0.05)
        }
        #expect(collections == 0)
        let remaining = try scheduler.snapshot()
        #expect(remaining.tasks.isEmpty)
    }
}

@Test func `quiet measurement acquires exclusive reservation`() throws {
    let fixture = try Fixture()
    var collections = 0
    let scheduler = try Scheduler(path: fixture.lockPath) {
        collections += 1
        return idleSensors()
    }
    let now = ProcessInfo.processInfo.systemUptime
    try scheduler.transaction {
        $0.record(idleSensors(at: now))
        $0.quietSince = now - 3
    }
    let reservation = try scheduler.reserve(name: "measurement", arguments: ["true"], requirements: TaskRequirements(), timeout: 0)
    try withExtendedLifetime(reservation) {
        let state = try scheduler.snapshot()
        #expect(state.tasks.first?.state == .running)
        #expect(state.tasks.first?.requirements.mode == .isolated)
        #expect(state.quietSince == nil)
        #expect(collections == 0)
        #expect(throws: LatchError.self) {
            try scheduler.reserve(name: "batch", arguments: ["true"], requirements: TaskRequirements(mode: .batch), timeout: 0)
        }
        let legacy = try FileLatch(path: fixture.lockPath)
        #expect(throws: LatchError.self) { try legacy.acquire(shared: true, timeout: 0) }
    }
}

@Test func `legacy shared latch blocks an otherwise eligible measurement`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath, collect: { idleSensors() })
    let now = ProcessInfo.processInfo.systemUptime
    try scheduler.transaction {
        $0.record(idleSensors(at: now))
        $0.quietSince = now - 3
    }
    let holder = try FileLatch(path: fixture.lockPath)
    try holder.acquire(shared: true, timeout: 0)
    try withExtendedLifetime(holder) {
        #expect(throws: LatchError.self) {
            try scheduler.reserve(name: "measurement", arguments: ["true"], requirements: TaskRequirements(), timeout: 0.05)
        }
        let remaining = try scheduler.snapshot()
        #expect(remaining.tasks.isEmpty)
    }
}

@Test func `failed sensors are visible and fail closed`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath) { throw LatchError("sensor failure") }
    #expect(throws: LatchError.self) {
        try scheduler.reserve(name: "blocked", arguments: ["true"], requirements: TaskRequirements(mode: .batch), timeout: 0)
    }
    let state = try scheduler.snapshot()
    #expect(state.sensorError == "sensor failure")
    #expect(state.tasks.isEmpty)
}

@Test func `damaged scheduler state is not silently reset`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath, collect: { idleSensors() })
    let file = scheduler.directory.appendingPathComponent("state.json")
    try Data("invalid".utf8).write(to: file)
    #expect(throws: (any Error).self) { try scheduler.snapshot() }
    #expect(try String(contentsOf: file, encoding: .utf8) == "invalid")
}

@Test func `killed queued process is pruned and tasks are JSON`() throws {
    let fixture = try Fixture()
    let holder = try FileLatch(path: fixture.lockPath)
    try holder.acquire(shared: false, timeout: 0)
    try withExtendedLifetime(holder) {
        let child = try fixture.launch(["schedule", "--standalone", "--name", "parked-agent", "--", "/usr/bin/true"])
        let scheduler = try Scheduler(path: fixture.lockPath, collect: { idleSensors() })
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try scheduler.snapshot().tasks.isEmpty, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(try scheduler.snapshot().tasks.first?.name == "parked-agent")
        let inspection = try fixture.launch(["tasks"])
        #expect(try fixture.finish(inspection) == 0)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(SchedulerState.self, from: Data(inspection.output.utf8))
        #expect(state.tasks.first?.state == .queued)
        #expect(kill(child.process.processIdentifier, SIGKILL) == 0)
        #expect(try fixture.finish(child) == SIGKILL)
        #expect(try scheduler.snapshot().tasks.isEmpty)
    }
}
