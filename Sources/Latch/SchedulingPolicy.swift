import Foundation

struct TaskRequirements: Codable, Equatable {
    enum Mode: String, Codable { case isolated, batch }

    var mode: Mode = .isolated
    var cpuCores = 1
    var memoryMiB = 512
    var gpu = false
    var io = false
    var bandwidth = false
    var measurement = false
    var temperatureGuard: TemperatureGuard?

    func validate() throws {
        try temperatureGuard?.validate()
        guard !measurement || mode == .isolated else { throw LatchError("measurements require exclusive admission") }
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
        let limits = QuietLimits(baseline: baseline)
        guard cpuActive >= 0, cpuActive <= limits.cpuActive else {
            return "background CPU load"
        }
        guard busiestCore >= 0, busiestCore <= limits.busiestCore else {
            return "background single-core CPU load"
        }
        guard gpuActive >= 0, gpuActive <= limits.gpuActive else {
            return "background GPU load"
        }
        guard aneWatts >= 0, aneWatts <= limits.aneWatts else { return "background ANE load" }
        guard diskBytesPerSecond >= 0, diskBytesPerSecond <= limits.diskBytesPerSecond else {
            return "background disk I/O"
        }
        guard memoryPressure == "normal" else { return "memory pressure is \(memoryPressure)" }
        guard thermalState == "nominal" else { return "thermal state is \(thermalState)" }
        return nil
    }
}

struct ScheduledTask: Codable, Equatable, Identifiable {
    enum State: String, Codable { case queued, running, parked, cancelling }

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
    var plan: TaskPlan?
    var admission: AdmissionSnapshot?
}

struct SchedulerState: Codable, Equatable {
    var version = 1
    var jobs: [DurableJobRecord]?
    var tasks: [ScheduledTask] = []
    var sensors: SensorSnapshot?
    var sensorError: String?
    var lastSensorAttempt: Double?
    var quietSince: Double?
    var quietPeak: SensorSnapshot?
    var idleBaseline: IdleBaseline?

    mutating func resetCooldowns() {
        quietSince = nil
        quietPeak = nil
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
        if !tasks.contains(where: { $0.state == .running }), let sample = IdleReading(snapshot) {
            if idleBaseline == nil { idleBaseline = IdleBaseline() }
            idleBaseline?.observe(sample, allowIncrease: tasks.isEmpty)
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
        if tasks.contains(where: { $0.state == .running }) || snapshot.quietBlocker(baseline: idleBaseline) != nil {
            quietSince = nil
            quietPeak = nil
        } else if quietSince == nil || previous == nil
            || snapshot.uptime - previous!.uptime > 2 || snapshot.uptime < previous!.uptime
        {
            quietSince = snapshot.uptime
            quietPeak = snapshot
        } else {
            var peak = snapshot
            let prior = quietPeak ?? previous!
            peak.cpuActive = max(prior.cpuActive, snapshot.cpuActive)
            peak.busiestCore = max(prior.busiestCore, snapshot.busiestCore)
            peak.gpuActive = max(prior.gpuActive ?? 0, snapshot.gpuActive ?? 0)
            peak.aneWatts = max(prior.aneWatts ?? 0, snapshot.aneWatts ?? 0)
            peak.diskBytesPerSecond = max(prior.diskBytesPerSecond ?? 0, snapshot.diskBytesPerSecond ?? 0)
            if peak.quietBlocker(baseline: idleBaseline) != nil {
                quietSince = snapshot.uptime
                quietPeak = snapshot
            } else {
                quietPeak = peak
            }
        }
    }
}

enum SchedulingPolicy {
    static let sampleInterval = 1.0
    static let maximumSampleAge = 2.0
    static let quietPeriod = 2.0

    static func cpuHeadroom(in state: SchedulerState, sensors: SensorSnapshot, ordinary: Bool) -> Int {
        let running = state.tasks.filter { $0.state == .running }
        let reserved = running.reduce(0) { $0 + $1.requirements.cpuCores }
        guard (0...1).contains(sensors.cpuActive) else { return 0 }
        if ordinary, !running.isEmpty, running.allSatisfy({ $0.plan != nil && $0.requirements.mode == .batch }) {
            return max(0, sensors.cpuCores - reserved)
        }
        guard sensors.cpuActive <= 0.8 else { return 0 }
        return max(
            0,
            Int(floor(Double(sensors.cpuCores) - max(Double(reserved), sensors.cpuActive * Double(sensors.cpuCores)))))
    }

    static func reason(for task: ScheduledTask, in state: SchedulerState, now: Double) -> String? {
        if task.state == .cancelling { return "queued task cancelled by operator" }
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
        let ordinary = task.plan != nil && request.mode == .batch
        let runningOrdinary = running.filter { $0.plan != nil && $0.requirements.mode == .batch }
        if ordinary, let lastSample = runningOrdinary.compactMap({ $0.admission?.sensors.uptime }).max(),
            sensors.uptime <= lastSample
        {
            return "waiting for sensors after ordinary admission"
        }
        let reservedMemory = running.reduce(0) { $0 + $1.requirements.memoryMiB }
        guard reservedCPU + request.cpuCores <= sensors.cpuCores else { return "CPU reservation capacity" }
        // Count outstanding reservations conservatively even if some are already resident.
        // Parked allocations are already reflected in available memory; reserve only additional headroom on resume.
        let additionalMemory = max(0, request.memoryMiB - (task.residentMemoryMiB ?? 0))
        guard reservedMemory + additionalMemory <= sensors.memoryAvailableMiB - sensors.memoryTotalMiB / 10 else {
            return "insufficient memory headroom"
        }
        if request.measurement {
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
        } else if request.mode == .batch {
            // Admitted ordinary work already contributes to observed CPU load. Bound its
            // concurrency instead of treating its own activity as unrelated contention.
            let sharedOrdinaryLoad = ordinary && !runningOrdinary.isEmpty && runningOrdinary.count == running.count
            guard (0...1).contains(sensors.cpuActive) else { return "invalid CPU activity" }
            guard sharedOrdinaryLoad || sensors.cpuActive <= 0.8 else { return "background CPU load" }
            guard
                request.cpuCores <= cpuHeadroom(in: state, sensors: sensors, ordinary: ordinary)
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
        } else if !(0...0.8).contains(sensors.cpuActive) {
            return "background CPU load"
        }
        return nil
    }
}
