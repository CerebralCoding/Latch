import Foundation
import Testing

@testable import Latch

private func readings(_ uptime: Double = 10) -> SensorSnapshot {
    SensorSnapshot(
        sampledAt: Date(), uptime: uptime, cpuCores: 8, cpuActive: 0.04, busiestCore: 0.24,
        gpuActive: 0.04, aneWatts: 0, memoryAvailableMiB: 24000, memoryTotalMiB: 32000,
        memoryPressure: "normal", thermalState: "nominal", diskBytesPerSecond: 0, unavailable: [],
        cpuTemperature: 70, gpuTemperature: 60)
}

private func compilation(_ path: String, id: String = UUID().uuidString) -> ScheduledTask {
    let requirements = TaskRequirements(
        mode: .batch, cpuCores: 4, memoryMiB: 4096,
        temperatureGuard: TemperatureGuard(maxCPU: 85, maxGPU: 80, cooldown: 0))
    let plan = TaskPlan(
        arguments: ["build", "-Xswiftc", "-num-threads", "-Xswiftc", "1", "--jobs", "4"],
        requirements: requirements, reason: "test",
        buildPaths: [path])
    return ScheduledTask(
        id: id, name: path, pid: 0, arguments: ["/usr/bin/swift"] + plan.arguments,
        requirements: requirements, plan: plan)
}

@Test func `independent builds share capacity without measurement cooldowns`() {
    var first = compilation("/a")
    let second = compilation("/b")
    var state = SchedulerState(tasks: [first, second], sensors: readings())
    first = TaskPlanner.allocate(first, in: state)
    #expect(first.requirements.cpuCores == 3)
    #expect(SchedulingPolicy.reason(for: first, in: state, now: 10) == nil)
    first.state = .running
    state.tasks[0] = first
    let prepared = TaskPlanner.allocate(second, in: state)
    #expect(prepared.requirements.cpuCores == 3)
    #expect(prepared.plan?.arguments == ["build", "-Xswiftc", "-num-threads", "-Xswiftc", "1", "--jobs", "3"])
    #expect(SchedulingPolicy.reason(for: second, in: state, now: 10) == nil)
    state.sensors?.cpuTemperature = 90
    #expect(SchedulingPolicy.reason(for: second, in: state, now: 10)?.hasPrefix("temperature guard") == true)
}

@Test func `build conflicts and exclusive barriers preserve strict FIFO`() {
    var first = compilation("/a/.build")
    first.state = .running
    let conflict = compilation("/a/.build/nested")
    let later = compilation("/b")
    let state = SchedulerState(tasks: [first, conflict, later], sensors: readings())
    #expect(SchedulingPolicy.reason(for: conflict, in: state, now: 10) == "build outputs reserved by \(first.id)")
    #expect(SchedulingPolicy.reason(for: later, in: state, now: 10) == "waiting for earlier queued tasks")
    let measurement = ScheduledTask(
        id: UUID().uuidString, name: "measure", pid: 0, arguments: [],
        requirements: TaskRequirements(measurement: true))
    let barrier = SchedulerState(tasks: [first, measurement, later], sensors: readings())
    #expect(SchedulingPolicy.reason(for: measurement, in: barrier, now: 10) == "waiting for running tasks to drain")
    #expect(SchedulingPolicy.reason(for: later, in: barrier, now: 10) == "waiting for earlier queued tasks")
}

@Test func `compilation allocations respect aggregate bounds and memory pressure`() {
    var a = compilation("/a")
    var b = compilation("/b")
    a.state = .running
    b.state = .running
    let c = compilation("/c")
    var state = SchedulerState(tasks: [a, b, c], sensors: readings())
    #expect(SchedulingPolicy.reason(for: c, in: state, now: 10) == "compilation concurrency limit")
    state.tasks = [c]
    state.sensors?.memoryAvailableMiB = 5250
    let small = TaskPlanner.allocate(c, in: state)
    #expect(small.requirements.cpuCores == 2)
    #expect(small.requirements.memoryMiB == 2048)
    #expect(SchedulingPolicy.reason(for: c, in: state, now: 10) == nil)
    state.sensors?.memoryAvailableMiB = 3300
    #expect(SchedulingPolicy.reason(for: c, in: state, now: 10) == "insufficient memory headroom")
    state.sensors?.memoryPressure = "warning"
    #expect(SchedulingPolicy.reason(for: c, in: state, now: 10) == "memory pressure is warning")
    #expect(TaskPlanner.allocate(a, in: state) == a)
    state.sensors = nil
    #expect(SchedulingPolicy.reason(for: c, in: state, now: 10) == "waiting for fresh sensors")
    state.sensorError = "test failure"
    #expect(SchedulingPolicy.reason(for: c, in: state, now: 10) == "sensors unavailable: test failure")
}

@Test func `ordinary exclusive work does not wait for an impossible measurement quiet window`() {
    let plan = TaskPlanner.plan(executable: "/model", arguments: [], measurement: false, cpuCount: 8, memoryMiB: 32000)
    let task = ScheduledTask(
        id: UUID().uuidString, name: "ordinary", pid: 0, arguments: [], requirements: plan.requirements)
    let state = SchedulerState(tasks: [task], sensors: readings())
    #expect(plan.requirements.mode == .isolated)
    #expect(!plan.requirements.measurement)
    #expect(SchedulingPolicy.reason(for: task, in: state, now: 10) == nil)
}

@Test func `rolling idle calibration resists spikes and never lifts the absolute ceilings`() throws {
    var state = SchedulerState()
    for uptime in 1...32 {
        var sample = readings(Double(uptime))
        sample.cpuActive = uptime.isMultiple(of: 3) ? 0.1 : 0.04
        sample.busiestCore = uptime.isMultiple(of: 3) ? 0.5 : 0.24
        sample.gpuActive = uptime.isMultiple(of: 3) ? 0.06 : 0.04
        state.record(sample)
    }
    let baseline = try #require(state.idleBaseline)
    #expect(baseline.calibrationSamples == 5)
    #expect(baseline.cpuActive == 0.04)
    #expect(baseline.gpuActive == 0.04)
    #expect(baseline.readings?.count == 32)
    var high = baseline
    high.cpuActive = 0.1
    high.busiestCore = 0.5
    high.gpuActive = 0.06
    let limits = QuietLimits(baseline: high)
    #expect(limits.cpuActive == 0.12)
    #expect(limits.busiestCore == 0.6)
    #expect(limits.gpuActive == 0.08)
    var noisy = readings(33)
    noisy.gpuActive = 0.09
    #expect(noisy.quietBlocker(baseline: high) == "background GPU load")
}

@Test func `admission retains policy evidence without calibration history`() throws {
    var state = SchedulerState()
    state.record(readings())
    let admission = try #require(AdmissionSnapshot(state: state, measurement: true))
    #expect(admission.sensors == state.sensors)
    #expect(abs((admission.quietLimits?.gpuActive ?? 0) - 0.06) < 0.000001)
    #expect(admission.idleBaseline?.readings == nil)
    state.record(readings(11))
    #expect(admission.sensors.uptime == 10)
}

@Test func `tightening a baseline restarts an interval containing now excessive activity`() throws {
    var state = SchedulerState()
    for time in 1...5 { state.record(readings(Double(time))) }
    var peak = readings(6)
    peak.gpuActive = 0.0599
    state.record(peak)
    #expect(state.quietSince == 1)
    for time in 7...40 {
        var low = readings(Double(time))
        low.gpuActive = 0
        state.record(low)
    }
    #expect(try #require(state.quietSince) > 6)
    #expect(state.quietPeak?.gpuActive == 0)
}

@Test func `calibrated pending and parked work never raises the baseline`() throws {
    var state = SchedulerState()
    for time in 1...5 { state.record(readings(Double(time))) }
    let baseline = try #require(state.idleBaseline)
    var task = compilation("/a")
    for phase in [ScheduledTask.State.queued, .parked, .running] {
        task.state = phase
        state.tasks = [task]
        for index in 0..<40 {
            var higher = readings(state.sensors!.uptime + 1)
            higher.gpuActive = 0.06
            higher.cpuActive = 0.1
            higher.busiestCore = 0.5
            higher.diskBytesPerSecond = Double(index * 1024)
            state.record(higher)
        }
        #expect(state.idleBaseline?.gpuActive == baseline.gpuActive)
        #expect(state.idleBaseline?.cpuActive == baseline.cpuActive)
    }
    #expect(state.idleBaseline?.readings?.count == 32)
}

@Test func `SwiftPM paths resolve overrides symlinks and shared scratch directories`() throws {
    let fixture = try Fixture()
    let root = fixture.directory
    for name in ["a", "b"] {
        let project = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("// swift-tools-version: 6.4".utf8).write(to: project.appendingPathComponent("Package.swift"))
    }
    try FileManager.default.createSymbolicLink(
        atPath: root.appendingPathComponent("alias").path,
        withDestinationPath: root.appendingPathComponent("a").path)
    func plan(_ args: [String]) -> TaskPlan {
        TaskPlanner.plan(
            executable: "/usr/bin/swift", arguments: ["build"] + args, measurement: false,
            workingDirectory: root.path, environment: [:])
    }
    let a = plan(["--package-path", "a"])
    let alias = plan(["--package-path=alias"])
    let b = plan(["--package-path=b"])
    #expect(a.buildPaths != nil)
    #expect(TaskPlanner.conflicts(a, alias))
    #expect(!TaskPlanner.conflicts(a, b))
    #expect(
        plan(["--package-path", "a", "--scratch-path", "shared"]).buildPaths?.contains(
            root.appendingPathComponent("shared").path) == true)
    #expect(
        TaskPlanner.conflicts(
            plan(["--package-path", "a", "--scratch-path", "../shared"]),
            plan(["--package-path", "b", "--scratch-path=../shared"])))
    for args in [["--jobs", "8"], ["-j8"], ["-Xswiftc", "-index-store-path"], ["--future-option"], [""]] {
        #expect(plan(["--package-path", "a"] + args).requirements.mode == .isolated)
    }
}
