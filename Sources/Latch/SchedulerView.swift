import Foundation

struct SchedulerView: Encodable {
    struct Capacity: Encodable {
        var totalCPUCores: Int
        var reservedCPUCores: Int
        var reservedMemoryMiB: Int
        var batchCPUHeadroom: Int?
        var memoryHeadroomMiB: Int?
        var gpuReserved: Bool
        var ioReserved: Bool
        var bandwidthReserved: Bool
        var parkedResidentMemoryMiB: Int = 0
    }

    struct Task: Encodable {
        var task: ScheduledTask
        var queuePosition: Int?
        var blockedBy: String?
        var cooldownRemainingSeconds: Double?
    }

    let version = 1
    let observedAt = Date()
    var service: SchedulerService.Status
    var processLatch: String
    var sensorAgeSeconds: Double?
    var sensorsFresh: Bool
    var sensors: SensorSnapshot?
    var idleBaseline: IdleBaseline?
    var quietLimits: QuietLimits
    var drainingForTaskID: String?
    var sensorError: String?
    var capacity: Capacity
    var nextTaskID: String?
    var isolatedTaskRunning: Bool
    var tasks: [Task] = []

    init(scheduler: Scheduler) throws {
        let state = try scheduler.snapshot()
        let now = ProcessInfo.processInfo.systemUptime
        service = try SchedulerService.status(in: scheduler.directory)
        processLatch = try Self.latchState(path: scheduler.path)
        sensors = state.sensors
        idleBaseline = state.idleBaseline
        idleBaseline?.readings = nil
        quietLimits = QuietLimits(baseline: state.idleBaseline)
        sensorError = state.sensorError
        sensorAgeSeconds = state.sensors.map { now - $0.uptime }
        sensorsFresh =
            sensorError == nil && sensorAgeSeconds.map { (0...SchedulingPolicy.maximumSampleAge).contains($0) } == true
        let running = state.tasks.filter { $0.state == .running }
        isolatedTaskRunning = running.contains { $0.requirements.mode == .isolated }
        nextTaskID = state.tasks.first { $0.state == .queued }?.id
        if let next = state.tasks.first(where: { $0.state == .queued }), next.requirements.mode == .isolated,
            !running.isEmpty
        {
            drainingForTaskID = next.id
        }
        let cpu = running.reduce(0) { $0 + $1.requirements.cpuCores }
        let memory = running.reduce(0) { $0 + $1.requirements.memoryMiB }
        capacity = Capacity(
            totalCPUCores: ProcessInfo.processInfo.activeProcessorCount,
            reservedCPUCores: cpu, reservedMemoryMiB: memory,
            gpuReserved: running.contains { $0.requirements.gpu },
            ioReserved: running.contains { $0.requirements.io },
            bandwidthReserved: running.contains { $0.requirements.bandwidth })
        capacity.parkedResidentMemoryMiB = state.tasks.filter { $0.state != .running }.reduce(0) {
            $0 + ($1.residentMemoryMiB ?? 0)
        }
        if sensorsFresh, let sensors {
            capacity.batchCPUHeadroom =
                sensors.cpuActive <= 0.8
                ? max(
                    0,
                    Int(
                        floor(Double(sensors.cpuCores) - max(Double(cpu), sensors.cpuActive * Double(sensors.cpuCores)))
                    )) : 0
            capacity.memoryHeadroomMiB = max(0, sensors.memoryAvailableMiB - sensors.memoryTotalMiB / 10 - memory)
        }
        var position = 0
        tasks = state.tasks.map { task in
            guard task.state == .queued else { return Task(task: task) }
            position += 1
            var blocked = SchedulingPolicy.reason(for: task, in: state, now: now)
            if blocked == nil,
                processLatch == "exclusive" || (processLatch == "shared" && task.requirements.mode == .isolated)
            {
                blocked = "waiting for the process latch"
            }
            if !service.running {
                blocked = "service stopped; requires service or --standalone"
            }
            let remaining: Double? =
                if let guardrail = task.requirements.temperatureGuard {
                    if sensorsFresh, let sensors, guardrail.satisfied(by: sensors), let since = task.coolSince {
                        max(0, guardrail.cooldown - (sensors.uptime - since))
                    } else {
                        guardrail.cooldown
                    }
                } else {
                    nil
                }
            return Task(
                task: task, queuePosition: position, blockedBy: blocked,
                cooldownRemainingSeconds: remaining)
        }
    }

    private static func latchState(path: String) throws -> String {
        let probe = try FileLatch(path: path)
        do {
            try probe.acquire(shared: false, timeout: 0)
            return "free"
        } catch let error as LatchError where error.exitCode == 75 {}
        do {
            try probe.acquire(shared: true, timeout: 0)
            return "shared"
        } catch let error as LatchError where error.exitCode == 75 {
            return "exclusive"
        }
    }
}
