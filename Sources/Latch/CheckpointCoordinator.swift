import Darwin
import Foundation

struct CheckpointMessage: Codable {
    static let schemaVersion = 1
    var version = Self.schemaVersion
    var kind: String
    var iteration: Int
}

final class CheckpointCoordinator {
    let id: String
    let scheduler: Scheduler
    let lease: FileLatch
    let gate: FileLatch
    let channel: Int32
    let clientChannel: Int32
    var clientOpen = true
    var channelOpen = true
    var pid: Int32 = 0
    var stage = "setup"
    var iteration = 0
    var completedIterations = 0
    var iterations: [MCPValue] = []
    var started: Double?
    var queued = ProcessInfo.processInfo.systemUptime
    var admission: SensorSnapshot?
    var admissionSnapshot: AdmissionSnapshot?
    var buffer = Data()
    var error: String?

    init(id: String, scheduler: Scheduler) throws {
        self.id = id
        self.scheduler = scheduler
        lease = try FileLatch(path: scheduler.directory.appendingPathComponent(id + ".lease").path)
        try lease.acquire(shared: false, timeout: 0)
        gate = try FileLatch(path: scheduler.path)
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw LatchError.system("create checkpoint channel")
        }
        channel = pair[0]
        clientChannel = pair[1]
        for fd in pair {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var enabled: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        }
        _ = fcntl(channel, F_SETFL, O_NONBLOCK)
    }

    deinit {
        close(channel)
        if clientOpen { close(clientChannel) }
    }

    func spawned(_ pid: Int32) throws {
        self.pid = pid
        close(clientChannel)
        clientOpen = false
        try scheduler.transaction { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else {
                throw LatchError("checkpoint ticket missing")
            }
            state.tasks[index].pid = pid
        }
    }

    func admit() throws -> Bool {
        guard (try? SchedulerService.requireRunning(in: scheduler.directory)) != nil else { return false }
        return try scheduler.transaction { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else {
                throw LatchError("checkpoint ticket missing")
            }
            guard state.tasks[index].state != .cancelling,
                !FileManager.default.fileExists(
                    atPath: scheduler.directory.appendingPathComponent("jobs/\(id).cancel").path)
            else { return false }
            if let reason = SchedulingPolicy.reason(
                for: state.tasks[index], in: state, now: ProcessInfo.processInfo.systemUptime)
            {
                state.tasks[index].waitingFor = reason
                return false
            }
            do { try gate.acquire(shared: false, timeout: 0) } catch let error as LatchError where error.exitCode == 75
            { return false }
            state.tasks[index].state = .running
            state.tasks[index].startedAt = Date()
            state.tasks[index].waitingFor = nil
            admissionSnapshot = AdmissionSnapshot(state: state, measurement: true)
            state.tasks[index].admission = admissionSnapshot
            state.quietSince = nil
            admission = state.sensors
            return true
        }
    }

    func park(ready: Bool) throws {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else {
            throw LatchError.system("read parked process memory")
        }
        try scheduler.transaction { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else {
                throw LatchError("checkpoint ticket missing")
            }
            var task = state.tasks.remove(at: index)
            task.state = ready ? .queued : .parked
            task.residentMemoryMiB = Int((info.pti_resident_size + 1_048_575) / 1_048_576)
            task.startedAt = nil
            task.queuedAt = Date()
            task.queuedUptime = ProcessInfo.processInfo.systemUptime
            task.waitingFor = ready ? "waiting for checkpoint admission" : "waiting for next checkpoint"
            task.coolSince = nil
            state.tasks.append(task)
            state.resetCooldowns()
            gate.release()
        }
    }

    func receive() throws {
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = read(channel, &bytes, bytes.count)
        if count == 0 {
            channelOpen = false
            guard stage == "parked" else { throw LatchError("checkpoint channel closed before finishing an iteration") }
            return
        }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN { return }
            throw LatchError.system("read checkpoint")
        }
        buffer.append(contentsOf: bytes.prefix(count))
        guard buffer.count <= 1024 else { throw LatchError("checkpoint frame exceeds limit") }
        while let end = buffer.firstIndex(of: 10) {
            let data = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            let message = try JSONDecoder().decode(CheckpointMessage.self, from: data)
            guard message.version == CheckpointMessage.schemaVersion, message.iteration >= 0,
                message.iteration <= 9_007_199_254_740_991
            else {
                throw LatchError("invalid checkpoint message")
            }
            if message.kind == "ready", message.iteration == iteration {
                if stage == "waiting" { continue }
                if stage == "running" {
                    try send("permit", iteration: iteration)
                    continue
                }
                guard stage == "setup" || stage == "parked" else { throw LatchError("unexpected checkpoint ready") }
                try park(ready: true)
                queued = ProcessInfo.processInfo.systemUptime
                stage = "waiting"
            } else if message.kind == "finished" {
                if stage == "parked", message.iteration == iteration - 1 {
                    try send("finished", iteration: message.iteration)
                    continue
                }
                guard stage == "running", message.iteration == iteration, let started else {
                    throw LatchError("unexpected checkpoint completion")
                }
                let now = ProcessInfo.processInfo.systemUptime
                iterations.append([
                    "iteration": .number(Double(iteration)), "executionSeconds": .number(max(0, now - started)),
                    "waitingSeconds": .number(max(0, started - queued)), "admissionSensors": try .encoded(admission),
                    "admission": try .encoded(admissionSnapshot),
                ])
                if iterations.count > 64 { iterations.removeFirst() }
                completedIterations += 1
                iteration += 1
                try park(ready: false)
                stage = "parked"
                try send("finished", iteration: message.iteration)
            } else {
                throw LatchError("unexpected checkpoint message")
            }
        }
    }

    func advance() throws {
        if stage == "waiting", try admit() {
            stage = "running"
            started = ProcessInfo.processInfo.systemUptime
            try send("permit", iteration: iteration)
        }
    }

    private func send(_ kind: String, iteration: Int) throws {
        var bytes = try JSONEncoder().encode(CheckpointMessage(kind: kind, iteration: iteration))
        bytes.append(10)
        let count = bytes.withUnsafeBytes { write(channel, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw LatchError("checkpoint peer closed or is not reading") }
    }
}
