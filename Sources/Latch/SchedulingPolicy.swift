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

    var quiet: Bool {
        guard let gpuActive, let aneWatts, let diskBytesPerSecond else { return false }
        return cpuActive <= 0.05 && busiestCore <= 0.25 && gpuActive <= 0.02
            && aneWatts <= 0.1 && diskBytesPerSecond <= 1_048_576
            && memoryPressure == "normal" && thermalState == "nominal"
    }
}

struct ScheduledTask: Codable, Equatable, Identifiable {
    enum State: String, Codable { case queued, running }

    var id: String
    var name: String
    var pid: Int32
    var arguments: [String]
    var requirements: TaskRequirements
    var state: State = .queued
    var queuedAt = Date()
    var startedAt: Date?
    var waitingFor: String?
    var coolSince: Double?
}

struct SchedulerState: Codable, Equatable {
    var version = 1
    var jobs: [DurableJobRecord]?
    var tasks: [ScheduledTask] = []
    var sensors: SensorSnapshot?
    var sensorError: String?
    var lastSensorAttempt: Double?
    var quietSince: Double?

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
        for index in tasks.indices where tasks[index].state == .queued {
            guard let guardrail = tasks[index].requirements.temperatureGuard else { continue }
            if !guardrail.satisfied(by: snapshot) {
                tasks[index].coolSince = nil
            } else if tasks[index].coolSince == nil || previous == nil
                || snapshot.uptime < previous!.uptime || snapshot.uptime - previous!.uptime > SchedulingPolicy.maximumSampleAge
            {
                tasks[index].coolSince = snapshot.uptime
            }
        }
        if !snapshot.quiet {
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
        guard reservedMemory + request.memoryMiB <= sensors.memoryAvailableMiB - sensors.memoryTotalMiB / 10 else {
            return "insufficient memory headroom"
        }
        if request.mode == .isolated {
            guard sensors.gpuActive != nil, sensors.aneWatts != nil, sensors.diskBytesPerSecond != nil else {
                return "required sensors unavailable: \(sensors.unavailable.joined(separator: ", "))"
            }
            guard sensors.quiet, let since = state.quietSince, now >= since,
                  sensors.uptime - since >= quietPeriod
            else {
                return "waiting for a quiet CPU/GPU/ANE/disk window"
            }
        } else {
            guard sensors.cpuActive <= 0.8 else { return "background CPU load" }
            guard max(Double(reservedCPU), sensors.cpuActive * Double(sensors.cpuCores)) + Double(request.cpuCores) <= Double(sensors.cpuCores) else {
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
