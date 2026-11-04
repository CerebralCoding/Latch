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
    /// Seconds a head-of-queue job may stay short of memory that no Latch job can release before it ends as
    /// unsatisfiable. nil uses `SchedulingPolicy.defaultStallTimeout`; 0 waits indefinitely.
    var stallTimeout: Double?

    func validate(
        cpuCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        memoryMiB total: Int = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
    ) throws {
        try temperatureGuard?.validate()
        guard !measurement || mode == .isolated else { throw LatchError("measurements require exclusive admission") }
        guard cpuCores > 0 else { throw LatchError("--cpu requires at least one core") }
        guard memoryMiB > 0 else { throw LatchError("--memory-mib requires a positive MiB count") }
        if let stallTimeout, !stallTimeout.isFinite || stallTimeout < 0 {
            throw LatchError("--stall-timeout requires seconds of 0 or more")
        }
        guard cpuCores <= cpuCount else {
            throw LatchError(
                "capacity: --cpu \(cpuCores) exceeds the \(cpuCount) cores this machine has; this request can never be admitted",
                admissionReason: "capacity")
        }
        let grantable = SchedulingPolicy.grantableMemoryMiB(total: total)
        guard memoryMiB <= grantable else {
            throw LatchError(
                "capacity: --memory-mib \(memoryMiB) exceeds the \(grantable) MiB this machine can grant "
                    + "(\(total) MiB total minus the \(SchedulingPolicy.memoryReserveMiB(total: total)) MiB 10% reserve); "
                    + "this request can never be admitted",
                admissionReason: "capacity")
        }
    }
}

/// A shortfall that waiting cannot fix because no Latch job holds the missing resource.
struct AdmissionStall: Equatable {
    enum Kind: String { case memory }

    var kind: Kind
    var neededMiB: Int
    var headroomMiB: Int

    /// What the submitter is told when the job ends; `elapsed` is how long the shortfall has stood.
    func message(elapsed: Double) -> String {
        "unsatisfiable: needs \(HumanOutput.memory(Double(neededMiB))) additional \(kind.rawValue) but only "
            + "\(HumanOutput.memory(Double(headroomMiB))) is available after the 10% reserve, and no Latch job is "
            + "running or holding memory, so waiting cannot help (short for \(HumanOutput.duration(elapsed)), the stall timeout)"
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
    var aneActivity: ANEActivity?
    var cpuWatts: Double?
    var gpuWatts: Double?

    func aneQuietBlocker(limits: QuietLimits) -> String? {
        guard let aneWatts, aneWatts.isFinite, aneWatts >= 0 else { return "ANE power unavailable or invalid" }
        if let activity = aneActivity {
            guard (0...1).contains(activity.fraction) else { return "invalid ANE activity" }
            if activity.source != .powerFloor, activity.fraction > QuietLimits.aneActivity {
                return "background ANE activity"
            }
        }
        return aneWatts > limits.aneWatts ? "background ANE load" : nil
    }

    func quietBlocker(baseline: IdleBaseline?) -> String? {
        guard let gpuActive, aneWatts != nil, let diskBytesPerSecond else { return "required sensors unavailable" }
        let limits = QuietLimits(baseline: baseline, aneActivity: aneActivity)
        guard cpuActive >= 0, cpuActive <= limits.cpuActive else {
            return "background CPU load"
        }
        guard busiestCore >= 0, busiestCore <= limits.busiestCore else {
            return "background single-core CPU load"
        }
        guard gpuActive >= 0, gpuActive <= limits.gpuActive else {
            return "background GPU load"
        }
        if let blocker = aneQuietBlocker(limits: limits) { return blocker }
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
    var queuedUptime = ProcessInfo.processInfo.systemUptime
    var startedAt: Date?
    var waitingFor: String?
    var coolSince: Double?
    var residentMemoryMiB: Int?
    var plan: TaskPlan?
    var admission: AdmissionSnapshot?
    /// Uptime at which this job, at the head of the queue, first found itself short of memory that no Latch job
    /// holds. Cleared when the shortfall ends.
    var stalledSince: Double?
    /// Who queued the job and from which session. Both are self-declared labels for operators, never an authorization.
    var owner: String?
    var sessionID: String?
}

struct SchedulerState: Codable, Equatable {
    static let schemaVersion = 1
    var version = Self.schemaVersion
    var jobs: [DurableJobRecord] = []
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

    /// The readings admission may act on: no sensor error and a sample no older than `maximumSampleAge`.
    func currentSensors(now: Double) -> SensorSnapshot? {
        guard sensorError == nil, let sensors, (0...SchedulingPolicy.maximumSampleAge).contains(now - sensors.uptime)
        else { return nil }
        return sensors
    }

    var hasActiveWork: Bool { tasks.contains { $0.state == .running || $0.state == .cancelling } }

    mutating func record(_ snapshot: SensorSnapshot, workloadActive: Bool = false) {
        let active = workloadActive || hasActiveWork
        let previous = sensors
        sensors = snapshot
        sensorError = nil
        lastSensorAttempt = snapshot.uptime
        if let baseline = idleBaseline, snapshot.uptime < baseline.uptime {
            idleBaseline = nil
        }
        if !active, let sample = IdleReading(snapshot) {
            if idleBaseline == nil { idleBaseline = IdleBaseline() }
            idleBaseline?.observe(sample, allowIncrease: tasks.isEmpty)
        }
        for index in tasks.indices where tasks[index].state == .queued {
            guard let guardrail = tasks[index].requirements.temperatureGuard else { continue }
            if (active && tasks[index].requirements.measurement) || !guardrail.satisfied(by: snapshot) {
                tasks[index].coolSince = nil
            } else if tasks[index].coolSince == nil || previous == nil
                || snapshot.uptime < previous!.uptime
                || snapshot.uptime - previous!.uptime > SchedulingPolicy.maximumSampleAge
            {
                tasks[index].coolSince = snapshot.uptime
            }
        }
        if active || snapshot.quietBlocker(baseline: idleBaseline) != nil {
            quietSince = nil
            quietPeak = nil
        } else if quietSince == nil || previous == nil
            || snapshot.uptime - previous!.uptime > 2 || snapshot.uptime < previous!.uptime
            || snapshot.aneActivity?.source != previous!.aneActivity?.source
        {
            quietSince = snapshot.uptime
            quietPeak = snapshot
        } else {
            var peak = snapshot
            let prior = quietPeak ?? previous!
            peak.cpuActive = max(prior.cpuActive, snapshot.cpuActive)
            peak.busiestCore = max(prior.busiestCore, snapshot.busiestCore)
            peak.gpuActive = max(prior.gpuActive ?? 0, snapshot.gpuActive ?? 0)
            // Keep power and floor evidence paired, retaining the observation with the least idle margin.
            if (prior.aneWatts ?? 0) - QuietLimits.anePowerAllowance(for: prior.aneActivity)
                > (snapshot.aneWatts ?? 0) - QuietLimits.anePowerAllowance(for: snapshot.aneActivity)
            {
                peak.aneWatts = prior.aneWatts
                peak.aneActivity = prior.aneActivity
            }
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
    /// Long enough to ride out transient pressure and a process that is still tearing down, short enough that a
    /// request nothing will satisfy does not hold the queue for the length of a coffee break.
    static let defaultStallTimeout = 300.0

    /// Admission keeps a tenth of physical memory free.
    static func memoryReserveMiB(total: Int) -> Int { total / 10 }

    /// The most memory any reservation could ever be granted on a machine with `total` MiB.
    static func grantableMemoryMiB(total: Int) -> Int { total - memoryReserveMiB(total: total) }

    /// Available memory beyond the reserve, before any Latch reservation is subtracted.
    static func memoryHeadroomMiB(sensors: SensorSnapshot) -> Int {
        sensors.memoryAvailableMiB - memoryReserveMiB(total: sensors.memoryTotalMiB)
    }

    /// The job's memory shortfall when waiting on the queue cannot clear it: the job heads the queue, sensors are
    /// current, and no other Latch job runs, parks, cancels or holds resident memory that could be released. Heat,
    /// memory pressure, guards and quiet windows are separate waits; they neither create nor hide a stall.
    static func stall(for task: ScheduledTask, in state: SchedulerState, now: Double) -> AdmissionStall? {
        guard task.state == .queued, state.tasks.first(where: { $0.state == .queued })?.id == task.id,
            let sensors = state.currentSensors(now: now),
            !state.tasks.contains(where: {
                $0.id != task.id && ($0.state != .queued || $0.residentMemoryMiB != nil)
            })
        else { return nil }
        let needed = max(0, task.requirements.memoryMiB - (task.residentMemoryMiB ?? 0))
        let headroom = memoryHeadroomMiB(sensors: sensors)
        guard needed > headroom else { return nil }
        return AdmissionStall(kind: .memory, neededMiB: needed, headroomMiB: max(0, headroom))
    }

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
        guard reservedMemory + additionalMemory <= memoryHeadroomMiB(sensors: sensors) else {
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
