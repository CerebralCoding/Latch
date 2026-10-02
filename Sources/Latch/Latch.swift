import Darwin
import Foundation

struct LatchError: Error, CustomStringConvertible {
    let description: String
    let exitCode: Int32

    init(_ description: String, exitCode: Int32 = 64) {
        self.description = description
        self.exitCode = exitCode
    }

    static func system(_ operation: String) -> LatchError {
        LatchError("\(operation): \(String(cString: strerror(errno)))", exitCode: 74)
    }
}

@main
struct Latch {
    static func main() {
        if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "__mcp_supervisor",
            let lease = Int32(CommandLine.arguments[4]), let activity = Int32(CommandLine.arguments[5])
        {
            exit(
                MCPSupervisor.run(
                    path: CommandLine.arguments[2], id: CommandLine.arguments[3], lease: lease, activity: activity))
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "__mcp_worker" {
            exit(MCPWorker.run(requestPath: CommandLine.arguments[2]))
        }
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.command == .version {
                print(BuildIdentity.version)
                return
            }
            if options.command == .help {
                print(CLIHelp.text(for: options.helpCommand, service: options.helpServiceAction))
                return
            }
            if options.command == .sensors {
                let sensors = try NativeSensors.sample()
                if options.json {
                    try printJSON(sensors)
                } else {
                    print(
                        HumanOutput.wrap(
                            HumanOutput.sensors(sensors, verbose: options.verbose), width: HumanOutput.terminalWidth))
                }
                return
            }
            if options.command == .update || options.command == .rollback {
                try ServiceInstallation.update(
                    rollback: options.command == .rollback, timeout: options.timeout ?? 600,
                    restartService: options.restartService)
                return
            }

            if options.command == .mcp {
                exit(try MCPServer(path: options.resolvedPath()).run())
            }
            let path = try options.resolvedPath()
            if [.list, .prioritize, .clear].contains(options.command) {
                let queue = try OperatorQueue(scheduler: Scheduler(path: path))
                switch options.command {
                case .list:
                    if options.json {
                        try printJSON(SchedulerView(scheduler: queue.scheduler).jobs)
                    } else {
                        print(try queue.list(verbose: options.verbose))
                    }
                case .prioritize:
                    try queue.prioritize(options.jobID!)
                    print("Prioritized \(options.jobID!); admission guards still apply.")
                case .clear:
                    let ids = try queue.clear()
                    print("Cancellation requested for \(ids.count) queued job(s). Already-started work is preserved.")
                default: break
                }
                return
            }
            if options.command == .service {
                try ServiceInstallation.perform(
                    options.serviceAction!, path: path, verbose: options.verbose, json: options.json)
                return
            }
            if options.command == .view || options.command == .tasks {
                let view = try SchedulerView(scheduler: Scheduler(path: path))
                if options.json {
                    try printJSON(view)
                } else if options.command == .tasks {
                    print(HumanOutput.list(view.jobs, verbose: options.verbose))
                } else {
                    print(HumanOutput.view(view, verbose: options.verbose))
                }
                return
            }
            if options.command == .schedule || options.command == .guard {
                let scheduler = try Scheduler(path: path)
                let reservation = try scheduler.reserve(
                    name: options.taskName ?? options.childArguments.first ?? "temperature guard",
                    arguments: options.childArguments,
                    requirements: options.requirements, timeout: options.timeout, useService: !options.standalone,
                )
                defer { try? scheduler.withdraw(reservation.id) }
                try withExtendedLifetime(reservation) {
                    if options.command == .guard {
                        try printJSON(scheduler.snapshot())
                        return
                    }
                    try reservation.inheritAcrossExec()
                    try execute(options.childArguments)
                }
                return
            }
            let latch = try FileLatch(path: path)
            switch options.command {
            case .run:
                let updatePermit = try UpdateDrain.admit(in: Scheduler(path: path).directory)
                defer { withExtendedLifetime(updatePermit) {} }
                try latch.acquire(shared: options.shared, timeout: options.timeout)
                try withExtendedLifetime(latch) {
                    try updatePermit.inheritAcrossExec()
                    try latch.inheritAcrossExec()
                    try execute(options.childArguments)
                }
            case .wait:
                try latch.acquire(shared: true, timeout: options.timeout)
            case .status:
                do {
                    try latch.acquire(shared: false, timeout: 0)
                    print("free")
                } catch let error as LatchError where error.exitCode == 75 {
                    print("held")
                    exit(75)
                }
            case .help, .schedule, .tasks, .sensors, .guard, .service, .view, .mcp, .update, .rollback, .version,
                .list, .prioritize, .clear:
                break
            }
        } catch let error as LatchError {
            FileHandle.standardError.write(Data("latch: \(error)\n".utf8))
            exit(error.exitCode)
        } catch {
            FileHandle.standardError.write(Data("latch: \(error.localizedDescription)\n".utf8))
            exit(74)
        }
    }

    static func printJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    static func execute(_ arguments: [String]) throws {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        defer { for pointer in pointers { free(pointer) } }
        for argument in arguments {
            guard let pointer = strdup(argument) else {
                throw LatchError("out of memory", exitCode: 71)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        pointers.withUnsafeBufferPointer { buffer in
            _ = execvp(buffer[0], buffer.baseAddress!)
        }
        let code: Int32 = errno == ENOENT ? 127 : 126
        throw LatchError("cannot execute \(arguments[0]): \(String(cString: strerror(errno)))", exitCode: code)
    }
}
