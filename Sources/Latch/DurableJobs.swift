import Darwin
import Foundation

struct DurableJobRecord: Codable, Equatable {
    var id: String
    var submission: MCPSubmission
    var environment = ProcessInfo.processInfo.environment
    var createdAt = Date()
    var updatedAt = Date()
    var state = "queued"
    var complete = false
    var supervisorPID: Int32?
    var protocolTask = false
    var submissionScope: String?
}

final class DurableJobs {
    static let globalOutstandingLimit = 64
    let scheduler: Scheduler
    let directory: URL

    init(scheduler: Scheduler) throws {
        self.scheduler = scheduler
        directory = scheduler.directory.appendingPathComponent("jobs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
        else {
            throw LatchError("job directory must be private and owned by this user", exitCode: 74)
        }
    }

    func file(_ id: String, _ suffix: String) -> URL {
        directory.appendingPathComponent(id + "." + suffix)
    }

    func records() throws -> [DurableJobRecord] {
        try scheduler.snapshot().jobs
    }

    func submit(_ submission: MCPSubmission, scope: String? = nil) throws -> DurableJobRecord {
        try scheduler.transaction { state in
            var records = state.jobs
            if let existing = records.first(where: { $0.submission.requestKey == submission.requestKey }) {
                guard existing.submission == submission, existing.submissionScope == scope else {
                    throw MCPFailure.invalid("requestKey already belongs to a different submission")
                }
                return existing
            }
            guard state.tasks.count < Self.globalOutstandingLimit,
                records.filter({ !$0.complete }).count < Self.globalOutstandingLimit
            else {
                throw LatchError("shared queue has reached its \(Self.globalOutstandingLimit)-job limit", exitCode: 75)
            }
            let record = DurableJobRecord(id: UUID().uuidString, submission: submission, submissionScope: scope)
            let plan = TaskPlanner.plan(
                arguments: submission.arguments, measurement: submission.measurement,
                classification: submission.classification)
            records.append(record)
            state.jobs = records
            state.tasks.append(
                ScheduledTask(
                    id: record.id, name: submission.name, pid: 0, arguments: [submission.executable] + plan.arguments,
                    requirements: plan.requirements, plan: plan))
            return record
        }
    }

    func markTask(_ id: String) throws {
        try scheduler.transaction { state in
            guard let index = state.jobs.firstIndex(where: { $0.id == id }) else {
                throw MCPFailure.invalid("Unknown jobID")
            }
            state.jobs[index].protocolTask = true
        }
    }

    func publish(_ id: String, result: MCPValue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        try scheduler.transaction { state in
            guard let index = state.jobs.firstIndex(where: { $0.id == id }) else { return }
            try data.write(to: file(id, "result.json"), options: .atomic)
            let phase = result["state"]?.string ?? "queued"
            if state.jobs[index].state != phase {
                state.jobs[index].state = phase
                state.jobs[index].updatedAt = Date()
            }
            if result["complete"] == true {
                try settleControls(id)
                state.jobs[index].complete = true
                state.jobs[index].environment = [:]
                if state.tasks.contains(where: { $0.id == id && $0.state == .running }) {
                    state.resetCooldowns()
                }
                state.tasks.removeAll { $0.id == id }
            }
        }
    }

    func cancel(_ id: String) throws {
        try Data().write(to: file(id, "cancel"), options: .atomic)
    }

    func clearOwn(scopeToken: String) throws -> [String] {
        let scope = try SubmissionScope.validate(scopeToken, in: scheduler.directory)
        return try scheduler.transaction { state in
            var ids: [String] = []
            for record in state.jobs where !record.complete && record.submissionScope == scope {
                guard let index = state.tasks.firstIndex(where: { $0.id == record.id }),
                    state.tasks[index].state == .queued,
                    state.tasks[index].startedAt == nil, state.tasks[index].residentMemoryMiB == nil
                else { continue }
                // Admission holds the same state lock, so a selected job cannot start before cancellation.
                try cancel(record.id)
                state.tasks[index].state = .cancelling
                state.tasks[index].waitingFor = "queued task cancelled within submission scope"
                ids.append(record.id)
            }
            return ids
        }
    }

    func stopOwn(scopeToken: String) throws -> [String] {
        let scope = try SubmissionScope.validate(scopeToken, in: scheduler.directory)
        return try scheduler.transaction { state in
            let ids = state.jobs.filter { !$0.complete && $0.submissionScope == scope }.map(\.id)
            for id in ids { try cancel(id) }
            return ids
        }
    }

    func forget(_ id: String) throws {
        try scheduler.transaction { state in
            guard let record = state.jobs.first(where: { $0.id == id }) else { return }
            guard record.complete else { throw MCPFailure.invalid("Only completed jobs can be forgotten") }
            state.jobs.removeAll { $0.id == id }
            for suffix in [
                "result.json", "cancel", "status.json", "request.json", "supervisor.lock", "controls.json",
                "output.json",
            ] {
                try? FileManager.default.removeItem(at: file(id, suffix))
            }
            let leaseURL = scheduler.directory.appendingPathComponent(id + ".lease")
            if let lease = try? FileLatch(path: leaseURL.path), (try? lease.acquire(shared: false, timeout: 0)) != nil {
                withExtendedLifetime(lease) { try? FileManager.default.removeItem(at: leaseURL) }
            }
        }
    }

    func recover(executable: URL) throws {
        for record in try records() where !record.complete {
            try launch(record.id, executable: executable)
        }
    }

    func launch(_ id: String, executable: URL) throws {
        let supervisor = try FileLatch(path: file(id, "supervisor.lock").path)
        do { try supervisor.acquire(shared: false, timeout: 0) } catch let error as LatchError
            where error.exitCode == 75
        { return }
        // A lost supervisor never permits replay while its old worker or descendants retain the lease.
        let worker = try FileLatch(path: scheduler.directory.appendingPathComponent(id + ".lease").path)
        do { try worker.acquire(shared: false, timeout: 0) } catch let error as LatchError where error.exitCode == 75 {
            return
        }
        worker.release()
        guard let record = try records().first(where: { $0.id == id }), !record.complete else { return }
        if let data = try? Data(contentsOf: file(id, "result.json")),
            let result = try? JSONDecoder().decode(MCPValue.self, from: data), result["complete"] == true
        {
            try publish(id, result: result)
            return
        }
        let task = try scheduler.snapshot().tasks.first { $0.id == id }
        if task?.state == .running || task?.residentMemoryMiB != nil || record.state == "running"
            || record.state == "cancelling" || task == nil
        {
            var result =
                (try? Data(contentsOf: file(id, "result.json")))
                .flatMap { try? JSONDecoder().decode(MCPValue.self, from: $0).object } ?? [:]
            result.merge([
                "jobID": .string(id), "requestKey": .string(record.submission.requestKey),
                "name": .string(record.submission.name),
                "state": "completed", "complete": true, "succeeded": false, "phase": "execution", "exitCode": 74,
                "terminationReason": "unknown",
                "progressMessage": "completed: execution uncertain after supervisor loss",
                "error": "Supervisor was lost; execution may have occurred. This job will not be replayed.",
                "stdout": "", "stderr": "", "stdoutTruncated": true, "stderrTruncated": true,
            ]) { _, terminal in terminal }
            try publish(id, result: .object(result))
            return
        }
        let activity = try FileLatch(path: scheduler.directory.appendingPathComponent("activity.lock").path)
        try activity.acquire(shared: true, timeout: 0)
        try withExtendedLifetime((supervisor, activity)) {
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            func check(_ code: Int32) throws {
                guard code == 0 else {
                    throw LatchError("spawn supervisor: \(String(cString: strerror(code)))", exitCode: 74)
                }
            }
            try check(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }
            try check(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }
            for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
                try check(
                    posix_spawn_file_actions_addopen(
                        &actions, fd, "/dev/null", fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0))
            }
            for fd in [supervisor.descriptor, activity.descriptor] {
                try check(posix_spawn_file_actions_addinherit_np(&actions, fd))
            }
            try check(posix_spawnattr_setpgroup(&attributes, 0))
            var mask = sigset_t(0)
            try check(posix_spawnattr_setsigmask(&attributes, &mask))
            try check(
                posix_spawnattr_setflags(
                    &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)))
            let strings = [
                executable.path, "__mcp_supervisor", scheduler.path, id, String(supervisor.descriptor),
                String(activity.descriptor),
            ].map { strdup($0) }
            let environment = record.environment.map { strdup("\($0.key)=\($0.value)") }
            defer { for pointer in strings + environment { free(pointer) } }
            guard (strings + environment).allSatisfy({ $0 != nil }) else {
                throw LatchError("out of memory", exitCode: 71)
            }
            var argv = strings + [nil]
            var env = environment + [nil]
            var pid: Int32 = 0
            try check(posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &env))
            try scheduler.transaction { state in
                if let index = state.jobs.firstIndex(where: { $0.id == id }) {
                    state.jobs[index].supervisorPID = pid
                }
            }
        }
    }
}

final class MCPJob {
    let id: String
    let submission: MCPSubmission
    let store: DurableJobs
    var record: DurableJobRecord
    private var value: MCPValue
    var complete: Bool {
        value["complete"] == true
    }

    var cancelAt: Double? {
        value["state"] == "cancelled" || value["state"] == "cancelling" ? 0 : nil
    }

    init(record: DurableJobRecord, store: DurableJobs) {
        self.record = record
        id = record.id
        submission = record.submission
        self.store = store
        value = [
            "jobID": .string(record.id), "requestKey": .string(record.submission.requestKey),
            "name": .string(record.submission.name),
            "state": "queued", "complete": false,
        ]
    }

    func update(now _: Double) throws {
        do {
            value = try JSONDecoder().decode(MCPValue.self, from: Data(contentsOf: store.file(id, "result.json")))
        } catch CocoaError.fileReadNoSuchFile {}
        if let pid = record.supervisorPID {
            _ = waitpid(pid, nil, WNOHANG)
        }
    }

    func cancel(now _: Double) throws {
        if !complete {
            try store.cancel(id)
        }
    }

    func result(includeOutput: Bool) throws -> MCPValue {
        var result = value.object ?? [:]
        if !includeOutput {
            for key in ["stdout", "stderr", "stdoutTruncated", "stderrTruncated"] {
                result.removeValue(forKey: key)
            }
        }
        return .object(result)
    }
}
