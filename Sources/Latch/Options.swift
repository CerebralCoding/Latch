import Foundation

struct Options {
    enum Command: String {
        case run, wait, status, schedule, sensors, service, view, mcp, update, rollback, `guard`, help
        case list, prioritize, clear, stop, tui
        case version = "--version"
        case about = "--about"
    }

    enum ServiceAction: String { case run, install, start, stop, status, uninstall }

    var command: Command
    var file: String?
    var shared = false
    var timeout: Double?
    var childArguments: [String] = []
    var taskName: String?
    var requirements = TaskRequirements()
    var standalone = false
    var serviceAction: ServiceAction?
    var restartService = false
    var jobID: String?
    var verbose = false
    var json = false
    var refreshInterval: Double?
    var helpCommand: Command?
    var helpServiceAction: ServiceAction?

    init(arguments: [String]) throws {
        guard let first = arguments.first else {
            command = .help
            return
        }
        if ["help", "--help", "-h"].contains(first) {
            command = .help
            if first != "help", arguments.count != 1 {
                throw LatchError("use latch help COMMAND or latch COMMAND --help")
            }
            if arguments.count > 1 {
                guard arguments.count <= 3, let target = Command(rawValue: arguments[1]), target != .help else {
                    throw LatchError("expected a command after help")
                }
                helpCommand = target
                if arguments.count == 3 {
                    guard target == .service, let action = ServiceAction(rawValue: arguments[2]) else {
                        throw LatchError("expected a service action after help service")
                    }
                    helpServiceAction = action
                }
            }
            return
        }
        if first == "--version" {
            guard arguments.count == 1 else { throw LatchError("unexpected arguments after version") }
            command = .version
            return
        }
        if first == "--about" {
            guard arguments.count == 1 else { throw LatchError("unexpected arguments after about") }
            command = .about
            return
        }
        guard let command = Command(rawValue: first) else {
            throw LatchError("unknown command '\(first)'; see latch --help")
        }
        self.command = command
        if command == .schedule || command == .guard {
            requirements.temperatureGuard = TemperatureGuard()
        }
        var index = 1
        if command == .service {
            if arguments.count > 1, ["--help", "-h"].contains(arguments[1]) {
                guard arguments.count == 2 else { throw LatchError("unexpected arguments after service help") }
                self.command = .help
                helpCommand = .service
                return
            }
            guard arguments.count > 1, let action = ServiceAction(rawValue: arguments[1]) else {
                throw LatchError(
                    "service requires run, install, start, stop, status, or uninstall; see latch service --help")
            }
            serviceAction = action
            index = 2
        }
        let valueOptions: Set<String> = [
            "--file", "--timeout", "--name", "--mode", "--cpu", "--memory-mib",
            "--max-cpu-temp", "--max-gpu-temp", "--cooldown", "--interval",
        ]
        var seen: Set<String> = []
        var operandsOnly = false
        while index < arguments.count {
            let raw = arguments[index]
            index += 1
            if !operandsOnly, raw == "--" {
                if command == .run || command == .schedule {
                    childArguments = Array(arguments[index...])
                    break
                }
                operandsOnly = true
                continue
            }
            if operandsOnly || !raw.hasPrefix("-") {
                if command == .run || command == .schedule {
                    throw LatchError("\(command.rawValue) requires -- before the command")
                }
                guard command == .prioritize, jobID == nil, let id = UUID(uuidString: raw) else {
                    throw LatchError("unexpected operand '\(raw)'; see latch \(command.rawValue) --help")
                }
                jobID = id.uuidString
                continue
            }
            let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let argument = String(parts[0])
            let inlineValue = parts.count == 2 ? String(parts[1]) : nil
            if inlineValue != nil, !valueOptions.contains(argument) {
                throw LatchError("option '\(argument)' does not accept a value")
            }
            if !seen.insert(argument).inserted {
                throw LatchError("duplicate option '\(argument)'")
            }
            func optionValue() throws -> String {
                if let inlineValue { return inlineValue }
                guard index < arguments.count, !arguments[index].hasPrefix("--"), arguments[index] != "-h" else {
                    throw LatchError(
                        "\(argument) requires a value; use \(argument)=VALUE for a value beginning with '-'")
                }
                let result = arguments[index]
                index += 1
                return result
            }
            switch argument {
            case "--interval":
                let text = try optionValue()
                guard command == .tui, let value = Double(text), value.isFinite, (0.5...60).contains(value) else {
                    throw LatchError("--interval requires 0.5–60 seconds for tui")
                }
                refreshInterval = value
            case "--help", "-h":
                helpCommand = command
                helpServiceAction = serviceAction
                self.command = .help
                return
            case "--verbose", "--json":
                guard [.view, .sensors, .list, .service].contains(command) else {
                    throw LatchError("\(argument) is only valid for diagnostic commands")
                }
                if argument == "--verbose" { verbose = true } else { json = true }
            case "--file":
                if command == .service, let action = serviceAction, [.start, .stop, .uninstall].contains(action) {
                    throw LatchError("service \(action.rawValue) uses the installed configuration; --file is not valid")
                }
                let path = try optionValue()
                guard ![.sensors, .update, .rollback].contains(command), file == nil, !path.isEmpty
                else {
                    throw LatchError("--file requires one nonempty path")
                }
                file = path
            case "--shared":
                guard command == .run, !shared else {
                    throw LatchError("--shared may be specified once for run")
                }
                shared = true
            case "--timeout":
                let text = try optionValue()
                guard [.run, .wait, .schedule, .guard, .update, .rollback].contains(command), timeout == nil,
                    let value = Double(text), value.isFinite,
                    value >= 0, value <= Double(Int32.max)
                else {
                    throw LatchError(
                        "--timeout requires seconds between 0 and \(Int32.max); cannot combine with --no-wait")
                }
                timeout = value
            case "--restart-service":
                guard [.update, .rollback].contains(command) else {
                    throw LatchError("--restart-service is only valid for update or rollback")
                }
                restartService = true
            case "--no-wait":
                guard [.run, .wait, .schedule, .guard].contains(command), timeout == nil else {
                    throw LatchError("--no-wait cannot be repeated, combined with --timeout, or used with status")
                }
                timeout = 0
            case "--name", "--mode", "--cpu", "--memory-mib":
                guard [.schedule, .guard].contains(command) else {
                    throw LatchError("\(argument) requires a value and is only valid for schedule or guard")
                }
                let value = try optionValue()
                switch argument {
                case "--name":
                    guard !value.isEmpty, value.count <= 128 else {
                        throw LatchError("task name must contain 1–128 characters")
                    }
                    taskName = value
                case "--mode":
                    guard let mode = TaskRequirements.Mode(rawValue: value) else {
                        throw LatchError("mode must be isolated or batch")
                    }
                    requirements.mode = mode
                case "--cpu":
                    guard let count = Int(value) else { throw LatchError("--cpu requires an integer core count") }
                    requirements.cpuCores = count
                default:
                    guard let count = Int(value) else { throw LatchError("--memory-mib requires an integer MiB count") }
                    requirements.memoryMiB = count
                }
            case "--gpu", "--io", "--bandwidth":
                guard command == .schedule else { throw LatchError("\(argument) is only valid for schedule") }
                if argument == "--gpu" {
                    requirements.gpu = true
                }
                if argument == "--io" {
                    requirements.io = true
                }
                if argument == "--bandwidth" {
                    requirements.bandwidth = true
                }
            case "--standalone":
                guard [.schedule, .guard].contains(command) else {
                    throw LatchError("--standalone is only valid for schedule or guard")
                }
                standalone = true
            case "--max-cpu-temp", "--max-gpu-temp", "--cooldown":
                let text = try optionValue()
                guard [.schedule, .guard].contains(command), let value = Double(text), value.isFinite
                else {
                    throw LatchError("\(argument) requires a finite number for schedule or guard")
                }
                if argument == "--max-cpu-temp" {
                    requirements.temperatureGuard?.maxCPU = value
                }
                if argument == "--max-gpu-temp" {
                    requirements.temperatureGuard?.maxGPU = value
                }
                if argument == "--cooldown" {
                    requirements.temperatureGuard?.cooldown = value
                }
            default:
                throw LatchError("unknown option '\(argument)'; see latch \(command.rawValue) --help")
            }
        }
        if command == .run || command == .schedule, childArguments.isEmpty || childArguments[0].isEmpty {
            throw LatchError("\(command.rawValue) requires -- followed by a command")
        }
        if command == .service, verbose || json, serviceAction != .status {
            throw LatchError("--verbose and --json are only valid for service status")
        }
        if verbose && json { throw LatchError("choose --verbose or --json, not both") }
        if command == .prioritize, jobID == nil {
            throw LatchError("prioritize requires one queued job ID from latch list")
        }
        if command == .run {
            requirements.mode = shared ? .batch : .isolated
            requirements.temperatureGuard = TemperatureGuard(maxCPU: 85, maxGPU: 80, cooldown: 0)
        }
        if [.run, .schedule, .guard].contains(command) {
            requirements.measurement = requirements.mode == .isolated
            if command == .run { requirements.measurement = false }
            try requirements.validate()
        }
    }

    func resolvedPath(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        if let path = file ?? environment["LATCH_FILE"] {
            guard !path.isEmpty else { throw LatchError("latch file path must not be empty") }
            return path
        }
        let directory = InstallationPaths().state
        try InstallationPaths.privateDirectory(directory)
        return directory.appendingPathComponent("default.lock").path
    }
}
