import Foundation
import Testing

@testable import Latch

/// 24,000 of 32,000 MiB free leaves 20,800 MiB of headroom after the 10% reserve.
func stallSensors(
    at uptime: Double = ProcessInfo.processInfo.systemUptime, available: Int = 24000, total: Int = 32000,
    cpuTemperature: Double? = 40, cores: Int = 8
) -> SensorSnapshot {
    SensorSnapshot(
        sampledAt: Date(), uptime: uptime, cpuCores: cores, cpuActive: 0, busiestCore: 0,
        gpuActive: 0, aneWatts: 0, memoryAvailableMiB: available, memoryTotalMiB: total,
        memoryPressure: "normal", thermalState: "nominal", diskBytesPerSecond: 0, unavailable: [],
        cpuTemperature: cpuTemperature, gpuTemperature: 40)
}

/// A scheduler whose capacity is the totals of the sensors it samples, as admission sees them, so no test depends
/// on the machine running it.
func stallScheduler(path: String, cpuTemperature: Double? = 40) throws -> Scheduler {
    try Scheduler(
        path: path, capacity: MachineCapacity(sensors: stallSensors()),
        collect: { stallSensors(cpuTemperature: cpuTemperature) })
}

/// Keeps fresh readings in a queue for work whose admission runs in other processes.
final class SensorFeeder: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true

    init(path: String, available: Int, total: Int, cores: Int) {
        let thread = Thread { [self] in
            guard let scheduler = try? Scheduler(path: path) else { return }
            while isRunning {
                try? scheduler.transaction {
                    $0.record(stallSensors(available: available, total: total, cores: cores))
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        thread.start()
    }

    private var isRunning: Bool { lock.withLock { running } }

    func stop() { lock.withLock { running = false } }
}

private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32?
    private var text: String?
    let finished = DispatchSemaphore(value: 0)

    func finish(code: Int32, text: String) {
        lock.withLock {
            self.code = code
            self.text = text
        }
        finished.signal()
    }

    var exitCode: Int32? { lock.withLock { code } }
    var message: String? { lock.withLock { text } }
}

private func task(memoryMiB: Int, mode: TaskRequirements.Mode = .batch) -> ScheduledTask {
    ScheduledTask(
        id: UUID().uuidString, name: "stalled", pid: getpid(), arguments: ["true"],
        requirements: TaskRequirements(mode: mode, memoryMiB: memoryMiB))
}

private func serviceStatus() -> SchedulerService.Status {
    SchedulerService.Status(running: true, pid: 1, path: "/tmp/latch", serviceRevision: 1)
}

// MARK: Capacity refusal

@Test func `memory above what admission could ever grant is refused as over capacity`() {
    let total = 262_144
    let ceiling = total - total / 10
    #expect(throws: Never.self) {
        try TaskRequirements(memoryMiB: ceiling).validate(capacity: MachineCapacity(cpuCores: 32, memoryMiB: total))
    }
    #expect {
        try TaskRequirements(memoryMiB: ceiling + 1).validate(capacity: MachineCapacity(cpuCores: 32, memoryMiB: total))
    } throws: { error in
        guard let error = error as? LatchError else { return false }
        return error.exitCode == 64 && error.admissionReason == "capacity"
            && error.description.hasPrefix("capacity: ")
            && error.description.contains("--memory-mib \(ceiling + 1)")
            && error.description.contains("\(ceiling) MiB") && error.description.contains("\(total) MiB")
            && error.description.contains("10% reserve")
    }
}

@Test func `cores above the machine are refused as over capacity`() {
    #expect(throws: Never.self) {
        try TaskRequirements(cpuCores: 32).validate(capacity: MachineCapacity(cpuCores: 32, memoryMiB: 262_144))
    }
    #expect {
        try TaskRequirements(cpuCores: 33).validate(capacity: MachineCapacity(cpuCores: 32, memoryMiB: 262_144))
    } throws: { error in
        guard let error = error as? LatchError else { return false }
        return error.exitCode == 64 && error.admissionReason == "capacity"
            && error.description.contains("--cpu 33") && error.description.contains("32")
    }
}

@Test func `non-positive requests stay usage errors`() {
    for requirements in [TaskRequirements(cpuCores: 0), TaskRequirements(memoryMiB: 0)] {
        #expect {
            try requirements.validate(capacity: MachineCapacity(cpuCores: 32, memoryMiB: 262_144))
        } throws: { error in (error as? LatchError)?.exitCode == 64 }
    }
}

@Test func `the CLI refuses a memory request between the reserve and physical memory before queueing`() throws {
    let physical = MachineCapacity.machine.memoryMiB
    #expect {
        try Options(arguments: ["schedule", "--memory-mib", String(physical), "--", "true"])
    } throws: { error in
        (error as? LatchError)?.exitCode == 64
    }
    let fixture = try Fixture()
    let child = try fixture.launch(["schedule", "--standalone", "--memory-mib", String(physical), "--", "true"])
    #expect(try fixture.finish(child) == 64)
    #expect(child.errors.contains("capacity:"))
    #expect(try Scheduler(path: fixture.lockPath).snapshot().tasks.isEmpty)
}

@Test func `the unsatisfiable exit is distinct from usage and busy`() {
    #expect(![0, 64, 69, 71, 74, 75, 126, 127].contains(LatchError.unsatisfiableExitCode))
    #expect(LatchError("x", exitCode: 75).admissionReason == nil)
}

@Test func `a scheduler validates against the capacity it admits against, not the host's`() throws {
    let fixture = try Fixture()
    let scheduler = try stallScheduler(path: fixture.lockPath)
    // stallSensors() describes 8 cores and 32000 MiB, so 28800 MiB is the most it can ever grant.
    let grantable = SchedulingPolicy.grantableMemoryMiB(total: 32000)
    #expect(scheduler.capacity == MachineCapacity(cpuCores: 8, memoryMiB: 32000))
    #expect {
        try scheduler.reserve(
            name: "too big", arguments: ["true"],
            requirements: TaskRequirements(mode: .batch, memoryMiB: grantable + 1), timeout: 0)
    } throws: { error in
        (error as? LatchError)?.admissionReason == "capacity"
    }
    #expect(try scheduler.snapshot().tasks.isEmpty)
    #expect {
        try scheduler.reserve(
            name: "fits capacity", arguments: ["true"],
            requirements: TaskRequirements(mode: .batch, cpuCores: 8, memoryMiB: grantable), timeout: 0)
    } throws: { error in
        (error as? LatchError)?.admissionReason != "capacity"
    }
}

// MARK: --stall-timeout

@Test func `stall timeout is an optional per job requirement`() throws {
    #expect(try Options(arguments: ["schedule", "--", "true"]).requirements.stallTimeout == nil)
    #expect(
        try Options(arguments: ["schedule", "--stall-timeout", "30", "--", "true"]).requirements.stallTimeout == 30)
    #expect(try Options(arguments: ["schedule", "--stall-timeout=0", "--", "true"]).requirements.stallTimeout == 0)
    #expect(try Options(arguments: ["run", "--stall-timeout", "5", "--", "true"]).requirements.stallTimeout == 5)
    #expect(try Options(arguments: ["guard", "--stall-timeout", "5"]).requirements.stallTimeout == 5)
}

@Test(arguments: [
    ["schedule", "--stall-timeout", "-1", "--", "true"], ["schedule", "--stall-timeout", "nan", "--", "true"],
    ["schedule", "--stall-timeout", "soon", "--", "true"],
    ["schedule", "--stall-timeout", "1", "--stall-timeout", "2", "--", "true"], ["list", "--stall-timeout", "1"],
    ["schedule", "--stall-timeout"],
])
func `rejects an invalid stall timeout`(arguments: [String]) {
    #expect(throws: LatchError.self) { try Options(arguments: arguments) }
}

// MARK: The stall predicate

@Test func `a head job that needs more memory than is free while nothing runs is stalled`() throws {
    let head = task(memoryMiB: 21000)
    let state = SchedulerState(tasks: [head], sensors: stallSensors(at: 10))
    let stall = try #require(SchedulingPolicy.stall(for: head, in: state, now: 10))
    #expect(stall == AdmissionStall(kind: .memory, neededMiB: 21000, headroomMiB: 20800))
    #expect(SchedulingPolicy.stall(for: task(memoryMiB: 20800), in: state, now: 10) == nil)
}

@Test func `memory a Latch job holds can be released so the shortfall is not a stall`() {
    let head = task(memoryMiB: 21000)
    for held in [ScheduledTask.State.running, .parked, .cancelling] {
        var holder = task(memoryMiB: 1)
        holder.state = held
        let state = SchedulerState(tasks: [holder, head], sensors: stallSensors(at: 10))
        #expect(SchedulingPolicy.stall(for: head, in: state, now: 10) == nil, "\(held)")
    }
    var waiting = task(memoryMiB: 1)
    waiting.residentMemoryMiB = 4000
    let state = SchedulerState(tasks: [waiting, head], sensors: stallSensors(at: 10))
    #expect(SchedulingPolicy.stall(for: head, in: state, now: 10) == nil)
}

@Test func `only the FIFO head can be stalled`() {
    let first = task(memoryMiB: 1000)
    let second = task(memoryMiB: 21000)
    let state = SchedulerState(tasks: [first, second], sensors: stallSensors(at: 10))
    #expect(SchedulingPolicy.stall(for: second, in: state, now: 10) == nil)
}

@Test func `a resumed job counts only the memory it does not already hold`() {
    var resumed = task(memoryMiB: 21000)
    resumed.residentMemoryMiB = 21000
    let state = SchedulerState(tasks: [resumed], sensors: stallSensors(at: 10))
    #expect(SchedulingPolicy.stall(for: resumed, in: state, now: 10) == nil)
}

@Test func `stale or missing sensors never produce a stall`() {
    let head = task(memoryMiB: 21000)
    #expect(SchedulingPolicy.stall(for: head, in: SchedulerState(tasks: [head]), now: 10) == nil)
    let state = SchedulerState(tasks: [head], sensors: stallSensors(at: 10))
    #expect(SchedulingPolicy.stall(for: head, in: state, now: 13) == nil)
    var failed = state
    failed.sensorError = "sensor failure"
    #expect(SchedulingPolicy.stall(for: head, in: failed, now: 10) == nil)
}

@Test func `a thermal wait is not a stall and does not hide one`() {
    let head = task(memoryMiB: 1000)
    var hot = SchedulerState(tasks: [head], sensors: stallSensors(at: 10))
    hot.sensors?.thermalState = "serious"
    #expect(SchedulingPolicy.stall(for: head, in: hot, now: 10) == nil)
    var short = task(memoryMiB: 21000)
    short.requirements.temperatureGuard = TemperatureGuard(maxCPU: 50, maxGPU: 50, cooldown: 0)
    let state = SchedulerState(tasks: [short], sensors: stallSensors(at: 10, cpuTemperature: 70))
    #expect(SchedulingPolicy.stall(for: short, in: state, now: 10)?.kind == .memory)
}

// MARK: Ending a stalled job

@Test func `a stalled head job ends as unsatisfiable and the next job is admitted`() throws {
    let fixture = try Fixture()
    let path = fixture.lockPath
    let outcome = Outcome()
    // Create the queue directory before the second scheduler opens it; two first openings can race.
    let observer = try stallScheduler(path: path)
    let thread = Thread {
        do {
            let scheduler = try stallScheduler(path: path)
            _ = try scheduler.reserve(
                name: "stalled", arguments: ["true"],
                requirements: TaskRequirements(mode: .batch, memoryMiB: 21000, stallTimeout: 0.4), timeout: nil)
            outcome.finish(code: 0, text: "admitted")
        } catch let error as LatchError {
            outcome.finish(code: error.exitCode, text: error.description)
        } catch {
            outcome.finish(code: -1, text: String(describing: error))
        }
    }
    thread.start()
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while try observer.snapshot().tasks.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    #expect(try !observer.snapshot().tasks.isEmpty, "the stalled job never reached the queue")
    let next = try observer.reserve(
        name: "next", arguments: ["true"], requirements: TaskRequirements(mode: .batch, memoryMiB: 512), timeout: 10)
    // FIFO: the next job cannot start until the stalled head is out of the queue.
    let queued = try observer.snapshot().tasks.map(\.name)
    #expect(outcome.finished.wait(timeout: .now() + 5) == .success)
    withExtendedLifetime(next) {
        #expect(outcome.exitCode == LatchError.unsatisfiableExitCode, "\(outcome.message ?? "no outcome")")
        let message = outcome.message ?? ""
        #expect(message.hasPrefix("unsatisfiable: "))
        #expect(message.contains("20.5 GiB") && message.contains("20.3 GiB"))
        #expect(queued == ["next"])
    }
}

@Test func `a thermal wait outlasting the stall timeout times out as busy and not unsatisfiable`() throws {
    let fixture = try Fixture()
    let scheduler = try stallScheduler(path: fixture.lockPath, cpuTemperature: 70)
    let requirements = TaskRequirements(
        mode: .batch, memoryMiB: 1000, temperatureGuard: TemperatureGuard(maxCPU: 50, maxGPU: 50, cooldown: 0),
        stallTimeout: 0.2)
    #expect {
        try scheduler.reserve(name: "hot", arguments: ["true"], requirements: requirements, timeout: 1.2)
    } throws: { error in
        guard let error = error as? LatchError else { return false }
        return error.exitCode == 75 && error.description.hasPrefix("timeout: ") && error.admissionReason == nil
    }
}

@Test func `a shortfall behind memory a Latch job holds waits instead of ending`() throws {
    let fixture = try Fixture()
    let scheduler = try stallScheduler(path: fixture.lockPath)
    let holder = try scheduler.reserve(
        name: "holder", arguments: ["true"], requirements: TaskRequirements(mode: .batch, memoryMiB: 15000),
        timeout: 0)
    withExtendedLifetime(holder) {
        let requirements = TaskRequirements(mode: .batch, memoryMiB: 8000, stallTimeout: 0.2)
        #expect {
            try scheduler.reserve(name: "waits", arguments: ["true"], requirements: requirements, timeout: 1.2)
        } throws: { error in (error as? LatchError)?.exitCode == 75 }
    }
}

@Test func `a stall timeout of zero waits as before`() throws {
    let fixture = try Fixture()
    let scheduler = try stallScheduler(path: fixture.lockPath)
    let requirements = TaskRequirements(mode: .batch, memoryMiB: 21000, stallTimeout: 0)
    #expect {
        try scheduler.reserve(name: "patient", arguments: ["true"], requirements: requirements, timeout: 1.2)
    } throws: { error in (error as? LatchError)?.exitCode == 75 }
}

@Test func `the stall clock starts once and clears when the shortfall does`() throws {
    let fixture = try Fixture()
    let scheduler = try stallScheduler(path: fixture.lockPath)
    #expect {
        try scheduler.reserve(
            name: "waits", arguments: ["true"],
            requirements: TaskRequirements(mode: .batch, memoryMiB: 21000, stallTimeout: 0), timeout: 0.3)
    } throws: { error in (error as? LatchError)?.exitCode == 75 }
    // The timed-out job withdrew itself; a job that fits never carries a stall clock.
    let admitted = try scheduler.reserve(
        name: "fits", arguments: ["true"], requirements: TaskRequirements(mode: .batch, memoryMiB: 512), timeout: 0)
    let clock = try scheduler.snapshot().tasks.first?.stalledSince
    withExtendedLifetime(admitted) { #expect(clock == nil) }
}

// MARK: Surfaces

@Test func `a stalled job is marked in view and list JSON and text`() throws {
    var head = task(memoryMiB: 21000)
    head.stalledSince = 4
    var other = task(memoryMiB: 512)
    other.name = "behind"
    let state = SchedulerState(tasks: [head, other], sensors: stallSensors(at: 10))
    let view = SchedulerView(state: state, service: serviceStatus(), processLatch: "free", now: 10)
    let summary = try #require(view.jobs.first)
    let stalled = try #require(summary.stalled)
    #expect(stalled.kind == "memory")
    #expect(stalled.neededMiB == 21000)
    #expect(stalled.headroomMiB == 20800)
    #expect(stalled.elapsedSeconds == 6)
    #expect(stalled.remainingSeconds == 294)
    #expect(abs(stalled.since.timeIntervalSince(view.observedAt) + 6) < 0.001)
    #expect(summary.state == "queued")
    #expect(summary.blockerDetail?.contains("unsatisfiable") == true)
    #expect(view.tasks.first?.stalled == stalled)
    #expect(view.jobs[1].stalled == nil)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let list = try JSONDecoder().decode(MCPValue.self, from: encoder.encode(view.jobs))
    guard case .array(let jobs) = list else {
        Issue.record("list JSON is not an array")
        return
    }
    #expect(jobs[0]["stalled"]?["kind"] == "memory")
    #expect(jobs[0]["stalled"]?["neededMiB"] == 21000)
    #expect(jobs[0]["stalled"]?["headroomMiB"] == 20800)
    #expect(jobs[0]["stalled"]?["since"]?.string != nil)
    #expect(jobs[1]["stalled"] == nil)

    #expect(HumanOutput.list(view.jobs, verbose: false, width: 160).contains("stalled"))
    #expect(HumanOutput.list(view.jobs, verbose: false, width: 60).contains("stalled"))
    #expect(HumanOutput.view(view, verbose: false, width: 160).contains("unsatisfiable"))
}

@Test func `a stall that has cleared is no longer reported`() throws {
    var head = task(memoryMiB: 512)
    head.stalledSince = 4
    let state = SchedulerState(tasks: [head], sensors: stallSensors(at: 10))
    let view = SchedulerView(state: state, service: serviceStatus(), processLatch: "free", now: 10)
    #expect(view.jobs.first?.stalled == nil)
}

@Test func `a disabled stall timeout reports no remaining time`() throws {
    var head = task(memoryMiB: 21000)
    head.stalledSince = 4
    head.requirements.stallTimeout = 0
    let state = SchedulerState(tasks: [head], sensors: stallSensors(at: 10))
    let view = SchedulerView(state: state, service: serviceStatus(), processLatch: "free", now: 10)
    let stalled = try #require(view.jobs.first?.stalled)
    #expect(stalled.remainingSeconds == nil)
    #expect(view.jobs.first?.blockerDetail?.contains("unsatisfiable") == false)
}

@Test func `MCP instructions tell agents an unsatisfiable end is final`() {
    #expect(MCPTools.instructions.contains("terminationReason unsatisfiable"))
    #expect(MCPTools.instructions.contains("instead of resubmitting unchanged"))
}
