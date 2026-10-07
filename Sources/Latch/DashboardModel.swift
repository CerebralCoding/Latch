import Foundation

struct DashboardSnapshot {
    var view: SchedulerView
    var records: [DurableJobRecord]
    let history: [JobSummary]

    init(scheduler: Scheduler) throws {
        let state = try scheduler.snapshot()
        view = SchedulerView(
            state: state, service: try SchedulerService.status(in: scheduler.directory),
            processLatch: try SchedulerView.latchState(path: scheduler.path), now: ProcessInfo.processInfo.systemUptime)
        records = state.jobs
        history = Self.history(records, observedAt: view.observedAt)
    }

    init(view: SchedulerView, records: [DurableJobRecord] = []) {
        self.view = view
        self.records = records
        history = Self.history(records, observedAt: view.observedAt)
    }

    private static func history(_ records: [DurableJobRecord], observedAt: Date) -> [JobSummary] {
        records.filter(\.complete).map { JobSummary(record: $0, observedAt: observedAt) }
            .sorted {
                let left = $0.finishedAt ?? $0.createdAt
                let right = $1.finishedAt ?? $1.createdAt
                return left == right ? $0.jobID < $1.jobID : left > right
            }
    }

    var canControl: Bool { view.service.running && view.service.serviceRevision == BuildIdentity.serviceRevision }

    var totalJobs: Int { Set(view.jobs.map(\.jobID)).union(history.map(\.jobID)).count }
}

struct DashboardAlert: Equatable {
    var id: String
    var text: String
    var tone: DashboardTone
}

enum DashboardMetric: String, CaseIterable {
    case cpu = "CPU activity"
    case gpu = "GPU activity"
    case ane = "ANE activity"
    case memory = "Memory used"
    case cpuTemperature = "CPU temperature"
    case gpuTemperature = "GPU temperature"

    var ceiling: Double { self == .cpuTemperature || self == .gpuTemperature ? 125 : 100 }
    var unit: String { self == .cpuTemperature || self == .gpuTemperature ? "°C" : "%" }

    func value(_ sensors: SensorSnapshot) -> Double? {
        let value: Double? =
            switch self {
            case .cpu: sensors.cpuActive * 100
            case .gpu: sensors.gpuActive.map { $0 * 100 }
            case .memory:
                sensors.memoryTotalMiB > 0
                    ? 100 * (1 - Double(sensors.memoryAvailableMiB) / Double(sensors.memoryTotalMiB)) : nil
            case .cpuTemperature: sensors.cpuTemperature
            case .gpuTemperature: sensors.gpuTemperature
            case .ane: sensors.aneActivity.map { $0.fraction * 100 }
            }
        return value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    func tone(_ value: Double?, previous: DashboardTone = .good) -> DashboardTone {
        guard let value else { return .muted }
        let warning: Double
        let critical: Double
        switch self {
        case .cpuTemperature:
            warning = 75
            critical = 85
        case .gpuTemperature:
            warning = 70
            critical = 80
        case .memory:
            warning = 70
            critical = 85
        default:
            warning = 75
            critical = 90
        }
        if value >= critical || previous == .critical && value >= critical - 5 { return .critical }
        if value >= warning || previous == .warning && value >= warning - 5 { return .warning }
        return .good
    }
}

struct DashboardSample {
    var date: Date
    var values: [DashboardMetric: Double]
    var tones: [DashboardMetric: DashboardTone]
}

struct DashboardAction: Equatable {
    enum Kind { case prioritize, cancel, clear, stop }
    var kind: Kind
    var ids: Set<String>
    var names: [String]

    var title: String {
        switch kind {
        case .prioritize: "Prioritize this job?"
        case .cancel: "Cancel this job?"
        case .clear: "Clear \(ids.count) never-started jobs?"
        case .stop: "Stop \(ids.count) outstanding jobs?"
        }
    }

    var explanation: String {
        switch kind {
        case .prioritize: "Move this ticket to the front. Running work is not preempted; admission guards still apply."
        case .clear: "Cancel only the listed jobs if they still have never started. Started work is preserved."
        case .cancel, .stop:
            "Request cancellation, including running or parked work. Active workloads receive TERM, then KILL if needed. Results remain available."
        }
    }

    func perform(queue: OperatorQueue) throws -> String {
        switch kind {
        case .prioritize:
            guard let id = ids.first, ids.count == 1 else { throw LatchError("select one queued job") }
            try queue.prioritize(id)
            return "Prioritized \(id). Admission guards still apply."
        case .cancel, .clear, .stop:
            let cancelled = try queue.cancel(ids, onlyNeverStarted: kind == .clear)
            return "Cancellation requested for \(cancelled.count) job(s). Waiting for completion."
        }
    }
}

struct DashboardJobDetail {
    var job: JobSummary
    var task: ScheduledTask?
    var record: DurableJobRecord?
    var current: Bool
}

struct DashboardModel {
    enum Modal { case help, sensors }
    enum Sort: String, CaseIterable {
        case queue = "queue"
        case name = "name"
        case elapsed = "elapsed"
    }

    var snapshot: DashboardSnapshot?
    var sort = Sort.queue
    var showHistory = false
    var filter = ""
    var editingFilter = false
    var selectedID: String?
    var details = false {
        didSet {
            if details {
                if !oldValue { retainDetail() }
            } else {
                retainedDetail = nil
            }
        }
    }
    private(set) var retainedDetail: DashboardJobDetail?
    var detailOffset = 0
    var modal: Modal?
    var modalOffset = 0
    var paused = false
    var interval: Double
    var error: String?
    var notice = "Cached scheduler readings · ? for help"
    var confirmation: DashboardAction?
    var busy = false
    var outputID: String?
    var outputLines: [String] = []
    private(set) var samples: [DashboardSample] = []
    private(set) var alerts: [DashboardAlert] = []
    private var lastSensorUptime: Double?
    private var inGap = false
    static let historyLimit = 300

    var sensorHoldReason: String? {
        guard let view = snapshot?.view else { return "waiting" }
        if error != nil || view.sensorError != nil { return "unavailable" }
        if !view.service.running { return "stopped" }
        if view.samplingPaused { return "paused" }
        if paused { return "frozen" }
        guard view.sensors != nil else { return "waiting" }
        guard let age = view.sensorAgeSeconds, (0...SchedulingPolicy.maximumSampleAge).contains(age) else {
            return "stale"
        }
        return nil
    }

    var jobs: [JobSummary] {
        guard let snapshot else { return [] }
        var rows = showHistory ? snapshot.history : snapshot.view.jobs
        if !filter.isEmpty {
            rows = rows.filter {
                [$0.name, $0.jobID, $0.state, $0.classification].contains {
                    $0.localizedCaseInsensitiveContains(filter)
                }
            }
        }
        rows.sort {
            switch sort {
            case .name:
                if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case .elapsed:
                if $0.elapsedSeconds != $1.elapsedSeconds { return $0.elapsedSeconds > $1.elapsedSeconds }
            case .queue:
                if showHistory, $0.finishedAt != $1.finishedAt {
                    return ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt)
                }
                let left = $0.state == "running" ? -1 : $0.queuePosition ?? Int.max
                let right = $1.state == "running" ? -1 : $1.queuePosition ?? Int.max
                if left != right { return left < right }
            }
            return $0.jobID < $1.jobID
        }
        return rows
    }

    var selected: JobSummary? {
        details ? retainedDetail?.job : jobs.first { $0.jobID == selectedID }
    }

    private mutating func retainDetail() {
        guard let snapshot, let selectedID else { return }
        let current =
            snapshot.view.jobs.first { $0.jobID == selectedID }
            ?? snapshot.history.first { $0.jobID == selectedID }
        let previous = retainedDetail?.job.jobID == selectedID ? retainedDetail : nil
        guard let job = current ?? previous?.job else { return }
        retainedDetail = DashboardJobDetail(
            job: job,
            task: snapshot.view.tasks.first { $0.task.id == selectedID }?.task ?? previous?.task,
            record: snapshot.records.first { $0.id == selectedID } ?? previous?.record,
            current: current != nil)
    }

    mutating func reconcileSelection() {
        if details { return }
        if !jobs.contains(where: { $0.jobID == selectedID }) {
            selectedID = jobs.first?.jobID
            detailOffset = 0
        }
    }

    mutating func move(_ amount: Int) {
        if details {
            detailOffset = max(0, detailOffset + amount)
            return
        }
        let rows = jobs
        guard !rows.isEmpty else {
            selectedID = nil
            return
        }
        let index = rows.firstIndex { $0.jobID == selectedID } ?? 0
        selectedID = rows[max(0, min(rows.count - 1, index + amount))].jobID
        detailOffset = 0
    }

    mutating func failed(_ message: String) {
        error = message
        addGap()
    }

    mutating func ingest(_ snapshot: DashboardSnapshot) {
        error = nil
        let view = snapshot.view
        alerts = Self.warnings(view)
        if view.samplingPaused || view.sensorError != nil || !view.service.running {
            addGap()
        } else if let sensors = view.sensors, sensors.uptime != lastSensorUptime,
            (view.sensorAgeSeconds ?? .infinity) <= SchedulingPolicy.maximumSampleAge
        {
            if let lastSensorUptime,
                sensors.uptime < lastSensorUptime
                    || sensors.uptime - lastSensorUptime > max(interval, SchedulingPolicy.sampleInterval)
                        + SchedulingPolicy.maximumSampleAge
            {
                addGap()
            }
            let previous = samples.last?.tones ?? [:]
            var sample = DashboardSample(date: sensors.sampledAt, values: [:], tones: [:])
            for metric in DashboardMetric.allCases {
                let value = metric.value(sensors)
                sample.values[metric] = value
                sample.tones[metric] = metric.tone(value, previous: previous[metric] ?? .good)
            }
            samples.append(sample)
            lastSensorUptime = sensors.uptime
            inGap = false
        } else if (view.sensorAgeSeconds ?? 0) > SchedulingPolicy.maximumSampleAge {
            addGap()
        }
        if samples.count > Self.historyLimit { samples.removeFirst(samples.count - Self.historyLimit) }
        self.snapshot = snapshot
        if details { retainDetail() }
        reconcileSelection()
    }

    mutating func addGap() {
        if !inGap {
            samples.append(DashboardSample(date: Date(), values: [:], tones: [:]))
            if samples.count > Self.historyLimit { samples.removeFirst() }
            inGap = true
        }
    }

    mutating func prepare(_ kind: DashboardAction.Kind) {
        guard !busy, !paused, error == nil, let snapshot, snapshot.canControl else {
            notice = "Controls need a live display and a matching running service."
            return
        }
        let rows: [JobSummary]
        switch kind {
        case .prioritize:
            guard let selected = snapshot.view.jobs.first(where: { $0.jobID == selectedID }),
                selected.queuePosition != nil, selected.state != "cancelling", !selected.complete
            else {
                notice = "Select a queued job to prioritize."
                return
            }
            rows = [selected]
        case .cancel:
            guard let selected = snapshot.view.jobs.first(where: { $0.jobID == selectedID }), !selected.complete else {
                notice = "Select an outstanding job to cancel."
                return
            }
            rows = [selected]
        case .clear:
            let ids = Set(
                snapshot.view.tasks.filter {
                    $0.task.state == .queued && $0.task.startedAt == nil && $0.task.residentMemoryMiB == nil
                }.map { $0.task.id })
            rows = snapshot.view.jobs.filter { ids.contains($0.jobID) }
        case .stop: rows = snapshot.view.jobs
        }
        guard !rows.isEmpty else {
            notice = "No eligible jobs."
            return
        }
        confirmation = DashboardAction(
            kind: kind, ids: Set(rows.map(\.jobID)), names: rows.map { "\($0.name) [\($0.jobID)]" })
        modalOffset = 0
    }

    static func warnings(_ view: SchedulerView) -> [DashboardAlert] {
        var alerts: [DashboardAlert] = []
        func add(_ id: String, _ text: String, _ tone: DashboardTone = .warning) {
            alerts.append(DashboardAlert(id: id, text: text, tone: tone))
        }
        if !view.service.running {
            add("service", "SERVICE STOPPED · accepted jobs wait for recovery", .critical)
        } else if view.service.serviceRevision != BuildIdentity.serviceRevision {
            add("revision", "SERVICE REVISION MISMATCH · controls disabled", .critical)
        }
        if let error = view.sensorError { add("sensors", "SENSOR ERROR · \(error)", .critical) }
        if view.samplingPaused {
            add("paused", "SAMPLING PAUSED · \(view.samplingPausedReason ?? "scheduler policy")", .muted)
        } else if view.sensorError == nil, view.service.running {
            if view.sensors == nil {
                add("missing", "WAITING FOR SENSORS · no cached reading")
            } else if (view.sensorAgeSeconds ?? 0) > SchedulingPolicy.maximumSampleAge {
                add("stale", "SENSOR SAMPLE OVERDUE · cached values only")
            }
        }
        if let sensors = view.sensors {
            if sensors.memoryPressure != "normal" {
                add("memory", "MEMORY PRESSURE · \(sensors.memoryPressure)", .critical)
            }
            if sensors.thermalState != "nominal" {
                add("thermal", "THERMAL PRESSURE · \(sensors.thermalState)", .critical)
            }
            if !sensors.unavailable.isEmpty {
                add("unavailable", "UNAVAILABLE · \(sensors.unavailable.joined(separator: ", "))")
            }
        }
        if view.drainingForTaskID != nil {
            add("drain", "DRAINING · exclusive queue head is waiting for running work", .accent)
        }
        func priority(_ tone: DashboardTone) -> Int {
            switch tone {
            case .critical: 0
            case .warning: 1
            default: 2
            }
        }
        return alerts.sorted { priority($0.tone) < priority($1.tone) }
    }
}
