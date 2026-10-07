import Foundation
import Testing

@testable import Latch

private func waitSensors(_ uptime: Double = 1000) -> SensorSnapshot {
    SensorSnapshot(
        sampledAt: Date(), uptime: uptime, cpuCores: 18, cpuActive: 0.064, busiestCore: 0.2,
        gpuActive: 0, aneWatts: 0, memoryAvailableMiB: 24000, memoryTotalMiB: 32000,
        memoryPressure: "normal", thermalState: "nominal", diskBytesPerSecond: 0, unavailable: [],
        cpuTemperature: 40, gpuTemperature: 38)
}

private func waitTask(_ name: String, measurement: Bool = true) -> ScheduledTask {
    let plan = TaskPlanner.plan(
        arguments: [], measurement: measurement, classification: .ordinary, cpuCount: 18, memoryMiB: 32000)
    return ScheduledTask(
        id: UUID().uuidString, name: name, pid: 0, arguments: [], requirements: plan.requirements,
        queuedUptime: 400, coolSince: 980, plan: plan)
}

private func waitView(_ state: SchedulerState, now: Double = 1000, running: Bool = true) -> SchedulerView {
    SchedulerView(
        state: state, service: SchedulerService.Status(running: running, path: "/queue"),
        processLatch: "free", now: now)
}

@Test func `correctness can overlap while performance measurements always require quiet exclusive admission`() {
    for classification in [MCPSubmission.Classification.ordinary, .sensitive] {
        for measurement in [false, true] {
            let plan = TaskPlanner.plan(
                arguments: [], measurement: measurement, classification: classification,
                cpuCount: 18, memoryMiB: 32000)
            let task = ScheduledTask(
                id: UUID().uuidString, name: "evaluation", pid: 0, arguments: [],
                requirements: plan.requirements, coolSince: 980, plan: plan)
            let state = SchedulerState(tasks: [task], sensors: waitSensors(), quietSince: 990)
            #expect(plan.requirements.mode == (measurement || classification == .sensitive ? .isolated : .batch))
            let reason = SchedulingPolicy.reason(for: task, in: state, now: 1000)
            #expect(reason == (measurement ? "waiting for a quiet window: background CPU load" : nil))
        }
    }
}

@Test func `quiet wait explains the CPU margin and the earlier ticket without attributing all queue time to it`() throws
{
    let first = waitTask("latency run")
    let second = waitTask("correctness check", measurement: false)
    var baseline = IdleBaseline()
    baseline.cpuActive = 0.01
    let state = SchedulerState(tasks: [first, second], sensors: waitSensors(), idleBaseline: baseline)
    let view = waitView(state)
    let detail = try #require(view.tasks.first?.blockerDetail)
    #expect(detail.contains("CPU activity 6.40%; requires ≤6.00%"))
    #expect(detail.contains("idle baseline 1.00%, excess 0.40 percentage points"))
    #expect(detail.contains("1.15 / limit 1.08 across 18 cores"))
    #expect(detail.contains("Queue age 10m 0s"))
    #expect(detail.contains("not the cause of the entire wait"))
    #expect(detail.contains("no process attribution"))
    let follower = try #require(view.tasks.last?.blockerDetail)
    #expect(follower.contains("FIFO: earlier measurement job latency run (\(first.id))"))
    #expect(follower.contains("CPU activity 6.40%"))
    #expect(view.tasks.last?.blockedBy == "waiting for earlier queued tasks")
    #expect(SchedulingPolicy.reason(for: second, in: state, now: 1000) == "waiting for earlier queued tasks")
}

@Test func `wait explanations name running work without requiring sensor readings`() throws {
    var first = waitTask("long finite job")
    first.state = .running
    let second = waitTask("correctness check", measurement: false)
    let view = waitView(SchedulerState(tasks: [first, second]))
    let detail = try #require(view.tasks.last?.blockerDetail)
    #expect(detail.contains("long finite job (\(first.id))"))
    #expect(detail.contains("without preemption or a runtime limit"))
    #expect(!detail.contains("CPU activity"))
}

@Test func `quiet interval fresh sensor and service blockers remain distinct`() throws {
    let task = waitTask("measurement")
    var sensors = waitSensors()
    sensors.cpuActive = 0.01
    var state = SchedulerState(tasks: [task], sensors: sensors, quietSince: 999)
    let detail = try #require(waitView(state).tasks.first?.blockerDetail)
    #expect(detail.contains("observed quiet interval 1.0s / 2.0s"))
    #expect(detail.contains("sampling gap restarts"))
    let stale = try #require(waitView(state, now: 1003).tasks.first?.blockerDetail)
    #expect(stale.contains("waiting for fresh sensors"))
    #expect(!stale.contains("CPU activity"))
    let stopped = try #require(waitView(state, running: false).tasks.first?.blockerDetail)
    #expect(stopped.contains("service stopped"))
    state.sensorError = "sensor failure"
    #expect(waitView(state).tasks.first?.blockerDetail?.contains("sensors unavailable: sensor failure") == true)
}

@Test func `wait messages refresh evidence but notify only when the blocker changes`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let store = try DurableJobs(scheduler: scheduler)
    let submission = try MCPSubmission([
        "requestKey": "wait-explanation", "name": "measurement", "measurement": true,
        "executable": "/usr/bin/true", "workingDirectory": .string(fixture.directory.path),
    ])
    let record = DurableJobRecord(id: UUID().uuidString, submission: submission)
    let job = MCPJob(record: record, store: store)
    var first = waitTask("measurement")
    first.id = record.id
    var state = SchedulerState(jobs: [record], tasks: [first], sensors: waitSensors())
    try job.update(now: 1000, view: waitView(state))
    let initial = try job.result(includeOutput: false)
    #expect(initial["progressMessage"]?.string?.hasPrefix(MCPTools.pendingGuidance) == true)
    #expect(initial["progressMessage"]?.string?.contains("CPU activity 6.40%") == true)
    let progress = MCPProgress(token: "wait")
    let task = MCPTask(jobID: job.id, progress: nil)
    #expect(try task.update(job: job))
    #expect(
        progress.update(state: initial["progressMessage"]!.string!, identity: job.progressIdentity(for: initial)) != nil
    )

    state.sensors = waitSensors(1001)
    state.sensors?.cpuActive = 0.066
    try job.update(now: 1001, view: waitView(state, now: 1001))
    let latest = try job.result(includeOutput: true)
    #expect(latest["progressMessage"]?.string?.contains("CPU activity 6.60%") == true)
    #expect(
        progress.update(state: latest["progressMessage"]!.string!, identity: job.progressIdentity(for: latest)) == nil)
    #expect(try !task.update(job: job))
    #expect(task.message.contains("CPU activity 6.60%"))

    state.sensors?.cpuActive = 0.01
    state.sensors?.gpuActive = 0.1
    try job.update(now: 1001, view: waitView(state, now: 1001))
    let changed = try job.result(includeOutput: false)
    #expect(
        progress.update(state: changed["progressMessage"]!.string!, identity: job.progressIdentity(for: changed)) != nil
    )
    #expect(try task.update(job: job))

    state.sensors?.gpuActive = 0
    state.sensors?.aneActivity = ANEActivity(fraction: 0.3, source: .compute)
    try job.update(now: 1001, view: waitView(state, now: 1001))
    let ane = try job.result(includeOutput: false)
    #expect(ane["progressMessage"]?.string?.contains("ANE compute 30.0%; requires ≤2.0%") == true)
    #expect(progress.update(state: ane["progressMessage"]!.string!, identity: job.progressIdentity(for: ane)) != nil)
    #expect(try task.update(job: job))
    state.sensors?.aneActivity?.fraction = 0.4
    try job.update(now: 1001, view: waitView(state, now: 1001))
    let aneChanged = try job.result(includeOutput: false)
    #expect(aneChanged["progressMessage"]?.string?.contains("ANE compute 40.0%") == true)
    #expect(
        progress.update(state: aneChanged["progressMessage"]!.string!, identity: job.progressIdentity(for: aneChanged))
            == nil)
    #expect(try !task.update(job: job))

    state.tasks[0].state = .running
    try job.update(now: 1001, view: waitView(state, now: 1001))
    #expect(
        try job.result(includeOutput: false)["progressMessage"]?.string?.hasPrefix(MCPTools.pendingGuidance) == true)
}

@Test func `ANE wait evidence shares effective limits with diagnostics and FIFO followers`() throws {
    let first = waitTask("ANE measurement")
    let second = waitTask("correctness", measurement: false)
    var sensors = waitSensors()
    sensors.cpuActive = 0.01
    sensors.aneWatts = 0.075
    sensors.aneActivity = ANEActivity(fraction: 0.5, source: .powerFloor)
    let state = SchedulerState(tasks: [first, second], sensors: sensors)
    let view = waitView(state)
    #expect(view.quietLimits.aneWatts == 0.05)
    let detail = try #require(view.tasks.first?.blockerDetail)
    #expect(detail.contains("ANE power 0.075 W; requires ≤0.050 W"))
    #expect(detail.contains("Floor estimate 50.0%"))
    #expect(detail.contains("estimate alone does not block"))
    #expect(view.tasks.last?.blockerDetail?.contains(detail) == true)
    #expect(HumanOutput.view(view, verbose: true, width: 240).contains("requires ≤0.050 W"))
    let encoded = try JSONDecoder().decode(MCPValue.self, from: JSONEncoder().encode(view))
    #expect(encoded["quietLimits"]?["aneWatts"] == .number(0.05))
    #expect(encoded["sensors"]?["aneActivity"]?["source"] == "powerFloor")
}

@Test func `pending guidance preserves lifecycle status and disappears on completion`() throws {
    let fixture = try Fixture()
    let store = try DurableJobs(scheduler: Scheduler(path: fixture.lockPath))
    let submission = try MCPSubmission([
        "requestKey": "pending-lifecycle", "name": "correctness", "classification": "ordinary",
        "executable": "/usr/bin/true", "workingDirectory": .string(fixture.directory.path),
    ])
    let record = DurableJobRecord(id: UUID().uuidString, submission: submission)
    let job = MCPJob(record: record, store: store)
    for stage in ["queued", "running", "parked", "cancelling", "completed"] {
        let value: MCPValue = [
            "jobID": .string(job.id), "state": .string(stage), "complete": .bool(stage == "completed"),
            "progressMessage": .string("\(stage): lifecycle detail"),
        ]
        try JSONEncoder().encode(value).write(to: store.file(job.id, "result.json"), options: .atomic)
        try job.update(now: 1000)
        let first = try job.result(includeOutput: false)
        let second = try job.result(includeOutput: true)
        let message = try #require(first["progressMessage"]?.string)
        #expect(message.contains("\(stage): lifecycle detail"))
        #expect(message.hasPrefix(MCPTools.pendingGuidance) == (stage != "completed"))
        #expect(second["progressMessage"] == first["progressMessage"])
        #expect(job.progressIdentity(for: first) == job.progressIdentity(for: second))
    }
}
