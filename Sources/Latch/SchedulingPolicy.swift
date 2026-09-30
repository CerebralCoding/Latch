import Foundation

struct TaskRequirements: Codable, Equatable {
    enum Mode: String, Codable { case isolated, batch }

    var mode: Mode = .isolated
    var cpuCores = 1
    var memoryMiB = 512
    var gpu = false
    var io = false
    var bandwidth = false
    var temperatureGuard: TemperatureGuard?

    func validate() throws {
        try temperatureGuard?.validate()
        guard cpuCores > 0, cpuCores <= ProcessInfo.processInfo.activeProcessorCount else {
            throw LatchError("--cpu must fit this machine's available core count")
        }
        guard memoryMiB > 0, UInt64(memoryMiB) <= ProcessInfo.processInfo.physicalMemory / 1_048_576 else {
            throw LatchError("--memory-mib must fit this machine's physical memory")
        }
    }
}

struct SensorSnapshot: Codable, Equatable {
    var sampledAt: Date
    var uptime: Double
    var cpuCores: Int
    var cpuActive: Double
    var busiestCore: Double
    var gpuActive: Double?
    var aneWatts: Double?
    var memoryAvailableMiB: Int
    var memoryTotalMiB: Int
    var memoryPressure: String
    var thermalState: String
    var diskBytesPerSecond: Double?
    var unavailable: [String]
    var cpuTemperature: Double?
    var gpuTemperature: Double?

    func quietBlocker(baseline: IdleBaseline?) -> String? {
        guard let gpuActive, let aneWatts, let diskBytesPerSecond else { return "required sensors unavailable" }
        let idle = baseline ?? IdleBaseline()
        guard cpuActive >= 0, cpuActive <= idle.cpuActive + max(0.05, idle.cpuActive * 0.5) else {
            return "background CPU load"
        }
        guard busiestCore >= 0, busiestCore <= idle.busiestCore + max(0.25, idle.busiestCore * 0.5) else {
            return "background single-core CPU load"
        }
        guard gpuActive >= 0, gpuActive <= idle.gpuActive + max(0.02, idle.gpuActive * 0.5) else {
            return "background GPU load"
        }
        guard aneWatts >= 0, aneWatts <= idle.aneWatts + 0.1 else { return "background ANE load" }
        guard diskBytesPerSecond >= 0, diskBytesPerSecond <= idle.diskBytesPerSecond + 1_048_576 else {
            return "background disk I/O"
        }
        guard memoryPressure == "normal" else { return "memory pressure is \(memoryPressure)" }
        guard thermalState == "nominal" else { return "thermal state is \(thermalState)" }
        return nil
    }
}

struct IdleBaseline: Codable, Equatable {
    var cpuActive = 0.0
    var busiestCore = 0.0
    var gpuActive = 0.0
    var aneWatts = 0.0
    var diskBytesPerSecond = 0.0
    var uptime = 0.0
    var calibrationSamples = 0

    init() {}

    init?(_ sensors: SensorSnapshot) {
        guard let gpu = sensors.gpuActive, let ane = sensors.aneWatts, let disk = sensors.diskBytesPerSecond,
            (0...0.1).contains(sensors.cpuActive), (0...0.5).contains(sensors.busiestCore),
            (0...0.1).contains(gpu), (0...0.1).contains(ane), (0...1_048_576).contains(disk),
            sensors.memoryPressure == "normal", sensors.thermalState == "nominal"
        else { return nil }
        cpuActive = sensors.cpuActive
        busiestCore = sensors.busiestCore
        gpuActive = gpu
        aneWatts = ane
        diskBytesPerSecond = disk
        uptime = sensors.uptime
        calibrationSamples = 1
    }

    mutating func observe(_ sample: IdleBaseline, allowIncrease: Bool) {
        for field in [\Self.cpuActive, \.busiestCore, \.gpuActive, \.aneWatts, \.diskBytesPerSecond] {
            let current = self[keyPath: field]
            let measured = sample[keyPath: field]
            // Average startup readings; one unusually quiet sample must not collapse the baseline.
            let weight = calibrationSamples < 3 ? 1 / Double(calibrationSamples + 1) : 0.05
            if calibrationSamples < 3 || allowIncrease || measured < current {
                self[keyPath: field] = current + weight * (measured - current)
            }
        }
        uptime = sample.uptime
        calibrationSamples = min(3, calibrationSamples + 1)
    }
}

struct ScheduledTask: Codable, Equatable, Identifiable {
    enum State: String, Codable { case queued, running, parked }

    var id: String
    var name: String
    var pid: Int32
    var arguments: [String]
    var requirements: TaskRequirements
    var state: State = .queued
    var queuedAt = Date()
    var queuedUptime: Double? = ProcessInfo.processInfo.systemUptime
    var startedAt: Date?
    var waitingFor: String?
    var coolSince: Double?
    var residentMemoryMiB: Int?
}

struct SchedulerState: Codable, Equatable {
    var version = 1
    var jobs: [DurableJobRecord]?
    var tasks: [ScheduledTask] = []
    var sensors: SensorSnapshot?
    var sensorError: String?
    var lastSensorAttempt: Double?
    var quietSince: Double?
    var idleBaseline: IdleBaseline?

    mutating func resetCooldowns() {
        quietSince = nil
        for index in tasks.indices {
            tasks[index].coolSince = nil
        }
    }

    mutating func record(_ snapshot: SensorSnapshot) {
        let previous = sensors
        sensors = snapshot
        sensorError = nil
        lastSensorAttempt = snapshot.uptime
        if let baseline = idleBaseline, snapshot.uptime < baseline.uptime {
            idleBaseline = nil
        }
        if !tasks.contains(where: { $0.state == .running }), let sample = IdleBaseline(snapshot) {
            if idleBaseline == nil {
                idleBaseline = sample
            } else {
                idleBaseline?.observe(sample, allowIncrease: tasks.isEmpty)
            }
        }
        for index in tasks.indices where tasks[index].state == .queued {
            guard let guardrail = tasks[index].requirements.temperatureGuard else { continue }
            if !guardrail.satisfied(by: snapshot) {
                tasks[index].coolSince = nil
            } else if tasks[index].coolSince == nil || previous == nil
                || snapshot.uptime < previous!.uptime
                || snapshot.uptime - previous!.uptime > SchedulingPolicy.maximumSampleAge
            {
                tasks[index].coolSince = snapshot.uptime
            }
        }
        if snapshot.quietBlocker(baseline: idleBaseline) != nil {
            quietSince = nil
        } else if quietSince == nil || previous == nil
            || snapshot.uptime - previous!.uptime > 2 || snapshot.uptime < previous!.uptime
        {
            quietSince = snapshot.uptime
        }
    }
}

enum SchedulingPolicy {
    static let sampleInterval = 1.0
    static let maximumSampleAge = 2.0
    static let quietPeriod = 2.0

    static func reason(for task: ScheduledTask, in state: SchedulerState, now: Double) -> String? {
        let running = state.tasks.filter { $0.state == .running }
        let request = task.requirements
        guard state.tasks.first(where: { $0.state == .queued })?.id == task.id else {
            return "waiting for earlier queued tasks"
        }
        if running.contains(where: { $0.requirements.mode == .isolated }) {
            return "isolated task is running"
        }
        if request.mode == .isolated, !running.isEmpty {
            return "waiting for running tasks to drain"
        }
        if let error = state.sensorError {
            return "sensors unavailable: \(error)"
        }
        guard let sensors = state.sensors, now >= sensors.uptime,
            now - sensors.uptime <= maximumSampleAge
        else {
            return "waiting for fresh sensors"
        }
        guard sensors.thermalState == "nominal" else { return "thermal state is \(sensors.thermalState)" }
        guard sensors.memoryPressure == "normal" else { return "memory pressure is \(sensors.memoryPressure)" }
        if let guardrail = request.temperatureGuard,
            let reason = guardrail.reason(sensors: sensors, since: task.coolSince)
        {
            return reason
        }

        let reservedCPU = running.reduce(0) { $0 + $1.requirements.cpuCores }
        let reservedMemory = running.reduce(0) { $0 + $1.requirements.memoryMiB }
        guard reservedCPU + request.cpuCores <= sensors.cpuCores else { return "CPU reservation capacity" }
        // Count outstanding reservations conservatively even if some are already resident.
        // Parked allocations are already reflected in available memory; reserve only additional headroom on resume.
        let additionalMemory = max(0, request.memoryMiB - (task.residentMemoryMiB ?? 0))
        guard reservedMemory + additionalMemory <= sensors.memoryAvailableMiB - sensors.memoryTotalMiB / 10 else {
            return "insufficient memory headroom"
        }
        if request.mode == .isolated {
            guard sensors.gpuActive != nil, sensors.aneWatts != nil, sensors.diskBytesPerSecond != nil else {
                return "required sensors unavailable: \(sensors.unavailable.joined(separator: ", "))"
            }
            if let blocker = sensors.quietBlocker(baseline: state.idleBaseline) {
                return "waiting for a quiet window: \(blocker)"
            }
            guard let since = state.quietSince, now >= since,
                sensors.uptime - since >= quietPeriod
            else {
                return "waiting for a quiet CPU/GPU/ANE/disk window"
            }
        } else {
            guard sensors.cpuActive <= 0.8 else { return "background CPU load" }
            guard
                max(Double(reservedCPU), sensors.cpuActive * Double(sensors.cpuCores)) + Double(request.cpuCores)
                    <= Double(sensors.cpuCores)
            else {
                return "insufficient CPU headroom"
            }
            if request.gpu {
                guard !running.contains(where: \.requirements.gpu) else { return "GPU is reserved" }
                guard let activity = sensors.gpuActive, activity <= 0.02 else { return "GPU is busy or unavailable" }
            }
            if request.io {
                guard !running.contains(where: \.requirements.io) else { return "disk I/O is reserved" }
                guard let activity = sensors.diskBytesPerSecond, activity <= 1_048_576 else {
                    return "disk I/O is busy or unavailable"
                }
            }
            if request.bandwidth, running.contains(where: \.requirements.bandwidth) {
                return "memory bandwidth is reserved"
            }
        }
        return nil
    }
}
