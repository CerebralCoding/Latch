import Darwin
import Foundation

struct MCPWorkerRequest: Codable {
    var submission: MCPSubmission
    var latchPath: String
    var parentPID: Int32
    var statusPath: String
    var updateDescriptor: Int32
    var ticketID: String
    var checkpointDescriptors: [Int32]?
}

struct MCPWorkerStatus: Codable {
    var admitted: Bool
    var taskID: String?
    var error: String?
    var code: Int32?
    var plan: TaskPlan?
    var admittedAt: Double?
    var admissionSensors: SensorSnapshot?
    var admission: AdmissionSnapshot?
    var waitingSeconds: Double?
}

enum MCPWorker {
    static func run(requestPath: String) -> Int32 {
        var request: MCPWorkerRequest?
        var status = MCPWorkerStatus(admitted: false)
        do {
            for number in [SIGTERM, SIGINT, SIGPIPE] {
                signal(number, SIG_DFL)
            }
            let decoded = try JSONDecoder().decode(
                MCPWorkerRequest.self, from: Data(contentsOf: URL(fileURLWithPath: requestPath)))
            request = decoded
            if decoded.submission.input == "terminal" {
                guard setsid() >= 0, ioctl(STDIN_FILENO, TIOCSCTTY, 0) == 0,
                    tcsetpgrp(STDIN_FILENO, getpid()) == 0
                else { throw LatchError.system("attach controlling terminal") }
            } else {
                guard setpgid(0, 0) == 0 || getpgrp() == getpid() else {
                    throw LatchError.system("create workload process group")
                }
            }
            guard decoded.updateDescriptor > STDERR_FILENO, fcntl(decoded.updateDescriptor, F_GETFD) >= 0 else {
                throw LatchError("missing inherited update permit", exitCode: 74)
            }
            guard fcntl(decoded.updateDescriptor, F_SETFD, 0) == 0 else {
                throw LatchError.system("inherit update permit")
            }
            let scheduler = try Scheduler(path: decoded.latchPath)
            let submission = decoded.submission
            guard let ticket = try scheduler.snapshot().tasks.first(where: { $0.id == decoded.ticketID }),
                let plan = ticket.plan
            else {
                throw LatchError("durable execution plan is missing", exitCode: 74)
            }
            status.plan = plan
            try JSONEncoder().encode(status).write(to: URL(fileURLWithPath: decoded.statusPath), options: .atomic)
            if let descriptors = decoded.checkpointDescriptors {
                guard descriptors.count == 3, descriptors.allSatisfy({ $0 > 2 && fcntl($0, F_GETFD) >= 0 }),
                    getppid() == decoded.parentPID
                else { throw LatchError("checkpoint supervisor unavailable", exitCode: 74) }
                for fd in descriptors { _ = fcntl(fd, F_SETFD, 0) }
                setenv("LATCH_CHECKPOINT_FD", String(descriptors[0]), 1)
                status.admitted = true
                status.taskID = decoded.ticketID
                try JSONEncoder().encode(status).write(to: URL(fileURLWithPath: decoded.statusPath), options: .atomic)
                try execute([submission.executable] + plan.arguments)
                return 0
            }
            unsetenv("LATCH_CHECKPOINT_FD")
            let queued = ticket.queuedUptime
            let reservation = try scheduler.reserve(
                name: submission.name, arguments: [submission.executable] + plan.arguments,
                requirements: plan.requirements, timeout: nil, useService: true, supervisorPID: decoded.parentPID,
                inheritedUpdatePermit: true, ticketID: decoded.ticketID)
            defer { try? scheduler.withdraw(reservation.id) }
            try withExtendedLifetime(reservation) {
                guard getppid() == decoded.parentPID else { throw LatchError("MCP supervisor exited", exitCode: 69) }
                status.admitted = true
                status.admittedAt = ProcessInfo.processInfo.systemUptime
                status.waitingSeconds = max(0, status.admittedAt! - queued)
                status.admission = reservation.admission
                status.admissionSensors = reservation.admission?.sensors
                guard let committed = reservation.plan else {
                    throw LatchError("admitted execution plan is missing", exitCode: 74)
                }
                status.plan = committed
                status.taskID = reservation.id
                try JSONEncoder().encode(status).write(to: URL(fileURLWithPath: decoded.statusPath), options: .atomic)
                try reservation.inheritAcrossExec()
                try execute([submission.executable] + committed.arguments)
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

    private static func execute(_ arguments: [String]) throws {
        let argv = arguments.map { strdup($0) }
        defer { for pointer in argv { free(pointer) } }
        guard argv.allSatisfy({ $0 != nil }) else { throw LatchError("out of memory", exitCode: 71) }
        var pointers = argv + [nil]
        _ = execvp(pointers[0], &pointers)
        throw LatchError(
            "cannot execute \(arguments[0]): \(String(cString: strerror(errno)))",
            exitCode: errno == ENOENT ? 127 : 126)
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
    var terminal: MCPPseudoTerminal?
    var inputPipe: Pipe?
    var inputOpen = false
    var pendingInput: [MCPControl] = []
    var liveOutput = MCPLiveOutput()
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
    let checkpoints: CheckpointCoordinator?

    init(
        id: String, submission: MCPSubmission, directory: URL, path: String, executable: URL, updateDescriptor: Int32,
        checkpoints: CheckpointCoordinator? = nil
    ) throws {
        self.id = id
        self.submission = submission
        self.checkpoints = checkpoints
        statusURL = directory.appendingPathComponent(id + ".status.json")
        requestURL = directory.appendingPathComponent(id + ".request.json")
        let inherited = checkpoints.map { [$0.clientChannel, $0.gate.descriptor, $0.lease.descriptor] }
        let request = MCPWorkerRequest(
            submission: submission, latchPath: path, parentPID: getpid(), statusPath: statusURL.path,
            updateDescriptor: updateDescriptor, ticketID: id, checkpointDescriptors: inherited)
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try Self.check(posix_spawn_file_actions_addinherit_np(&actions, updateDescriptor))
        for fd in inherited ?? [] { try Self.check(posix_spawn_file_actions_addinherit_np(&actions, fd)) }
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        if submission.input == "terminal" {
            let terminal = try MCPPseudoTerminal(columns: submission.columns, rows: submission.rows)
            self.terminal = terminal
            for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
                try Self.check(posix_spawn_file_actions_adddup2(&actions, terminal.slave.fileDescriptor, fd))
            }
            stderrOpen = false
        } else {
            if submission.input == "pipe" {
                let pipe = Pipe()
                inputPipe = pipe
                inputOpen = true
                _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK)
                try Self.check(
                    posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForReading.fileDescriptor, STDIN_FILENO))
            } else {
                try Self.check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
            }
            try Self.check(
                posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
            try Self.check(
                posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO))
        }
        try Self.check(posix_spawn_file_actions_addchdir(&actions, submission.workingDirectory))
        try Self.check(posix_spawnattr_setpgroup(&attributes, 0))
        var defaults = sigset_t(0)
        for number in [SIGTERM, SIGINT, SIGPIPE] {
            sigaddset(&defaults, number)
        }
        var mask = sigset_t(0)
        try Self.check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try Self.check(posix_spawnattr_setsigmask(&attributes, &mask))
        let groupFlag = submission.input == "terminal" ? 0 : POSIX_SPAWN_SETPGROUP
        try Self.check(
            posix_spawnattr_setflags(
                &attributes,
                Int16(groupFlag | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        let arguments = [executable.path, "__mcp_worker", requestURL.path].map { strdup($0) }
        defer { for pointer in arguments { free(pointer) } }
        guard arguments.allSatisfy({ $0 != nil }) else { throw LatchError("out of memory", exitCode: 71) }
        var pointers = arguments + [nil]
        let inheritedEnvironment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { for pointer in inheritedEnvironment { free(pointer) } }
        guard inheritedEnvironment.allSatisfy({ $0 != nil }) else { throw LatchError("out of memory", exitCode: 71) }
        var environment = inheritedEnvironment + [nil]
        try Self.check(posix_spawn(&pid, executable.path, &actions, &attributes, &pointers, &environment))
        try checkpoints?.spawned(pid)
        try? terminal?.slave.close()
        try? inputPipe?.fileHandleForReading.close()
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
        guard result == 0 else {
            throw LatchError("spawn MCP worker: \(String(cString: strerror(result)))", exitCode: 74)
        }
    }

    var descriptors: [Int32] {
        (stdoutOpen ? [outputDescriptor] : []) + (stderrOpen ? [stderr.fileHandleForReading.fileDescriptor] : [])
    }

    func drain(_ descriptor: Int32) {
        let isOutput = stdoutOpen && descriptor == outputDescriptor
        var buffer = [UInt8](repeating: 0, count: 8192)
        // Bound each turn so a noisy command cannot starve protocol input or cancellation.
        for _ in 0..<16 {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                liveOutput.append(Data(buffer.prefix(count)), output: isOutput)
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
                    closeOutput()
                } else {
                    stderrOpen = false
                    try? stderr.fileHandleForReading.close()
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
        signalGroup(SIGCONT)
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
                    stdoutTruncated = true
                    closeOutput()
                }
                if stderrOpen {
                    stderrTruncated = true
                    stderrOpen = false
                    try? stderr.fileHandleForReading.close()
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
        if let terminal, stdoutOpen {
            let foreground = tcgetpgrp(terminal.master.fileDescriptor)
            if foreground > 0, foreground != pid {
                _ = kill(-foreground, number)
            }
        }
        if kill(-pid, number) != 0, errno == ESRCH {
            _ = kill(pid, number)
        }
    }

    func result(includeOutput: Bool) throws -> MCPValue {
        let status = (try? Data(contentsOf: statusURL)).flatMap {
            try? JSONDecoder().decode(MCPWorkerStatus.self, from: $0)
        }
        var value: [String: MCPValue] = [
            "jobID": .string(id), "requestKey": .string(submission.requestKey), "name": .string(submission.name),
            "pid": .number(Double(pid)), "complete": .bool(complete),
            "state": .string(
                complete
                    ? (cancelAt == nil ? "completed" : "cancelled")
                    : (cancelAt == nil ? (status?.admitted == true ? "running" : "queued") : "cancelling")),
        ]
        if let taskID = status?.taskID {
            value["taskID"] = .string(taskID)
        }
        if let plan = status?.plan {
            value["plan"] = try MCPValue.encoded(plan)
        }
        if let waiting = status?.waitingSeconds { value["waitingSeconds"] = .number(waiting) }
        if let sensors = status?.admissionSensors { value["admissionSensors"] = try .encoded(sensors) }
        if let admission = status?.admission { value["admission"] = try .encoded(admission) }
        if let started = status?.admittedAt, let exitedAt {
            value["executionSeconds"] = .number(max(0, exitedAt - started))
        }
        if let checkpoints {
            if !complete, cancelAt == nil { value["state"] = .string(checkpoints.stage) }
            value["completedIterations"] = .number(Double(checkpoints.completedIterations))
            value["iterations"] = .array(checkpoints.iterations)
            value["iterationsTruncated"] = .bool(checkpoints.completedIterations > checkpoints.iterations.count)
            value["progressMessage"] = .string(
                "\(value["state"]?.string ?? checkpoints.stage): iteration \(checkpoints.iteration)")
        }
        if complete {
            let phase =
                status?.error != nil || status?.admitted != true
                ? (status?.admitted == true ? "execution" : "admission") : "command"
            let signal = terminationStatus & 0x7F
            let code = signal == 0 ? (terminationStatus >> 8) & 0xFF : signal
            value["exitCode"] = .number(Double(code))
            value["terminationReason"] = .string(signal == 0 ? "exit" : "signal")
            value["phase"] = .string(phase)
            value["succeeded"] = .bool(cancelAt == nil && phase == "command" && signal == 0 && code == 0)
            if let error = status?.error {
                value["error"] = .string(error)
            }
            if let checkpoints,
                let error = checkpoints.error
                    ?? (cancelAt != nil || (checkpoints.stage == "parked" && checkpoints.completedIterations > 0)
                        ? nil : "Checkpoint process exited without completing its protocol")
            {
                value["succeeded"] = false
                value["error"] = .string(error)
                value["phase"] = "checkpoint"
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
