import Darwin
import Foundation

final class MCPServer {
    private struct Waiter {
        var requestID: MCPValue
        var jobID: String
        var deadline: Double
    }

    private let scheduler: Scheduler
    private let executable: URL
    private let directory: URL
    private let queue: Int32
    private var input = Data()
    private var output = Data()
    private var jobs: [String: MCPJob] = [:]
    private var waiters: [Waiter] = []
    private var initialized = false
    private var ready = false
    private var closingAt: Double?
    private var watchingOutput = false
    private var directoryCreated = false

    init(path: String) throws {
        scheduler = try Scheduler(path: URL(fileURLWithPath: path).standardizedFileURL.path)
        executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        directory = scheduler.directory.appendingPathComponent("mcp-" + UUID().uuidString, isDirectory: true)
        queue = kqueue()
        guard queue >= 0 else { throw LatchError.system("create MCP event queue") }
        _ = fcntl(queue, F_SETFD, FD_CLOEXEC)
    }

    deinit {
        for job in jobs.values where !job.complete {
            job.signalGroup(SIGKILL)
        }
        jobs.removeAll()
        close(queue)
        if directoryCreated {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func run() throws {
        let inputFlags = fcntl(STDIN_FILENO, F_GETFL)
        let outputFlags = fcntl(STDOUT_FILENO, F_GETFL)
        guard inputFlags >= 0, outputFlags >= 0,
              fcntl(STDIN_FILENO, F_SETFL, inputFlags | O_NONBLOCK) == 0,
              fcntl(STDOUT_FILENO, F_SETFL, outputFlags | O_NONBLOCK) == 0 else { throw LatchError.system("configure MCP stdio") }
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
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            for job in jobs.values {
                job.update(now: now)
            }
            try finishWaiters(now: now)
            if let closingAt, jobs.values.allSatisfy(\.complete) || now - closingAt >= 3 {
                return
            }
            var deadlines = waiters.map(\.deadline)
            for job in jobs.values where !job.complete {
                if let cancel = job.cancelAt, !job.killSent {
                    deadlines.append(cancel + 2)
                }
                if let exited = job.exitedAt {
                    deadlines.append(exited + 2)
                }
            }
            if let closingAt {
                deadlines.append(closingAt + 3)
            }
            let seconds = deadlines.min().map { max(0, $0 - now) }
            var timeout = timespec(tv_sec: Int(seconds ?? 0), tv_nsec: Int(((seconds ?? 0).truncatingRemainder(dividingBy: 1)) * 1_000_000_000))
            var events = Array(repeating: kevent(), count: 32)
            let count: Int32 = if seconds != nil {
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
                    beginClosing(); continue
                }
                if event.filter == Int16(EVFILT_PROC) {
                    continue
                }
                let descriptor = Int32(event.ident)
                if descriptor == STDIN_FILENO {
                    if closingAt == nil {
                        try readInput()
                    }
                } else if descriptor == STDOUT_FILENO {
                    try flushOutput()
                } else if let job = jobs.values.first(where: { $0.descriptors.contains(descriptor) }) {
                    job.drain(descriptor)
                }
            }
        }
    }

    private func watch(_ ident: UInt, filter: Int32, flags: Int32 = EV_ADD, fflags: UInt32 = 0) throws {
        var event = kevent(ident: ident, filter: Int16(filter), flags: UInt16(flags), fflags: fflags, data: 0, udata: nil)
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
            try? watch(UInt(STDOUT_FILENO), filter: EVFILT_WRITE, flags: EV_DELETE); watchingOutput = false
        }
        for job in jobs.values {
            job.cancel(now: now)
        }
    }

    private func readInput() throws {
        var buffer = [UInt8](repeating: 0, count: 16384)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count == 0 {
            beginClosing(); return
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
        do { message = try JSONDecoder().decode(MCPValue.self, from: data) }
        catch { try failure(id: .null, code: -32700, message: "Parse error"); return }
        guard let envelope = message.object, envelope["jsonrpc"] == "2.0", let method = envelope["method"]?.string else {
            // No server-initiated requests are advertised, so unsolicited responses are ignored.
            if message["jsonrpc"] == "2.0", message["method"] == nil, message["result"] != nil || message["error"] != nil {
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
        case let .number(value) where value.isFinite && value.rounded() == value && abs(value) <= 9_007_199_254_740_991: break
        default: try failure(id: .null, code: -32600, message: "Request ID must be a string or integer"); return
        }
        if waiters.contains(where: { $0.requestID == id }) {
            try failure(id: id, code: -32600, message: "Duplicate pending request ID"); return
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
                initialized = true
                try respond(id: id, result: ["protocolVersion": .string(version), "capabilities": ["tools": ["listChanged": false]],
                                             "serverInfo": ["name": "latch", "version": "0.3.0"], "instructions": .string(MCPTools.instructions)])
            } else if method == "ping" {
                try respond(id: id, result: [:])
            } else {
                guard ready else { throw MCPFailure(code: -32600, message: "Initialize and send notifications/initialized before using tools") }
                switch method {
                case "tools/list":
                    guard params["cursor"] == nil else { throw MCPFailure.invalid("No pagination cursor is supported") }
                    try respond(id: id, result: ["tools": .array(MCPTools.list)])
                case "tools/call":
                    guard let name = params["name"]?.string else { throw MCPFailure.invalid("tool name is required") }
                    try call(name, arguments: params["arguments"], id: id)
                default: throw MCPFailure(code: -32601, message: "Method not found: \(method)")
                }
            }
        } catch let error as MCPFailure { try failure(id: id, code: error.code, message: error.message) }
        catch {
            try toolResult(id: id, value: ["error": .string(String(describing: error)), "code": .number(Double((error as? LatchError)?.exitCode ?? 74))], isError: true)
        }
    }

    private func call(_ name: String, arguments: MCPValue?, id: MCPValue) throws {
        switch name {
        case "latch_view":
            _ = try MCPArguments(arguments, allowed: [])
            try toolResult(id: id, value: ["scheduler": MCPValue.encoded(SchedulerView(scheduler: scheduler)),
                                           "jobs": .array(jobs.values.sorted { $0.id < $1.id }.map { try $0.result(includeOutput: false) })])
        case "latch_submit":
            let submission = try MCPSubmission(arguments)
            if let existing = jobs.values.first(where: { $0.submission.requestKey == submission.requestKey }) {
                guard existing.submission == submission else { throw MCPFailure.invalid("requestKey already belongs to a different submission") }
                try toolResult(id: id, value: existing.result(includeOutput: false))
                return
            }
            guard jobs.count < 64 else { throw LatchError("connection holds 64 jobs; forget completed jobs before submitting more", exitCode: 75) }
            _ = try SchedulerService.requireRunning(in: scheduler.directory)
            if !directoryCreated {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                directoryCreated = true
            }
            let job = try MCPJob(submission: submission, directory: directory, path: scheduler.path, executable: executable)
            jobs[job.id] = job
            do {
                for descriptor in job.descriptors {
                    try watch(UInt(descriptor), filter: EVFILT_READ)
                }
            } catch {
                job.signalGroup(SIGKILL)
                jobs.removeValue(forKey: job.id)
                throw error
            }
            // A child that already exited is detected by update without waiting for another event.
            try? watch(UInt(job.pid), filter: EVFILT_PROC, flags: EV_ADD | EV_ONESHOT, fflags: UInt32(NOTE_EXIT))
            try toolResult(id: id, value: job.result(includeOutput: false))
        case "latch_wait", "latch_cancel", "latch_forget":
            let input = try MCPArguments(arguments, allowed: name == "latch_wait" ? ["jobID", "timeoutSeconds"] : ["jobID"])
            let jobID = try input.text("jobID", maximum: 128)
            if name == "latch_forget", jobs[jobID] == nil {
                try toolResult(id: id, value: ["forgotten": false]); return
            }
            guard let job = jobs[jobID] else { throw MCPFailure.invalid("Unknown jobID for this connection") }
            if name == "latch_cancel" {
                job.cancel(now: ProcessInfo.processInfo.systemUptime)
                try toolResult(id: id, value: job.result(includeOutput: false))
            } else if name == "latch_forget" {
                guard job.complete else { throw MCPFailure.invalid("Only completed jobs can be forgotten") }
                jobs.removeValue(forKey: jobID)
                try toolResult(id: id, value: ["forgotten": true])
            } else {
                let timeout = try input.number("timeoutSeconds", default: 25, range: 0 ... 600)
                if job.complete || timeout == 0 {
                    try toolResult(id: id, value: job.result(includeOutput: true), isError: job.complete && job.result(includeOutput: false)["succeeded"] == false)
                } else {
                    guard waiters.count < 128 else { throw MCPFailure.invalid("Too many pending waits") }
                    waiters.append(Waiter(requestID: id, jobID: jobID, deadline: ProcessInfo.processInfo.systemUptime + timeout))
                }
            }
        default: throw MCPFailure.invalid("Unknown tool: \(name)")
        }
    }

    private func finishWaiters(now: Double) throws {
        let finished = waiters.filter { jobs[$0.jobID]?.complete == true || $0.deadline <= now }
        waiters.removeAll { waiter in finished.contains { $0.requestID == waiter.requestID } }
        for waiter in finished {
            guard let job = jobs[waiter.jobID] else { continue }
            let result = try job.result(includeOutput: true)
            try toolResult(id: waiter.requestID, value: result, isError: job.complete && result["succeeded"] == false)
        }
    }

    private func toolResult(id: MCPValue, value: MCPValue, isError: Bool = false) throws {
        let text = try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
        try respond(id: id, result: ["content": [["type": "text", "text": .string(text)]], "structuredContent": value, "isError": .bool(isError)])
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
        guard output.count + data.count < 4 * 1_048_576 else { throw LatchError("MCP client is not consuming responses", exitCode: 74) }
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
                beginClosing(); return
            }
        }
        if !output.isEmpty, !watchingOutput {
            try watch(UInt(STDOUT_FILENO), filter: EVFILT_WRITE); watchingOutput = true
        }
        if output.isEmpty, watchingOutput {
            try watch(UInt(STDOUT_FILENO), filter: EVFILT_WRITE, flags: EV_DELETE); watchingOutput = false
        }
    }
}
