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

@Test func `ordinary exclusive work does not wait for an impossible measurement quiet window`() {
    let plan = TaskPlanner.plan(arguments: [], measurement: false, cpuCount: 8, memoryMiB: 32000)
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
    var task = ScheduledTask(
        id: UUID().uuidString, name: "pending", pid: 0, arguments: [], requirements: TaskRequirements())
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
