import Darwin
import Foundation

struct MCPControl: Codable, Equatable {
    var id = UUID().uuidString
    var requestKey: String
    var operation: String
    var signal: String?
    var data: Data?
    var eof = false
    var columns: Int?
    var rows: Int?
    var state = "queued"
    var bytesWritten = 0
    var error: String?

    var complete: Bool {
        !["queued", "applying"].contains(state)
    }

    static let signals: [String: Int32] = ["interrupt": SIGINT, "terminate": SIGTERM, "hangup": SIGHUP, "quit": SIGQUIT,
                                           "stop": SIGSTOP, "continue": SIGCONT, "user1": SIGUSR1, "user2": SIGUSR2]

    init(operation: String, arguments: MCPArguments) throws {
        self.operation = operation
        requestKey = try arguments.text("requestKey", maximum: 128)
        switch operation {
        case "latch_signal":
            signal = try arguments.text("signal")
            guard Self.signals[signal!] != nil else { throw MCPFailure.invalid("unsupported signal") }
        case "latch_input":
            guard arguments.values["text"] == nil || arguments.values["base64"] == nil else { throw MCPFailure.invalid("provide text or base64, not both") }
            if let value = arguments.values["text"] {
                guard let text = value.string else { throw MCPFailure.invalid("text must be a string") }
                data = Data(text.utf8)
            } else if let value = arguments.values["base64"] {
                guard let text = value.string, let bytes = Data(base64Encoded: text) else { throw MCPFailure.invalid("base64 must encode valid bytes") }
                data = bytes
            } else {
                data = Data()
            }
            eof = try arguments.flag("eof")
            guard data!.count <= 16384, !data!.isEmpty || eof else { throw MCPFailure.invalid("input requires 1–16384 bytes, or eof") }
        case "latch_resize":
            guard arguments.values["columns"] != nil, arguments.values["rows"] != nil else { throw MCPFailure.invalid("columns and rows are required") }
            columns = try Int(arguments.number("columns", default: 80, range: 1 ... 1000, integer: true))
            rows = try Int(arguments.number("rows", default: 24, range: 1 ... 1000, integer: true))
        default: throw MCPFailure.invalid("unknown control operation")
        }
    }

    func matches(_ other: Self) -> Bool {
        operation == other.operation && signal == other.signal && data == other.data && eof == other.eof && columns == other.columns && rows == other.rows
    }

    func value(jobID: String) -> MCPValue {
        var result: [String: MCPValue] = ["jobID": .string(jobID), "controlID": .string(id), "requestKey": .string(requestKey),
                                          "state": .string(state), "complete": .bool(complete), "bytesWritten": .number(Double(bytesWritten))]
        if complete {
            result["succeeded"] = .bool(state == "delivered")
        }
        if let error {
            result["error"] = .string(error)
        }
        return .object(result)
    }
}

extension DurableJobs {
    func controls(_ id: String) throws -> [MCPControl] {
        do { return try JSONDecoder().decode([MCPControl].self, from: Data(contentsOf: file(id, "controls.json"))) }
        catch CocoaError.fileReadNoSuchFile { return [] }
    }

    func writeControls(_ id: String, _ controls: [MCPControl]) throws {
        try JSONEncoder().encode(controls).write(to: file(id, "controls.json"), options: .atomic)
    }

    func enqueueControl(_ control: MCPControl, id: String, owner: String) throws -> MCPControl {
        try scheduler.transaction { state in
            guard let job = state.jobs?.first(where: { $0.id == id && $0.owner == owner }) else { throw MCPFailure.invalid("Unknown jobID for this owner") }
            var controls = try controls(id)
            if let previous = controls.first(where: { $0.requestKey == control.requestKey }) {
                guard previous.matches(control) else { throw MCPFailure.invalid("control requestKey belongs to different input") }
                return previous
            }
            guard !job.complete, job.state == "running" else { throw MCPFailure.invalid("controls require a running job; use latch_cancel for queued work") }
            guard controls.count < 64, controls.filter({ !$0.complete }).count < 16 else { throw LatchError("control limit reached; await delivery and forget completed receipts", exitCode: 75) }
            if control.operation == "latch_input" {
                guard controls.filter({ !$0.complete && $0.operation == "latch_input" }).count < 12 else { throw LatchError("pending input limit reached; four control slots remain reserved for signals and resizing", exitCode: 75) }
                guard job.submission.input != "closed" else { throw MCPFailure.invalid("job was submitted with closed stdin") }
                guard !control.eof || job.submission.input == "pipe" else { throw MCPFailure.invalid("eof closes pipe input; for a terminal send its EOF character, usually Ctrl+D (\\u0004)") }
            }
            if control.operation == "latch_resize", job.submission.input != "terminal" {
                throw MCPFailure.invalid("resize requires a terminal job")
            }
            controls.append(control)
            try writeControls(id, controls)
            return control
        }
    }

    func claimControls(_ id: String) throws -> [MCPControl] {
        try scheduler.transaction { _ in
            var controls = try controls(id)
            let pending = controls.filter { $0.state == "queued" }
            if !pending.isEmpty {
                for index in controls.indices where controls[index].state == "queued" {
                    controls[index].state = "applying"
                }
                try writeControls(id, controls)
            }
            return pending
        }
    }

    func acknowledge(_ control: MCPControl, id: String) throws {
        try scheduler.transaction { _ in
            var controls = try controls(id)
            guard let index = controls.firstIndex(where: { $0.id == control.id }) else { return }
            controls[index] = control
            try writeControls(id, controls)
        }
    }

    /// Called inside the completion transaction. Claimed input is never replayed after supervisor loss.
    func settleControls(_ id: String) throws {
        var controls = try controls(id)
        guard controls.contains(where: { !$0.complete }) else { return }
        for index in controls.indices where !controls[index].complete {
            controls[index].state = controls[index].state == "queued" ? "failed" : "unknown"
            controls[index].error = "Job ended before delivery was acknowledged; do not blindly resend input."
        }
        try writeControls(id, controls)
    }

    func forgetControl(_ controlID: String, id: String) throws {
        try scheduler.transaction { _ in
            var controls = try controls(id)
            guard let control = controls.first(where: { $0.id == controlID }), control.complete else { throw MCPFailure.invalid("only completed control receipts can be forgotten") }
            controls.removeAll { $0.id == controlID }
            try writeControls(id, controls)
        }
    }
}

struct MCPLiveOutput: Codable, Equatable {
    var stdout = Data()
    var stderr = Data()
    var stdoutEnd = 0
    var stderrEnd = 0

    mutating func append(_ bytes: Data, output: Bool) {
        if output {
            stdoutEnd += bytes.count
            stdout.append(bytes)
            stdout = Data(stdout.suffix(MCPExecution.outputLimit))
        } else {
            stderrEnd += bytes.count
            stderr.append(bytes)
            stderr = Data(stderr.suffix(MCPExecution.outputLimit))
        }
    }

    func value(stdoutOffset: Int, stderrOffset: Int, complete: Bool) throws -> MCPValue {
        guard stdoutOffset <= stdoutEnd, stderrOffset <= stderrEnd else { throw MCPFailure.invalid("output offset exceeds the stream") }
        func stream(_ data: Data, end: Int, offset: Int) -> MCPValue {
            let start = max(offset, end - data.count)
            let bytes = Data(data.suffix(end - start))
            return ["text": .string(String(decoding: bytes, as: UTF8.self)), "base64": .string(bytes.base64EncodedString()),
                    "startOffset": .number(Double(start)), "nextOffset": .number(Double(end)), "truncated": .bool(start > offset)]
        }
        return ["complete": .bool(complete), "stdout": stream(stdout, end: stdoutEnd, offset: stdoutOffset),
                "stderr": stream(stderr, end: stderrEnd, offset: stderrOffset)]
    }
}

extension MCPTools {
    static let interactiveTools: [MCPValue] = [
        tool("latch_signal", description: "Relay a signal to a running owned job. interrupt sends SIGINT (Ctrl+C semantics). No automatic escalation or job deadline; stop keeps its reservation until continue or explicit cancellation. Returns a delivery receipt; await it with latch_control. Retry identical calls with the same requestKey.", properties: [
            "jobID": ["type": "string"], "requestKey": ["type": "string"],
            "signal": ["type": "string", "enum": .array(MCPControl.signals.keys.sorted().map(MCPValue.string))],
        ], required: ["jobID", "requestKey", "signal"], readOnly: false),
        tool("latch_input", description: "Write literal UTF-8 text or base64 bytes (up to 16 KiB) to an owned pipe/terminal job. Terminal control characters follow its line discipline; Ctrl+C is \\u0003, Ctrl+D is \\u0004. eof closes pipe stdin after these bytes. No shell parsing. Returns a receipt; await latch_control. Delivery means bytes written, not consumed. Retry only with the same requestKey.", properties: [
            "jobID": ["type": "string"], "requestKey": ["type": "string"], "text": ["type": "string"], "base64": ["type": "string"], "eof": ["type": "boolean", "default": false],
        ], required: ["jobID", "requestKey"], readOnly: false, openWorld: true),
        tool("latch_resize", description: "Resize an owned pseudo-terminal; its foreground process group receives SIGWINCH. Await the delivery receipt with latch_control.", properties: [
            "jobID": ["type": "string"], "requestKey": ["type": "string"], "columns": ["type": "integer", "minimum": 1, "maximum": 1000], "rows": ["type": "integer", "minimum": 1, "maximum": 1000],
        ], required: ["jobID", "requestKey", "columns", "rows"], readOnly: false),
        tool("latch_control", description: "Wait for a control receipt, or forget a completed receipt and its retry key with forget=true. Defaults to a 25-second event wait. Pending means wait again with this controlID. unknown means delivery may have happened: never blindly resend. Each job retains 64 receipts, at most 16 pending including at most 12 input writes. Forget only when retries are no longer possible.", properties: [
            "jobID": ["type": "string"], "controlID": ["type": "string"], "timeoutSeconds": ["type": "number", "minimum": 0, "maximum": 600, "default": 25], "forget": ["type": "boolean", "default": false],
        ], required: ["jobID", "controlID"], readOnly: false),
        tool("latch_read", description: "Wait for live output or completion without polling. Pass returned nextOffset values on subsequent reads. Each stream retains its most recent 32 KiB; truncated identifies a gap. base64 preserves exact bytes across UTF-8 boundaries. Terminal output is merged into stdout. Does not consume output for other connections.", properties: [
            "jobID": ["type": "string"], "stdoutOffset": ["type": "integer", "minimum": 0, "default": 0], "stderrOffset": ["type": "integer", "minimum": 0, "default": 0], "timeoutSeconds": ["type": "number", "minimum": 0, "maximum": 600, "default": 25],
        ], required: ["jobID"], readOnly: true),
    ]
}
