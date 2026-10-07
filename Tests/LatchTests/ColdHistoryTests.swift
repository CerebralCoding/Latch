import Foundation
import Testing

@testable import Latch

private func coldSample(_ uptime: Double, temperature: Double = 30) -> SensorSnapshot {
    SensorSnapshot(
        sampledAt: Date(timeIntervalSince1970: uptime), uptime: uptime, cpuCores: 18,
        cpuActive: 0.01, busiestCore: 0.1, gpuActive: 0, aneWatts: 0,
        memoryAvailableMiB: 24000, memoryTotalMiB: 32000, memoryPressure: "normal",
        thermalState: "nominal", diskBytesPerSecond: 0, unavailable: [],
        cpuTemperature: temperature, gpuTemperature: temperature)
}

private func coldTask(_ queued: Double = 1020) -> ScheduledTask {
    ScheduledTask(
        id: UUID().uuidString, name: "latency", pid: 0, arguments: [],
        requirements: TaskRequirements(
            measurement: true, temperatureGuard: TemperatureGuard(maxCPU: 50, maxGPU: 50, cooldown: 10)),
        queuedUptime: queued)
}

private func recordCold(_ sample: SensorSnapshot, history: inout ColdHistory, state: inout SchedulerState) {
    state.record(sample)
    history.observe(sample, state: &state)
}

@Test func `recent idle cold history credits cooldown but never quiet admission`() {
    var history = ColdHistory()
    var state = SchedulerState()
    for time in 1000..<1030 {
        var sample = coldSample(Double(time))
        sample.gpuActive = 0.1
        recordCold(sample, history: &history, state: &state)
    }
    state.tasks = [coldTask(1030)]
    recordCold(coldSample(1030), history: &history, state: &state)
    #expect(state.tasks[0].coolSince == 1000)
    #expect(
        SchedulingPolicy.reason(for: state.tasks[0], in: state, now: 1030)
            == "waiting for a quiet CPU/GPU/ANE/disk window")
    recordCold(coldSample(1031), history: &history, state: &state)
    recordCold(coldSample(1032), history: &history, state: &state)
    #expect(SchedulingPolicy.reason(for: state.tasks[0], in: state, now: 1032) == nil)
    #expect(SchedulingPolicy.reason(for: state.tasks[0], in: state, now: 1035) == "waiting for fresh sensors")
    recordCold(coldSample(1035), history: &history, state: &state)
    #expect(state.tasks[0].coolSince == 1035)
}

@Test(arguments: [
    "warm", "hot", "gpu", "ane", "ane-floor", "ane-power", "ane-missing", "gap", "sleep", "rewind", "running",
    "completed", "restart",
])
func `cold history fails closed when evidence is unsuitable`(condition: String) throws {
    var history = ColdHistory()
    var state = SchedulerState()
    for time in 1000..<1010 {
        recordCold(coldSample(Double(time)), history: &history, state: &state)
    }
    var middle = coldSample(1010)
    switch condition {
    case "warm": middle.cpuTemperature = 45
    case "hot": middle.cpuActive = 0.9
    case "gpu": middle.gpuActive = 0.8
    case "ane": middle.aneActivity = ANEActivity(fraction: 0.5, source: .compute)
    case "ane-floor":
        middle.aneActivity = ANEActivity(fraction: 0.5, source: .powerFloor)
        middle.aneWatts = 0.075
    case "ane-power": middle.aneWatts = 1
    case "ane-missing": middle.aneWatts = nil
    case "gap": middle.uptime = 1012
    case "sleep": middle.sampledAt = Date(timeIntervalSince1970: 900)
    case "rewind": middle.uptime = 999
    case "running":
        var task = coldTask()
        task.state = .running
        state.tasks = [task]
    default: break
    }
    recordCold(middle, history: &history, state: &state)
    state.tasks = [coldTask(1011)]
    if condition == "completed" {
        let submission = try MCPSubmission([
            "requestKey": "cold-history", "name": "completed", "executable": "/usr/bin/true",
            "workingDirectory": "/",
        ])
        state.jobs = [
            DurableJobRecord(id: UUID().uuidString, submission: submission, state: "completed", complete: true)
        ]
    }
    if condition == "restart" { history = ColdHistory() }
    recordCold(coldSample(1011), history: &history, state: &state)
    #expect(state.tasks[0].coolSince == 1011)
}

@Test func `cold history never lends idle observations to stricter custom temperatures`() {
    var history = ColdHistory()
    var state = SchedulerState()
    for time in 1000..<1015 {
        recordCold(coldSample(Double(time)), history: &history, state: &state)
    }
    state.tasks = [coldTask(1015)]
    state.tasks[0].requirements.temperatureGuard?.maxCPU = 35
    recordCold(coldSample(1015), history: &history, state: &state)
    #expect(state.tasks[0].coolSince == 1015)
}

@Test func `sensor cadence accounts for collection cost and queue wakeups`() {
    var cadence = SensorCadence()
    #expect(cadence.delay(now: 100) == 0)
    cadence.startedAt = 100
    #expect(abs(cadence.delay(now: 100.4) - 0.6) < 0.000001)
    #expect(cadence.delay(now: 100.5) == 0.5)
    #expect(cadence.delay(now: 101.5) == 0)
    #expect(cadence.delay(now: 99) == 0)
}
