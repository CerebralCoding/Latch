import Darwin
import Foundation

struct TaskReservation {
    let id: String
    let lease: FileLatch
    let gate: FileLatch

    func inheritAcrossExec() throws {
        try lease.inheritAcrossExec()
        try gate.inheritAcrossExec()
    }
}

final class Scheduler {
    let path: String
    let directory: URL
    private let collect: () throws -> SensorSnapshot

    init(path: String, collect: @escaping () throws -> SensorSnapshot = NativeSensors.sample) throws {
        self.path = path
        self.collect = collect
        directory = URL(fileURLWithPath: path + ".queue", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch CocoaError.fileWriteFileExists {}
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
        else {
            throw LatchError("scheduler directory must be owned by this user with permissions 0700", exitCode: 74)
        }
    }

    func reserve(name: String, arguments: [String], requirements: TaskRequirements, timeout: Double?) throws -> TaskReservation {
        try requirements.validate()
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = timeout.map { started + $0 }
        let watcher = try QueueWatcher(directory: directory.path)
        let id = UUID().uuidString
        let lease = try FileLatch(path: leasePath(id))
        try lease.acquire(shared: false, timeout: 0)
        let gate = try FileLatch(path: path)
        var admitted = false
        defer {
            if !admitted {
                try? withdraw(id)
            }
        }
        try transaction { state in
            state.tasks.append(ScheduledTask(id: id, name: name, pid: getpid(), arguments: arguments, requirements: requirements))
        }
        while true {
            var view = try snapshot()
            var samplingBlocked = false
            if view.tasks.first(where: { $0.state == .queued })?.id == id,
               !view.tasks.contains(where: { $0.state == .running && $0.requirements.mode == .isolated }),
               !(requirements.mode == .isolated && view.tasks.contains(where: { $0.state == .running }))
            {
                samplingBlocked = try !refreshSensors()
            }
            var reason = "waiting for admission"
            var blockedByLatch = false
            let now = ProcessInfo.processInfo.systemUptime
            try transaction { state in
                guard let index = state.tasks.firstIndex(where: { $0.id == id }) else {
                    throw LatchError("queued task was removed", exitCode: 75)
                }
                if let deadline, timeout != 0, now >= deadline {
                    reason = "timeout: \(state.tasks[index].waitingFor ?? "waiting for admission")"
                } else if let blocked = SchedulingPolicy.reason(for: state.tasks[index], in: state, now: now) {
                    reason = blocked
                } else {
                    do {
                        try gate.acquire(shared: requirements.mode == .batch, timeout: 0)
                        state.tasks[index].state = .running
                        state.tasks[index].startedAt = Date()
                        state.tasks[index].waitingFor = nil
                        // A new task invalidates any quiet period accumulated before its start.
                        state.quietSince = nil
                        admitted = true
                    } catch let error as LatchError where error.exitCode == 75 {
                        reason = "waiting for the process latch"
                        blockedByLatch = true
                    }
                }
                if !admitted {
                    state.tasks[index].waitingFor = reason
                }
                view = state
            }
            if admitted {
                return TaskReservation(id: id, lease: lease, gate: gate)
            }
            let remaining = deadline.map { max(0, $0 - ProcessInfo.processInfo.systemUptime) }
            if let remaining, remaining <= 0 {
                throw LatchError(reason, exitCode: 75)
            }
            let isolatedRunning = view.tasks.contains { $0.state == .running && $0.requirements.mode == .isolated }
            if isolatedRunning || blockedByLatch || samplingBlocked {
                // Park behind an exclusive workload without sampling or periodic wakeups.
                let checkpoint = try FileLatch(path: path)
                try checkpoint.acquire(shared: isolatedRunning || requirements.mode == .batch, timeout: remaining)
            } else {
                watcher.wait(seconds: min(remaining ?? 1, 1), pids: view.tasks.filter { $0.state == .running }.map(\.pid))
            }
        }
    }

    func snapshot() throws -> SchedulerState {
        try transaction { $0 }
    }

    func withdraw(_ id: String) throws {
        try transaction { state in state.tasks.removeAll { $0.id == id } }
        try? FileManager.default.removeItem(atPath: leasePath(id))
    }

    @discardableResult
    func refreshSensors() throws -> Bool {
        let collector = try FileLatch(path: directory.appendingPathComponent("sensors.lock").path)
        do { try collector.acquire(shared: false, timeout: 0) }
        catch let error as LatchError where error.exitCode == 75 { return true }
        return try withExtendedLifetime(collector) {
            let gate = try FileLatch(path: path)
            do { try gate.acquire(shared: true, timeout: 0) }
            catch let error as LatchError where error.exitCode == 75 { return false }
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
            do { previous = try Data(contentsOf: file) }
            catch CocoaError.fileReadNoSuchFile { previous = nil }
            var state = try previous.map { try JSONDecoder().decode(SchedulerState.self, from: $0) } ?? SchedulerState()
            guard state.version == 1 else { throw LatchError("unsupported scheduler state version", exitCode: 74) }
            var live: [ScheduledTask] = []
            for task in state.tasks {
                guard UUID(uuidString: task.id) != nil else { throw LatchError("invalid task ID in scheduler state", exitCode: 74) }
                let probe = try FileLatch(path: leasePath(task.id))
                do {
                    try probe.acquire(shared: false, timeout: 0)
                    try? FileManager.default.removeItem(atPath: leasePath(task.id))
                } catch let error as LatchError where error.exitCode == 75 { live.append(task) }
            }
            if live.count != state.tasks.count {
                state.quietSince = nil
            }
            state.tasks = live
            let result = try body(&state)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            if data != previous {
                try data.write(to: file, options: .atomic)
            }
            return result
        }
    }

    private func leasePath(_ id: String) -> String {
        directory.appendingPathComponent(id + ".lease").path
    }
}
