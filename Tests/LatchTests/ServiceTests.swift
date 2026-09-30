import Darwin
import Foundation
import Testing

@testable import Latch

@Test func `command link installation is repeatable and preserves unrelated files`() throws {
    let fixture = try Fixture()
    let link = fixture.directory.appendingPathComponent("bin/latch")
    let target = fixture.directory.appendingPathComponent("installed/latch")
    let manager = FileManager.default
    try ServiceInstallation.installCommandLink(at: link, target: target)
    try ServiceInstallation.installCommandLink(at: link, target: target)
    #expect(try manager.destinationOfSymbolicLink(atPath: link.path) == target.path)
    try ServiceInstallation.removeCommandLink(at: link, target: target)
    try Data("another executable".utf8).write(to: link)
    #expect(throws: LatchError.self) { try ServiceInstallation.installCommandLink(at: link, target: target) }
    try ServiceInstallation.removeCommandLink(at: link, target: target)
    #expect(try String(contentsOf: link, encoding: .utf8) == "another executable")
    try manager.removeItem(at: link)
    try manager.createSymbolicLink(atPath: link.path, withDestinationPath: "/missing/unrelated/latch")
    #expect(throws: LatchError.self) { try ServiceInstallation.installCommandLink(at: link, target: target) }
    try ServiceInstallation.removeCommandLink(at: link, target: target)
    #expect(try manager.destinationOfSymbolicLink(atPath: link.path) == "/missing/unrelated/latch")
}

private func coolSensors(at uptime: Double) -> SensorSnapshot {
    SensorSnapshot(
        sampledAt: Date(), uptime: uptime, cpuCores: 8, cpuActive: 0, busiestCore: 0,
        gpuActive: 0, aneWatts: 0, memoryAvailableMiB: 24000, memoryTotalMiB: 32000,
        memoryPressure: "normal", thermalState: "nominal", diskBytesPerSecond: 0,
        unavailable: [], cpuTemperature: 40, gpuTemperature: 38)
}

@Test func `temperature cooldown requires consecutive cool readings and resets after gaps`() {
    let request = TaskRequirements(mode: .batch, temperatureGuard: TemperatureGuard(cooldown: 2))
    let task = ScheduledTask(id: UUID().uuidString, name: "guard", pid: getpid(), arguments: [], requirements: request)
    var state = SchedulerState(tasks: [task])
    state.record(coolSensors(at: 10))
    #expect(SchedulingPolicy.reason(for: state.tasks[0], in: state, now: 10) != nil)
    state.record(coolSensors(at: 11))
    state.record(coolSensors(at: 12))
    #expect(SchedulingPolicy.reason(for: state.tasks[0], in: state, now: 12) == nil)
    var hot = coolSensors(at: 13)
    hot.cpuTemperature = 60
    state.record(hot)
    #expect(state.tasks[0].coolSince == nil)
    #expect(SchedulingPolicy.reason(for: state.tasks[0], in: state, now: 13)?.contains("temperature guard") == true)
    state.record(coolSensors(at: 14))
    state.record(coolSensors(at: 18))
    #expect(state.tasks[0].coolSince == 18)
    state.record(coolSensors(at: 9))
    #expect(state.tasks[0].coolSince == 9)
    var missing = coolSensors(at: 10)
    missing.gpuTemperature = nil
    state.record(missing)
    #expect(
        SchedulingPolicy.reason(for: state.tasks[0], in: state, now: 10) == "CPU/GPU temperature sensors unavailable")
    #expect(TemperatureGuard(cooldown: 0).reason(sensors: coolSensors(at: 10), since: nil) == nil)
    #expect(TemperatureGuard(cooldown: 0).reason(sensors: missing, since: nil) != nil)
}

@Test func `SMC temperatures decode both formats and reject invalid readings`() {
    #expect(NativeSMC.decodeTemperature([0, 0, 32, 66], type: NativeSMC.key("flt ")) == 40)
    #expect(NativeSMC.decodeTemperature([40, 128], type: NativeSMC.key("sp78")) == 40.5)
    #expect(NativeSMC.decodeTemperature([255, 128], type: NativeSMC.key("sp78")) == nil)
    #expect(NativeSMC.decodeTemperature([0, 0, 128, 127], type: NativeSMC.key("flt ")) == nil)
    #expect(NativeSMC.decodeTemperature([0, 0], type: NativeSMC.key("sp78")) == nil)
    #expect(NativeSMC.decodeTemperature([40], type: NativeSMC.key("sp78")) == nil)
}

@Test func `service and guard options validate temperature limits`() throws {
    let options = try Options(arguments: [
        "guard", "--mode", "batch", "--max-cpu-temp", "48", "--max-gpu-temp", "49", "--cooldown", "3.5", "--timeout",
        "60",
    ])
    #expect(options.requirements.temperatureGuard == TemperatureGuard(maxCPU: 48, maxGPU: 49, cooldown: 3.5))
    #expect(try Options(arguments: ["service", "install"]).serviceAction == .install)
    for arguments in [
        ["service"], ["service", "start", "stop"], ["guard", "--cooldown", "nan"],
        ["guard", "--cooldown", "-1"], ["guard", "--max-cpu-temp", "126"],
        ["guard", "--max-gpu-temp", "0"], ["guard", "--", "true"], ["tasks", "--standalone"],
    ] {
        #expect(throws: LatchError.self) { try Options(arguments: arguments) }
    }
}

private func waitForTask(_ scheduler: Scheduler, state: ScheduledTask.State = .queued) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 4
    while ProcessInfo.processInfo.systemUptime < deadline {
        if try scheduler.snapshot().tasks.contains(where: { $0.state == state }) {
            return
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    throw LatchError("test task did not reach \(state)")
}

private func fakeService(_ scheduler: Scheduler) throws -> FileLatch {
    let lease = try FileLatch(path: scheduler.directory.appendingPathComponent("service.lock").path)
    try lease.acquire(shared: false, timeout: 0)
    let status = SchedulerService.Status(running: true, pid: getpid(), path: scheduler.path)
    try JSONEncoder().encode(status).write(
        to: scheduler.directory.appendingPathComponent("service.json"), options: .atomic)
    return lease
}

@Test func `service clients wake from published sensors and preserve command output`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try fakeService(scheduler)
    try withExtendedLifetime(service) {
        let child = try fixture.launch([
            "schedule", "--mode", "batch", "--cooldown", "2", "--", "/usr/bin/printf", "%s", "admitted",
        ])
        try waitForTask(scheduler)
        #expect(child.process.isRunning)
        #expect(try scheduler.snapshot().sensors == nil)
        let now = ProcessInfo.processInfo.systemUptime
        try scheduler.transaction {
            $0.record(coolSensors(at: now - 2))
            $0.record(coolSensors(at: now - 1))
            $0.record(coolSensors(at: now))
        }
        #expect(try fixture.finish(child) == 0)
        #expect(child.output == "admitted")
        #expect(try scheduler.snapshot().tasks.isEmpty)
    }
}

@Test func `service loss fails parked clients closed without sampling behind measurement`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let holder = try FileLatch(path: fixture.lockPath)
    try holder.acquire(shared: false, timeout: 0)
    try withExtendedLifetime(holder) {
        let service = try fixture.launch(["service", "run"])
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while (try? SchedulerService.requireRunning(in: scheduler.directory)) == nil,
            ProcessInfo.processInfo.systemUptime < deadline
        {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(try SchedulerService.requireRunning(in: scheduler.directory) == service.process.processIdentifier)
        let duplicate = try fixture.launch(["service", "run"])
        #expect(try fixture.finish(duplicate) == 75)
        let child = try fixture.launch(["guard"])
        try waitForTask(scheduler)
        #expect(try scheduler.snapshot().lastSensorAttempt == nil)
        #expect(kill(service.process.processIdentifier, SIGTERM) == 0)
        #expect(try fixture.finish(service) == SIGTERM)
        #expect(try fixture.finish(child) == 69)
        #expect(try scheduler.snapshot().tasks.isEmpty)
        #expect(try !SchedulerService.status(in: scheduler.directory).running)
    }
}

@Test func `running commands retain leases after the service stops`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    var service: FileLatch? = try fakeService(scheduler)
    let child = try fixture.launch(["schedule", "--mode", "batch", "--cooldown", "0", "--", "/bin/sleep", "30"])
    try waitForTask(scheduler)
    try scheduler.transaction { $0.record(coolSensors(at: ProcessInfo.processInfo.systemUptime)) }
    try waitForTask(scheduler, state: .running)
    withExtendedLifetime(service) {}
    service = nil
    #expect(try !SchedulerService.status(in: scheduler.directory).running)
    #expect(child.process.isRunning)
    #expect(try scheduler.snapshot().tasks.first?.state == .running)
    let probe = try FileLatch(path: fixture.lockPath)
    #expect(throws: LatchError.self) { try probe.acquire(shared: false, timeout: 0) }
    #expect(kill(child.process.processIdentifier, SIGTERM) == 0)
    #expect(try fixture.finish(child) == SIGTERM)
    #expect(try scheduler.snapshot().tasks.isEmpty)
}

@Test func `guard times out without the client collecting sensors`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath)
    let service = try fakeService(scheduler)
    try withExtendedLifetime(service) {
        let child = try fixture.launch(["guard", "--timeout", "0.1"])
        #expect(try fixture.finish(child) == 75)
        #expect(child.errors.contains("fresh sensors"))
        #expect(try scheduler.snapshot().lastSensorAttempt == nil)
        #expect(try scheduler.snapshot().tasks.isEmpty)
    }
}

@Test func `launch agent configuration uses stable executable and the selected latch`() throws {
    let config = ServiceInstallation.configuration(
        executable: "/path with spaces/latch", path: "/state/custom.lock", logs: "/logs")
    let data = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
    let decoded = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(
        decoded["ProgramArguments"] as? [String] == [
            "/path with spaces/latch", "service", "run", "--file", "/state/custom.lock",
        ])
    #expect(decoded["KeepAlive"] as? Bool == true)
    #expect(decoded["RunAtLoad"] as? Bool == true)
    #expect(decoded["UserName"] == nil)
}

@Test func `planning view explains queue order headroom and stale sensors without sampling`() throws {
    let fixture = try Fixture()
    var samples = 0
    let scheduler = try Scheduler(path: fixture.lockPath) {
        samples += 1
        return coolSensors(at: ProcessInfo.processInfo.systemUptime)
    }
    let service = try fakeService(scheduler)
    let running = try scheduler.reserve(
        name: "build", arguments: [], requirements: TaskRequirements(mode: .batch, cpuCores: 2, memoryMiB: 2048),
        timeout: 0)
    let id = UUID().uuidString
    let lease = try FileLatch(path: scheduler.directory.appendingPathComponent(id + ".lease").path)
    try lease.acquire(shared: false, timeout: 0)
    try withExtendedLifetime((service, running, lease)) {
        try scheduler.transaction {
            $0.tasks.append(
                ScheduledTask(
                    id: id, name: "benchmark", pid: getpid(), arguments: [],
                    requirements: TaskRequirements(temperatureGuard: TemperatureGuard())))
        }
        let view = try SchedulerView(scheduler: scheduler)
        #expect(view.sensorsFresh)
        #expect(view.processLatch == "shared")
        #expect(view.capacity.reservedCPUCores == 2)
        #expect(view.capacity.batchCPUHeadroom == 6)
        #expect(view.capacity.memoryHeadroomMiB == 18752)
        #expect(view.nextTaskID == id)
        #expect(view.tasks[1].queuePosition == 1)
        #expect(view.tasks[1].blockedBy == "waiting for running tasks to drain")
        #expect(view.tasks[1].cooldownRemainingSeconds == 5)
        try scheduler.transaction { $0.sensors?.uptime -= 10 }
        let stale = try SchedulerView(scheduler: scheduler)
        #expect(!stale.sensorsFresh)
        #expect(stale.capacity.batchCPUHeadroom == nil)
        #expect(stale.capacity.memoryHeadroomMiB == nil)
        let child = try fixture.launch(["view"])
        #expect(try fixture.finish(child) == 0)
        let json = try #require(JSONSerialization.jsonObject(with: Data(child.output.utf8)) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        #expect(json["sensorsFresh"] as? Bool == false)
        #expect(samples == 1)
    }
}

@Test func `completion of running work restarts queued cooldowns`() throws {
    let fixture = try Fixture()
    let scheduler = try Scheduler(path: fixture.lockPath) { coolSensors(at: ProcessInfo.processInfo.systemUptime) }
    var running: TaskReservation? = try scheduler.reserve(
        name: "build", arguments: [], requirements: TaskRequirements(mode: .batch), timeout: 0)
    let id = UUID().uuidString
    let lease = try FileLatch(path: scheduler.directory.appendingPathComponent(id + ".lease").path)
    try lease.acquire(shared: false, timeout: 0)
    try withExtendedLifetime(lease) {
        try scheduler.transaction {
            $0.tasks.append(
                ScheduledTask(
                    id: id, name: "next", pid: getpid(), arguments: [],
                    requirements: TaskRequirements(temperatureGuard: TemperatureGuard()), coolSince: 1))
        }
        #expect(try scheduler.snapshot().tasks.last?.coolSince == 1)
        withExtendedLifetime(running) {}
        running = nil
        #expect(try scheduler.snapshot().tasks.last?.coolSince == nil)
    }
}
