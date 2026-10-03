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
            let status = try JSONDecoder().decode(Status.self, from: data)
            guard status.running, let pid = status.pid, pid > 0,
                let revision = status.serviceRevision, revision > 0
            else { throw LatchError("invalid scheduler service metadata", exitCode: 74) }
            return status
        }
    }

    static func requireRunning(in directory: URL) throws -> Int32 {
        let state = try status(in: directory)
        guard state.running, let pid = state.pid, pid > 0 else {
            throw LatchError(
                "scheduler service is not running; use latch service install or latch service run (or --standalone)",
                exitCode: 69)
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
        do { try lock.acquire(shared: false, timeout: 0) } catch let error as LatchError where error.exitCode == 75 {
            throw LatchError("scheduler service is already running for this latch", exitCode: 75)
        }
        try withExtendedLifetime(lock) {
            let jobs = try DurableJobs(scheduler: scheduler)
            let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
                .resolvingSymlinksInPath()
            let watcher = try QueueWatcher(directory: scheduler.directory.path)
            try scheduler.transaction {
                $0.resetCooldowns()
                $0.sensors = nil
                $0.lastSensorAttempt = nil
            }
            let status = Status(
                running: true, pid: getpid(), path: path, serviceRevision: BuildIdentity.serviceRevision)
            try JSONEncoder().encode(status).write(
                to: scheduler.directory.appendingPathComponent("service.json"), options: .atomic)
            while true {
                while waitpid(-1, nil, WNOHANG) > 0 {}
                try jobs.recover(executable: executable)
                let state = try scheduler.snapshot()
                if state.tasks.isEmpty {
                    try scheduler.refreshSensors()
                } else if let next = state.tasks.first(where: { $0.state == .queued }),
                    !state.tasks.contains(where: { $0.state == .running && $0.requirements.mode == .isolated }),
                    !(next.requirements.mode == .isolated && state.tasks.contains(where: { $0.state == .running }))
                {
                    try scheduler.refreshSensors()
                }
                watcher.wait(
                    seconds: state.tasks.isEmpty
                        ? SchedulingPolicy.idleSampleInterval : SchedulingPolicy.sampleInterval,
                    pids: state.tasks.map(\.pid))
            }
        }
    }
}

enum ServiceInstallation {
    static let label = InstallationPaths.serviceIdentifier
    static var paths: InstallationPaths { InstallationPaths() }
    static var executable: URL { paths.executable }
    static var plist: URL { paths.plist }

    static var domain: String {
        "gui/\(getuid())"
    }

    static func configuration(executable: String, path: String, logs: String, label: String = Self.label) -> [String:
        Any]
    {
        [
            "Label": label,
            "ProgramArguments": [executable, "service", "run", "--file", path],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10,
            "ProcessType": "Background",
            "StandardOutPath": logs + "/service.log",
            "StandardErrorPath": logs + "/service-error.log",
        ]
    }

    static func perform(_ action: Options.ServiceAction, path: String, verbose: Bool = false, json: Bool = false) throws
    {
        switch action {
        case .run:
            try SchedulerService.run(path: path)
        case .status:
            let scheduler = try Scheduler(path: path)
            let status = try SchedulerService.status(in: scheduler.directory)
            if json {
                try Latch.printJSON(status)
            } else {
                print(HumanOutput.wrap(HumanOutput.service(status, verbose: verbose), width: HumanOutput.terminalWidth))
            }
            if !status.running {
                throw LatchError("scheduler service is stopped", exitCode: 69)
            }
        case .install:
            let scheduler = try Scheduler(path: path)
            guard try !SchedulerService.status(in: scheduler.directory).running else {
                throw LatchError(
                    "scheduler is already running for this queue; refusing initial installation", exitCode: 75)
            }
            let source = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
                .resolvingSymlinksInPath()
            try ServiceInstall.install(
                source: source, paths: paths, queue: path,
                service: UpdateServiceControl(
                    loaded: isLoaded, revision: { nil }, stop: stopIfLoaded,
                    start: {
                        try launchctl(["bootstrap", domain, plist.path])
                        try waitUntilRunning(path: path)
                    }))
            print("Installed and started \(label)\nCommand: \(executable.path)")
            if !(ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains(
                Substring(executable.deletingLastPathComponent().path))
            {
                print(
                    "Add ~/.local/bin to your shell PATH to run latch by name. MCP hosts use the absolute executable path."
                )
            }
        case .start:
            let installedQueue = try installedPath()
            if try isLoaded() {
                try launchctl(["kickstart", "\(domain)/\(label)"])
            } else {
                try launchctl(["bootstrap", domain, plist.path])
            }
            try waitUntilRunning(path: installedQueue)
            print("Started \(label).")
        case .stop:
            try stopIfLoaded()
            print("Stopped \(label). Accepted jobs are retained.")
        case .uninstall:
            try ServiceInstall.uninstall(paths: paths, stop: stopIfLoaded)
        }
    }

    static func installedPath(paths: InstallationPaths = InstallationPaths()) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.plist.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid()
        else { throw LatchError("service configuration must be a regular file owned by this user", exitCode: 74) }
        let config =
            try PropertyListSerialization.propertyList(from: Data(contentsOf: paths.plist), format: nil)
            as? [String: Any]
        guard let arguments = config?["ProgramArguments"] as? [String], arguments.count == 5,
            config?["Label"] as? String == paths.label,
            arguments[0] == paths.executable.path, Array(arguments[1...3]) == ["service", "run", "--file"],
            arguments[4].hasPrefix("/")
        else {
            throw LatchError("invalid installed service configuration", exitCode: 74)
        }
        return arguments[4]
    }

    static func update(rollback: Bool, timeout: Double, restartService: Bool) throws {
        let path = try installedPath()
        let scheduler = try Scheduler(path: path)
        let source = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        let restarted = try ServiceUpdate.apply(
            source: source, target: executable, updates: paths.updates, scheduler: scheduler, rollback: rollback,
            timeout: timeout, restartService: restartService, expectedIdentifier: InstallationPaths.identifier,
            service: UpdateServiceControl(
                loaded: isLoaded,
                revision: { try SchedulerService.status(in: scheduler.directory).serviceRevision },
                stop: stopIfLoaded,
                start: {
                    try launchctl(["bootstrap", domain, plist.path])
                    try waitUntilRunning(path: path)
                }))
        print(
            "\(rollback ? "Rolled back" : "Updated") \(executable.path)\nService: \(restarted ? "restarted" : "unchanged")\nReconnect MCP hosts before submitting new work; retrieve retained results by job ID."
        )
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
        throw LatchError("service did not start; inspect \(paths.logs.path)/service-error.log", exitCode: 69)
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
