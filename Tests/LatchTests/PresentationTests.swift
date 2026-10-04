import Darwin
import Foundation
import Testing

@testable import Latch

private func presentationSensors(_ uptime: Double = 10) -> SensorSnapshot {
    SensorSnapshot(
        sampledAt: Date(), uptime: uptime, cpuCores: 8, cpuActive: 0.1, busiestCore: 0.2,
        gpuActive: 0, aneWatts: 0, memoryAvailableMiB: 24000, memoryTotalMiB: 32000,
        memoryPressure: "normal", thermalState: "nominal", diskBytesPerSecond: 0,
        unavailable: [], cpuTemperature: 40, gpuTemperature: 38)
}

private func presentationView(_ state: SchedulerState, now: Double = 10, running: Bool = true, latch: String = "free")
    -> SchedulerView
{
    SchedulerView(
        state: state,
        service: SchedulerService.Status(
            running: running, pid: running ? 123 : nil, path: "/queue",
            serviceRevision: running ? BuildIdentity.serviceRevision : nil), processLatch: latch, now: now)
}

@Test func `diagnostic flags and focused help preserve literal child arguments`() throws {
    for command in ["view", "list", "sensors"] {
        #expect(try Options(arguments: [command, "--verbose"]).verbose)
        #expect(try Options(arguments: [command, "--json"]).json)
        #expect(throws: LatchError.self) { try Options(arguments: [command, "--json", "--verbose"]) }
    }
    #expect(try Options(arguments: ["service", "status", "--json"]).json)
    for arguments in [
        ["service", "run", "--json"], ["service", "start", "--verbose"], ["run", "--json", "--", "true"],
        ["view", "--json", "--json"],
    ] {
        #expect(throws: LatchError.self) { try Options(arguments: arguments) }
    }
    let help = try Options(arguments: ["view", "--help"])
    #expect(help.command == .help)
    #expect(help.helpCommand == .view)
    #expect(try Options(arguments: ["help", "service", "status"]).helpServiceAction == .status)
    #expect(
        try Options(arguments: ["run", "--", "true", "--json", "--help"]).childArguments == [
            "true", "--json", "--help",
        ])
    let fixture = try Fixture()
    let child = try fixture.launch(["view", "--help"])
    #expect(try fixture.finish(child) == 0)
    let helpText = child.output
    #expect(helpText.contains("--verbose | --json"))
    #expect(!helpText.contains("Usage: latch schedule"))
}

@Test func `human diagnostics are short by default and JSON stays explicit when redirected`() throws {
    let fixture = try Fixture()
    let short = try fixture.launch(["view"])
    #expect(try fixture.finish(short) == 0)
    let shortText = short.output
    #expect(shortText.contains("service stopped"))
    #expect(shortText.contains("No outstanding jobs."))
    #expect(!shortText.contains("Measurement quiet limits"))
    #expect(!shortText.hasPrefix("{"))
    let verbose = try fixture.launch(["view", "--verbose"])
    #expect(try fixture.finish(verbose) == 0)
    let verboseText = verbose.output
    #expect(verboseText.contains("Measurement quiet limits"))
    #expect(verboseText.replacingOccurrences(of: "\n", with: "").contains(fixture.lockPath))
    let json = try fixture.launch(["view", "--json"])
    #expect(try fixture.finish(json) == 0)
    let value = try JSONDecoder().decode(MCPValue.self, from: Data(json.output.utf8))
    #expect(value["service"]?["running"] == false)
    #expect(value["jobs"] == [])
    let status = try fixture.launch(["service", "status"])
    #expect(try fixture.finish(status) == 69)
    #expect(status.output.contains("Latch service stopped"))
    let statusJSON = try fixture.launch(["service", "status", "--json"])
    #expect(try fixture.finish(statusJSON) == 69)
    #expect(try JSONDecoder().decode(MCPValue.self, from: Data(statusJSON.output.utf8))["running"] == false)
    let list = try fixture.launch(["list", "--json"])
    #expect(try fixture.finish(list) == 0)
    #expect(list.output.trimmingCharacters(in: .whitespacesAndNewlines) == "[]")
}

@Test func `ordinary diagnostic headroom matches admission despite admitted CPU activity`() throws {
    let plan = TaskPlanner.plan(
        arguments: [], measurement: false, classification: .ordinary, cpuCount: 8, memoryMiB: 32000)
    var running = ScheduledTask(
        id: UUID().uuidString, name: "build", pid: 1, arguments: [], requirements: plan.requirements, plan: plan)
    running.state = .running
    let next = ScheduledTask(
        id: UUID().uuidString, name: "next", pid: 0, arguments: [], requirements: plan.requirements, plan: plan)
    var sensors = presentationSensors()
    sensors.cpuActive = 1
    let state = SchedulerState(tasks: [running, next], sensors: sensors)
    let view = presentationView(state, latch: "shared")
    #expect(view.capacity.unreservedCPUCores == 6)
    #expect(view.capacity.ordinaryCPUHeadroom == 6)
    #expect(view.capacity.batchCPUHeadroom == 0)
    #expect(SchedulingPolicy.reason(for: next, in: state, now: 10) == nil)
    #expect(view.tasks.last?.blockedBy == nil)
    let stale = presentationView(state, now: 13)
    #expect(stale.capacity.ordinaryCPUHeadroom == nil)
    #expect(stale.capacity.unreservedCPUCores == 6)
    #expect(stale.tasks.last?.blockedBy == "waiting for fresh sensors")
}

@Test func `idle cached sensors are normal without relaxing admission freshness`() {
    let sensors = presentationSensors()
    let idle = presentationView(SchedulerState(sensors: sensors), now: 20)
    #expect(!idle.sensorsFresh)
    #expect(HumanOutput.view(idle, verbose: false, width: 200).contains("Idle cached readings 10.0s old"))
    let overdue = presentationView(SchedulerState(sensors: sensors), now: 28)
    #expect(HumanOutput.view(overdue, verbose: false, width: 200).contains("Sampling overdue"))
    let stopped = presentationView(SchedulerState(sensors: sensors), now: 20, running: false)
    #expect(HumanOutput.view(stopped, verbose: false, width: 200).contains("Sampling stopped"))
    let task = ScheduledTask(
        id: UUID().uuidString, name: "build", pid: 0, arguments: [], requirements: TaskRequirements())
    let queued = SchedulerState(tasks: [task], sensors: sensors)
    #expect(SchedulingPolicy.reason(for: task, in: queued, now: 20) == "waiting for fresh sensors")
    #expect(
        HumanOutput.view(presentationView(queued, now: 20), verbose: false, width: 200).contains("Sampling overdue"))
}

@Test func `view exposes measured blockers cooldown conditions and expected sensor pauses`() {
    var request = TaskRequirements(measurement: true, temperatureGuard: TemperatureGuard(cooldown: 5))
    var next = ScheduledTask(
        id: UUID().uuidString, name: "benchmark", pid: 0, arguments: [], requirements: request, coolSince: 8)
    let state = SchedulerState(tasks: [next], sensors: presentationSensors())
    let text = HumanOutput.view(presentationView(state), verbose: false, width: 200)
    #expect(text.contains("3.0s remaining if conditions stay satisfied"))
    #expect(text.contains("not a start-time estimate"))
    request.temperatureGuard = TemperatureGuard(cooldown: 0)
    next.requirements = request
    let busy = presentationView(SchedulerState(tasks: [next], sensors: presentationSensors()))
    #expect(busy.tasks.first?.blockerDetail?.contains("CPU activity 10.0%; requires ≤") == true)
    var running = next
    running.state = .running
    let paused = presentationView(
        SchedulerState(tasks: [running], sensors: presentationSensors()), now: 100, latch: "exclusive")
    let pausedText = HumanOutput.view(paused, verbose: false, width: 200)
    #expect(paused.samplingPaused)
    #expect(pausedText.contains("Sampling paused during exclusive work"))
    #expect(pausedText.contains("Last read"))
    var failed = state
    failed.sensorError = "temperature access failed"
    #expect(HumanOutput.view(presentationView(failed), verbose: false).contains("Sensors    Failed"))
}

@Test func `tables retain full IDs escape terminal controls and include accepted unlaunched work`() throws {
    let fixture = try Fixture()
    let record = DurableJobRecord(
        id: UUID().uuidString,
        submission: try MCPSubmission([
            "requestKey": "presentation-test", "name": "build\n\u{1B}[31m\u{202e}",
            "executable": "/usr/bin/true", "workingDirectory": .string(fixture.directory.path),
        ]))
    let view = presentationView(SchedulerState(jobs: [record]))
    #expect(view.jobs.count == 1)
    #expect(view.jobs.first?.blockedBy == "waiting for supervisor state")
    for width in [20, 60, 100, 160] {
        let text = HumanOutput.list(view.jobs, verbose: false, width: width)
        #expect(text.contains(record.id))
        #expect(!text.contains("\u{1B}"))
        #expect(!text.contains("\u{202e}"))
    }
    let text = HumanOutput.list(view.jobs, verbose: false, width: 160)
    #expect(text.contains("\\n\\u{1b}[31m\\u{202e}"))
    var jobs = view.jobs
    for _ in 0..<12 {
        var job = jobs[0]
        job.jobID = UUID().uuidString
        jobs.append(job)
    }
    #expect(HumanOutput.list(jobs, verbose: false, width: 160).contains("3 more outstanding jobs"))
    #expect(!HumanOutput.list(jobs, verbose: true, width: 160).contains("more outstanding"))
    #expect(HumanOutput.sensors(presentationSensors(), verbose: true).contains("GiB"))
}

@Test func `narrow output accounts for wide Unicode and combining characters`() {
    for text in [String(repeating: "界", count: 20), String(repeating: "🚀", count: 20)] {
        let lines = HumanOutput.wrap(text, width: 20).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.count == 10 })
    }
    let accent = String(repeating: "e\u{301}", count: 40)
    #expect(HumanOutput.wrap(accent, width: 20).split(separator: "\n").count == 2)
}
