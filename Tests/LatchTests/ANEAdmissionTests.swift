import Foundation
import Testing

@testable import Latch

@Suite struct ANEAdmissionTests {
    private func sample(
        _ uptime: Double = 100, source: ANEActivity.Source? = .compute,
        activity: Double = 0, watts: Double = 0
    ) -> SensorSnapshot {
        SensorSnapshot(
            sampledAt: Date(timeIntervalSince1970: uptime), uptime: uptime, cpuCores: 8,
            cpuActive: 0.01, busiestCore: 0.1, gpuActive: 0, aneWatts: watts,
            memoryAvailableMiB: 24000, memoryTotalMiB: 32000, memoryPressure: "normal",
            thermalState: "nominal", diskBytesPerSecond: 0, unavailable: [],
            cpuTemperature: 30, gpuTemperature: 30,
            aneActivity: source.map { ANEActivity(fraction: activity, source: $0) })
    }

    private func task(measurement: Bool = true, classification: MCPSubmission.Classification = .ordinary)
        -> ScheduledTask
    {
        let plan = TaskPlanner.plan(
            arguments: [], measurement: measurement, classification: classification,
            cpuCount: 8, memoryMiB: 32000)
        var task = ScheduledTask(
            id: UUID().uuidString, name: "ANE check", pid: 0, arguments: [],
            requirements: plan.requirements, queuedUptime: 80, coolSince: 80, plan: plan)
        task.requirements.temperatureGuard?.cooldown = 0
        return task
    }

    @Test(arguments: [ANEActivity.Source.compute, .cluster])
    func lowPowerActivityRestartsMeasurementQuietWindow(source: ANEActivity.Source) throws {
        let task = task()
        var state = SchedulerState(tasks: [task])
        state.record(sample(100, source: source))
        state.record(sample(101, source: source))
        state.record(sample(102, source: source, activity: 0.3, watts: 0.01))
        #expect(state.quietSince == nil)
        #expect(state.quietPeak == nil)
        #expect(state.idleBaseline?.calibrationSamples == 2)
        #expect(
            SchedulingPolicy.reason(for: state.tasks[0], in: state, now: 102)
                == "waiting for a quiet window: background ANE activity")
        state.record(sample(103, source: source))
        state.record(sample(104, source: source))
        #expect(
            SchedulingPolicy.reason(for: state.tasks[0], in: state, now: 104)
                == "waiting for a quiet CPU/GPU/ANE/disk window")
        state.record(sample(105, source: source))
        #expect(SchedulingPolicy.reason(for: state.tasks[0], in: state, now: 105) == nil)
        let admission = try #require(AdmissionSnapshot(state: state, measurement: true))
        #expect(admission.sensors.aneActivity?.source == source)
    }

    @Test func floorEstimateRequiresPowerCorroboration() throws {
        let powerOnly = sample(source: nil, watts: 0.075)
        #expect(powerOnly.quietBlocker(baseline: nil) == nil)
        let demand = sample(source: .powerFloor, activity: 0.5, watts: 0.075)
        #expect(demand.quietBlocker(baseline: nil) == "background ANE load")
        #expect(IdleReading(demand) == nil)
        #expect(sample(source: .powerFloor, activity: 1, watts: 0).quietBlocker(baseline: nil) == nil)
        #expect(sample(source: .powerFloor, activity: 0.5, watts: 0.05).quietBlocker(baseline: nil) == nil)
        #expect(sample(source: .powerFloor, activity: 0.5, watts: 0.051).quietBlocker(baseline: nil) != nil)
        #expect(sample(source: .powerFloor, activity: 0.02, watts: 0.075).quietBlocker(baseline: nil) == nil)

        var baseline = IdleBaseline()
        baseline.aneWatts = 0.03
        #expect(demand.quietBlocker(baseline: baseline) == nil)
        let state = SchedulerState(sensors: demand, idleBaseline: baseline)
        let admission = try #require(AdmissionSnapshot(state: state, measurement: true))
        #expect(admission.quietLimits?.aneWatts == 0.08)
        let decoded = try JSONDecoder().decode(AdmissionSnapshot.self, from: JSONEncoder().encode(admission))
        #expect(decoded == admission)
    }

    @Test func activeANEIsNeverCalibratedAsIdle() {
        for source in [ANEActivity.Source.compute, .cluster, .powerFloor] {
            var state = SchedulerState()
            for uptime in 100...110 {
                state.record(sample(Double(uptime), source: source, activity: 0.3, watts: 0.075))
            }
            #expect(state.idleBaseline == nil)
            #expect(state.quietSince == nil)
        }
    }

    @Test func activityCannotReplaceMissingPowerAndInvalidReadingsFailClosed() {
        var missing = sample()
        missing.aneWatts = nil
        #expect(missing.quietBlocker(baseline: nil) == "required sensors unavailable")
        #expect(IdleReading(missing) == nil)
        for fraction in [-0.1, 1.1, Double.nan, Double.infinity] {
            let invalid = sample(activity: fraction)
            #expect(invalid.quietBlocker(baseline: nil) == "invalid ANE activity")
            #expect(IdleReading(invalid) == nil)
        }
        for watts in [-0.1, Double.nan, Double.infinity] {
            let invalid = sample(watts: watts)
            #expect(invalid.quietBlocker(baseline: nil) == "ANE power unavailable or invalid")
        }
        #expect(sample(source: nil).quietBlocker(baseline: nil) == nil)
        #expect(sample(activity: 0.02).quietBlocker(baseline: nil) == nil)
        #expect(sample(activity: 0.0201).quietBlocker(baseline: nil) == "background ANE activity")
    }

    @Test func floorEvidenceStaysPairedWhileSourceChangesEarnANewQuietWindow() {
        var state = SchedulerState()
        state.record(sample(100, source: .powerFloor, activity: 0.01, watts: 0.075))
        state.record(sample(101, source: .powerFloor, activity: 0.5, watts: 0.04))
        #expect(state.quietSince == 100)
        #expect(state.quietPeak?.aneWatts == 0.04)
        state.record(sample(102, source: .powerFloor, activity: 0.4, watts: 0.03))
        #expect(state.quietSince == 100)
        #expect(state.quietPeak?.aneActivity?.fraction == 0.5)
        state.record(sample(103, source: .cluster))
        #expect(state.quietSince == 103)
        state.record(sample(104, source: nil))
        #expect(state.quietSince == 104)
        state.record(sample(105, source: .compute))
        #expect(state.quietSince == 105)
    }

    @Test func fluctuatingFloorWithoutPowerNeverDelaysMeasurement() {
        var state = SchedulerState(tasks: [task()])
        for uptime in 100...110 {
            state.record(
                sample(
                    Double(uptime), source: .powerFloor,
                    activity: uptime.isMultiple(of: 2) ? 0.5 : 0.01))
        }
        #expect(state.quietSince == 100)
        #expect(SchedulingPolicy.reason(for: state.tasks[0], in: state, now: 110) == nil)
    }

    @Test func tighteningPowerBaselineRechecksEarlierCorroboratedFloorReadings() throws {
        var baseline = IdleBaseline()
        baseline.aneWatts = 0.03
        baseline.calibrationSamples = 5
        var state = SchedulerState(idleBaseline: baseline)
        state.record(sample(100, source: .powerFloor, activity: 0.5, watts: 0.075))
        #expect(state.quietSince == 100)
        for uptime in 101...140 { state.record(sample(Double(uptime), source: .powerFloor, activity: 0.5)) }
        #expect(try #require(state.quietSince) > 100)
        #expect(state.quietPeak?.aneWatts == 0)
    }

    @Test func ordinaryAndSensitiveCorrectnessDoNotAcquireMeasurementActivityGuards() {
        for classification in [MCPSubmission.Classification.ordinary, .sensitive] {
            let task = task(measurement: false, classification: classification)
            let state = SchedulerState(tasks: [task], sensors: sample(activity: 0.9, watts: 4))
            #expect(SchedulingPolicy.reason(for: task, in: state, now: 100) == nil)
        }
        var running = task(measurement: false)
        running.state = .running
        let next = task(measurement: false)
        let state = SchedulerState(tasks: [running, next], sensors: sample(activity: 0.9, watts: 4))
        #expect(SchedulingPolicy.reason(for: next, in: state, now: 100) == nil)
    }
}
