import Darwin
import Foundation

final class MCPServer {
    private struct Waiter {
        enum Kind { case tool, execute, taskResult, taskCancel, control, output }
        var requestID: MCPValue
        var jobID: String
        var deadline: Double?
        var kind: Kind = .tool
        var progress: MCPProgress?
        var controlID: String?
        var stdoutOffset = 0
        var stderrOffset = 0
    }

    private let scheduler: Scheduler
    private let executable: URL
    private let directory: URL
    private let queue: Int32
    private let generation: Data?
    private let executableIdentity: [FileAttributeKey: Any]
    private let store: DurableJobs
    private var input = Data()
    private var output = Data()
    private var jobs: [String: MCPJob] = [:]
    private var waiters: [Waiter] = []
    private var tasks: [String: MCPTask] = [:]
    private var supportsTasks = false
    private var directoryDescriptor: Int32 = -1
    private var initialized = false
    private var ready = false
    private var closingAt: Double?
    private var watchingOutput = false

    init(path: String) throws {
        scheduler = try Scheduler(path: URL(fileURLWithPath: path).standardizedFileURL.path)
        store = try DurableJobs(scheduler: scheduler)
        executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        generation = try UpdateDrain.generation(in: scheduler.directory)
        executableIdentity = try FileManager.default.attributesOfItem(atPath: executable.path)
        directory = store.directory
        queue = kqueue()
        guard queue >= 0 else { throw LatchError.system("create MCP event queue") }
        _ = fcntl(queue, F_SETFD, FD_CLOEXEC)
    }

    deinit {
        jobs.removeAll()
        close(queue)
        if directoryDescriptor >= 0 {
            close(directoryDescriptor)
        }
    }

    func run() throws {
        let inputFlags = fcntl(STDIN_FILENO, F_GETFL)
        let outputFlags = fcntl(STDOUT_FILENO, F_GETFL)
        guard inputFlags >= 0, outputFlags >= 0,
            fcntl(STDIN_FILENO, F_SETFL, inputFlags | O_NONBLOCK) == 0,
            fcntl(STDOUT_FILENO, F_SETFL, outputFlags | O_NONBLOCK) == 0
        else { throw LatchError.system("configure MCP stdio") }
        defer {
            _ = fcntl(STDIN_FILENO, F_SETFL, inputFlags)
            _ = fcntl(STDOUT_FILENO, F_SETFL, outputFlags)
        }
        signal(SIGPIPE, SIG_IGN)
        try watch(UInt(STDIN_FILENO), filter: EVFILT_READ)
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            try watch(UInt(number), filter: EVFILT_SIGNAL)
        }
        directoryDescriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw LatchError.system("open durable jobs directory") }
        try watch(UInt(directoryDescriptor), filter: EVFILT_VNODE, flags: EV_ADD | EV_CLEAR, fflags: UInt32(NOTE_WRITE))
        while true {
            if closingAt != nil {
                return
            }
            while waitpid(-1, nil, WNOHANG) > 0 {}
            let now = ProcessInfo.processInfo.systemUptime
            try syncJobs()
            for job in jobs.values {
                try job.update(now: now)
            }
            try updateTasks()
            try updateProgress()
            try finishWaiters(now: now)
            let deadlines = waiters.compactMap(\.deadline)
            let seconds = deadlines.min().map { max(0, $0 - now) }
            var timeout = timespec(
                tv_sec: Int(seconds ?? 0),
                tv_nsec: Int(((seconds ?? 0).truncatingRemainder(dividingBy: 1)) * 1_000_000_000))
            var events = Array(repeating: kevent(), count: 32)
            let count: Int32 =
                if seconds != nil {
                    kevent(queue, nil, 0, &events, Int32(events.count), &timeout)
                } else {
                    kevent(queue, nil, 0, &events, Int32(events.count), nil)
                }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw LatchError.system("wait for MCP events")
            }
            for event in events.prefix(Int(count)) {
                if event.filter == Int16(EVFILT_SIGNAL) {
                    beginClosing()
                    continue
                }
                if event.filter == Int16(EVFILT_PROC) || event.filter == Int16(EVFILT_VNODE) {
                    continue
                }
                let descriptor = Int32(event.ident)
                if descriptor == STDIN_FILENO {
                    if closingAt == nil {
                        try readInput()
                    }
                } else if descriptor == STDOUT_FILENO {
                    try flushOutput()
                }
            }
        }
    }

    private func watch(_ ident: UInt, filter: Int32, flags: Int32 = EV_ADD, fflags: UInt32 = 0) throws {
        var event = kevent(
            ident: ident, filter: Int16(filter), flags: UInt16(flags), fflags: fflags, data: 0, udata: nil)
        guard kevent(queue, &event, 1, nil, 0, nil) == 0 else { throw LatchError.system("register MCP event") }
    }

    private func beginClosing() {
        guard closingAt == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        closingAt = now
        waiters.removeAll()
        output.removeAll()
        try? watch(UInt(STDIN_FILENO), filter: EVFILT_READ, flags: EV_DELETE)
        if watchingOutput {
            try? watch(UInt(STDOUT_FILENO), filter: EVFILT_WRITE, flags: EV_DELETE)
            watchingOutput = false
        }
    }

    private func readInput() throws {
        var buffer = [UInt8](repeating: 0, count: 16384)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count == 0 {
            beginClosing()
            return
        }
        guard count > 0 else {
            if errno != EAGAIN, errno != EINTR {
                beginClosing()
            }
            return
        }
        input.append(contentsOf: buffer.prefix(count))
        while let newline = input.firstIndex(of: 10) {
            let line = Data(input[..<newline])
            input.removeSubrange(...newline)
            if line.count > 1_048_576 {
                throw LatchError("MCP message exceeds 1 MiB", exitCode: 74)
            }
            try receive(line)
            if closingAt != nil {
                return
            }
        }
        guard input.count <= 1_048_576 else { throw LatchError("MCP message exceeds 1 MiB", exitCode: 74) }
    }

    private func receive(_ data: Data) throws {
        let message: MCPValue
        do { message = try JSONDecoder().decode(MCPValue.self, from: data) } catch {
            try failure(id: .null, code: -32700, message: "Parse error")
            return
        }
        guard let envelope = message.object, envelope["jsonrpc"] == "2.0", let method = envelope["method"]?.string
        else {
            // No server-initiated requests are advertised, so unsolicited responses are ignored.
            if message["jsonrpc"] == "2.0", message["method"] == nil,
                message["result"] != nil || message["error"] != nil
            {
                return
            }
            try failure(id: .null, code: -32600, message: "Invalid Request")
            return
        }
        guard let id = envelope["id"] else {
            if method == "notifications/initialized", initialized {
                ready = true
            }
            if method == "notifications/cancelled", let cancelled = message["params"]?["requestId"] {
                waiters.removeAll { $0.requestID == cancelled }
            }
            return
        }
        switch id {
        case .string: break
        case .number(let value) where value.isFinite && value.rounded() == value && abs(value) <= 9_007_199_254_740_991:
            break
        default:
            try failure(id: .null, code: -32600, message: "Request ID must be a string or integer")
            return
        }
        if waiters.contains(where: { $0.requestID == id }) {
            try failure(id: id, code: -32600, message: "Duplicate pending request ID")
            return
        }
        do {
            let params = message["params"] ?? [:]
            guard params.object != nil else { throw MCPFailure.invalid("params must be an object") }
            if method == "initialize" {
                guard !initialized else { throw MCPFailure(code: -32600, message: "Already initialized") }
                guard let requested = params["protocolVersion"]?.string, params["capabilities"]?.object != nil,
                    params["clientInfo"]?["name"]?.string != nil, params["clientInfo"]?["version"]?.string != nil
                else {
                    throw MCPFailure.invalid("initialize requires protocolVersion, capabilities, and clientInfo")
                }
                let version = ["2025-11-25", "2025-06-18"].contains(requested) ? requested : "2025-11-25"
                supportsTasks = version == "2025-11-25"
                var capabilities: [String: MCPValue] = ["tools": ["listChanged": false]]
                if supportsTasks {
                    capabilities["tasks"] = ["list": [:], "cancel": [:], "requests": ["tools": ["call": [:]]]]
                }
                initialized = true
                try respond(
                    id: id,
                    result: [
                        "protocolVersion": .string(version), "capabilities": .object(capabilities),
                        "serverInfo": ["name": "latch", "version": .string(BuildIdentity.version)],
                        "instructions": .string(MCPTools.instructions),
                    ])
            } else if method == "ping" {
                try respond(id: id, result: [:])
            } else {
                guard ready else {
                    throw MCPFailure(
                        code: -32600, message: "Initialize and send notifications/initialized before using tools")
                }
                switch method {
                case "tools/list":
                    guard params["cursor"] == nil else { throw MCPFailure.invalid("No pagination cursor is supported") }
                    try respond(id: id, result: ["tools": .array(MCPTools.listing(tasks: supportsTasks))])
                case "tools/call":
                    guard let name = params["name"]?.string else { throw MCPFailure.invalid("tool name is required") }
                    let progress = try progress(params)
                    let task = supportsTasks ? params["task"] : nil
                    if let task {
                        guard name == "latch_execute" else {
                            throw MCPFailure(code: -32601, message: "Task execution is supported only by latch_execute")
                        }
                        let input = try MCPArguments(task, allowed: ["ttl"])
                        if input.values["ttl"] != nil {
                            _ = try input.number("ttl", default: 0, range: 0...9_007_199_254_740_991, integer: true)
                        }
                    }
                    try call(name, arguments: params["arguments"], id: id, progress: progress, task: task != nil)
                case "tasks/get", "tasks/list", "tasks/result", "tasks/cancel":
                    guard supportsTasks else {
                        throw MCPFailure(code: -32601, message: "Tasks require protocol 2025-11-25")
                    }
                    try taskRequest(method, params: params, id: id)
                default: throw MCPFailure(code: -32601, message: "Method not found: \(method)")
                }
            }
        } catch let error as MCPFailure { try failure(id: id, code: error.code, message: error.message) } catch {
            try toolResult(
                id: id,
                value: [
                    "error": .string(String(describing: error)),
                    "code": .number(Double((error as? LatchError)?.exitCode ?? 74)),
                ], isError: true)
        }
    }

    private func call(_ name: String, arguments: MCPValue?, id: MCPValue, progress: MCPProgress?, task: Bool) throws {
        try syncJobs()
        switch name {
        case "latch_view":
            _ = try MCPArguments(arguments, allowed: [])
            try toolResult(
                id: id,
                value: [
                    "scheduler": MCPValue.encoded(SchedulerView(scheduler: scheduler)),
                    "globalOutstandingLimit": .number(Double(DurableJobs.globalOutstandingLimit)),
                    "globalRetainedLimit": .number(Double(DurableJobs.globalRetainedLimit)),
                    "jobs": .array(jobs.values.sorted { $0.id < $1.id }.map { try $0.result(includeOutput: false) }),
                ])
        case "latch_submit", "latch_execute":
            if name == "latch_execute", !task {
                try requireWaiterSlot()
            }
            let job = try submit(MCPSubmission(arguments))
            if task {
                try store.markTask(job.id)
                let record =
                    tasks[job.id] ?? MCPTask(jobID: job.id, progress: progress, createdAt: job.record.createdAt)
                tasks[job.id] = record
                try respond(id: id, result: ["task": record.value()])
            } else if name == "latch_execute" {
                waiters.append(Waiter(requestID: id, jobID: job.id, kind: .execute, progress: progress))
            } else {
                try reportProgress(progress, job: job)
                try toolResult(id: id, value: job.result(includeOutput: false))
            }
        case "latch_signal", "latch_input", "latch_resize", "latch_control", "latch_read":
            try interactiveCall(name, arguments: arguments, id: id)
        case "latch_wait", "latch_cancel", "latch_forget":
            let input = try MCPArguments(
                arguments, allowed: name == "latch_wait" ? ["jobID", "timeoutSeconds"] : ["jobID"])
            let jobID = try input.text("jobID", maximum: 128)
            if name == "latch_forget", jobs[jobID] == nil {
                try toolResult(id: id, value: ["forgotten": false])
                return
            }
            guard let job = jobs[jobID] else { throw MCPFailure.invalid("Unknown jobID") }
            if name == "latch_cancel" {
                try job.cancel(now: ProcessInfo.processInfo.systemUptime)
                try toolResult(id: id, value: job.result(includeOutput: false))
            } else if name == "latch_forget" {
                guard job.complete else { throw MCPFailure.invalid("Only completed jobs can be forgotten") }
                guard !waiters.contains(where: { $0.jobID == jobID }) else {
                    throw MCPFailure.invalid("Job still has pending requests")
                }
                try store.forget(jobID)
                jobs.removeValue(forKey: jobID)
                tasks.removeValue(forKey: jobID)
                try toolResult(id: id, value: ["forgotten": true])
            } else {
                let timeout = try input.number("timeoutSeconds", default: 25, range: 0...600)
                if job.complete || timeout == 0 {
                    try reportProgress(progress, job: job)
                    try toolResult(
                        id: id, value: job.result(includeOutput: true),
                        isError: job.complete && job.result(includeOutput: false)["succeeded"] == false)
                } else {
                    try requireWaiterSlot()
                    waiters.append(
                        Waiter(
                            requestID: id, jobID: jobID, deadline: ProcessInfo.processInfo.systemUptime + timeout,
                            progress: progress))
                }
            }
        default: throw MCPFailure.invalid("Unknown tool: \(name)")
        }
    }

    private func submit(_ submission: MCPSubmission) throws -> MCPJob {
        if let existing = jobs.values.first(where: { $0.submission.requestKey == submission.requestKey }) {
            guard existing.submission == submission else {
                throw MCPFailure.invalid("requestKey already belongs to a different submission")
            }
            return existing
        }
        let updatePermit = try UpdateDrain.admit(in: scheduler.directory)
        defer { withExtendedLifetime(updatePermit) {} }
        let identity = try FileManager.default.attributesOfItem(atPath: executable.path)
        guard try UpdateDrain.generation(in: scheduler.directory) == generation,
            identity[.systemFileNumber] as? NSNumber == executableIdentity[.systemFileNumber] as? NSNumber,
            identity[.systemNumber] as? NSNumber == executableIdentity[.systemNumber] as? NSNumber
        else {
            throw LatchError(
                "Latch was updated; retrieve retained results, then reconnect this MCP host before submitting new work",
                exitCode: 69)
        }
        _ = try SchedulerService.requireRunning(in: scheduler.directory)
        guard try SchedulerService.status(in: scheduler.directory).serviceRevision == BuildIdentity.serviceRevision
        else {
            throw LatchError(
                "durable jobs require the updated scheduler service; ask the operator to update it", exitCode: 69)
        }
        let record = try store.submit(submission)
        let job = MCPJob(record: record, store: store)
        jobs[job.id] = job
        // The ticket is committed before launch; the service recovers a missed launch after a connection crash.
        try? store.launch(record.id, executable: executable)
        return job
    }

    private func syncJobs() throws {
        let records = try store.records()
        for record in records {
            let job = jobs[record.id] ?? MCPJob(record: record, store: store)
            job.record = record
            try job.update(now: ProcessInfo.processInfo.systemUptime)
            jobs[record.id] = job
            if record.protocolTask, tasks[record.id] == nil {
                tasks[record.id] = MCPTask(jobID: record.id, progress: nil, createdAt: record.createdAt)
            }
        }
        let ids = Set(records.map(\.id))
        for id in jobs.keys where !ids.contains(id) {
            let forgotten = waiters.filter { $0.jobID == id }
            waiters.removeAll { $0.jobID == id }
            for waiter in forgotten {
                try failure(id: waiter.requestID, code: -32602, message: "Job was forgotten by another connection")
            }
            jobs.removeValue(forKey: id)
            tasks.removeValue(forKey: id)
        }
    }

    private func requireWaiterSlot() throws {
        guard waiters.count < 128 else { throw MCPFailure.invalid("Too many pending waits") }
    }

    private func interactiveCall(_ name: String, arguments: MCPValue?, id: MCPValue) throws {
        let fields: Set<String> =
            switch name {
            case "latch_signal": ["jobID", "requestKey", "signal"]
            case "latch_input": ["jobID", "requestKey", "text", "base64", "eof"]
            case "latch_resize": ["jobID", "requestKey", "columns", "rows"]
            case "latch_control": ["jobID", "controlID", "timeoutSeconds", "forget"]
            default: ["jobID", "stdoutOffset", "stderrOffset", "timeoutSeconds"]
            }
        let input = try MCPArguments(arguments, allowed: fields)
        let jobID = try input.text("jobID", maximum: 128)
        guard let job = jobs[jobID] else { throw MCPFailure.invalid("Unknown jobID") }
        if name == "latch_control" {
            let controlID = try input.text("controlID", maximum: 128)
            guard let control = try store.controls(jobID).first(where: { $0.id == controlID }) else {
                throw MCPFailure.invalid("Unknown controlID")
            }
            if try input.flag("forget") {
                try store.forgetControl(controlID, id: jobID)
                try toolResult(id: id, value: ["forgotten": true])
            } else {
                try requireWaiterSlot()
                let timeout = try input.number("timeoutSeconds", default: 25, range: 0...600)
                if control.complete || timeout == 0 {
                    try toolResult(
                        id: id, value: control.value(jobID: jobID),
                        isError: control.complete && control.state != "delivered")
                } else {
                    waiters.append(
                        Waiter(
                            requestID: id, jobID: jobID, deadline: ProcessInfo.processInfo.systemUptime + timeout,
                            kind: .control, controlID: controlID))
                }
            }
        } else if name == "latch_read" {
            try requireWaiterSlot()
            let stdout = try Int(
                input.number("stdoutOffset", default: 0, range: 0...9_007_199_254_740_991, integer: true))
            let stderr = try Int(
                input.number("stderrOffset", default: 0, range: 0...9_007_199_254_740_991, integer: true))
            _ = try readOutput(jobID).value(stdoutOffset: stdout, stderrOffset: stderr, complete: job.complete)
            let timeout = try input.number("timeoutSeconds", default: 25, range: 0...600)
            waiters.append(
                Waiter(
                    requestID: id, jobID: jobID, deadline: ProcessInfo.processInfo.systemUptime + timeout,
                    kind: .output, stdoutOffset: stdout, stderrOffset: stderr))
        } else {
            let control = try store.enqueueControl(MCPControl(operation: name, arguments: input), id: jobID)
            try toolResult(
                id: id, value: control.value(jobID: jobID), isError: control.complete && control.state != "delivered")
        }
    }

    private func readOutput(_ id: String) throws -> MCPLiveOutput {
        do {
            return try JSONDecoder().decode(MCPLiveOutput.self, from: Data(contentsOf: store.file(id, "output.json")))
        } catch CocoaError.fileReadNoSuchFile { return MCPLiveOutput() }
    }

    private func progress(_ params: MCPValue) throws -> MCPProgress? {
        guard let meta = params["_meta"] else { return nil }
        guard meta.object != nil else { throw MCPFailure.invalid("_meta must be an object") }
        guard let token = meta["progressToken"] else { return nil }
        switch token {
        case .string: break
        case .number(let value) where value.isFinite && value.rounded() == value && abs(value) <= 9_007_199_254_740_991:
            break
        default: throw MCPFailure.invalid("progressToken must be a string or integer")
        }
        let active = waiters.compactMap(\.progress) + tasks.values.filter { !$0.terminal }.compactMap(\.progress)
        guard !active.contains(where: { $0.token == token }) else {
            throw MCPFailure.invalid("progressToken is already active")
        }
        return MCPProgress(token: token)
    }

    private func notify(_ method: String, params: MCPValue) throws {
        guard ready else { return }
        try emit(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    private func reportProgress(_ progress: MCPProgress?, job: MCPJob) throws {
        let result = try job.result(includeOutput: false)
        guard let progress, let state = result["progressMessage"]?.string ?? result["state"]?.string,
            let params = progress.update(state: state)
        else { return }
        try notify("notifications/progress", params: params)
    }

    private func updateProgress() throws {
        for waiter in waiters {
            if let job = jobs[waiter.jobID] {
                try reportProgress(waiter.progress, job: job)
            }
        }
    }

    private func updateTasks() throws {
        for task in tasks.values {
            guard let job = jobs[task.jobID], !task.terminal else { continue }
            let changed = try task.update(job: job)
            if task.terminal {
                let value = try job.result(includeOutput: true)
                task.result = try resultValue(value: value, isError: value["succeeded"] == false, taskID: task.jobID)
            }
            if let params = task.progress?.update(state: task.message, taskID: task.jobID) {
                try notify("notifications/progress", params: params)
            }
            if changed {
                try notify("notifications/tasks/status", params: task.value())
            }
        }
    }

    private func taskRequest(_ method: String, params: MCPValue, id: MCPValue) throws {
        try syncJobs()
        for job in jobs.values {
            try job.update(now: ProcessInfo.processInfo.systemUptime)
        }
        try updateTasks()
        let input = try MCPArguments(
            params, allowed: method == "tasks/list" ? ["cursor", "_meta"] : ["taskId", "_meta"])
        if method == "tasks/list" {
            guard input.values["cursor"] == nil else { throw MCPFailure.invalid("No pagination cursor is supported") }
            try respond(
                id: id, result: ["tasks": .array(tasks.values.sorted { $0.jobID < $1.jobID }.map { try $0.value() })])
            return
        }
        let taskID = try input.text("taskId", maximum: 128)
        guard let task = tasks[taskID], let job = jobs[taskID] else { throw MCPFailure.invalid("Unknown taskId") }
        if method == "tasks/get" {
            try respond(id: id, result: task.value())
        } else if method == "tasks/cancel" {
            guard !task.terminal else { throw MCPFailure.invalid("Cannot cancel a terminal task") }
            try requireWaiterSlot()
            try job.cancel(now: ProcessInfo.processInfo.systemUptime)
            // Reply only after process-group cleanup; cancelled is terminal and its result must be final.
            waiters.append(Waiter(requestID: id, jobID: taskID, kind: .taskCancel))
        } else {
            try requireWaiterSlot()
            waiters.append(Waiter(requestID: id, jobID: taskID, kind: .taskResult))
        }
    }

    private func finishWaiters(now: Double) throws {
        for waiter in waiters where waiter.kind == .control || waiter.kind == .output {
            guard let job = jobs[waiter.jobID] else { continue }
            let expired = waiter.deadline.map { $0 <= now } ?? false
            if waiter.kind == .control {
                guard let control = try store.controls(waiter.jobID).first(where: { $0.id == waiter.controlID }) else {
                    waiters.removeAll { $0.requestID == waiter.requestID }
                    try failure(id: waiter.requestID, code: -32602, message: "Control receipt was forgotten")
                    continue
                }
                if !control.complete, !expired {
                    continue
                }
                waiters.removeAll { $0.requestID == waiter.requestID }
                try toolResult(
                    id: waiter.requestID, value: control.value(jobID: job.id),
                    isError: control.complete && control.state != "delivered")
            } else {
                let output = try readOutput(job.id)
                if !job.complete, !expired, output.stdoutEnd == waiter.stdoutOffset,
                    output.stderrEnd == waiter.stderrOffset
                {
                    continue
                }
                waiters.removeAll { $0.requestID == waiter.requestID }
                var value = try output.value(
                    stdoutOffset: waiter.stdoutOffset, stderrOffset: waiter.stderrOffset, complete: job.complete
                ).object!
                value["jobID"] = .string(job.id)
                try toolResult(id: waiter.requestID, value: .object(value))
            }
        }
        let finished = waiters.filter {
            $0.kind != .control && $0.kind != .output
                && (jobs[$0.jobID]?.complete == true || ($0.deadline.map { $0 <= now } ?? false))
        }
        waiters.removeAll { waiter in finished.contains { $0.requestID == waiter.requestID } }
        for waiter in finished {
            guard let job = jobs[waiter.jobID] else { continue }
            if waiter.kind == .taskCancel, let task = tasks[waiter.jobID] {
                try respond(id: waiter.requestID, result: task.value())
                continue
            }
            if waiter.kind == .taskResult, let result = tasks[waiter.jobID]?.result {
                try respond(id: waiter.requestID, result: result)
                continue
            }
            let result = try job.result(includeOutput: true)
            try toolResult(
                id: waiter.requestID, value: result, isError: job.complete && result["succeeded"] == false,
                taskID: waiter.kind == .taskResult ? waiter.jobID : nil)
        }
    }

    private func toolResult(id: MCPValue, value: MCPValue, isError: Bool = false, taskID: String? = nil) throws {
        try respond(id: id, result: resultValue(value: value, isError: isError, taskID: taskID))
    }

    private func resultValue(value: MCPValue, isError: Bool, taskID: String?) throws -> MCPValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = try String(decoding: encoder.encode(value), as: UTF8.self)
        var result: [String: MCPValue] = [
            "content": [["type": "text", "text": .string(text)]], "structuredContent": value, "isError": .bool(isError),
        ]
        if let taskID {
            result["_meta"] = MCPTask.metadata(taskID)
        }
        return .object(result)
    }

    private func respond(id: MCPValue, result: MCPValue) throws {
        try emit(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func failure(id: MCPValue, code: Int, message: String) throws {
        try emit(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]])
    }

    private func emit(_ value: MCPValue) throws {
        guard closingAt == nil else { return }
        let data = try JSONEncoder().encode(value)
        guard output.count + data.count < 4 * 1_048_576 else {
            throw LatchError("MCP client is not consuming responses", exitCode: 74)
        }
        output.append(data)
        output.append(10)
        try flushOutput()
    }

    private func flushOutput() throws {
        while !output.isEmpty {
            let count = output.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if count > 0 {
                output.removeFirst(count)
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN {
                break
            } else {
                beginClosing()
                return
            }
        }
        if !output.isEmpty, !watchingOutput {
            try watch(UInt(STDOUT_FILENO), filter: EVFILT_WRITE)
            watchingOutput = true
        }
        if output.isEmpty, watchingOutput {
            try watch(UInt(STDOUT_FILENO), filter: EVFILT_WRITE, flags: EV_DELETE)
            watchingOutput = false
        }
    }
}
