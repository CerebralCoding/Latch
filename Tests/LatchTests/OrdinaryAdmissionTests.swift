import Foundation
import Testing

@testable import Latch

private func ordinarySensors(cores: Int = 8, memory: Int = 32000, uptime: Double = 10) -> SensorSnapshot {
    SensorSnapshot(
        sampledAt: Date(), uptime: uptime, cpuCores: cores, cpuActive: 0.1, busiestCore: 0.2,
        gpuActive: 0, aneWatts: 0, memoryAvailableMiB: memory * 8 / 10, memoryTotalMiB: memory,
        memoryPressure: "normal", thermalState: "nominal", diskBytesPerSecond: 0, unavailable: [],
        cpuTemperature: 40, gpuTemperature: 40)
}

private func ordinaryTask(cores: Int = 8, memory: Int = 32000) -> ScheduledTask {
    let plan = TaskPlanner.plan(
        arguments: ["unchanged"], measurement: false, classification: .ordinary,
        cpuCount: cores, memoryMiB: memory)
    return ScheduledTask(
        id: UUID().uuidString, name: "ordinary", pid: 0, arguments: plan.arguments,
        requirements: plan.requirements, plan: plan)
}

@Test(arguments: [4, 8, 20])
func `ordinary concurrency grows with machine core capacity`(cores: Int) {
    let next = ordinaryTask(cores: cores)
    var running = Array(repeating: next, count: cores / 2 - 1)
    for index in running.indices {
        running[index].id = UUID().uuidString
        running[index].state = .running
    }
    var state = SchedulerState(tasks: running + [next], sensors: ordinarySensors(cores: cores))
    state.sensors?.cpuActive = 1
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 10) == nil)
    var extra = next
    extra.id = UUID().uuidString
    extra.state = .running
    state.tasks.insert(extra, at: 0)
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 10) == "CPU reservation capacity")
    #expect(next.plan?.arguments == ["unchanged"])
    #expect(next.plan?.admissionTimeout == nil)
}

@Test func `ordinary starts require a new sensor observation and retain thermal memory and FIFO guards`() throws {
    var running = ordinaryTask()
    running.state = .running
    running.admission = AdmissionSnapshot(state: SchedulerState(sensors: ordinarySensors()), measurement: false)
    let next = ordinaryTask()
    var state = SchedulerState(tasks: [running, next], sensors: ordinarySensors())
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 10) == "waiting for sensors after ordinary admission")
    state.sensors = ordinarySensors(uptime: 11)
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 11) == nil)
    state.sensors?.cpuTemperature = 90
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 11) != nil)
    state.sensors = ordinarySensors(uptime: 11)
    state.sensors?.memoryAvailableMiB = 4000
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 11) == "insufficient memory headroom")
    state.sensors = ordinarySensors(uptime: 11)
    state.sensors?.memoryPressure = "warning"
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 11) == "memory pressure is warning")
    state.sensors = ordinarySensors(uptime: 11)
    state.sensors?.thermalState = "serious"
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 11) == "thermal state is serious")
    state.sensors = ordinarySensors(uptime: 11)
    var barrier = next
    barrier.id = UUID().uuidString
    barrier.requirements.mode = .isolated
    state.tasks.insert(barrier, at: 1)
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 11) == "waiting for earlier queued tasks")
    #expect(SchedulingPolicy.reason(for: barrier, in: state, now: 11) == "waiting for running tasks to drain")
    state.tasks.removeFirst()
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 11) == "waiting for earlier queued tasks")
}

@Test func `ordinary admission fails closed for missing sensors stale readings and unrelated CPU load`() {
    let next = ordinaryTask()
    var state = SchedulerState(tasks: [next])
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 10) == "waiting for fresh sensors")
    state.sensors = ordinarySensors(uptime: 7)
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 10) == "waiting for fresh sensors")
    state.sensors = ordinarySensors()
    state.sensors?.cpuTemperature = nil
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 10) != nil)
    state.sensors = ordinarySensors()
    state.sensors?.cpuActive = 0.9
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 10) == "background CPU load")
}

@Test func `classification is declarative and cannot downgrade measurements or checkpoints`() throws {
    let fixture = try Fixture()
    var arguments: MCPValue = [
        "requestKey": .string(UUID().uuidString), "name": "classification", "executable": "/usr/bin/true",
        "workingDirectory": .string(fixture.directory.path), "classification": "ordinary",
    ]
    #expect(try MCPSubmission(arguments).classification == .ordinary)
    var values = try #require(arguments.object)
    values["measurement"] = true
    #expect(try MCPSubmission(.object(values)).classification == .sensitive)
    values.removeValue(forKey: "measurement")
    values["checkpoints"] = true
    #expect(try MCPSubmission(.object(values)).measurement)
    #expect(try MCPSubmission(.object(values)).classification == .sensitive)
    values["classification"] = "swiftpm"
    #expect(throws: MCPFailure.self) { try MCPSubmission(.object(values)) }
    values["classification"] = nil
    values["checkpoints"] = nil
    arguments = .object(values)
    #expect(try MCPSubmission(arguments).classification == .sensitive)
}
