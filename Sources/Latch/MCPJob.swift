import Darwin
import Foundation

struct MCPWorkerRequest: Codable {
    var submission: MCPSubmission
    var latchPath: String
    var parentPID: Int32
    var statusPath: String
    var updateDescriptor: Int32
    var ticketID: String
}

struct MCPWorkerStatus: Codable {
    var admitted: Bool
    var taskID: String?
    var error: String?
    var code: Int32?
    var plan: TaskPlan?
}

enum MCPWorker {
    static func run(requestPath: String) -> Int32 {
        var request: MCPWorkerRequest?
        var status = MCPWorkerStatus(admitted: false)
        do {
            guard setpgid(0, 0) == 0 || getpgrp() == getpid() else { throw LatchError.system("create workload process group") }
            for number in [SIGTERM, SIGINT, SIGPIPE] {
                signal(number, SIG_DFL)
            }
            let decoded = try JSONDecoder().decode(MCPWorkerRequest.self, from: Data(contentsOf: URL(fileURLWithPath: requestPath)))
            request = decoded
            guard decoded.updateDescriptor > STDERR_FILENO, fcntl(decoded.updateDescriptor, F_GETFD) >= 0 else {
                throw LatchError("missing inherited update permit", exitCode: 74)
            }
            guard fcntl(decoded.updateDescriptor, F_SETFD, 0) == 0 else { throw LatchError.system("inherit update permit") }
            let scheduler = try Scheduler(path: decoded.latchPath)
            let submission = decoded.submission
            let plan = TaskPlanner.plan(executable: submission.executable, arguments: submission.arguments, measurement: submission.measurement)
            status.plan = plan
            try JSONEncoder().encode(status).write(to: URL(fileURLWithPath: decoded.statusPath), options: .atomic)
            let reservation = try scheduler.reserve(name: submission.name, arguments: [submission.executable] + plan.arguments,
                                                    requirements: plan.requirements, timeout: nil, useService: true, ownerPID: decoded.parentPID, inheritedUpdatePermit: true, ticketID: decoded.ticketID)
            defer { try? scheduler.withdraw(reservation.id) }
            try withExtendedLifetime(reservation) {
                guard getppid() == decoded.parentPID else { throw LatchError("MCP connection owner exited", exitCode: 69) }
                status.admitted = true
                status.taskID = reservation.id
                try JSONEncoder().encode(status).write(to: URL(fileURLWithPath: decoded.statusPath), options: .atomic)
                try reservation.inheritAcrossExec()
                try Latch.execute([submission.executable] + plan.arguments)
            }
        } catch {
            status.error = String(describing: error)
            status.code = (error as? LatchError)?.exitCode ?? 74
            if let request {
                try? JSONEncoder().encode(status).write(to: URL(fileURLWithPath: request.statusPath), options: .atomic)
            }
            return status.code ?? 74
        }
        return 0
    }
}

final class MCPExecution {
    static let outputLimit = 32768
    let id: String
    let submission: MCPSubmission
    private(set) var pid: Int32 = 0
    private var terminationStatus: Int32 = 0
    let stdout = Pipe()
    let stderr = Pipe()
    let statusURL: URL
    let requestURL: URL
    var stdoutOpen = true
    var stderrOpen = true
    var stdoutData = Data()
    var stderrData = Data()
    var stdoutTruncated = false
    var stderrTruncated = false
    var cancelAt: Double?
    var killSent = false
    var exitedAt: Double?
    var complete = false

    init(id: String, submission: MCPSubmission, directory: URL, path: String, executable: URL, updateDescriptor: Int32) throws {
        self.id = id
        self.submission = submission
        statusURL = directory.appendingPathComponent(id + ".status.json")
        requestURL = directory.appendingPathComponent(id + ".request.json")
        let request = MCPWorkerRequest(submission: submission, latchPath: path, parentPID: getpid(), statusPath: statusURL.path, updateDescriptor: updateDescriptor, ticketID: id)
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try Self.check(posix_spawn_file_actions_addinherit_np(&actions, updateDescriptor))
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try Self.check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO))
        try Self.check(posix_spawn_file_actions_addchdir(&actions, submission.workingDirectory))
        try Self.check(posix_spawnattr_setpgroup(&attributes, 0))
        var defaults = sigset_t(0)
        for number in [SIGTERM, SIGINT, SIGPIPE] {
            sigaddset(&defaults, number)
        }
        var mask = sigset_t(0)
        try Self.check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try Self.check(posix_spawnattr_setsigmask(&attributes, &mask))
        try Self.check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        let arguments = [executable.path, "__mcp_worker", requestURL.path].map { strdup($0) }
        defer { arguments.forEach { free($0) } }
        guard arguments.allSatisfy({ $0 != nil }) else { throw LatchError("out of memory", exitCode: 71) }
        var pointers = arguments + [nil]
        let inheritedEnvironment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { inheritedEnvironment.forEach { free($0) } }
        guard inheritedEnvironment.allSatisfy({ $0 != nil }) else { throw LatchError("out of memory", exitCode: 71) }
        var environment = inheritedEnvironment + [nil]
        try Self.check(posix_spawn(&pid, executable.path, &actions, &attributes, &pointers, &environment))
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        for pipe in [stdout, stderr] {
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        }
    }

    deinit {
        if pid > 0, !complete {
            signalGroup(SIGKILL)
            _ = waitpid(pid, nil, WNOHANG)
        }
        try? FileManager.default.removeItem(at: requestURL)
        try? FileManager.default.removeItem(at: statusURL)
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else { throw LatchError("spawn MCP worker: \(String(cString: strerror(result)))", exitCode: 74) }
    }

    var descriptors: [Int32] {
        (stdoutOpen ? [stdout.fileHandleForReading.fileDescriptor] : []) + (stderrOpen ? [stderr.fileHandleForReading.fileDescriptor] : [])
    }

    func drain(_ descriptor: Int32) {
        let isOutput = stdoutOpen && descriptor == stdout.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 8192)
        // Bound each turn so a noisy command cannot starve protocol input or cancellation.
        for _ in 0 ..< 16 {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                if isOutput {
                    let retained = min(count, Self.outputLimit - stdoutData.count)
                    stdoutData.append(contentsOf: buffer.prefix(retained))
                    stdoutTruncated = stdoutTruncated || retained < count
                } else {
                    let retained = min(count, Self.outputLimit - stderrData.count)
                    stderrData.append(contentsOf: buffer.prefix(retained))
                    stderrTruncated = stderrTruncated || retained < count
                }
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                if isOutput {
                    stdoutOpen = false; try? stdout.fileHandleForReading.close()
                } else {
                    stderrOpen = false; try? stderr.fileHandleForReading.close()
                }
                break
            } else {
                break
            }
        }
    }

    func cancel(now: Double) {
        guard !complete, cancelAt == nil else { return }
        cancelAt = now
        signalGroup(SIGTERM)
    }

    func update(now: Double) {
        guard !complete else { return }
        if let cancelAt, now - cancelAt >= 2, !killSent {
            signalGroup(SIGKILL)
            killSent = true
        }
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid {
            if exitedAt == nil {
                exitedAt = now
            }
            for descriptor in descriptors {
                drain(descriptor)
            }
            if let exitedAt, now - exitedAt >= 2 {
                if stdoutOpen {
                    stdoutTruncated = true; stdoutOpen = false; try? stdout.fileHandleForReading.close()
                }
                if stderrOpen {
                    stderrTruncated = true; stderrOpen = false; try? stderr.fileHandleForReading.close()
                }
            }
            if descriptors.isEmpty, cancelAt == nil || killSent {
                _ = waitpid(pid, &terminationStatus, 0)
                complete = true
            }
        }
    }

    func signalGroup(_ number: Int32) {
        guard pid > 0, !complete else { return }
        // Keep the leader unreaped until completion, so its process-group ID cannot be reused.
        _ = kill(-pid, number)
    }

    func result(includeOutput: Bool) throws -> MCPValue {
        let status = (try? Data(contentsOf: statusURL)).flatMap { try? JSONDecoder().decode(MCPWorkerStatus.self, from: $0) }
        var value: [String: MCPValue] = [
            "jobID": .string(id), "requestKey": .string(submission.requestKey), "name": .string(submission.name),
            "pid": .number(Double(pid)), "complete": .bool(complete),
            "state": .string(complete ? (cancelAt == nil ? "completed" : "cancelled") : (cancelAt == nil ? (status?.admitted == true ? "running" : "queued") : "cancelling")),
        ]
        if let taskID = status?.taskID {
            value["taskID"] = .string(taskID)
        }
        if let plan = status?.plan {
            value["plan"] = try MCPValue.encoded(plan)
        }
        if complete {
            let phase = status?.error != nil || status?.admitted != true ? (status?.admitted == true ? "execution" : "admission") : "command"
            let signal = terminationStatus & 0x7F
            let code = signal == 0 ? (terminationStatus >> 8) & 0xFF : signal
            value["exitCode"] = .number(Double(code))
            value["terminationReason"] = .string(signal == 0 ? "exit" : "signal")
            value["phase"] = .string(phase)
            value["succeeded"] = .bool(cancelAt == nil && phase == "command" && signal == 0 && code == 0)
            if let error = status?.error {
                value["error"] = .string(error)
            }
        }
        if includeOutput {
            value["stdout"] = .string(String(decoding: stdoutData, as: UTF8.self))
            value["stderr"] = .string(String(decoding: stderrData, as: UTF8.self))
            value["stdoutTruncated"] = .bool(stdoutTruncated)
            value["stderrTruncated"] = .bool(stderrTruncated)
        }
        return .object(value)
    }
}
