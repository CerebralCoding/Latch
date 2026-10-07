import Darwin
import Foundation

// State-file locks and output reads never block the terminal event loop.
final class DashboardWorker: @unchecked Sendable {
    struct Update {
        var snapshot: DashboardSnapshot?
        var error: String?
        var outputID: String?
        var output: [String] = []
        var actionMessage: String?
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "latch.operator.snapshot", qos: .utility)
    private var running = false
    private var update: Update?
    private var scheduler: Scheduler?

    @discardableResult
    func request(path: String, outputID: String?, action: DashboardAction? = nil) -> Bool {
        lock.lock()
        guard !running, update == nil else {
            lock.unlock()
            return false
        }
        running = true
        lock.unlock()
        queue.async {
            var result = Update()
            do {
                if self.scheduler == nil { self.scheduler = try Scheduler(path: path) }
                let scheduler = self.scheduler!
                if let action {
                    do { result.actionMessage = try action.perform(queue: OperatorQueue(scheduler: scheduler)) } catch {
                        result.actionMessage = "Action failed: \(error). Inspect current state before retrying."
                    }
                }
                let snapshot = try DashboardSnapshot(scheduler: scheduler)
                result.snapshot = snapshot
                if let outputID {
                    result.outputID = outputID
                    do { result.output = try Self.output(id: outputID, snapshot: snapshot, scheduler: scheduler) } catch
                    { result.output = ["Output unavailable: \(error)"] }
                }
            } catch { result.error = String(describing: error) }
            self.lock.lock()
            self.update = result
            self.running = false
            self.lock.unlock()
        }
        return true
    }

    func take() -> Update? {
        lock.lock()
        defer { lock.unlock() }
        let result = update
        update = nil
        return result
    }

    static func output(id: String, snapshot: DashboardSnapshot, scheduler: Scheduler) throws -> [String] {
        guard UUID(uuidString: id) != nil else { throw LatchError("invalid job ID") }
        guard let record = snapshot.records.first(where: { $0.id == id }) else {
            return ["CLI output belongs to the terminal that launched the command; it is not retained by Latch."]
        }
        let directory = scheduler.directory.appendingPathComponent("jobs")
        var lines: [String] = []
        let resultURL = directory.appendingPathComponent(id + ".result.json")
        if FileManager.default.fileExists(atPath: resultURL.path) {
            let result = try JSONDecoder().decode(MCPValue.self, from: Data(contentsOf: resultURL))
            for key in ["state", "phase", "exitCode", "terminationReason", "completedIterations", "error"] {
                if let value = result[key] {
                    let text: String
                    if case .number(let number) = value {
                        text = String(format: "%.0f", number)
                    } else {
                        text = value.string ?? ""
                    }
                    if !text.isEmpty { lines.append("\(key): \(text)") }
                }
            }
            if record.complete {
                for key in ["stdout", "stderr"] {
                    lines.append(
                        "\(key.uppercased()) · retained beginning"
                            + (result[key + "Truncated"] == true ? " · TRUNCATED" : ""))
                    lines += outputLines(result[key]?.string ?? "")
                }
                return lines
            }
        }
        let liveURL = directory.appendingPathComponent(id + ".output.json")
        if FileManager.default.fileExists(atPath: liveURL.path) {
            let output = try JSONDecoder().decode(MCPLiveOutput.self, from: Data(contentsOf: liveURL))
            lines.append(
                "STDOUT · recent tail" + (output.stdoutEnd > output.stdout.count ? " · earlier bytes omitted" : ""))
            lines += outputLines(String(decoding: output.stdout, as: UTF8.self))
            lines.append(
                "STDERR · recent tail" + (output.stderrEnd > output.stderr.count ? " · earlier bytes omitted" : ""))
            lines += outputLines(String(decoding: output.stderr, as: UTF8.self))
        } else {
            lines.append("No retained output yet.")
        }
        return lines
    }

    private static func outputLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return ["(empty)"] }
        return String(text.prefix(32768)).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

enum OperatorDashboard {
    static func run(path: String, interval: Double?) throws {
        let terminal = try TerminalSession()
        defer { terminal.restore() }
        let preferences = DashboardPreferences()
        let worker = DashboardWorker()
        var model = DashboardModel(interval: interval ?? preferences.loadInterval())
        if interval != nil { saveInterval(model: &model, preferences: preferences) }
        var input = TerminalInput()
        var previous: TerminalScreen?
        var nextRefresh = 0.0
        var pending: DashboardAction?
        var dirty = true
        let color = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        while true {
            if let update = worker.take() {
                dirty = true
                if let message = update.actionMessage {
                    model.notice = message
                    model.busy = false
                }
                if !model.paused || model.busy || update.actionMessage != nil {
                    if let snapshot = update.snapshot { model.ingest(snapshot) }
                    if let error = update.error { model.failed(error) }
                    model.outputID = update.outputID
                    model.outputLines = update.output
                }
                if model.busy, update.error != nil, pending == nil {
                    model.busy = false
                    model.notice = "Action outcome unavailable. Inspect the queue before retrying."
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let action = pending {
                if worker.request(
                    path: path, outputID: model.details ? model.selectedID : nil, action: action)
                {
                    pending = nil
                    nextRefresh = now + model.interval
                }
            } else if !model.paused, now >= nextRefresh {
                if worker.request(path: path, outputID: model.details ? model.selectedID : nil) {
                    nextRefresh = now + model.interval
                }
            }
            let size = terminal.size
            if dirty || previous?.width != min(500, size.width) || previous?.height != min(200, size.height) {
                let screen = DashboardRenderer.render(&model, width: size.width, height: size.height)
                let changes = screen.ansi(previous: previous, color: color)
                if !changes.isEmpty { try terminal.write(changes) }
                previous = screen
                dirty = false
            }
            let keys: [TerminalKey]
            switch try terminal.nextEvent() {
            case .input(let data): keys = input.feed(data)
            case .idle: keys = input.feed(Data(), flushEscape: true)
            case .end: return
            case .signal(let signal):
                if signal == SIGWINCH || signal == SIGCONT {
                    previous = nil
                    continue
                }
                if signal == SIGTSTP {
                    try terminal.suspend()
                    previous = nil
                    continue
                }
                return
            }
            for key in keys {
                dirty = true
                if key == .suspend {
                    try terminal.suspend()
                    previous = nil
                    continue
                }
                if key == .quit { return }
                let oldDetails = model.details
                let oldInterval = model.interval
                let oldPaused = model.paused
                if handle(key, model: &model, pending: &pending) { return }
                if oldInterval != model.interval { saveInterval(model: &model, preferences: preferences) }
                if oldDetails != model.details || oldInterval != model.interval
                    || oldPaused != model.paused
                {
                    nextRefresh = 0
                }
            }
        }
    }

    private static func saveInterval(model: inout DashboardModel, preferences: DashboardPreferences) {
        do {
            try preferences.saveInterval(model.interval)
            model.notice = "Refresh interval saved: \(HumanOutput.duration(model.interval))."
        } catch {
            model.notice = "Refresh interval applies this session; could not save setting: \(error)"
        }
    }

    // Returns true only for an explicit quit, never for pasted or unknown escape sequences.
    static func handle(_ key: TerminalKey, model: inout DashboardModel, pending: inout DashboardAction?) -> Bool {
        if model.confirmation != nil {
            scrollModal(key, model: &model)
            if key == .character("y"), !model.busy {
                pending = model.confirmation
                model.busy = true
            }
            if [.character("y"), .character("n"), .escape, .enter, .character("q")].contains(key) {
                model.confirmation = nil
            }
            return false
        }
        if let modal = model.modal {
            scrollModal(key, model: &model)
            let toggle: TerminalKey = modal == .help ? .character("?") : .character("i")
            if [toggle, .escape, .character("q")].contains(key) { model.modal = nil }
            return false
        }
        if model.editingFilter {
            switch key {
            case .tab:
                model.editingFilter = false
            case .escape:
                model.filter = ""
                model.editingFilter = false
            case .enter: model.editingFilter = false
            case .backspace: if !model.filter.isEmpty { model.filter.removeLast() }
            case .character(let character): if model.filter.count < 128 { model.filter.append(character) }
            default: break
            }
            model.reconcileSelection()
            return false
        }
        switch key {
        case .character("q"), .quit:
            if model.busy {
                model.notice = "Waiting for the confirmed queue action to finish."
                return false
            }
            return true
        case .character("?"):
            model.modal = .help
            model.modalOffset = 0
        case .character("i"):
            model.modal = .sensors
            model.modalOffset = 0
        case .escape:
            if model.details {
                model.details = false
                model.reconcileSelection()
            } else {
                model.filter = ""
                model.reconcileSelection()
            }
        case .tab:
            if model.details {
                model.details = false
                model.reconcileSelection()
            } else if model.selected != nil {
                model.details = true
            }
        case .character(" "):
            if !model.busy {
                model.paused.toggle()
                model.addGap()
                model.notice =
                    model.paused
                    ? "Display frozen. Scheduler and jobs continue; controls disabled." : "Display resumed."
            }
        case .character("+"), .character("="): model.interval = max(0.5, model.interval / 2)
        case .character("-"): model.interval = min(60, model.interval * 2)
        case .up, .character("k"): model.move(-1)
        case .down, .character("j"): model.move(1)
        case .pageUp: model.move(-10)
        case .pageDown: model.move(10)
        case .home: model.move(-1_000_000)
        case .end: model.move(1_000_000)
        case .enter:
            if model.selected != nil {
                model.details = true
            }
        case .character("/"):
            model.details = false
            model.editingFilter = true
        case .character("s"):
            guard !model.details else { break }
            let sorts = DashboardModel.Sort.allCases
            model.sort = sorts[(sorts.firstIndex(of: model.sort)! + 1) % sorts.count]
        case .character("h"):
            model.showHistory.toggle()
            model.details = false
            model.reconcileSelection()
        case .character("P"): model.prepare(.prioritize)
        case .character("x"): model.prepare(.cancel)
        case .character("C"): model.prepare(.clear)
        case .character("S"): model.prepare(.stop)
        default: break
        }
        return false
    }

    private static func scrollModal(_ key: TerminalKey, model: inout DashboardModel) {
        switch key {
        case .up, .character("k"): model.modalOffset = max(0, model.modalOffset - 1)
        case .down, .character("j"): model.modalOffset += 1
        case .pageUp: model.modalOffset = max(0, model.modalOffset - 10)
        case .pageDown: model.modalOffset += 10
        case .home: model.modalOffset = 0
        case .end: model.modalOffset = 1_000_000
        default: break
        }
    }
}
