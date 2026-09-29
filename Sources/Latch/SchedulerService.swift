import Darwin
import Foundation

enum SchedulerService {
    struct Status: Codable {
        var running: Bool
        var pid: Int32?
        var path: String
        var serviceRevision: Int?
    }

    static func status(in directory: URL) throws -> Status {
        let lock = try FileLatch(path: directory.appendingPathComponent("service.lock").path)
        do {
            try lock.acquire(shared: false, timeout: 0)
            return Status(running: false, path: directory.deletingPathExtension().path)
        } catch let error as LatchError where error.exitCode == 75 {
            let data = try Data(contentsOf: directory.appendingPathComponent("service.json"))
            return try JSONDecoder().decode(Status.self, from: data)
        }
    }

    static func requireRunning(in directory: URL) throws -> Int32 {
        let state = try status(in: directory)
        guard state.running, let pid = state.pid, pid > 0 else {
            throw LatchError("scheduler service is not running; use latch service install or latch service run (or --standalone)", exitCode: 69)
        }
        return pid
    }

    static func run(path: String) throws {
        var sensors: NativeSensors?
        let scheduler = try Scheduler(path: path) {
            if sensors == nil {
                sensors = NativeSensors()
            }
            return try sensors!.read()
        }
        let lock = try FileLatch(path: scheduler.directory.appendingPathComponent("service.lock").path)
        do { try lock.acquire(shared: false, timeout: 0) }
        catch let error as LatchError where error.exitCode == 75 {
            throw LatchError("scheduler service is already running for this latch", exitCode: 75)
        }
        try withExtendedLifetime(lock) {
            let watcher = try QueueWatcher(directory: scheduler.directory.path)
            try scheduler.transaction {
                $0.resetCooldowns()
                $0.sensors = nil
                $0.lastSensorAttempt = nil
            }
            let status = Status(running: true, pid: getpid(), path: path, serviceRevision: BuildIdentity.serviceRevision)
            try JSONEncoder().encode(status).write(to: scheduler.directory.appendingPathComponent("service.json"), options: .atomic)
            while true {
                let state = try scheduler.snapshot()
                if let next = state.tasks.first(where: { $0.state == .queued }),
                   !state.tasks.contains(where: { $0.state == .running && $0.requirements.mode == .isolated }),
                   !(next.requirements.mode == .isolated && state.tasks.contains(where: { $0.state == .running }))
                {
                    try scheduler.refreshSensors()
                }
                watcher.wait(seconds: state.tasks.isEmpty ? 3600 : SchedulingPolicy.sampleInterval, pids: state.tasks.map(\.pid))
            }
        }
    }
}

enum ServiceInstallation {
    static let label = "dev.latch.scheduler"
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Latch")
    }

    static var executable: URL {
        root.appendingPathComponent("bin/latch")
    }

    static var commandLink: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/latch")
    }

    static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var domain: String {
        "gui/\(getuid())"
    }

    static func configuration(executable: String, path: String, logs: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable, "service", "run", "--file", path],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10,
            "ProcessType": "Background",
            "StandardOutPath": logs + "/service.log",
            "StandardErrorPath": logs + "/service-error.log",
        ]
    }

    static func perform(_ action: Options.ServiceAction, path: String) throws {
        switch action {
        case .run:
            try SchedulerService.run(path: path)
        case .status:
            let scheduler = try Scheduler(path: path)
            let status = try SchedulerService.status(in: scheduler.directory)
            try Latch.printJSON(status)
            if !status.running {
                throw LatchError("scheduler service is stopped", exitCode: 69)
            }
        case .install:
            let manager = FileManager.default
            guard !manager.fileExists(atPath: executable.path), !manager.fileExists(atPath: plist.path) else {
                throw LatchError("Latch is already installed; run the new binary with update (or service start to start it)")
            }
            try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            let logs = root.appendingPathComponent("logs")
            try manager.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Stage the new executable before stopping the service; rename preserves running processes.
            let source = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
            let staged = executable.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            defer { try? manager.removeItem(at: staged) }
            try manager.copyItem(at: source, to: staged)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            let data = try PropertyListSerialization.data(fromPropertyList: configuration(executable: executable.path, path: URL(fileURLWithPath: path).standardizedFileURL.path, logs: logs.path), format: .xml, options: 0)
            try installCommandLink(at: commandLink, target: executable)
            try stopIfLoaded()
            guard rename(staged.path, executable.path) == 0 else { throw LatchError.system("install executable") }
            try data.write(to: plist, options: .atomic)
            try launchctl(["bootstrap", domain, plist.path])
            try waitUntilRunning(path: path)
            print("Installed and started \(label)\nCommand: \(commandLink.path)")
            if !(ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains(Substring(commandLink.deletingLastPathComponent().path)) {
                print("Add ~/.local/bin to your shell and agent PATH to run latch by name.")
            }
        case .start:
            let config = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
            guard let arguments = config?["ProgramArguments"] as? [String], arguments.count == 5,
                  Array(arguments[1 ... 3]) == ["service", "run", "--file"]
            else {
                throw LatchError("invalid installed service configuration; run service install", exitCode: 74)
            }
            if try isLoaded() {
                try launchctl(["kickstart", "\(domain)/\(label)"])
            } else {
                try launchctl(["bootstrap", domain, plist.path])
            }
            try waitUntilRunning(path: arguments[4])
        case .stop:
            try stopIfLoaded()
        case .uninstall:
            try stopIfLoaded()
            try removeCommandLink(at: commandLink, target: executable)
            if FileManager.default.fileExists(atPath: plist.path) {
                try FileManager.default.removeItem(at: plist)
            }
            if FileManager.default.fileExists(atPath: executable.path) {
                try FileManager.default.removeItem(at: executable)
            }
        }
    }

    static func installedPath() throws -> String {
        let config = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        guard let arguments = config?["ProgramArguments"] as? [String], arguments.count == 5,
              arguments[0] == executable.path, Array(arguments[1 ... 3]) == ["service", "run", "--file"],
              arguments[4].hasPrefix("/")
        else {
            throw LatchError("invalid installed service configuration", exitCode: 74)
        }
        return arguments[4]
    }

    static func update(rollback: Bool, timeout: Double, restartService: Bool) throws {
        let path = try installedPath()
        let scheduler = try Scheduler(path: path)
        let source = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let restarted = try ServiceUpdate.apply(source: source, target: executable, scheduler: scheduler, rollback: rollback,
                                                timeout: timeout, restartService: restartService,
                                                service: UpdateServiceControl(loaded: isLoaded,
                                                                              revision: { try SchedulerService.status(in: scheduler.directory).serviceRevision },
                                                                              stop: stopIfLoaded,
                                                                              start: {
                                                                                  try launchctl(["bootstrap", domain, plist.path])
                                                                                  try waitUntilRunning(path: path)
                                                                              }))
        print("\(rollback ? "Rolled back" : "Updated") \(executable.path)\nService: \(restarted ? "restarted" : "unchanged")\nRetrieve retained results, then reconnect MCP hosts before submitting new work.")
    }

    static func installCommandLink(at link: URL, target: URL) throws {
        let manager = FileManager.default
        if (try? manager.destinationOfSymbolicLink(atPath: link.path)) == target.path {
            return
        }
        try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try manager.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        } catch CocoaError.fileWriteFileExists {
            throw LatchError("refusing to replace existing command at \(link.path)", exitCode: 74)
        }
    }

    static func removeCommandLink(at link: URL, target: URL) throws {
        let manager = FileManager.default
        if (try? manager.destinationOfSymbolicLink(atPath: link.path)) == target.path {
            try manager.removeItem(at: link)
        }
    }

    private static func waitUntilRunning(path: String) throws {
        let scheduler = try Scheduler(path: path)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if (try? SchedulerService.requireRunning(in: scheduler.directory)) != nil {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw LatchError("service did not start; inspect \(root.path)/logs/service-error.log", exitCode: 69)
    }

    private static func isLoaded() throws -> Bool {
        try invoke(["print", "\(domain)/\(label)"], quiet: true) == 0
    }

    private static func stopIfLoaded() throws {
        if try isLoaded() {
            try launchctl(["bootout", "\(domain)/\(label)"])
        }
    }

    private static func launchctl(_ arguments: [String]) throws {
        let status = try invoke(arguments, quiet: false)
        guard status == 0 else { throw LatchError("launchctl \(arguments[0]) failed (\(status))", exitCode: 69) }
    }

    private static func invoke(_ arguments: [String], quiet: Bool) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        if quiet {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
