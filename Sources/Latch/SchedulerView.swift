import Foundation

struct SchedulerView: Encodable {
    struct Capacity: Encodable {
        var totalCPUCores: Int
        var reservedCPUCores: Int
        var unreservedCPUCores: Int
        var reservedMemoryMiB: Int
        var batchCPUHeadroom: Int?
        var ordinaryCPUHeadroom: Int?
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
        var blockerDetail: String?
        var cooldownRemainingSeconds: Double?
    }

    static let schemaVersion = 1
    let version = Self.schemaVersion
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
    var samplingPaused: Bool
    var samplingPausedReason: String?
    var tasks: [Task] = []
    var jobs: [JobSummary] = []

    init(scheduler: Scheduler) throws {
        let state = try scheduler.snapshot()
        self.init(
            state: state, service: try SchedulerService.status(in: scheduler.directory),
            processLatch: try Self.latchState(path: scheduler.path), now: ProcessInfo.processInfo.systemUptime)
    }

    init(state: SchedulerState, service: SchedulerService.Status, processLatch: String, now: Double) {
        self.service = service
        self.processLatch = processLatch
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
        samplingPausedReason =
            if !service.running { nil } else if processLatch == "exclusive" || isolatedTaskRunning {
                "exclusive work"
            } else if drainingForTaskID != nil {
                "draining running work"
            } else if !state.tasks.isEmpty && nextTaskID == nil { "no ready admission" } else { nil }
        samplingPaused = samplingPausedReason != nil
        let cpu = running.reduce(0) { $0 + $1.requirements.cpuCores }
        let memory = running.reduce(0) { $0 + $1.requirements.memoryMiB }
        capacity = Capacity(
            totalCPUCores: state.sensors?.cpuCores ?? ProcessInfo.processInfo.activeProcessorCount,
            reservedCPUCores: cpu,
            unreservedCPUCores: max(0, (state.sensors?.cpuCores ?? ProcessInfo.processInfo.activeProcessorCount) - cpu),
            reservedMemoryMiB: memory,
            gpuReserved: running.contains { $0.requirements.gpu },
            ioReserved: running.contains { $0.requirements.io },
            bandwidthReserved: running.contains { $0.requirements.bandwidth })
        capacity.parkedResidentMemoryMiB = state.tasks.filter { $0.state != .running }.reduce(0) {
            $0 + ($1.residentMemoryMiB ?? 0)
        }
        if sensorsFresh, let sensors {
            capacity.batchCPUHeadroom = SchedulingPolicy.cpuHeadroom(in: state, sensors: sensors, ordinary: false)
            capacity.ordinaryCPUHeadroom = SchedulingPolicy.cpuHeadroom(in: state, sensors: sensors, ordinary: true)
            capacity.memoryHeadroomMiB = max(0, sensors.memoryAvailableMiB - sensors.memoryTotalMiB / 10 - memory)
        }
        var position = 0
        let records = Dictionary(uniqueKeysWithValues: state.jobs.filter { !$0.complete }.map { ($0.id, $0) })
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
            if records[task.id]?.state == "cancelling" { blocked = "cancellation in progress" }
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
                blockerDetail: Self.detail(blocked, task: task, state: state, now: now),
                cooldownRemainingSeconds: remaining)
        }
        if let head = tasks.first(where: { $0.task.state == .queued }) {
            for index in tasks.indices where tasks[index].blockedBy == "waiting for earlier queued tasks" {
                tasks[index].blockerDetail =
                    "FIFO: earlier \(JobSummary.classification(head.task.requirements)) job \(head.task.name) (\(head.task.id)) is next. "
                    + (head.blockerDetail ?? "Eligible at this snapshot; admission is not reserved")
            }
        }
        for index in tasks.indices where tasks[index].task.state == .queued {
            let elapsed = max(0, now - tasks[index].task.queuedUptime)
            if elapsed >= 60, let detail = tasks[index].blockerDetail {
                tasks[index].blockerDetail =
                    "\(detail). Queue age \(HumanOutput.duration(elapsed)); this is the current blocker, not the cause of the entire wait"
            }
        }
        jobs = tasks.map { JobSummary(task: $0, record: records[$0.task.id], observedAt: observedAt) }
        let taskIDs = Set(tasks.map { $0.task.id })
        jobs += state.jobs.filter { !$0.complete && !taskIDs.contains($0.id) }
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
            .map { JobSummary(record: $0, observedAt: observedAt) }
    }

    func admissionProgress(for id: String) -> (message: String, identity: String)? {
        guard let entry = tasks.first(where: { $0.task.id == id && $0.task.state == .queued }),
            jobs.first(where: { $0.jobID == id })?.state != "cancelling"
        else { return nil }
        let head = tasks.first { $0.task.state == .queued }
        let runningIDs = tasks.filter { $0.task.state == .running }.map { $0.task.id }.sorted()
        let identity = [entry.blockedBy ?? "eligible", head?.task.id ?? "", head?.blockedBy ?? ""] + runningIDs
        return (
            entry.blockerDetail ?? "Eligible at this snapshot; admission is not reserved",
            identity.joined(separator: "|")
        )
    }

    private static func detail(_ reason: String?, task: ScheduledTask, state: SchedulerState, now: Double) -> String? {
        guard let reason else { return nil }
        if reason == "isolated task is running" || reason == "waiting for running tasks to drain" {
            let running = state.tasks.filter { $0.state == .running }
            let names = running.prefix(3).map { "\($0.name) (\($0.id))" }.joined(separator: "; ")
            let extra = running.count > 3 ? "; and \(running.count - 3) more" : ""
            return
                "Waiting for running work: \(names)\(extra). Running jobs finish without preemption or a runtime limit"
        }
        guard let sensors = state.sensors else { return reason }
        let limits = QuietLimits(baseline: state.idleBaseline)
        switch reason {
        case "waiting for a quiet window: background CPU load":
            func precise(_ value: Double) -> String {
                String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
            }
            let cores = Double(sensors.cpuCores)
            let baseline = state.idleBaseline.map { precise($0.cpuActive * 100) + "%" } ?? "not calibrated"
            return
                "CPU activity \(precise(sensors.cpuActive * 100))%; requires ≤\(precise(limits.cpuActive * 100))% "
                + "(idle baseline \(baseline), excess \(precise(max(0, sensors.cpuActive - limits.cpuActive) * 100)) percentage points). "
                + "Unweighted busy-core equivalents \(precise(sensors.cpuActive * cores)) / limit \(precise(limits.cpuActive * cores)) across \(sensors.cpuCores) cores. "
                + "Measurement quiet limits do not relax with waiting; no process attribution is available"
        case "waiting for a quiet CPU/GPU/ANE/disk window":
            let elapsed = state.quietSince.map { max(0, min(now, sensors.uptime) - $0) } ?? 0
            return
                "Measurement activity is below the quiet limits; observed quiet interval \(HumanOutput.duration(elapsed)) / \(HumanOutput.duration(SchedulingPolicy.quietPeriod)). Excess activity or a sampling gap restarts this interval"
        case "waiting for a quiet window: background single-core CPU load":
            return
                "Busiest core \(HumanOutput.percent(sensors.busiestCore)); requires ≤\(HumanOutput.percent(limits.busiestCore))"
        case "waiting for a quiet window: background GPU load":
            return
                "GPU activity \(HumanOutput.percent(sensors.gpuActive)); requires ≤\(HumanOutput.percent(limits.gpuActive))"
        case "waiting for a quiet window: background ANE load":
            return "ANE \(HumanOutput.number(sensors.aneWatts)) W; requires ≤\(HumanOutput.number(limits.aneWatts)) W"
        case "waiting for a quiet window: background disk I/O":
            return
                "Disk \(HumanOutput.memory((sensors.diskBytesPerSecond ?? 0) / 1_048_576))/s; requires ≤\(HumanOutput.memory(limits.diskBytesPerSecond / 1_048_576))/s"
        case "background CPU load": return "CPU activity \(HumanOutput.percent(sensors.cpuActive)); requires ≤80%"
        case "CPU reservation capacity":
            return
                "Needs \(task.requirements.cpuCores) CPU cores; running reservations use \(state.tasks.filter { $0.state == .running }.reduce(0) { $0 + $1.requirements.cpuCores }) of \(sensors.cpuCores)"
        case "insufficient CPU headroom":
            return
                "Needs \(task.requirements.cpuCores) CPU cores; CPU activity \(HumanOutput.percent(sensors.cpuActive)), headroom \(SchedulingPolicy.cpuHeadroom(in: state, sensors: sensors, ordinary: task.plan != nil)) cores"
        case "insufficient memory headroom":
            let reserved = state.tasks.filter { $0.state == .running }.reduce(0) { $0 + $1.requirements.memoryMiB }
            let available = max(0, sensors.memoryAvailableMiB - sensors.memoryTotalMiB / 10 - reserved)
            let additional = max(0, task.requirements.memoryMiB - (task.residentMemoryMiB ?? 0))
            return
                "Needs \(HumanOutput.memory(Double(additional))) additional memory; headroom \(HumanOutput.memory(Double(available))) after reservations and the 10% reserve"
        case let reason where reason.hasPrefix("temperature guard:"):
            guard let guardrail = task.requirements.temperatureGuard else { return reason }
            return
                "CPU \(HumanOutput.temperature(sensors.cpuTemperature)); requires ≤\(HumanOutput.temperature(guardrail.maxCPU)) · GPU \(HumanOutput.temperature(sensors.gpuTemperature)); requires ≤\(HumanOutput.temperature(guardrail.maxGPU))"
        default: return reason
        }
    }

    static func latchState(path: String) throws -> String {
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
