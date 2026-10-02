import Darwin
import Foundation

struct TaskReservation {
    let id: String
    let lease: FileLatch
    let gate: FileLatch
    var updatePermit: FileLatch?
    var plan: TaskPlan?
    var admission: AdmissionSnapshot?

    func inheritAcrossExec() throws {
        try lease.inheritAcrossExec()
        try gate.inheritAcrossExec()
        try updatePermit?.inheritAcrossExec()
    }
}

final class Scheduler {
    let path: String
    let directory: URL
    private let collect: () throws -> SensorSnapshot
    private var cachedState: (data: Data, state: SchedulerState)?

    init(path: String, collect: @escaping () throws -> SensorSnapshot = NativeSensors.sample) throws {
        self.path = path
        self.collect = collect
        directory = URL(fileURLWithPath: path + ".queue", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch CocoaError.fileWriteFileExists {}
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
        else {
            throw LatchError("scheduler directory must be owned by this user with permissions 0700", exitCode: 74)
        }
    }

    func reserve(
        name: String, arguments: [String], requirements: TaskRequirements, timeout: Double?, useService: Bool = false,
        supervisorPID: Int32? = nil, inheritedUpdatePermit: Bool = false, ticketID: String? = nil
    ) throws -> TaskReservation {
        try requirements.validate()
        let updatePermit = inheritedUpdatePermit ? nil : try UpdateDrain.admit(in: directory)
        if useService {
            _ = try SchedulerService.requireRunning(in: directory)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = timeout.map { started + $0 }
        let watcher = try QueueWatcher(directory: directory.path)
        let id = ticketID ?? UUID().uuidString
        let lease = try FileLatch(path: leasePath(id))
        try lease.acquire(shared: false, timeout: 0)
        let gate = try FileLatch(path: path)
        var admitted = false
        defer {
            if !admitted, ticketID == nil {
                try? withdraw(id)
            }
        }
        try transaction { state in
            if ticketID != nil {
                guard state.jobs.contains(where: { $0.id == id && !$0.complete }),
                    let index = state.tasks.firstIndex(where: { $0.id == id && $0.state == .queued })
                else { throw LatchError("durable admission ticket is missing", exitCode: 74) }
                state.tasks[index].pid = getpid()
            } else {
                guard state.tasks.count < DurableJobs.globalOutstandingLimit else {
                    throw LatchError("shared queue limit reached", exitCode: 75)
                }
                state.tasks.append(
                    ScheduledTask(id: id, name: name, pid: getpid(), arguments: arguments, requirements: requirements))
            }
        }
        while true {
            if let supervisorPID, getppid() != supervisorPID {
                throw LatchError("MCP supervisor exited", exitCode: 69)
            }
            let servicePID = useService ? try SchedulerService.requireRunning(in: directory) : nil
            var view = SchedulerState()
            if !useService {
                view = try snapshot()
                if view.tasks.first(where: { $0.state == .queued })?.id == id,
                    !view.tasks.contains(where: { $0.state == .running && $0.requirements.mode == .isolated }),
                    !(requirements.mode == .isolated && view.tasks.contains(where: { $0.state == .running }))
                {
                    _ = try refreshSensors()
                }
            }
            var reason = "waiting for admission"
            try transaction { state in
                let now = ProcessInfo.processInfo.systemUptime
                guard let index = state.tasks.firstIndex(where: { $0.id == id }) else {
                    throw LatchError("queued task was removed", exitCode: 75)
                }
                guard state.tasks[index].state != .cancelling else {
                    throw LatchError("queued task cancelled by operator", exitCode: 75)
                }
                guard
                    !FileManager.default.fileExists(atPath: directory.appendingPathComponent("jobs/\(id).cancel").path)
                else { throw LatchError("queued task cancellation requested", exitCode: 75) }
                if let deadline, timeout != 0, now >= deadline {
                    reason = "timeout: \(state.tasks[index].waitingFor ?? "waiting for admission")"
                } else if let blocked = SchedulingPolicy.reason(for: state.tasks[index], in: state, now: now) {
                    reason = blocked
                } else {
                    do {
                        try gate.acquire(shared: requirements.mode == .batch, timeout: 0)
                        state.tasks[index].admission = AdmissionSnapshot(
                            state: state, measurement: state.tasks[index].requirements.measurement)
                        state.tasks[index].state = .running
                        state.tasks[index].startedAt = Date()
                        state.tasks[index].waitingFor = nil
                        // A new task invalidates any quiet period accumulated before its start.
                        state.quietSince = nil
                        admitted = true
                    } catch let error as LatchError where error.exitCode == 75 {
                        reason = "waiting for the process latch"
                    }
                }
                if !admitted {
                    state.tasks[index].waitingFor = reason
                }
                view = state
            }
            if admitted {
                let task = view.tasks.first { $0.id == id }
                return TaskReservation(
                    id: id, lease: lease, gate: gate, updatePermit: updatePermit,
                    plan: task?.plan, admission: task?.admission)
            }
            let remaining = deadline.map { max(0, $0 - ProcessInfo.processInfo.systemUptime) }
            if let remaining, remaining <= 0 {
                throw LatchError(reason, exitCode: 75)
            }
            if useService {
                watcher.wait(
                    seconds: remaining ?? 3600,
                    pids: view.tasks.map(\.pid) + [servicePID!] + (supervisorPID.map { [$0] } ?? []))
            } else {
                // Queue notifications wake cancelled standalone waiters even while the process latch is held.
                watcher.wait(
                    seconds: min(remaining ?? 1, 1), pids: view.tasks.filter { $0.state == .running }.map(\.pid))
            }
        }
    }

    func snapshot() throws -> SchedulerState {
        try transaction { $0 }
    }

    func withdraw(_ id: String) throws {
        try transaction { state in
            if state.tasks.contains(where: { $0.id == id && $0.state == .running }) {
                state.resetCooldowns()
            }
            state.tasks.removeAll { $0.id == id }
        }
        try? FileManager.default.removeItem(atPath: leasePath(id))
    }

    @discardableResult
    func refreshSensors() throws -> Bool {
        let collector = try FileLatch(path: directory.appendingPathComponent("sensors.lock").path)
        do { try collector.acquire(shared: false, timeout: 0) } catch let error as LatchError where error.exitCode == 75
        { return true }
        return try withExtendedLifetime(collector) {
            let gate = try FileLatch(path: path)
            do { try gate.acquire(shared: true, timeout: 0) } catch let error as LatchError where error.exitCode == 75 {
                return false
            }
            return try withExtendedLifetime(gate) {
                let state = try snapshot()
                let now = ProcessInfo.processInfo.systemUptime
                if let last = state.lastSensorAttempt, now >= last, now - last < SchedulingPolicy.sampleInterval {
                    return true
                }
                do {
                    let sample = try collect()
                    try transaction { $0.record(sample) }
                } catch {
                    try transaction {
                        $0.sensorError = String(describing: error)
                        $0.lastSensorAttempt = ProcessInfo.processInfo.systemUptime
                        $0.quietSince = nil
                        $0.resetCooldowns()
                    }
                }
                return true
            }
        }
    }

    func transaction<T>(_ body: (inout SchedulerState) throws -> T) throws -> T {
        let mutex = try FileLatch(path: directory.appendingPathComponent("state.lock").path)
        try mutex.acquire(shared: false, timeout: nil)
        return try withExtendedLifetime(mutex) {
            let file = directory.appendingPathComponent("state.json")
            let previous: Data?
            do { previous = try Data(contentsOf: file) } catch CocoaError.fileReadNoSuchFile { previous = nil }
            var state: SchedulerState
            if let previous, let cachedState, previous == cachedState.data {
                state = cachedState.state
            } else {
                state = try previous.map { try JSONDecoder().decode(SchedulerState.self, from: $0) } ?? SchedulerState()
            }
            guard state.version == SchedulerState.schemaVersion else {
                throw LatchError("unsupported scheduler state version", exitCode: 74)
            }
            let original = state
            let unfinishedJobs = Set(state.jobs.lazy.filter { !$0.complete }.map(\.id))
            var live: [ScheduledTask] = []
            for task in state.tasks {
                guard UUID(uuidString: task.id) != nil else {
                    throw LatchError("invalid task ID in scheduler state", exitCode: 74)
                }
                if unfinishedJobs.contains(task.id) {
                    live.append(task)
                    continue
                }
                let probe = try FileLatch(path: leasePath(task.id))
                do {
                    try probe.acquire(shared: false, timeout: 0)
                    try? FileManager.default.removeItem(atPath: leasePath(task.id))
                } catch let error as LatchError where error.exitCode == 75 { live.append(task) }
            }
            if state.tasks.contains(where: { task in
                task.state == .running && !live.contains(where: { $0.id == task.id })
            }) {
                state.quietSince = nil
                for index in live.indices {
                    live[index].coolSince = nil
                }
            }
            state.tasks = live
            let result = try body(&state)
            if let previous, state == original {
                cachedState = (previous, state)
                return result
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            if data != previous {
                try data.write(to: file, options: .atomic)
            }
            cachedState = (data, state)
            return result
        }
    }

    private func leasePath(_ id: String) -> String {
        directory.appendingPathComponent(id + ".lease").path
    }
}
